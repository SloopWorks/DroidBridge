import AppKit
import CryptoKit
import DroidBridgeCore
import DroidBridgeStreaming

@main struct VerifyDesktopNative {
    @MainActor static func main() {
        let app = NSApplication.shared
        Task { @MainActor in
            do { try await run(); print("DESKTOP NATIVE PASS"); exit(0) }
            catch { fputs("DESKTOP NATIVE FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    @MainActor static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let serial = env["DROIDBRIDGE_TEST_SERIAL"] ?? "emulator-5580"
        guard ["emulator-5580", "emulator-5582"].contains(serial) else { throw BridgeError.message("Only dedicated test emulator is allowed") }
        let tools = Toolchain(), device = AndroidDevice(serial: serial, model: "Desktop verification")
        func adb(_ args: [String]) async throws -> String { try await ProcessRunner.run(tools.adb, arguments: ["-s", serial] + args).output }
        let api = try await adb(["shell", "getprop", "ro.build.version.sdk"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/verification/desktop-mode/api" + api)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try await adb(["logcat", "-c"])
        func ownedForwardLines(_ output: String) -> Set<String> { Set(output.split(separator: "\n").map(String.init).filter { $0.hasPrefix(serial + " ") }) }
        let beforeForwards = ownedForwardLines(try await adb(["forward", "--list"]))
        let beforeDisplay = try await adb(["shell", "dumpsys", "display"])
        var results: [[String: Any]] = []
        func png(_ image: CGImage?, _ name: String) throws {
            guard let image, let out = CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil) else { throw BridgeError.message("Missing decoded frame") }
            CGImageDestinationAddImage(out, image, nil)
            guard CGImageDestinationFinalize(out) else { throw BridgeError.message("Cannot encode frame") }
        }
        for decorations in [true, false] {
            let label = decorations ? "decorated" : "desktop"
            let session = BridgeSession(descriptor: SessionDescriptor(device: device, application: AndroidApplication(packageName: "dev.droidbridge.testapp", name: "Desktop input probe"), configuration: SessionConfiguration(backend: .native, showSystemDecorations: decorations)), toolchain: tools)
            var latest: CGImage?, hashes = Set<Data>()
            session.onFrame = { latest = $0; if let bytes = $0.dataProvider?.data { hashes.insert(Data(SHA256.hash(data: bytes as Data))) } }
            defer { session.stop(reason: "desktop_verification_defer") }
            try await session.start()
            try await Task.sleep(nanoseconds: 900_000_000)
            try png(latest, "native-\(label)-before.png")
            let display = try await adb(["shell", "dumpsys", "display"])
            let windows = try await adb(["shell", "dumpsys", "window", "displays"])
            try display.write(to: root.appendingPathComponent("native-\(label)-display.txt"), atomically: true, encoding: .utf8)
            try windows.write(to: root.appendingPathComponent("native-\(label)-windows.txt"), atomically: true, encoding: .utf8)
            func tap(_ x: Int, _ y: Int, width: Int = 720, height: Int = 1080) {
                for action: UInt8 in [0, 1] { session.sendInput(.touch(action: action, x: x, y: y, width: width, height: height)) }
            }
            tap(300, 210); tap(300, 280)
            let word = decorations ? "DesktopDecorated" : "DesktopClean"
            session.sendInput(.text(word))
            var input = ""
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 200_000_000)
                input = try await adb(["logcat", "-d", "-s", "DroidBridgeProbe:I", "*:S"])
                if input.contains("text=" + word) { break }
            }
            try png(latest, "native-\(label)-input.png")
            guard input.contains("click="), input.contains("text=" + word) else { throw BridgeError.message("Native input missing for \(label): \(input)") }
            func isMainProbe(_ image: CGImage?) -> Bool {
                guard let image, let pixel = image.cropping(to: CGRect(x: 0, y: 500, width: 1, height: 1)) else { return false }
                var bytes = [UInt8](repeating: 0, count: 4)
                guard let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return Int(bytes[2]) > Int(bytes[0]) + 10
            }
            tap(300, 345)
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 200_000_000)
                if !isMainProbe(latest) { break }
            }
            let secondary = try await adb(["logcat", "-d", "-s", "DroidBridgeProbe:I", "*:S"])
            guard secondary.contains("secondary display=") else { throw BridgeError.message("No secondary activity") }
            try png(latest, "native-\(label)-secondary.png")
            session.sendInput(.back)
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 200_000_000)
                if isMainProbe(latest) { break }
            }
            try png(latest, "native-\(label)-after-back.png")
            let backReturned = isMainProbe(latest)
            if !backReturned {
                try await adb(["shell", "dumpsys", "input"]).write(to: root.appendingPathComponent("native-\(label)-back-input-focus.txt"), atomically: true, encoding: .utf8)
                // Keep Back failure distinct from the display-flag verification.
                // The fixture's visible Return button is an independent pointer
                // path to MainActivity, with the result recorded explicitly.
                tap(300, 177)
                for _ in 0..<30 {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    if isMainProbe(latest) { break }
                }
                try png(latest, "native-\(label)-after-return-button.png")
                guard isMainProbe(latest) else { throw BridgeError.message("Neither Back nor fixture Return button returned to probe") }
            }
            let beforeResize = session.metrics.frames
            session.resize(width: 896, height: 640)
            for _ in 0..<80 {
                if latest?.width == 896 && latest?.height == 640 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard latest?.width == 896, latest?.height == 640, session.metrics.frames > beforeResize else { throw BridgeError.message("Adaptive resize failed") }
            try await Task.sleep(nanoseconds: 750_000_000)
            try png(latest, "native-\(label)-resized-before-input.png")
            tap(400, 210, width: 896, height: 640)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try png(latest, "native-\(label)-resized.png")
            let receipts = try await adb(["logcat", "-d", "-s", "DroidBridgeProbe:I", "*:S"])
            guard receipts.components(separatedBy: "click=").count > input.components(separatedBy: "click=").count else { throw BridgeError.message("No new click after resize") }
            try receipts.write(to: root.appendingPathComponent("native-\(label)-input.log"), atomically: true, encoding: .utf8)
            guard hashes.count > 3 else { throw BridgeError.message("Frames did not change") }
            let log = try String(contentsOf: session.logURL, encoding: .utf8)
            try log.write(to: root.appendingPathComponent("native-\(label)-session.log"), atomically: true, encoding: .utf8)
            results.append(["decorations": decorations, "frames": session.metrics.frames, "differentFrameHashes": hashes.count, "resize": "896x640", "mouseKeyboard": true, "backReturned": backReturned, "fixtureReturnButtonUsed": !backReturned])
            await session.stopAndWait()
            let settings = BridgeSession(descriptor: SessionDescriptor(device: device, application: AndroidApplication(packageName: "com.android.settings", name: "Settings"), configuration: SessionConfiguration(backend: .native, showSystemDecorations: decorations)), toolchain: tools)
            var settingsFrame: CGImage?
            settings.onFrame = { settingsFrame = $0 }
            try await settings.start()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try png(settingsFrame, "native-\(label)-settings.png")
            await settings.stopAndWait()
            _ = try await adb(["logcat", "-c"])
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        guard ownedForwardLines(try await adb(["forward", "--list"])) == beforeForwards else { throw BridgeError.message("Owned forwards not cleaned") }
        let afterDisplay = try await adb(["shell", "dumpsys", "display"])
        guard beforeDisplay.components(separatedBy: "DisplayDeviceInfo{").count == afterDisplay.components(separatedBy: "DisplayDeviceInfo{").count else { throw BridgeError.message("Display count not restored") }
        try JSONSerialization.data(withJSONObject: ["serial": serial, "api": api, "backend": "native", "results": results, "cleanup": true], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("native-results.json"))
    }
}
