import XCTest
import Foundation
import Darwin
@testable import DroidBridgeCore

final class CompanionJournalSecurityTests: XCTestCase {
    private struct InjectedFailure: Error {}
    private func directory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("journal-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return result
    }

    func testPublicationFaultsExposeOnlyCompletePrivateOldOrNewDocuments() throws {
        for point in ["persist_before_write", "persist_after_file_sync", "persist_after_rename"] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let file = root.appendingPathComponent("state.json"), old = Data(#"{"revision":0}"#.utf8), next = Data(#"{"revision":1,"payload":"complete"}"#.utf8)
            _ = try CompanionBrokerJournal.write(old, to: file, checkpoint: { _ in })
            var observed: [String] = []
            XCTAssertThrowsError(try CompanionBrokerJournal.write(next, to: file, checkpoint: { name in
                observed.append(name); if name == point { throw InjectedFailure() }
            }))
            let bytes = try Data(contentsOf: file)
            XCTAssertEqual(bytes, point == "persist_after_rename" ? next : old)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: bytes))
            let metadata = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((metadata[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["state.json"], "An injected failure must not leak a staged journal")
            XCTAssertEqual(observed.last, point)
        }
    }

    func testSymlinkAndHardlinkTargetsCannotOverwriteOtherFiles() throws {
        for symlink in [true, false] {
            let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
            let outside = root.appendingPathComponent("owned-unrelated-file"), target = root.appendingPathComponent("state.json")
            let original = Data("must remain unchanged".utf8)
            try original.write(to: outside); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outside.path)
            if symlink { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside) }
            else { XCTAssertEqual(link(outside.path, target.path), 0) }
            XCTAssertThrowsError(try CompanionBrokerJournal.write(Data("replacement".utf8), to: target, checkpoint: { _ in }))
            XCTAssertEqual(try Data(contentsOf: outside), original)
        }
    }

    func testByteLimitAndNonprivateDirectoryFailBeforePublication() throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("state.json")
        XCTAssertThrowsError(try CompanionBrokerJournal.write(Data(count: 4_194_305), to: file, checkpoint: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertThrowsError(try CompanionBrokerJournal.write(Data("{}".utf8), to: file, checkpoint: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
