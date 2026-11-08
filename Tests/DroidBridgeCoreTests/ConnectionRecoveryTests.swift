import XCTest
import DroidBridgeCore
@testable import DroidBridgeStreaming

final class ConnectionRecoveryTests: XCTestCase {
    @MainActor func testNormalFallbackWindowExitDoesNotRequestRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appendingPathComponent("tool")
        let script = """
        #!/bin/sh
        if [ "$1" = --version ]; then echo 'scrcpy 5.0.1'; exit 0; fi
        if [ "$1" = -s ]; then
          if [ "$4" = getprop ]; then echo 35
          elif [ "$4" = dumpsys ]; then echo mWakefulness=Awake
          else echo dev.example.test/.MainActivity; fi
          exit 0
        fi
        echo '[server] INFO: Starting app "Test" [dev.example.test] on display 7...'
        echo 'INFO: Texture: 720x1080'
        sleep 0.5
        exit 0
        """
        try script.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let session = BridgeSession(descriptor: SessionDescriptor(device: AndroidDevice(serial: "qa-clean-exit", model: "Fixture"), application: AndroidApplication(packageName: "dev.example.test", name: "Test"), configuration: SessionConfiguration(backend: .scrcpy)), toolchain: Toolchain(adb: tool.path, scrcpy: tool.path, server: tool.path))
        defer { for file in [session.logURL, session.logURL.appendingPathExtension("jsonl")] { try? FileManager.default.removeItem(at: file) } }
        session.testingAliasAdmission = { nil }
        try await session.start()
        XCTAssertEqual(session.state, .running)
        for _ in 0..<100 {
            if session.state != .running { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(session.state, .stopped)
        XCTAssertNil(session.recoveryReason, "A normally closed SDL window must not reopen itself")
        await session.stopAndWait()
    }

    func testSleepReadinessUsesWakefulnessRatherThanPanelPower() {
        XCTAssertEqual(DeviceVideoReadiness.parse(powerDump: "mWakefulness=Awake\nmWakefulness=1\nmScreenState=OFF"), .awake,
                       "An explicitly dark physical panel must not prevent virtual app sessions")
        XCTAssertEqual(DeviceVideoReadiness.parse(powerDump: "  mWakefulness=Dozing\nmWakefulness=3"), .sleeping)
        XCTAssertEqual(DeviceVideoReadiness.parse(powerDump: "mWakefulness=Asleep"), .sleeping)
        XCTAssertEqual(DeviceVideoReadiness.parse(powerDump: "mWakefulness=Dreaming"), .awake)
        for output in ["Permission denied", "", "mScreenState=OFF", "mWakefulness=0", "mWakefulness=Awake\nmWakefulness=Dozing"] {
            XCTAssertEqual(DeviceVideoReadiness.parse(powerDump: output), .unknown, output)
        }
    }

    func testBrieflyRunningSuccessorsDoNotResetRecoveryBudget() {
        let start = Date(timeIntervalSince1970: 1000)
        var retry = ReconnectRetry()
        for attempt in 0..<3 {
            let time = start.addingTimeInterval(Double(attempt) * 10)
            XCTAssertTrue(retry.admits(intentPresent: true, ready: true, enabled: true, now: time))
            retry.attempted(at: time)
            retry.running(at: time.addingTimeInterval(1))
            retry.interrupted(at: time.addingTimeInterval(2))
            XCTAssertEqual(retry.failures, attempt + 1)
            XCTAssertFalse(retry.admits(intentPresent: true, ready: true, enabled: true, now: time.addingTimeInterval(7)))
        }
        XCTAssertFalse(retry.admits(intentPresent: true, ready: true, enabled: true, now: start.addingTimeInterval(1000)))
        retry.running(at: start.addingTimeInterval(100))
        retry.interrupted(at: start.addingTimeInterval(100 + ReconnectRetry.stableInterval))
        XCTAssertEqual(retry.failures, 0)
        XCTAssertTrue(retry.admits(intentPresent: true, ready: true, enabled: true, now: start.addingTimeInterval(200)))
        XCTAssertFalse(retry.admits(intentPresent: false, ready: true, enabled: true, now: start.addingTimeInterval(200)))
        XCTAssertFalse(retry.admits(intentPresent: true, ready: true, enabled: false, now: start.addingTimeInterval(200)))
    }

    @MainActor func testSleepingStartupIsActionableAndDoesNotStageOrLaunchServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let adb = root.appendingPathComponent("adb"), calls = root.appendingPathComponent("calls")
        try "#!/bin/sh\necho \"$*\" >> '\(calls.path)'\nif [ \"$4\" = getprop ]; then echo 35; else echo '  mWakefulness=Dozing'; fi\n".write(to: adb, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: adb.path)
        let session = BridgeSession(descriptor: SessionDescriptor(device: AndroidDevice(serial: "qa-sleep", model: "Sleeping"), application: AndroidApplication(packageName: "dev.example.test", name: "Test"), configuration: SessionConfiguration()), toolchain: Toolchain(adb: adb.path, scrcpy: "/usr/bin/false", server: "/nonexistent"))
        defer { for file in [session.logURL, session.logURL.appendingPathExtension("jsonl")] { try? FileManager.default.removeItem(at: file) } }
        session.testingAliasAdmission = { nil }
        do { try await session.start(); XCTFail("Sleeping startup must wait for the owner to wake/unlock") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Wake and unlock")) }
        XCTAssertEqual(session.state, .failed)
        XCTAssertEqual(session.recoveryReason, .deviceSleeping)
        XCTAssertEqual(try String(contentsOf: calls).split(separator: "\n").map(String.init), ["-s qa-sleep shell getprop ro.build.version.sdk", "-s qa-sleep shell dumpsys power"])
        await session.stopAndWait()
        XCTAssertNil(session.recoveryReason, "Explicit stop must clear eligibility for future automatic recovery")
    }
}
