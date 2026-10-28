import XCTest
@testable import DroidBridgeCore

final class DesktopConfigurationTests: XCTestCase {
    func testLegacySessionKeepsDecorationsAndNewPreferenceRoundTrips() throws {
        let legacy = Data(#"{"width":720,"height":1080,"density":240,"backend":"native"}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(SessionConfiguration.self, from: legacy).showSystemDecorations)
        XCTAssertTrue(SessionConfiguration().showSystemDecorations)
        for backend in BackendKind.allCases {
            let configuration = SessionConfiguration(width: 900, height: 700, backend: backend, showSystemDecorations: false)
            let decoded = try JSONDecoder().decode(SessionConfiguration.self, from: JSONEncoder().encode(configuration))
            XCTAssertFalse(decoded.showSystemDecorations)
            XCTAssertEqual(decoded.backend, backend); XCTAssertEqual(decoded.width, 900); XCTAssertEqual(decoded.height, 700)
        }
    }

    func testDecorationChoiceDoesNotRewriteSavedDescriptor() throws {
        let original = SessionDescriptor(device: AndroidDevice(serial: "emulator-5580", model: "Test"), application: AndroidApplication(packageName: "com.android.settings", name: "Settings"), configuration: SessionConfiguration(showSystemDecorations: false))
        let saved = try JSONEncoder().encode(original)
        _ = SessionConfiguration(showSystemDecorations: true)
        let restored = try JSONDecoder().decode(SessionDescriptor.self, from: saved)
        XCTAssertEqual(restored.id, original.id)
        XCTAssertFalse(restored.configuration.showSystemDecorations)
    }
}
