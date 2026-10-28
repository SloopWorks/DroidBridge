import XCTest
@testable import DroidBridgeCore

final class DeviceReadinessTests: XCTestCase {
    func testBootReadinessProgressesWithoutLosingIntent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let adb = folder.appendingPathComponent("adb")
        let script = "#!/bin/sh\nif [ \"$4\" = getprop ]; then cat \"$(dirname \"$0\")/boot\"; else cat \"$(dirname \"$0\")/package\"; fi\n"
        try script.write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let tools = Toolchain(adb: adb.path), device = AndroidDevice(serial: "emulator-5580", model: "Test")
        try "0\n".write(to: folder.appendingPathComponent("boot"), atomically: true, encoding: .utf8)
        try "cmd: Can't find service: package\n".write(to: folder.appendingPathComponent("package"), atomically: true, encoding: .utf8)
        var ready = await DeviceReadiness.isReady(device: device, toolchain: tools)
        XCTAssertFalse(ready)
        try "1\n".write(to: folder.appendingPathComponent("boot"), atomically: true, encoding: .utf8)
        ready = await DeviceReadiness.isReady(device: device, toolchain: tools)
        XCTAssertFalse(ready, "boot property alone cannot establish package-service readiness")
        try "package:/system/framework/framework-res.apk\n".write(to: folder.appendingPathComponent("package"), atomically: true, encoding: .utf8)
        ready = await DeviceReadiness.isReady(device: device, toolchain: tools)
        XCTAssertTrue(ready)
    }
    func testProbeTimeoutAndFiniteRetryCadence() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let adb = folder.appendingPathComponent("adb")
        try "#!/bin/sh\nexec /bin/sleep 10\n".write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let start = Date()
        let ready = await DeviceReadiness.isReady(device: AndroidDevice(serial: "test", model: "Test"), toolchain: Toolchain(adb: adb.path), timeout: 0.1)
        XCTAssertFalse(ready); XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        var retry = ReconnectRetry()
        XCTAssertFalse(retry.admits(intentPresent: true, ready: false, enabled: true, now: start))
        XCTAssertFalse(retry.admits(intentPresent: true, ready: true, enabled: false, now: start))
        XCTAssertTrue(retry.admits(intentPresent: true, ready: true, enabled: true, now: start))
        XCTAssertFalse(retry.admits(intentPresent: false, ready: true, enabled: true, now: start), "Closing an intent cancels even a previously captured retry candidate")
        for failure in 0..<3 {
            let time = start.addingTimeInterval(Double(failure) * 8)
            retry.failed(at: time)
            XCTAssertFalse(retry.admits(intentPresent: true, ready: true, enabled: true, now: time.addingTimeInterval(7.9)))
        }
        XCTAssertFalse(retry.admits(intentPresent: true, ready: true, enabled: true, now: start.addingTimeInterval(1000)))
    }
}
