import XCTest
@testable import DroidBridgeCore

final class CompanionSetupValidationTests: XCTestCase {
    private let secret = String(repeating: "A", count: 43)
    private let pin = String(repeating: "a", count: 64)
    private let id = "63F48EE0-B351-4A51-8478-C29A68A853D0"
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPairingQRIsAnExpiringCapabilityWithoutNetworkAuthority() throws {
        let value = try CompanionPairCode("droidbridge://pair?secret=\(secret)&expires=1800000120&device_id=\(id)&server_pin=\(pin)", now: now)
        XCTAssertEqual(value.secret, secret)
        XCTAssertEqual(value.deviceID, id.lowercased())
        XCTAssertEqual(value.expires, now.addingTimeInterval(120))
        XCTAssertEqual(value.serverPin, pin)
        XCTAssertThrowsError(try CompanionPairCode(secret))
    }

    func testRejectAmbiguousOrNetworkBearingQR() {
        for value in [
            "droidbridge://pair?secret=\(secret)&expires=1800000120&device_id=\(id)&server_pin=\(pin)&host=192.168.0.1",
            "droidbridge://pair?secret=\(secret)&expires=1800000120&secret=\(secret)",
            "droidbridge://user@pair?secret=\(secret)&expires=1800000120&device_id=\(id)&server_pin=\(pin)",
            "droidbridge://pair:37841?secret=\(secret)&expires=1800000120&device_id=\(id)&server_pin=\(pin)",
            "droidbridge://pair/path?secret=\(secret)&expires=1800000120&device_id=\(id)&server_pin=\(pin)",
            "https://pair?secret=\(secret)&expires=1800000120&device_id=\(id)&server_pin=\(pin)",
            "droidbridge://pair?secret=\(secret)&expires=1800000120&device_id=not-a-uuid&server_pin=\(pin)",
            String(repeating: "a", count: 42), String(repeating: "a", count: 44),
            String(repeating: "a", count: 42) + ";"
        ] { XCTAssertThrowsError(try CompanionPairCode(value, now: now), value) }
    }

    func testWirelessEndpointCannotBecomeAnOptionShellOrArbitraryURL() throws {
        for valid in ["192.168.1.10:37123", "127.0.0.1:1", "[2001:db8::1]:65535", "[::1]:37123"] {
            XCTAssertEqual(try CompanionWirelessEndpoint(valid).argument, valid)
        }
        for invalid in ["--help", "example.com:37123", "https://192.168.0.1:37123", "192.168.0.1:0", "192.168.0.1:65536", "192.168.0.1:1;touch", "192.168.0.1:1\n--help", "192.168.0.1:+1", "[bad]:123", "2001:db8::1:37123", "192.168.0.1:", "192.168.0.1:１２３"] {
            XCTAssertThrowsError(try CompanionWirelessEndpoint(invalid), invalid)
        }
    }
    func testMissingPinMalformedFingerprintAndNoncanonicalSecretFailClosed() {
        let prefix = "droidbridge://pair?secret=\(secret)&expires=1800000120&device_id=\(id)"
        XCTAssertThrowsError(try CompanionPairCode(prefix, now: now))
        XCTAssertThrowsError(try CompanionPairCode(secret, now: now))
        for pin in [String(repeating: "a", count: 63), String(repeating: "a", count: 65), String(repeating: "A", count: 64), String(repeating: "g", count: 64)] { XCTAssertThrowsError(try CompanionPairCode(prefix + "&server_pin=" + pin, now: now)) }
        let noncanonical = "droidbridge://pair?secret=\(String(repeating: "a", count: 43))&expires=1800000120&device_id=\(id)&server_pin=\(pin)"
        XCTAssertThrowsError(try CompanionPairCode(noncanonical, now: now))
    }
}
