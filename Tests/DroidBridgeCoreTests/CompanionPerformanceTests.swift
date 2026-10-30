import XCTest
@testable import DroidBridgeCore

final class CompanionPerformanceTests: XCTestCase {
    func testLegacyConfigurationKeepsThirtyFPSAndDecorations() throws {
        let old = Data(#"{"width":720,"height":1080,"density":240,"backend":"native"}"#.utf8)
        let value = try JSONDecoder().decode(SessionConfiguration.self, from: old)
        XCTAssertEqual(value.maximumFramesPerSecond, 30)
        XCTAssertTrue(value.showSystemDecorations)
    }

    func testProfilesPreserveDisplayAndBackendAcrossPersistence() throws {
        let original = SessionConfiguration(width: 800, height: 1200, density: 220, backend: .scrcpy, showSystemDecorations: false)
        for profile in CompanionPerformanceProfile.allCases {
            let value = profile.applying(to: original)
            let restored = try JSONDecoder().decode(SessionConfiguration.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(restored.maximumFramesPerSecond, profile.maximumFramesPerSecond)
            XCTAssertEqual(restored.width, original.width)
            XCTAssertEqual(restored.height, original.height)
            XCTAssertEqual(restored.density, original.density)
            XCTAssertEqual(restored.backend, .scrcpy)
            XCTAssertFalse(restored.showSystemDecorations)
        }
        XCTAssertEqual(original.maximumFramesPerSecond, 30)
    }

    func testPersistedInvalidRateFailsRatherThanClamping() throws {
        for invalid in [0, 14, 61, Int.max] {
            let data = Data("{\"width\":720,\"height\":1080,\"density\":240,\"backend\":\"native\",\"maximumFramesPerSecond\":\(invalid)}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(SessionConfiguration.self, from: data))
        }
    }
}
