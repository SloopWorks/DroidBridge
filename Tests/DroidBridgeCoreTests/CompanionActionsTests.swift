import XCTest
@testable import DroidBridgeCore

final class CompanionActionsTests: XCTestCase {
    func testShareEffectsAreExplicitAndOpeningIsRestrictedToWebLinks() throws {
        XCTAssertEqual(try CompanionShareAction.validated(kind: "share_text", payload: ["text": .string("hello")]), .send)
        XCTAssertEqual(try CompanionShareAction.validated(kind: "share_text", payload: ["text": .string("hello"), "action": .string("copy")]), .copy)
        XCTAssertEqual(try CompanionShareAction.validated(kind: "share_url", payload: ["text": .string("https://example.com/path"), "action": .string("open")]), .open)
        for text in ["file:///Applications/Calculator.app", "javascript:alert(1)", "https://user:secret@example.com/", "http:///no-host"] {
            XCTAssertThrowsError(try CompanionShareAction.validated(kind: "share_url", payload: ["text": .string(text), "action": .string("open")]))
        }
        XCTAssertThrowsError(try CompanionShareAction.validated(kind: "share_text", payload: ["text": .string("https://example.com"), "action": .string("open")]))
        XCTAssertThrowsError(try CompanionShareAction.validated(kind: "share_text", payload: ["text": .string("hello"), "action": .string("execute")]))
        XCTAssertThrowsError(try CompanionShareAction.validated(kind: "share_text", payload: ["text": .string(String(repeating: "界", count: 22_000))]))
    }

    func testPresetsBoundLaunchesAndRejectMalformedOrRepeatedPackages() throws {
        let payload: [String: CompanionJSON] = ["packages": .array([.string("com.android.settings")]), "profile": .string("balanced"), "audio_route": .string("phone"), "screen_off": .bool(false)]
        let preset = try CompanionDesktopPreset(payload: payload)
        XCTAssertEqual(preset.packages, ["com.android.settings"])
        XCTAssertFalse(preset.screenOff)
        var duplicate = payload; duplicate["packages"] = .array([.string("com.android.settings"), .string("com.android.settings")])
        XCTAssertThrowsError(try CompanionDesktopPreset(payload: duplicate))
        for names in [[], [";reboot"], (0..<9).map { "dev.test.app\($0)" }] {
            var invalid = payload; invalid["packages"] = .array(names.map(CompanionJSON.string))
            XCTAssertThrowsError(try CompanionDesktopPreset(payload: invalid))
        }
        var invalid = payload; invalid["screen_off"] = .string("true")
        XCTAssertThrowsError(try CompanionDesktopPreset(payload: invalid))
    }
}
