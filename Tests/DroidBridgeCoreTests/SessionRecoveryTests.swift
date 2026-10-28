import XCTest
import Foundation
import Darwin
import DroidBridgeCore
@testable import DroidBridgeStreaming

final class SessionRecoveryTests: XCTestCase {
    @MainActor
    func testRecoveryScopesExactDeadOwnerResourcesAndRetainsOffline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("droidbridge-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let calls = root.appendingPathComponent("calls")
        let adb = root.appendingPathComponent("adb")
        let fixtures = root.appendingPathComponent("receipts")
        let script = """
        #!/bin/sh
        echo "$*" >> '\(calls.path)'
        if [ "$1" = "forward" ]; then
          echo 'qa-dead tcp:12345 localabstract:scrcpy_1234abcd'
          echo 'qa-dead tcp:23456 localabstract:scrcpy_7654abcd'
          echo 'other-device tcp:34567 localabstract:scrcpy_1234abcd'
        elif [ "$2" = "qa-offline" ]; then
          echo offline >&2
          exit 1
        fi
        """
        try script.write(to:adb,atomically:true,encoding:.utf8)
        try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:adb.path)
        let dead = SessionReceipt(ownerPID:Int32.max,serial:"qa-dead",scid:"1234abcd")
        let live = SessionReceipt(ownerPID:getpid(),serial:"qa-live",scid:"1234abce")
        let offline = SessionReceipt(ownerPID:Int32.max,serial:"qa-offline",scid:"1234abcf")
        let malformed = SessionReceipt(ownerPID:Int32.max,serial:"qa-dead",scid:"../bad")
        let deadURL = try dead.save(directory:fixtures)
        let liveURL = try live.save(directory:fixtures)
        let offlineURL = try offline.save(directory:fixtures)
        let malformedURL = fixtures.appendingPathComponent("invalid.json")
        try JSONEncoder().encode(malformed).write(to:malformedURL)
        let tools = Toolchain(adb:adb.path,scrcpy:"/unused",server:"/unused")
        let messages = await BridgeSession.recoverAbandonedSessions(toolchain:tools,receiptsDirectory:fixtures)
        let output = try String(contentsOf:calls)
        XCTAssertTrue(output.contains("-s qa-dead forward --remove tcp:12345"))
        XCTAssertTrue(output.contains("-s qa-dead shell rm -f /data/local/tmp/droidbridge-1234abcd.jar"))
        XCTAssertFalse(output.contains("--remove tcp:23456"))
        XCTAssertFalse(output.contains("--remove tcp:34567"))
        XCTAssertFalse(output.contains("qa-live"))
        XCTAssertFalse(output.contains("../bad"))
        XCTAssertFalse(FileManager.default.fileExists(atPath:deadURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:liveURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:offlineURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:malformedURL.path))
        XCTAssertEqual(messages.filter{$0.hasPrefix("Recovered")}.count,1)
        XCTAssertEqual(messages.filter{$0.hasPrefix("Deferred")}.count,1)
    }
    func testReceiptValidationRejectsTraversalAndShellCharacters() {
        for scid in ["../bad","ffffffff","1234abcd;rm","1234ABCd",""] { XCTAssertFalse(SessionReceipt(ownerPID:123,serial:"qa",scid:scid).valid) }
        XCTAssertFalse(SessionReceipt(ownerPID:1,serial:"qa",scid:"1234abcd").valid)
        XCTAssertFalse(SessionReceipt(ownerPID:123,serial:"qa;reboot",scid:"1234abcd").valid)
        XCTAssertTrue(SessionReceipt(ownerPID:123,serial:"emulator-5580",scid:"1234abcd").valid)
    }
}
