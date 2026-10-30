import XCTest
@testable import DroidBridgeCore

final class CompanionDiagnosticsTests: XCTestCase {
    func testOnlyTypedOperationalFieldsCanLeaveDiagnostics() {
        let value = CompanionDiagnostics.sanitized(["battery_percent": .number(64), "charging": .bool(false), "network_class": .string("wifi"), "credential": .string("secret"), "notification_body": .string("private"), "battery": .object(["clipboard": .string("private")]), "permissions": .object(["notifications": .string("denied"), "clipboard_contents": .string("private")]), "counters": .object(["requests": .number(3), "secret_key": .number(1)])])
        XCTAssertEqual(value["battery_percent"], .number(64)); XCTAssertEqual(value["network_class"], .string("wifi"))
        XCTAssertNil(value["credential"]); XCTAssertNil(value["battery"]); XCTAssertNil(value["notification_body"])
        XCTAssertEqual(value["permissions"]?.object, ["notifications": .string("denied")]); XCTAssertEqual(value["counters"]?.object, ["requests": .number(3)])
    }
    func testUnknownInvalidAndMissingFactsAreNotReportedAsZero() {
        let value = CompanionDiagnostics.sanitized(["battery_percent": .number(-1), "thermal_status": .number(1e200), "network_class": .string("home-ssid"), "charging": .null])
        XCTAssertEqual(value["battery_percent"], .null); XCTAssertEqual(value["thermal_status"], .null); XCTAssertEqual(value["network_class"], .null)
        let text = CompanionDiagnostics.healthSummary(value)
        XCTAssertTrue(text.contains("Battery unknown")); XCTAssertTrue(text.contains("Thermal unknown")); XCTAssertTrue(text.contains("Network unknown")); XCTAssertFalse(text.contains("0%"))
    }
}
