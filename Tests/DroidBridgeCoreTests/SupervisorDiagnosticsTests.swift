import XCTest
import Foundation
import DroidBridgeCore

final class SupervisorDiagnosticsTests: XCTestCase {
    private func runCleanup(_ diagnostic: String, exit: Int = 1) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("supervisor-diagnostics-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let fake = directory.appendingPathComponent("adb")
        // All arguments remain an array; this fixed fixture never contacts ADB.
        let fixture = "#!/bin/sh\nif [ \"$3\" = forward ]; then\n  printf '%s\\n' \"$DROIDBRIDGE_TEST_CLEANUP_DIAGNOSTIC\" >&2\n  exit \"$DROIDBRIDGE_TEST_CLEANUP_EXIT\"\nfi\nexit 0\n"
        try fixture.write(to:fake,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:fake.path)
        let helper = FileManager.default.currentDirectoryPath+"/.build/debug/DroidBridgeSupervisor"
        return try await ProcessRunner.run(helper,arguments:["--parent",String(getpid()),"--adb",fake.path,"--serial","qa-no-device","--forward","tcp:12345","--remote","/data/local/tmp/fixture.jar","--","/usr/bin/true"],environment:["DROIDBRIDGE_TEST_CLEANUP_DIAGNOSTIC":diagnostic,"DROIDBRIDGE_TEST_CLEANUP_EXIT":String(exit)]).output
    }
    func testTerminalOutputRelaysBufferedClientBeforeItExits() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let log=directory.appendingPathComponent("output")
        FileManager.default.createFile(atPath:log.path,contents:Data())
        let handle=try FileHandle(forWritingTo:log)
        defer {try? handle.close()}
        let helper=Process()
        helper.executableURL=URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/.build/debug/DroidBridgeSupervisor")
        helper.arguments=["--parent",String(getpid()),"--terminal-output","1","--","/usr/bin/python3","-c","import sys,time; print('INFO: Texture: 480x620'); print('terminal='+str(sys.stdout.isatty())); time.sleep(10)"]
        helper.standardOutput=handle;helper.standardError=handle
        try helper.run()
        defer {if helper.isRunning {helper.terminate()}}
        var output=""
        let deadline=ProcessInfo.processInfo.systemUptime+3
        while ProcessInfo.processInfo.systemUptime<deadline {
            output=(try? String(contentsOf:log,encoding:.utf8)) ?? ""
            if output.contains("terminal=True") {break}
            try await Task.sleep(for:.milliseconds(20))
        }
        XCTAssertTrue(helper.isRunning,"Fixture must remain running when readiness is observed")
        XCTAssertTrue(output.contains("INFO: Texture: 480x620"),output)
        XCTAssertTrue(output.contains("terminal=True"),output)
        XCTAssertFalse(output.contains("\r"),"Relay must preserve parser lines without TTY CR conversion")
        if helper.isRunning {helper.terminate()}
        let stopDeadline=ProcessInfo.processInfo.systemUptime+3
        while helper.isRunning && ProcessInfo.processInfo.systemUptime<stopDeadline {try await Task.sleep(for:.milliseconds(20))}
        XCTAssertFalse(helper.isRunning,"Supervisor must stop its live terminal child")
    }
    func testAlreadyAbsentExactListenerIsAnIdempotentSuccess() async throws {
        let output = try await runCleanup("adb: error: listener 'tcp:12345' not found")
        XCTAssertTrue(output.contains("supervisor_cleanup_already_complete"))
        XCTAssertFalse(output.contains("supervisor_cleanup_failed"))
        XCTAssertFalse(output.contains("adb: error:"))
        let lines = output.split(separator:"\n").compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] }
        let stopped = try XCTUnwrap(lines.first { $0["event"] as? String == "supervisor_stopped" })
        XCTAssertEqual(stopped["reason"] as? String,"child_exit")
        XCTAssertEqual(stopped["exit_status"] as? Int,0)
        XCTAssertTrue(stopped["signal"] is NSNull)
    }
    func testOtherFailuresRemainVisibleIncludingDifferentListener() async throws {
        for diagnostic in ["adb: error: device unauthorized","adb: error: listener 'tcp:54321' not found"] {
            let output = try await runCleanup(diagnostic)
            XCTAssertTrue(output.contains(diagnostic))
            XCTAssertTrue(output.contains("supervisor_cleanup_failed"))
            XCTAssertFalse(output.contains("supervisor_cleanup_already_complete"))
        }
    }
}
