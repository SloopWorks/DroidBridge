import XCTest
import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@testable import DroidBridgeStreaming
import DroidBridgeCore

final class StreamingTests: XCTestCase {
    func testWireMessagesMatchPinnedScrcpy() {
        let touch = ScrcpyControl.encode(.touch(action:0,x:12,y:34,width:720,height:1080))
        XCTAssertEqual(touch.count,32); XCTAssertEqual(touch[0],2)
        XCTAssertEqual(touch.number(10,4),12); XCTAssertEqual(touch.number(14,4),34)
        XCTAssertEqual(touch.number(18,2),720); XCTAssertEqual(touch.number(20,2),1080)
        XCTAssertEqual(touch.number(2,8),UInt64.max-1)
        XCTAssertEqual(ScrcpyControl.resize(width:800,height:600),Data([21,3,32,2,88]))
        XCTAssertEqual(ScrcpyControl.encode(.key(action:0,keycode:66,metastate:0)).count,14)
        XCTAssertEqual(ScrcpyControl.encode(.scroll(x:0,y:0,width:720,height:1080,horizontal:0,vertical:1)).count,21)
    }
    func testUnicodeLimitDoesNotSplitCodePoint() {
        let message = ScrcpyControl.encode(.text(String(repeating:"🙂",count:100)))
        XCTAssertEqual(message.count,305); XCTAssertNotNil(String(data:message.dropFirst(5),encoding:.utf8))
    }
    func testAnnexBUnits() {
        XCTAssertEqual(H264Decoder.nalUnits(Data([0,0,0,1,0x67,1,2,0,0,1,0x68,3])),[Data([0x67,1,2]),Data([0x68,3])])
    }
    @MainActor
    func testActualNativeConcurrentStreams() async throws {
        guard ProcessInfo.processInfo.environment["DROIDBRIDGE_INTEGRATION"] == "1" else { throw XCTSkip("Set DROIDBRIDGE_INTEGRATION=1 with emulator-5580 running") }
        let tools = Toolchain()
        let device = AndroidDevice(serial:ProcessInfo.processInfo.environment["DROIDBRIDGE_TEST_SERIAL"] ?? "emulator-5580",model:"Pixel API35")
        let root = URL(fileURLWithPath:ProcessInfo.processInfo.environment["DROIDBRIDGE_EVIDENCE"] ?? FileManager.default.currentDirectoryPath + "/verification/streaming")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        func adb(_ args:[String]) async throws -> String { try await ProcessRunner.run(tools.adb,arguments:["-s",device.serial]+args,environment:tools.environment).output }
        _ = try await adb(["forward","--list"])
        _ = try await adb(["logcat","-c"])
        let a = BridgeSession(descriptor:SessionDescriptor(device:device,application:AndroidApplication(packageName:"dev.droidbridge.testapp",name:"Probe"),configuration:SessionConfiguration(width:720,height:1080,backend:.native)),toolchain:tools)
        let b = BridgeSession(descriptor:SessionDescriptor(device:device,application:AndroidApplication(packageName:"dev.droidbridge.testapp2",name:"Probe 2"),configuration:SessionConfiguration(width:720,height:1080,backend:.native)),toolchain:tools)
        defer { a.stop(); b.stop() }
        var latestA: CGImage?; var latestB: CGImage?; var signatures = Set<Data>()
        a.onState = { state,error in print("PROBE A \(state): \(error ?? "")") }
        b.onState = { state,error in print("PROBE B \(state): \(error ?? "")") }
        a.onFrame = { image in latestA = image; if let bytes = image.dataProvider?.data { signatures.insert(Data(SHA256.hash(data:bytes as Data))) } }
        b.onFrame = { image in latestB = image }
        try await a.start(); try await b.start()
        let ownedEndpoints = [a.forwardedEndpoint,b.forwardedEndpoint].compactMap { $0 }
        for _ in 0..<200 { if a.metrics.frames > 20 && b.metrics.frames > 2 { break }; try await Task.sleep(nanoseconds:100_000_000) }
        XCTAssertGreaterThan(a.metrics.frames,20); XCTAssertGreaterThan(b.metrics.frames,2)
        func png(_ image:CGImage?,_ name:String) throws {
            guard let image, let destination = CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL,UTType.png.identifier as CFString,1,nil) else { XCTFail("Missing actual decoded image"); return }
            CGImageDestinationAddImage(destination,image,nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        try png(latestA,"native-probe-before.png"); try png(latestB,"native-probe2-before.png")
        XCTAssertGreaterThan(signatures.count,3,"Changing probe content must produce distinct decoded frames")
        if let fa = latestA?.dataProvider?.data, let fb = latestB?.dataProvider?.data { XCTAssertNotEqual(SHA256.hash(data:fa as Data),SHA256.hash(data:fb as Data)) }
        // Positions are expressed in actual decoded frame pixels (720x1080).
        for action:UInt8 in [0,1] { a.sendInput(.touch(action:action,x:300,y:225,width:720,height:1080)) }
        try await Task.sleep(nanoseconds:500_000_000)
        for action:UInt8 in [0,1] { a.sendInput(.touch(action:action,x:260,y:295,width:720,height:1080)) }
        for session in [a] { session.sendInput(.key(action:0,keycode:29,metastate:0x1000)); session.sendInput(.key(action:1,keycode:29,metastate:0x1000)); session.sendInput(.key(action:0,keycode:67,metastate:0)); session.sendInput(.key(action:1,keycode:67,metastate:0)) }
        a.sendInput(.text("DroidBridgeNative"))
        for action:UInt8 in [0,1] { b.sendInput(.touch(action:action,x:300,y:225,width:720,height:1080)) }
        for action:UInt8 in [0,1] { b.sendInput(.touch(action:action,x:260,y:295,width:720,height:1080)) }
        b.sendInput(.key(action:0,keycode:29,metastate:0x1000)); b.sendInput(.key(action:1,keycode:29,metastate:0x1000)); b.sendInput(.key(action:0,keycode:67,metastate:0)); b.sendInput(.key(action:1,keycode:67,metastate:0))
        b.sendInput(.text("IndependentB"))
        try await Task.sleep(nanoseconds:1_500_000_000)
        let inputLog = try await adb(["logcat","-d","-s","DroidBridgeProbe:I","*:S"])
        try inputLog.write(to:root.appendingPathComponent("native-input.log"),atomically:true,encoding:.utf8)
        print(inputLog)
        try png(latestA,"native-probe-after.png"); try png(latestB,"native-probe2-after.png")
        XCTAssertTrue(inputLog.contains("text=IndependentB"))
        func displayID(_ marker:String) -> String? { inputLog.components(separatedBy:"\n").first { $0.contains(marker) }?.components(separatedBy:"display=").last }
        let displayA = displayID("text=DroidBridgeNative"); let displayB = displayID("text=IndependentB")
        XCTAssertNotNil(displayA); XCTAssertNotNil(displayB); XCTAssertNotEqual(displayA,displayB,"Input must be routed to independent virtual displays")
        XCTAssertTrue(inputLog.contains("click="),"Mouse input must reach Android test app")
        XCTAssertTrue(inputLog.contains("text=DroidBridgeNative"),"Keyboard input must reach Android test app")
        let framesBeforeSecondary = b.metrics.frames
        for action:UInt8 in [0,1] { b.sendInput(.touch(action:action,x:300,y:365,width:720,height:1080)) }
        try await Task.sleep(nanoseconds:750_000_000)
        let activityLog = try await adb(["logcat","-d","-s","DroidBridgeProbe:I","*:S"])
        XCTAssertTrue(activityLog.contains("secondary display=" + (displayB ?? "invalid") + " package=dev.droidbridge.testapp2"),"Secondary activity must remain on the same virtual display")
        try activityLog.write(to:root.appendingPathComponent("native-secondary-activity.log"),atomically:true,encoding:.utf8)
        try png(latestB,"native-secondary-activity.png")
        b.sendInput(.back); try await Task.sleep(nanoseconds:500_000_000)
        XCTAssertGreaterThan(b.metrics.frames,framesBeforeSecondary)
        let framesBefore = a.metrics.frames
        a.resize(width:896,height:640)
        for _ in 0..<100 { if latestA?.width == 896 && latestA?.height == 640 { break }; try await Task.sleep(nanoseconds:100_000_000) }
        XCTAssertEqual(a.metrics.width,896); XCTAssertEqual(a.metrics.height,640)
        XCTAssertGreaterThan(a.metrics.frames,framesBefore)
        try await Task.sleep(nanoseconds:750_000_000)
        try png(latestA,"native-probe-resized.png")
        // After resize, Android layout coordinates move with the new dimensions.
        // The top text/button region retains its density; press the new button
        // center and verify it still targets the same virtual display.
        for action:UInt8 in [0,1] { a.sendInput(.touch(action:action,x:400,y:225,width:896,height:640)) }
        try await Task.sleep(nanoseconds:500_000_000)
        let resizedInput = try await adb(["logcat","-d","-s","DroidBridgeProbe:I","*:S"])
        func clicks(_ log:String) -> Int { log.components(separatedBy:"\n").filter { $0.contains("display=" + (displayA ?? "invalid")) }.compactMap { line in line.components(separatedBy:"click=").dropFirst().first?.components(separatedBy:" ").first.flatMap(Int.init) }.count }
        XCTAssertGreaterThan(clicks(resizedInput),clicks(inputLog),"Resized input must still reach probe")
        try resizedInput.write(to:root.appendingPathComponent("native-resized-input.log"),atomically:true,encoding:.utf8)
        XCTAssertEqual(b.metrics.width,720); XCTAssertEqual(b.metrics.height,1080)
        let report = "Distinct probe frame hashes=\(signatures.count)\nA frames=\(a.metrics.frames) bytes=\(a.metrics.bytes) size=\(a.metrics.width)x\(a.metrics.height)\nB frames=\(b.metrics.frames) bytes=\(b.metrics.bytes) size=\(b.metrics.width)x\(b.metrics.height)\n"
        try report.write(to:root.appendingPathComponent("native-metrics.txt"),atomically:true,encoding:.utf8)
        await a.stopAndWait(); await b.stopAndWait()
        let settings = BridgeSession(descriptor:SessionDescriptor(device:device,application:AndroidApplication(packageName:"com.android.settings",name:"Settings"),configuration:SessionConfiguration(width:720,height:1080,backend:.native)),toolchain:tools)
        var latestSettings: CGImage?; settings.onFrame = { latestSettings = $0 }
        try await settings.start(); try await Task.sleep(nanoseconds:4_000_000_000)
        try png(latestSettings,"native-settings.png"); await settings.stopAndWait()
        try await Task.sleep(nanoseconds:3_000_000_000)
        let after = try await adb(["forward","--list"])
        for endpoint in ownedEndpoints { XCTAssertFalse(after.components(separatedBy:.newlines).contains { $0.split(separator:" ").dropFirst().first.map(String.init) == endpoint },"Owned ADB forward must be removed: \(endpoint)") }
    }
}
