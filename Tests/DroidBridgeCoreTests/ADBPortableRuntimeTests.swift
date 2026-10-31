import XCTest
import Foundation
import Darwin
@testable import DroidBridgeCore

final class ADBPortableRuntimeTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("adb-portable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("owned adb".utf8).write(to: root.appendingPathComponent("adb"))
        try Data("owned library".utf8).write(to: root.appendingPathComponent("adb-libfixture.dylib"))
        try manifest(root)
        return root
    }
    private func manifest(_ root: URL) throws {
        let files = try ["adb", "adb-libfixture.dylib"].map { name in
            ADBPortableRuntime.File(name: name, sha256: try AvailabilityRuntimeStore.digest(root.appendingPathComponent(name)), size: Int64(try Data(contentsOf: root.appendingPathComponent(name)).count))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fileData = try encoder.encode(files)
        let data = Data("{\"version\":1,\"files\":".utf8) + fileData + Data("}".utf8)
        try data.write(to: root.appendingPathComponent(ADBPortableRuntime.manifestName))
    }
    func testPortableInventoryCopiesExactBytesAndBindsEveryDependency() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try ADBPortableRuntime.inventory(adb: root.appendingPathComponent("adb"))
        XCTAssertTrue(runtime.isPortable); XCTAssertEqual(runtime.files.count, 3)
        let target = root.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try runtime.copy(to: target)
        XCTAssertEqual(try ADBPortableRuntime.inventory(adb: target.appendingPathComponent("adb"), requireOwned: true).files, runtime.files)
        try Data("modified".utf8).write(to: target.appendingPathComponent("adb-libfixture.dylib"))
        XCTAssertThrowsError(try ADBPortableRuntime.inventory(adb: target.appendingPathComponent("adb")))
    }
    func testManifestTraversalSymlinksAndMissingDependenciesFailClosed() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("adb-libfixture.dylib")
        try FileManager.default.removeItem(at: library)
        XCTAssertThrowsError(try ADBPortableRuntime.inventory(adb: root.appendingPathComponent("adb")))
        try FileManager.default.createSymbolicLink(atPath: library.path, withDestinationPath: root.appendingPathComponent("adb").path)
        XCTAssertThrowsError(try ADBPortableRuntime.inventory(adb: root.appendingPathComponent("adb")))
        let invalid = Data("{\"version\":1,\"files\":[{\"name\":\"adb\",\"sha256\":\"\(String(repeating: "a", count: 64))\",\"size\":1},{\"name\":\"../adb-libescape.dylib\",\"sha256\":\"\(String(repeating: "a", count: 64))\",\"size\":1}]}".utf8)
        try invalid.write(to: root.appendingPathComponent(ADBPortableRuntime.manifestName))
        XCTAssertThrowsError(try ADBPortableRuntime.inventory(adb: root.appendingPathComponent("adb")))
    }
    func testLegacyStandaloneIdentityRemainsCompatibleAndMissingManifestCannotHideDynamicDependency() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let standalone = root.appendingPathComponent("standalone")
        try FileManager.default.removeItem(at: root.appendingPathComponent(ADBPortableRuntime.manifestName))
        try await compileStandalone(root, target: standalone, universal: false)
        let legacy = try ADBPortableRuntime.inventory(adb: standalone)
        XCTAssertFalse(legacy.isPortable); XCTAssertTrue(legacy.identitySuffix.isEmpty)
        try await legacy.verifyLoadClosure()
        try await compile(root, absoluteDependency: false)
        try FileManager.default.removeItem(at: root.appendingPathComponent(ADBPortableRuntime.manifestName))
        let unmanifested = try ADBPortableRuntime.inventory(adb: root.appendingPathComponent("adb"))
        do { try await unmanifested.verifyLoadClosure(); XCTFail("Unlisted dynamic runtime accepted") } catch {}
    }
    func testUniversalLegacyADBReadsOnlyTheSupportedArchitecture() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(ADBPortableRuntime.manifestName))
        try await compileStandalone(root, target: root.appendingPathComponent("adb"), universal: true)
        let runtime = try ADBPortableRuntime.inventory(adb: root.appendingPathComponent("adb"))
        XCTAssertFalse(runtime.isPortable)
        try await runtime.verifyLoadClosure()
    }
    func testSignedRuntimeActuallyExecutesAfterRelocationAndAbsoluteDependencyIsRejected() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await compile(root, absoluteDependency: false)
        let runtime = try ADBPortableRuntime.inventory(adb: root.appendingPathComponent("adb"))
        try await runtime.verifyLoadClosure()
        let copied = root.appendingPathComponent("independent")
        try FileManager.default.createDirectory(at: copied, withIntermediateDirectories: false)
        try runtime.copy(to: copied)
        try FileManager.default.removeItem(at: root.appendingPathComponent("adb-libfixture.dylib"))
        let relocated = try ADBPortableRuntime.inventory(adb: copied.appendingPathComponent("adb"), requireOwned: true)
        try await relocated.verifyLoadClosure()
        let result = try await ProcessRunner.run(copied.appendingPathComponent("adb").path, arguments: ["version"], timeout: 3)
        XCTAssertEqual(result.output.trimmingCharacters(in: .whitespacesAndNewlines), "41")
        try await compile(root, absoluteDependency: true)
        do { try await ADBPortableRuntime.inventory(adb: root.appendingPathComponent("adb")).verifyLoadClosure(); XCTFail("Absolute library load accepted") } catch {}
    }
    private func compile(_ root: URL, absoluteDependency: Bool) async throws {
        let lib = root.appendingPathComponent("adb-libfixture.dylib")
        let libSource = root.appendingPathComponent("library.c"), mainSource = root.appendingPathComponent("main.c")
        try Data("int bridge_answer(void) { return 41; }\n".utf8).write(to: libSource)
        try Data("#include <stdio.h>\nextern int bridge_answer(void); int main(void) { printf(\"%d\\n\", bridge_answer()); return 0; }\n".utf8).write(to: mainSource)
        _ = try await ProcessRunner.run("/usr/bin/clang", arguments: ["-dynamiclib", "-install_name", absoluteDependency ? lib.path : "@loader_path/" + lib.lastPathComponent, libSource.path, "-o", lib.path], timeout: 10)
        _ = try await ProcessRunner.run("/usr/bin/clang", arguments: [mainSource.path, lib.path, "-o", root.appendingPathComponent("adb").path], timeout: 10)
        for file in [lib, root.appendingPathComponent("adb")] { _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", file.path], timeout: 10) }
        try manifest(root)
    }
    private func compileStandalone(_ root: URL, target: URL, universal: Bool) async throws {
        let source = root.appendingPathComponent("standalone.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: source)
        var arguments = ["-arch", "arm64"]
        if universal { arguments += ["-arch", "x86_64"] }
        _ = try await ProcessRunner.run("/usr/bin/clang", arguments: arguments + [source.path, "-o", target.path], timeout: 10)
        _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", target.path], timeout: 10)
    }
}
