import XCTest
import Foundation
import Darwin
@testable import DroidBridgeCore

final class AvailabilityRuntimeStoreTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("availability-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); return root
    }
    private func source(_ root: URL, _ index: Int) throws -> (URL, URL) {
        let folder = root.appendingPathComponent("source-\(index)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let helper = folder.appendingPathComponent("helper"), adb = folder.appendingPathComponent("adb")
        try Data("owned helper \(index)".utf8).write(to: helper); try Data("owned adb \(index)".utf8).write(to: adb)
        return (helper, adb)
    }
    private func cohort(_ root: URL, count: Int = 8) async throws -> (URL, [URL]) {
        let parent = root.appendingPathComponent("availability/generations")
        var generations: [URL] = []
        for i in 0..<count {
            let files = try source(root, i)
            let lease = try await AvailabilityRuntimeStore.lock(parent: parent)
            let generation = try await AvailabilityRuntimeStore.prepare(parent: parent, helper: files.0, adb: files.1, preservedGeneration: nil, verify: { _ in }, inUse: { _ in false })
            withExtendedLifetime(lease) {}; generations.append(generation)
        }
        return (parent, generations)
    }
    func testFullStoreReclaimsVerifiedUnusedGenerationAndPreservesCurrent() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, old) = try await cohort(root)
        let files = try source(root, 9), pin = old[0]
        let lease = try await AvailabilityRuntimeStore.lock(parent: parent); defer { withExtendedLifetime(lease) {} }
        let installed = try await AvailabilityRuntimeStore.prepare(parent: parent, helper: files.0, adb: files.1, preservedGeneration: pin, verify: { _ in }, inUse: { _ in false })
        XCTAssertTrue(FileManager.default.fileExists(atPath: pin.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).count, 8)
        XCTAssertEqual(old.filter { FileManager.default.fileExists(atPath: $0.path) }.count, 7)
    }
    func testRunningLifetimeLeasesAndUnknownReferenceScanFailClosed() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, old) = try await cohort(root), files = try source(root, 9)
        var running: [AvailabilityRuntimeLease] = []
        for generation in old { running.append(try XCTUnwrap(AvailabilityRuntimeStore.holdRunning(executable: generation.appendingPathComponent("DroidBridgeAvailability")))) }
        do { _ = try await AvailabilityRuntimeStore.prepare(parent: parent, helper: files.0, adb: files.1, preservedGeneration: nil, verify: { _ in }, inUse: { _ in false }); XCTFail("Running generations reclaimed") } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).count, 8)
        running.removeAll()
        do { _ = try await AvailabilityRuntimeStore.prepare(parent: parent, helper: files.0, adb: files.1, preservedGeneration: nil, verify: { _ in }, inUse: { _ in throw BridgeError.message("unknown process scan") }); XCTFail("Unknown references reclaimed") } catch {}
        XCTAssertTrue(old.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
    func testPostRenameReferenceRecheckRollsBackWithoutDeletingBytes() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, old) = try await cohort(root), files = try source(root, 9)
        do {
            _ = try await AvailabilityRuntimeStore.prepare(parent: parent, helper: files.0, adb: files.1, preservedGeneration: nil, verify: { _ in }, inUse: { paths in paths[0].path.contains(".retiring-") })
            XCTFail("Mapped retirement deleted")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).count, 8)
        XCTAssertTrue(old.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }
    func testCorruptOrForeignGenerationContentsArePreserved() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, old) = try await cohort(root), files = try source(root, 9)
        for item in old { try Data("foreign".utf8).write(to: item.appendingPathComponent("keep.txt")) }
        do { _ = try await AvailabilityRuntimeStore.prepare(parent: parent, helper: files.0, adb: files.1, preservedGeneration: nil, verify: { _ in }, inUse: { _ in false }); XCTFail("Foreign bytes reclaimed") } catch {}
        for item in old { XCTAssertEqual(try Data(contentsOf: item.appendingPathComponent("keep.txt")), Data("foreign".utf8)) }
    }
    func testRepeatedPublicationReusesIdentityWithoutGrowingStore() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, old) = try await cohort(root), files = try source(root, 1)
        let result = try await AvailabilityRuntimeStore.prepare(parent: parent, helper: files.0, adb: files.1, preservedGeneration: nil, verify: { _ in }, inUse: { _ in false })
        XCTAssertEqual(result.path, old[1].path); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).count, 8)
    }
    private func staged(_ parent: URL, helper: URL, adb: URL, recovering: Bool = false, kind: String = "stage") throws -> (URL, URL) {
        let transaction = UUID(), directory = parent.deletingLastPathComponent().appendingPathComponent("transactions")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let generation = try AvailabilityRuntimeStore.identity(helper: helper, adb: adb)
        func source(_ file: URL) throws -> [String: Any] {
            ["path": file.path, "sha256": try AvailabilityRuntimeStore.digest(file), "size": try Data(contentsOf: file).count]
        }
        let receipt = directory.appendingPathComponent(transaction.uuidString + ".json")
        var object: [String: Any] = ["version": 1, "kind": kind, "transaction": transaction.uuidString, "generation": generation, "helper": try source(helper), "adb": try source(adb)]
        let runtime = try ADBPortableRuntime.inventory(adb: adb)
        if runtime.isPortable { object["additional"] = try runtime.extraFiles.map { ["name": $0.name, "source": try source(runtime.directory.appendingPathComponent($0.name))] as [String: Any] } }
        try JSONSerialization.data(withJSONObject: object).write(to: receipt)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        let stage = parent.appendingPathComponent(kind == "retire" ? ".retiring-" + generation + "-" + transaction.uuidString : (recovering ? ".recovering-stage-" : ".staging-") + transaction.uuidString)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return (stage, receipt)
    }
    func testCrashLeftRetirementResumesAndCurrentPinRestores() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, old) = try await cohort(root)
        let retired = parent.appendingPathComponent(".retiring-" + old[0].lastPathComponent + "-" + UUID().uuidString)
        try FileManager.default.moveItem(at: old[0], to: retired)
        try await AvailabilityRuntimeStore.recoverCrashLeft(parent: parent, preservedGeneration: old[0], verify: { _ in }, inUse: { _ in false })
        XCTAssertTrue(FileManager.default.fileExists(atPath: old[0].path)); XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
        try FileManager.default.moveItem(at: old[0], to: retired)
        try await AvailabilityRuntimeStore.recoverCrashLeft(parent: parent, preservedGeneration: nil, verify: { _ in }, inUse: { _ in false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path)); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).count, 7)
    }
    func testCrashLeftRetirementWithLiveOrUnknownReferencesPreservesBytes() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, old) = try await cohort(root, count: 1)
        let retired = parent.appendingPathComponent(".retiring-" + old[0].lastPathComponent + "-" + UUID().uuidString)
        try FileManager.default.moveItem(at: old[0], to: retired)
        try await AvailabilityRuntimeStore.recoverCrashLeft(parent: parent, preservedGeneration: nil, verify: { _ in }, inUse: { _ in true })
        XCTAssertTrue(FileManager.default.fileExists(atPath: retired.path))
        try await AvailabilityRuntimeStore.recoverCrashLeft(parent: parent, preservedGeneration: nil, verify: { _ in }, inUse: { _ in throw BridgeError.message("unknown") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: retired.path))
    }
    func testOwnedPartialStageAndInterruptedRecoveryResumeWithPrefixProof() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, _) = try await cohort(root, count: 1), files = try source(root, 2)
        for recovering in [false, true] {
            let (stage, receipt) = try staged(parent, helper: files.0, adb: files.1, recovering: recovering)
            try Data(try Data(contentsOf: files.0).prefix(4)).write(to: stage.appendingPathComponent("DroidBridgeAvailability"))
            try await AvailabilityRuntimeStore.recoverCrashLeft(parent: parent, preservedGeneration: nil, verify: { _ in }, inUse: { _ in false })
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
        }
    }
    func testPartialStageMissingSourceAndForeignBytesAreNeverDeleted() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, _) = try await cohort(root, count: 1), files = try source(root, 2)
        let (stage, receipt) = try staged(parent, helper: files.0, adb: files.1)
        let partial = Data(try Data(contentsOf: files.0).prefix(4))
        try partial.write(to: stage.appendingPathComponent("DroidBridgeAvailability")); try FileManager.default.removeItem(at: files.0)
        try await AvailabilityRuntimeStore.recoverCrashLeft(parent: parent, preservedGeneration: nil, verify: { _ in }, inUse: { _ in false })
        XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent("DroidBridgeAvailability")), partial); XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.path))
        try Data("foreign bytes".utf8).write(to: stage.appendingPathComponent("unknown.txt"))
        try await AvailabilityRuntimeStore.recoverCrashLeft(parent: parent, preservedGeneration: nil, verify: { _ in }, inUse: { _ in false })
        XCTAssertEqual(try Data(contentsOf: stage.appendingPathComponent("unknown.txt")), Data("foreign bytes".utf8))
    }
    func testCompleteStageRecoveryDoesNotRequireOriginalSources() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, _) = try await cohort(root, count: 1), files = try source(root, 2)
        let (stage, receipt) = try staged(parent, helper: files.0, adb: files.1)
        try FileManager.default.copyItem(at: files.0, to: stage.appendingPathComponent("DroidBridgeAvailability")); try FileManager.default.copyItem(at: files.1, to: stage.appendingPathComponent("adb"))
        try FileManager.default.removeItem(at: files.0); try FileManager.default.removeItem(at: files.1)
        try await AvailabilityRuntimeStore.recoverCrashLeft(parent: parent, preservedGeneration: nil, verify: { _ in }, inUse: { _ in false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }
    func testUnreceiptedStageRemainsCountedAtCapacity() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, old) = try await cohort(root, count: 7), files = try source(root, 9)
        let unknown = parent.appendingPathComponent(".staging-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: false)
        for item in old { try Data("foreign".utf8).write(to: item.appendingPathComponent("unknown")) }
        do { _ = try await AvailabilityRuntimeStore.prepare(parent: parent, helper: files.0, adb: files.1, preservedGeneration: nil, verify: { _ in }, inUse: { _ in false }); XCTFail("Unknown stage bypassed bound") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path)); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).count, 8)
    }
    func testCrashDuringRetirementDeletionRemovesOnlyReceiptedRemainingFiles() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, _) = try await cohort(root, count: 1), files = try source(root, 2)
        let (retired, receipt) = try staged(parent, helper: files.0, adb: files.1, kind: "retire")
        try FileManager.default.copyItem(at: files.1, to: retired.appendingPathComponent("adb"))
        try await AvailabilityRuntimeStore.recoverCrashLeft(parent: parent, preservedGeneration: nil, verify: { _ in }, inUse: { _ in false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }
    func testPartiallyDeletedPinnedRetirementWaitsForSuccessorAndUnknownBytesStay() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, _) = try await cohort(root, count: 1), files = try source(root, 2)
        let generation = try AvailabilityRuntimeStore.identity(helper: files.0, adb: files.1)
        let (retired, receipt) = try staged(parent, helper: files.0, adb: files.1, kind: "retire")
        try FileManager.default.copyItem(at: files.1, to: retired.appendingPathComponent("adb"))
        try await AvailabilityRuntimeStore.recoverCrashLeft(parent: parent, preservedGeneration: parent.appendingPathComponent(generation), verify: { _ in }, inUse: { _ in false })
        XCTAssertTrue(FileManager.default.fileExists(atPath: retired.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.path))
        try Data("unknown changed bytes".utf8).write(to: retired.appendingPathComponent("adb"))
        try await AvailabilityRuntimeStore.recoverCrashLeft(parent: parent, preservedGeneration: nil, verify: { _ in }, inUse: { _ in false })
        XCTAssertEqual(try Data(contentsOf: retired.appendingPathComponent("adb")), Data("unknown changed bytes".utf8))
    }
    private func portableSource(_ root: URL, _ index: Int) throws -> (URL, URL) {
        let pair = try source(root, index), directory = pair.1.deletingLastPathComponent()
        let name = "adb-libfixture.dylib"
        try Data("owned portable dependency \(index)".utf8).write(to: directory.appendingPathComponent(name))
        let files: [[String: Any]] = try ["adb", name].map { file in
            ["name": file, "sha256": try AvailabilityRuntimeStore.digest(directory.appendingPathComponent(file)), "size": try Data(contentsOf: directory.appendingPathComponent(file)).count]
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "files": files], options: [.sortedKeys]).write(to: directory.appendingPathComponent(ADBPortableRuntime.manifestName))
        return pair
    }
    func testPortableGenerationBindsLibraryBytesAndReclaimsUnderSameEightBound() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, old) = try await cohort(root)
        let source = try portableSource(root, 9)
        let generation = try await AvailabilityRuntimeStore.prepare(parent: parent, helper: source.0, adb: source.1, preservedGeneration: old[0], verify: { _ in }, inUse: { _ in false })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).count, 8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old[0].path))
        try AvailabilityRuntimeStore.validateGeneration(generation, identity: generation.lastPathComponent)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: generation.path)), ["DroidBridgeAvailability", "adb", "adb-libfixture.dylib", "adb-runtime.json"])
        try Data("foreign replacement".utf8).write(to: generation.appendingPathComponent("adb-libfixture.dylib"))
        XCTAssertThrowsError(try AvailabilityRuntimeStore.validateGeneration(generation, identity: generation.lastPathComponent))
    }
    func testPortableCrashReceiptsRecoverPartialLibrariesAndRetirementWithoutManifest() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, _) = try await cohort(root, count: 1), pair = try portableSource(root, 2)
        let library = pair.1.deletingLastPathComponent().appendingPathComponent("adb-libfixture.dylib")
        let (stage, stageReceipt) = try staged(parent, helper: pair.0, adb: pair.1)
        try Data(try Data(contentsOf: library).prefix(5)).write(to: stage.appendingPathComponent(library.lastPathComponent))
        try await AvailabilityRuntimeStore.recoverCrashLeft(parent: parent, preservedGeneration: nil, verify: { _ in }, inUse: { _ in false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: stageReceipt.path))
        let (retired, retirementReceipt) = try staged(parent, helper: pair.0, adb: pair.1, kind: "retire")
        try FileManager.default.copyItem(at: library, to: retired.appendingPathComponent(library.lastPathComponent))
        try FileManager.default.removeItem(at: pair.0.deletingLastPathComponent())
        try await AvailabilityRuntimeStore.recoverCrashLeft(parent: parent, preservedGeneration: nil, verify: { _ in }, inUse: { _ in false })
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: retirementReceipt.path))
    }
    func testActualMappedExecutableIsPreservedUntilOwnedProcessExits() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let (parent, _) = try await cohort(root, count: 7)
        let lease = try await AvailabilityRuntimeStore.lock(parent: parent); defer { withExtendedLifetime(lease) {} }
        let source = root.appendingPathComponent("owned-helper.c"), helper = root.appendingPathComponent("owned-helper")
        try Data("#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n".utf8).write(to: source)
        _ = try await ProcessRunner.run("/usr/bin/clang", arguments: [source.path, "-o", helper.path], timeout: 10)
        _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", helper.path], timeout: 10)
        let running = try await AvailabilityRuntimeStore.prepare(parent: parent, helper: helper, adb: helper, preservedGeneration: nil)
        let process = Process(); process.executableURL = running.appendingPathComponent("DroidBridgeAvailability")
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; try process.run()
        defer { try? stopOwnedFixture(process.processIdentifier) }
        try await Task.sleep(nanoseconds: 100_000_000)
        guard process.isRunning else { XCTFail("Owned mapped-process fixture did not stay alive"); return }
        do {
            _ = try await AvailabilityRuntimeStore.prepare(parent: parent, helper: URL(fileURLWithPath: "/bin/cat"), adb: helper, preservedGeneration: nil)
            XCTFail("A mapped executable was retired")
        } catch {}
        XCTAssertTrue(process.isRunning); XCTAssertTrue(FileManager.default.fileExists(atPath: running.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).count, 8)
        try stopOwnedFixture(process.processIdentifier)
        let installed = try await AvailabilityRuntimeStore.prepare(parent: parent, helper: URL(fileURLWithPath: "/bin/cat"), adb: helper, preservedGeneration: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: running.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path).count, 8)
    }
}

/// Foundation waitUntilExit may wait indefinitely for a run-loop notification
/// already consumed during the full suite. Reap only this exact owned child.
private func stopOwnedFixture(_ pid: Int32) throws {
    var status: Int32 = 0
    guard waitpid(pid, &status, WNOHANG) == 0 else { return }
    kill(pid, SIGTERM)
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
        if waitpid(pid, &status, WNOHANG) != 0 { return }
        Thread.sleep(forTimeInterval: 0.005)
    }
    kill(pid, SIGKILL)
    let forcedDeadline = Date().addingTimeInterval(1)
    while Date() < forcedDeadline {
        if waitpid(pid, &status, WNOHANG) != 0 { return }
        Thread.sleep(forTimeInterval: 0.005)
    }
    throw NSError(domain: "OwnedFixtureCleanup", code: 1)
}
