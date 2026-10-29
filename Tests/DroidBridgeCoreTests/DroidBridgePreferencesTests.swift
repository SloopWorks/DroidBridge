import XCTest
import Darwin
@testable import DroidBridgeCore

final class DroidBridgePreferencesTests: XCTestCase {
    func testDefaultsAndLegacyFieldsPreserveEnabledBehavior() throws {
        XCTAssertEqual(try JSONDecoder().decode(DroidBridgePreferences.self, from: Data("{}".utf8)), DroidBridgePreferences())
        XCTAssertTrue(DroidBridgePreferences().bulkWrapperOnboardingEnabled)
        XCTAssertTrue(DroidBridgePreferences().showAndroidSystemDecorations)
        XCTAssertTrue(DroidBridgePreferences().screenOffDeviceSerials.isEmpty)
    }
    func testAtomicUpdatesMergeFieldsAndCorruptionFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preferences.json")
        XCTAssertEqual(try DroidBridgePreferences.load(url: url), DroidBridgePreferences())
        try DroidBridgePreferences.update(url: url) { $0.bulkWrapperOnboardingEnabled = false }
        try DroidBridgePreferences.update(url: url) { $0.showAndroidSystemDecorations = false }
        XCTAssertEqual(try DroidBridgePreferences.load(url: url), DroidBridgePreferences(bulkWrapperOnboardingEnabled: false, showAndroidSystemDecorations: false))
        try Data("incomplete".utf8).write(to: url)
        XCTAssertThrowsError(try DroidBridgePreferences.load(url: url))
    }
    func testHeldWriterLockFailsWithinFiniteUIBudget() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let url=root.appendingPathComponent("preferences.json")
        let fd=open(url.appendingPathExtension("lock").path,O_CREAT|O_RDWR,0o600)
        XCTAssertGreaterThanOrEqual(fd,0);defer {flock(fd,LOCK_UN);close(fd)}
        XCTAssertEqual(flock(fd,LOCK_EX|LOCK_NB),0)
        let start=ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try DroidBridgePreferences.update(url:url){$0.bulkWrapperOnboardingEnabled=false})
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,0.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath:url.path))
    }

    func testScreenOffPreferencesArePerDeviceAndSurviveOtherFieldUpdates() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("preferences.json")
        try DroidBridgePreferences.update(url:url){$0.screenOffDeviceSerials.insert("first-phone")}
        try DroidBridgePreferences.update(url:url){$0.screenOffDeviceSerials.insert("second-phone")}
        try DroidBridgePreferences.update(url:url){$0.showAndroidSystemDecorations=false;$0.bulkWrapperOnboardingEnabled=false}
        XCTAssertEqual(try DroidBridgePreferences.load(url:url).screenOffDeviceSerials,["first-phone","second-phone"])
        try DroidBridgePreferences.update(url:url){$0.screenOffDeviceSerials.remove("first-phone")}
        XCTAssertEqual(try DroidBridgePreferences.load(url:url).screenOffDeviceSerials,["second-phone"])
    }
    func testInvalidScreenOffSerialIsRejectedWithoutReplacingAcceptedPreferences() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("preferences.json")
        try DroidBridgePreferences.update(url:url){$0.screenOffDeviceSerials=["valid-phone"]}
        let accepted=try Data(contentsOf:url)
        XCTAssertThrowsError(try DroidBridgePreferences.update(url:url){$0.screenOffDeviceSerials.insert("bad; serial")})
        XCTAssertEqual(try Data(contentsOf:url),accepted)
    }

}
