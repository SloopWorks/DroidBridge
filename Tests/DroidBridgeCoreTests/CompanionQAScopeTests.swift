import XCTest
import Darwin
@testable import DroidBridgeCore

final class CompanionQAScopeTests: XCTestCase {
    func testExplicitScopeFiltersOnlyOneOwnedEmulatorAndSeparatesAllPaths() throws {
        let proposed = FileManager.default.temporaryDirectory.appendingPathComponent("companion-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let resolved = try XCTUnwrap(realpath(proposed.path, nil)); defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved)); defer { try? FileManager.default.removeItem(at: root) }
        let value = try XCTUnwrap(CompanionQAScope.parse(arguments: ["DroidBridge", "--companion-qa-root", root.path, "--serial", "emulator-5582"]))
        XCTAssertEqual(value.serial, "emulator-5582")
        XCTAssertEqual(value.filterDevices([AndroidDevice(serial: "emulator-5554", model: "User emulator"), AndroidDevice(serial: "emulator-5580", model: "Other QA"), AndroidDevice(serial: "emulator-5582", model: "Owned QA"), AndroidDevice(serial: "physical-pixel", model: "Phone")]).map(\.serial), ["emulator-5582"])
        for path in [value.preferencesURL, value.audioDirectory, value.receiptDirectory, value.iconReceiptDirectory, value.logDirectory, value.sessionsURL, value.brokerDirectory, value.managedPaths.privateRoot, value.managedPaths.activeRoot] { XCTAssertTrue(path.path.hasPrefix(root.path + "/")) }
        XCTAssertEqual(value.serviceSuffix.count, 12)
        XCTAssertNil(try CompanionQAScope.parse(arguments: ["DroidBridge", "--serial", "emulator-5554"]))
    }
    func testInvalidScopeCannotFallBackToProduction() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("companion-invalid-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]); defer { try? FileManager.default.removeItem(at: root) }
        for arguments in [["DroidBridge", "--companion-qa-root", root.path], ["DroidBridge", "--companion-qa-root", root.path, "--serial", "emulator-5554"], ["DroidBridge", "--companion-qa-root", root.path, "--serial", "physical-pixel"], ["DroidBridge", "--companion-qa-root", root.path, "--serial", "emulator-5582", "--serial", "emulator-5580"], ["DroidBridge", "--companion-qa-root", root.path + "/../x", "--serial", "emulator-5582"]] { XCTAssertThrowsError(try CompanionQAScope.parse(arguments: arguments)) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertThrowsError(try CompanionQAScope.parse(arguments: ["DroidBridge", "--companion-qa-root", root.path, "--serial", "emulator-5582"]))
    }
}
