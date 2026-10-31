import XCTest
@testable import DroidBridgeCore

final class CompanionWirelessADBTests: XCTestCase {
    func testPairCodeUsesStdinAndIsRedactedFromReturnedOutput() async throws {
        let root = try fixture("""
        #!/bin/sh
        test "$#" -eq 2 || exit 2
        test "$1" = pair || exit 3
        test "$2" = 127.0.0.1:37123 || exit 4
        IFS= read -r code
        test "$code" = 123456 || exit 5
        printf 'Successfully paired [code %s]' "$code"
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await CompanionWirelessADB.pair(adb: root.appendingPathComponent("adb").path, endpoint: CompanionWirelessEndpoint("127.0.0.1:37123"), code: "123456")
        XCTAssertEqual(result, "Successfully paired [code [redacted]]")
        XCTAssertFalse(result.contains("123456"))
    }

    func testTimeoutAndCancellationFinishBoundedly() async throws {
        let root = try fixture("#!/bin/sh\nexec /bin/sleep 10\n")
        defer { try? FileManager.default.removeItem(at: root) }
        let endpoint = try CompanionWirelessEndpoint("127.0.0.1:37123")
        let start = ProcessInfo.processInfo.systemUptime
        do {
            _ = try await CompanionWirelessADB.connect(adb: root.appendingPathComponent("adb").path, endpoint: endpoint, timeout: 0.1)
            XCTFail("A hanging ADB process must time out")
        } catch { XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2) }
        let task = Task { try await CompanionWirelessADB.connect(adb: root.appendingPathComponent("adb").path, endpoint: endpoint) }
        try await Task.sleep(nanoseconds: 50_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled ADB setup must not succeed") }
        catch { XCTAssertTrue(error is CancellationError); XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 3) }
    }

    private func fixture(_ script: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wireless-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("adb")
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return root
    }
}
