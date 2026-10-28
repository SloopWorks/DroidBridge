import XCTest
import Foundation
import DroidBridgeCore
import DroidBridgeStreaming

final class QALifecycleTests: XCTestCase {
    @MainActor
    func testRejectsInvalidInputsBeforeAnySpawn() async throws {
        let absent = Toolchain(adb:"/nonexistent/adb",scrcpy:"/nonexistent/scrcpy",server:"/nonexistent/server")
        let inputs:[(String,String,SessionConfiguration)] = [
            ("emulator-5580","com.example;touch",SessionConfiguration()),
            ("emulator-5580;reboot","com.android.settings",SessionConfiguration()),
            ("emulator-5580","com.android.settings",SessionConfiguration(width:0)),
            ("emulator-5580","com.android.settings",SessionConfiguration(density:9999))
        ]
        for (serial,package,config) in inputs {
            let session = BridgeSession(descriptor:SessionDescriptor(device:AndroidDevice(serial:serial,model:"test"),application:AndroidApplication(packageName:package,name:"test"),configuration:config),toolchain:absent)
            do { try await session.start(); XCTFail("Invalid input must fail") }
            catch { XCTAssertFalse(error.localizedDescription.contains("doesn’t exist"),"Must validate before tool execution") }
            XCTAssertEqual(session.state,.stopped)
            session.stop(); session.stop()
            XCTAssertEqual(session.state,.stopped)
        }
    }
    @MainActor
    func testActualNativeCancelledStartAndRepeatedCleanup() async throws {
        guard ProcessInfo.processInfo.environment["DROIDBRIDGE_QA_LIFECYCLE"] == "1" else { throw XCTSkip("Opt in after coordinating exclusive emulator sessions") }
        let serial = ProcessInfo.processInfo.environment["DROIDBRIDGE_TEST_SERIAL"] ?? "emulator-5580"
        guard serial != "emulator-5554" else { throw XCTSkip("Never alter user's emulator") }
        let tools = Toolchain()
        func adb(_ args:[String]) async throws -> String { try await ProcessRunner.run(tools.adb,arguments:["-s",serial]+args,environment:tools.environment).output }
        let baseline = try await adb(["forward","--list"])
        let baselineDisplay = try await adb(["shell","dumpsys","display"])
        func displayCount(_ output:String) -> Int { output.components(separatedBy:"DisplayDeviceInfo{").count - 1 }
        func session(_ package:String = "dev.droidbridge.testapp") -> BridgeSession {
            BridgeSession(descriptor:SessionDescriptor(device:AndroidDevice(serial:serial,model:"QA"),application:AndroidApplication(packageName:package,name:"QA"),configuration:SessionConfiguration(backend:.native)),toolchain:tools)
        }
        let bad = session("dev.droidbridge.definitely_missing")
        do { try await bad.start(); XCTFail("Missing app must fail") } catch {}
        XCTAssertEqual(bad.state,.failed)
        bad.stop()
        for _ in 0..<3 {
            let cancelled = session()
            let startup = Task { try await cancelled.start() }
            try await Task.sleep(nanoseconds:20_000_000)
            cancelled.stop()
            do { try await startup.value; XCTFail("Stopped startup must not succeed") } catch {}
            XCTAssertEqual(cancelled.state,.stopped)
        }
        for _ in 0..<3 {
            let active = session()
            try await active.start()
            XCTAssertEqual(active.state,.running)
            XCTAssertGreaterThan(active.metrics.frames,0)
            active.stop(); active.stop()
            XCTAssertEqual(active.state,.stopped)
            try await Task.sleep(nanoseconds:1_000_000_000)
        }
        try await Task.sleep(nanoseconds:3_000_000_000)
        let after = try await adb(["forward","--list"])
        XCTAssertEqual(after,baseline,"Exact owned forwards must be removed")
        let afterDisplay = try await adb(["shell","dumpsys","display"])
        XCTAssertEqual(displayCount(afterDisplay),displayCount(baselineDisplay),"No orphan virtual displays after cancel/relaunch")
        print("QA lifecycle: invalid app, 3 cancelled startups, 3 decoded launch/stop cycles; exact forwards and display count restored")
    }
}

extension QALifecycleTests {
    @MainActor
    func testStopAndWaitIncludesLateForwardAllocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("droidbridge-qa-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let receipt = root.appendingPathComponent("receipt")
        let marker = root.appendingPathComponent("forward-started")
        let adb = root.appendingPathComponent("adb")
        let scrcpy = root.appendingPathComponent("scrcpy")
        // Generated filesystem names contain only a UUID; scripts are a fixture,
        // never a production shell command construction path.
        let body = """
        #!/bin/sh
        shift 2
        case "$1" in
        push) exit 0 ;;
        forward)
          if [ "$2" = "tcp:0" ]; then
            touch '\(marker.path)'
            sleep 0.4
            echo 54321
          else
            echo "removed:$3" >> '\(receipt.path)'
          fi ;;
        shell)
          if [ "$2" = "cmd" ]; then echo dev.droidbridge.testapp/.MainActivity
          else echo remote-cleaned >> '\(receipt.path)'; fi ;;
        esac
        """
        try body.write(to:adb,atomically:true,encoding:.utf8)
        try "#!/bin/sh\necho scrcpy 5.0.1\n".write(to:scrcpy,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:adb.path)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:scrcpy.path)
        let tools = Toolchain(adb:adb.path,scrcpy:scrcpy.path,server:root.appendingPathComponent("server").path)
        let session = BridgeSession(descriptor:SessionDescriptor(device:AndroidDevice(serial:"qa-serial",model:"fixture"),application:AndroidApplication(packageName:"dev.droidbridge.testapp",name:"fixture"),configuration:SessionConfiguration()),toolchain:tools)
        let startup = Task { try await session.start() }
        for _ in 0..<100 { if FileManager.default.fileExists(atPath:marker.path) { break }; try await Task.sleep(nanoseconds:10_000_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path),"Must stop while forward command is in flight")
        await session.stopAndWait()
        let output = (try? String(contentsOf:receipt)) ?? ""
        XCTAssertTrue(output.contains("removed:tcp:54321"),"Awaitable stop must include cleanup from late forward completion")
        do { try await startup.value; XCTFail("Stopped startup cannot succeed") } catch {}
        XCTAssertEqual(session.state,.stopped)
    }
}
