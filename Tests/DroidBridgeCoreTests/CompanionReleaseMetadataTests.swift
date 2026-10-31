import XCTest
@testable import DroidBridgeCore

final class CompanionReleaseMetadataTests: XCTestCase {
    func metadata(_ changes: [String: Any] = [:]) throws -> CompanionReleaseMetadata {
        var value: [String: Any] = ["version": "0.2.0", "architecture": "arm64", "minimum_macos": "26.0", "size_bytes": 30_000_000, "sha256": String(repeating: "a", count: 64), "signing": "ad_hoc_not_notarized", "download_url": "https://github.com/SloopWorks/DroidBridge/releases/download/v0.2.0/DroidBridge-0.2.0-arm64.dmg", "release_url": "https://github.com/SloopWorks/DroidBridge/releases/tag/v0.2.0"]
        value.merge(changes) { _, new in new }
        return try JSONDecoder().decode(CompanionReleaseMetadata.self, from: JSONSerialization.data(withJSONObject: value))
    }
    func testReleaseMetadataBindsExactVersionPlatformAndOfficialArtifact() throws {
        let value = try metadata(); try value.validate()
        XCTAssertEqual(value.brokerPayload["size_bytes"]?.number, 30_000_000)
        XCTAssertEqual(value.brokerPayload["download_url"]?.string, value.downloadURL)
        XCTAssertEqual(CompanionReleaseMetadata.manifestURL.absoluteString, "https://github.com/SloopWorks/DroidBridge/releases/download/v0.2.0/release-manifest.json")
    }
    func testReleaseMetadataRefusesSubstitutedURLsUnknownSigningAndUnsafeBounds() throws {
        for changes: [String: Any] in [
            ["download_url": "https://github.com/attacker/DroidBridge/releases/download/v0.2.0/DroidBridge-0.2.0-arm64.dmg"],
            ["download_url": "http://github.com/SloopWorks/DroidBridge/releases/download/v0.2.0/DroidBridge-0.2.0-arm64.dmg"],
            ["release_url": "https://github.com/SloopWorks/DroidBridge/releases"],
            ["version": "0.3.0"], ["architecture": "x86_64"], ["minimum_macos": "13.0"],
            ["signing": "notarized"], ["size_bytes": 0], ["size_bytes": 268_435_457], ["sha256": String(repeating: "A", count: 64)]
        ] { XCTAssertThrowsError(try metadata(changes).validate(), "Accepted \(changes.keys)") }
    }
    func testWireMetadataRejectsDuplicateEscapedKeysNestedValuesAndByteAbuse() throws {
        let original = try JSONEncoder().encode(metadata())
        XCTAssertEqual(try CompanionReleaseMetadata.decode(original).version, "0.2.0")
        for bytes in [
            Data("{\"version\":\"0.2.0\",\"ver\\u0073ion\":\"0.2.0\"}".utf8),
            Data("{\"unknown\":{\"nested\":true}}".utf8),
            Data("{\"unknown\":[]}".utf8),
            Data(repeating: 32, count: 16_385),
            Data([0xc3, 0x28])
        ] { XCTAssertThrowsError(try CompanionReleaseMetadata.decode(bytes)) }
    }
}
