import AppKit
import Foundation
import CryptoKit
import DroidBridgeCore
import DroidBridgeStreaming

/// Uses the shipping NativeWindow.swift view/controller, real decoded frames,
/// NSWindow event dispatch, and Android logcat receipts. No screen-capture permission.
@main
struct AppKitVerification {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); print("APPKIT VERIFICATION PASS"); exit(0) }
            catch { fputs("APPKIT VERIFICATION FAIL: \(error)\n",stderr); exit(1) }
        }
        app.run()
    }
    @MainActor static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let serial = env["DROIDBRIDGE_TEST_SERIAL"] ?? "emulator-5580"
        guard serial != "emulator-5554" else { throw BridgeError.message("Refusing user's emulator") }
        let root = URL(fileURLWithPath: env["DROIDBRIDGE_EVIDENCE"] ?? FileManager.default.currentDirectoryPath + "/verification/review/appkit")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let tools = Toolchain()
        let device = AndroidDevice(serial: serial, model: "QA dedicated emulator")
        func adb(_ args: [String]) async throws -> String { try await ProcessRunner.run(tools.adb, arguments: ["-s",serial] + args, environment: tools.environment).output }
        let baseline = try await adb(["forward","--list"])
        _ = try await adb(["logcat","-c"])
        let probe = BridgeSession(descriptor: SessionDescriptor(device:device,application:AndroidApplication(packageName:"dev.droidbridge.testapp",name:"QA Probe"),configuration:SessionConfiguration(backend:.native)),toolchain:tools)
        let settings = BridgeSession(descriptor: SessionDescriptor(device:device,application:AndroidApplication(packageName:"com.android.settings",name:"QA Settings"),configuration:SessionConfiguration(backend:.native)),toolchain:tools)
        let first = NativeWindowController(session:probe)
        let second = NativeWindowController(session:settings)
        first.video.input = { event in print("APPKIT INPUT \(event)"); probe.sendInput(event) }
        defer { probe.stop(); settings.stop(); first.close(); second.close() }
        first.showWindow(nil); second.showWindow(nil)
        try await probe.start(); try await settings.start()
        try await wait("two live AppKit views") { first.video.frameImage != nil && second.video.frameImage != nil && probe.metrics.frames > 6 && settings.metrics.frames > 1 }
        guard first.window !== second.window, first.window?.isVisible == true, second.window?.isVisible == true else { throw BridgeError.message("Expected distinct visible NSWindows") }
        func capture(_ controller: NativeWindowController, _ name: String) throws -> Data {
            let view = controller.video
            view.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw BridgeError.message("View bitmap unavailable") }
            view.cacheDisplay(in:view.bounds,to:bitmap)
            guard let png = bitmap.representation(using:.png,properties:[:]) else { throw BridgeError.message("Cannot encode AppKit draw") }
            try png.write(to:root.appendingPathComponent(name))
            return Data(SHA256.hash(data:png))
        }
        let before = try capture(first,"appkit-probe-before.png")
        let other = try capture(second,"appkit-settings.png")
        second.window?.makeKeyAndOrderFront(nil)
        for (kind,y) in [(NSEvent.EventType.leftMouseDown,850),(.leftMouseDragged,700),(.leftMouseDragged,550),(.leftMouseDragged,400),(.leftMouseUp,300)] {
            try pointer(second,kind:kind,x:360,y:y)
            try await Task.sleep(nanoseconds:100_000_000)
        }
        try await Task.sleep(nanoseconds:500_000_000)
        let dragged = try capture(second,"appkit-settings-after-drag.png")
        guard dragged != other else { throw BridgeError.message("NSWindow drag did not change Android Settings content") }
        settings.sendInput(.scroll(x:360,y:500,width:720,height:1080,horizontal:0,vertical:4))
        try await Task.sleep(nanoseconds:500_000_000)
        let scrolled = try capture(second,"appkit-settings-after-scroll.png")
        guard dragged != scrolled else { throw BridgeError.message("Android scroll injection did not change Settings content") }
        guard before != other else { throw BridgeError.message("Independent apps rendered equal pixels") }
        first.window?.miniaturize(nil)
        try await Task.sleep(nanoseconds:100_000_000)
        guard first.window?.isMiniaturized == true else { throw BridgeError.message("Standard minimize failed") }
        first.window?.deminiaturize(nil)
        first.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        first.window?.makeFirstResponder(first.video)
        try await Task.sleep(nanoseconds:200_000_000)
        try click(first,x:300,y:225)
        try click(first,x:260,y:295)
        let word = "AppKitQA"
        guard let key = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:first.window!.windowNumber,context:nil,characters:word,charactersIgnoringModifiers:word,isARepeat:false,keyCode:0) else { throw BridgeError.message("Cannot construct keyboard event") }
        first.window!.sendEvent(key)
        try await Task.sleep(nanoseconds:1_000_000_000)
        let log = try await adb(["logcat","-d","-s","DroidBridgeProbe:I","*:S"])
        try log.write(to:root.appendingPathComponent("appkit-input.log"),atomically:true,encoding:.utf8)
        guard log.contains("click=1"), log.contains("text=AppKitQA") else { throw BridgeError.message("NSWindow input missing Android receipts: \(log)") }
        let after = try capture(first,"appkit-probe-after.png")
        guard before != after else { throw BridgeError.message("Rendered view never changed") }
        for size in [NSSize(width:500,height:550), NSSize(width:700,height:400), NSSize(width:400,height:700), NSSize(width:640,height:440)] {
            first.window!.setContentSize(size)
            try await Task.sleep(nanoseconds:40_000_000)
        }
        try await wait("adaptive resize") { first.video.frameImage?.width == 960 && first.video.frameImage?.height == 656 }
        _ = try capture(first,"appkit-probe-resized-before-input.png")
        try await Task.sleep(nanoseconds:1_500_000_000)
        _ = try capture(first,"appkit-probe-resized-stable.png")
        print("RESIZED actual \(first.video.frameImage!.width)x\(first.video.frameImage!.height) bounds=\(first.video.bounds)")
        _ = try await adb(["logcat","-c"])
        try click(first,x:400,y:225)
        try await Task.sleep(nanoseconds:500_000_000)
        let resized = try await adb(["logcat","-d","-s","DroidBridgeProbe:I","*:S"])
        try resized.write(to:root.appendingPathComponent("appkit-resized-input.log"),atomically:true,encoding:.utf8)
        guard resized.contains("click=1") else { throw BridgeError.message("Input after AppKit resize failed") }
        _ = try capture(first,"appkit-probe-resized.png")
        let report = "Two distinct visible NSWindows; actual rendered PNGs unequal and changing.\nNSWindow mouse/key dispatch produced Android click/text receipts.\nNSWindow drag and Android scroll changed Settings content.\nStandard minimize/restore and rapid resize coalescing succeeded.\nNative frame sizes after resize: \(probe.metrics.width)x\(probe.metrics.height).\nProbe frames=\(probe.metrics.frames), Settings frames=\(settings.metrics.frames).\n"
        try report.write(to:root.appendingPathComponent("results.txt"),atomically:true,encoding:.utf8)
        await probe.stopAndWait(); await settings.stopAndWait(); first.close(); second.close()
        try await Task.sleep(nanoseconds:3_000_000_000)
        guard try await adb(["forward","--list"]) == baseline else { throw BridgeError.message("Leaked ADB forward") }
        print(report)
    }
    @MainActor static func wait(_ label:String, until condition:() -> Bool) async throws {
        for _ in 0..<150 { if condition() { return }; try await Task.sleep(nanoseconds:100_000_000) }
        throw BridgeError.message("Timed out: \(label)")
    }
    @MainActor static func click(_ host:NativeWindowController,x:Int,y:Int) throws {
        for kind:NSEvent.EventType in [.leftMouseDown,.leftMouseUp] { try pointer(host,kind:kind,x:x,y:y) }
    }
    @MainActor static func pointer(_ host:NativeWindowController,kind:NSEvent.EventType,x:Int,y:Int) throws {
        guard let image = host.video.frameImage, let window = host.window else { throw BridgeError.message("Cannot click without video") }
        let rect = host.video.videoRect
        let inView = NSPoint(x:rect.minX + CGFloat(x)/CGFloat(image.width)*rect.width,y:rect.minY + CGFloat(y)/CGFloat(image.height)*rect.height)
        let point = host.video.convert(inView,to:nil)
        guard let event = NSEvent.mouseEvent(with:kind,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1) else { throw BridgeError.message("Cannot construct mouse event") }
        window.sendEvent(event)
    }
}
