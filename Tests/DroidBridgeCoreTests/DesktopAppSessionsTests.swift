import XCTest
import Darwin
@testable import DroidBridgeCore

final class DesktopAppSessionsTests: XCTestCase {
    private func fixture(_ action: (DesktopAppSessionStore, DesktopAppProcess) throws -> Void) throws {
        let resolved = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(resolved) }
        let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            .appendingPathComponent("desktop-app-sessions-\(UUID().uuidString)", isDirectory: true)
        defer { if FileManager.default.fileExists(atPath: root.path) { try? FileManager.default.removeItem(at: root) } }
        let process = DesktopAppProcess(owner: try XCTUnwrap(CompanionBrokerOwner.live(getpid())),
                                        bundleURL: URL(fileURLWithPath: "/Applications/Registry Fixture.app"),
                                        bundleIdentifier: "app.droidbridge.wrapper.dev.fixture")
        try action(DesktopAppSessionStore(root: root), process)
    }
    private func begin(_ store: DesktopAppSessionStore, _ process: DesktopAppProcess) throws -> DesktopAppSessionProducer {
        try store.begin(process: process, serial: "emulator-5580", packageName: "dev.droidbridge.fixture", backend: .native)
    }
    private func payload(_ store: DesktopAppSessionStore) throws -> URL {
        try XCTUnwrap(FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
    }

    func testRoundTripAndExactExpectedProcessIdentity() throws {
        try fixture { store, process in
            let producer = try begin(store, process)
            XCTAssertEqual(try store.read(expected: process)?.sessions, [])
            let session = DesktopAppSession(id: UUID(), name: "Deterministic test app", state: .recovering)
            XCTAssertTrue(try store.publish(producer, sessions: [session]))
            let value = try XCTUnwrap(store.read(expected: process))
            XCTAssertEqual(value.process, process)
            XCTAssertEqual(value.generation, producer.generation)
            XCTAssertEqual(value.serial, "emulator-5580")
            XCTAssertEqual(value.packageName, "dev.droidbridge.fixture")
            XCTAssertEqual(value.backend, .native)
            XCTAssertEqual(value.sessions, [session])

            let reusedPID = DesktopAppProcess(owner: .init(pid: process.owner.pid, start: process.owner.start + 1),
                                              bundleURL: process.bundleURL, bundleIdentifier: process.bundleIdentifier)
            XCTAssertNil(try store.read(expected: reusedPID))
            XCTAssertThrowsError(try begin(store, reusedPID))
            XCTAssertNil(try store.read(expected: .init(owner: process.owner, bundleURL: process.bundleURL,
                                                      bundleIdentifier: "app.droidbridge.different")))
            XCTAssertNil(try store.read(expected: .init(owner: process.owner, bundleURL: URL(fileURLWithPath: "/Applications/Other.app"),
                                                      bundleIdentifier: process.bundleIdentifier)))
            XCTAssertTrue(try store.remove(producer))
            XCTAssertNil(try store.read(expected: process))
        }
    }

    func testLatePublisherAndCleanupCannotOverwriteNewGeneration() throws {
        try fixture { store, process in
            let old = try begin(store, process)
            let current = try begin(store, process)
            let session = DesktopAppSession(id: UUID(), name: "Current", state: .running)
            XCTAssertTrue(try store.publish(current, sessions: [session]))
            XCTAssertFalse(try store.publish(old, sessions: []))
            XCTAssertFalse(try store.remove(old))
            XCTAssertEqual(try store.read(expected: process)?.generation, current.generation)
            XCTAssertEqual(try store.read(expected: process)?.sessions, [session])
        }
    }

    func testBundleDirectoryURLHintDoesNotChangeObservedProcessIdentity() throws {
        try fixture { store, process in
            let directoryURL = URL(fileURLWithPath: process.bundleURL.path, isDirectory: true)
            let fileURL = URL(fileURLWithPath: process.bundleURL.path, isDirectory: false)
            XCTAssertNotEqual(directoryURL, fileURL, "Fixture must exercise the real Foundation directory-hint difference")
            let directoryProcess = DesktopAppProcess(owner: process.owner, bundleURL: directoryURL,
                                                     bundleIdentifier: process.bundleIdentifier)
            let fileProcess = DesktopAppProcess(owner: process.owner, bundleURL: fileURL,
                                                bundleIdentifier: process.bundleIdentifier)
            XCTAssertEqual(directoryProcess, fileProcess)
            let producer = try begin(store, directoryProcess)
            let session = DesktopAppSession(id: UUID(), name: "Fixture", state: .running)
            XCTAssertTrue(try store.publish(producer, sessions: [session]))
            let fromFileHint = try XCTUnwrap(store.read(expected: fileProcess))
            XCTAssertEqual(fromFileHint.process, directoryProcess)
            XCTAssertEqual(fromFileHint.sessions, [session])

            let replacement = try begin(store, fileProcess)
            XCTAssertFalse(try store.remove(producer), "Equivalent URL hints must still preserve generation fencing")
            XCTAssertEqual(try store.read(expected: directoryProcess)?.generation, replacement.generation)
            XCTAssertNotEqual(fileProcess, .init(owner: process.owner, bundleURL: URL(fileURLWithPath: "/Applications/Other.app"),
                                                bundleIdentifier: process.bundleIdentifier))
            XCTAssertNotEqual(fileProcess, .init(owner: .init(pid: process.owner.pid, start: process.owner.start + 1),
                                                bundleURL: fileURL, bundleIdentifier: process.bundleIdentifier))
        }
    }

    func testSessionBackendCanChangeWithoutChangingWrapperLaunchIdentity() throws {
        try fixture { store, process in
            let producer = try begin(store, process)
            let id = UUID()
            XCTAssertTrue(try store.publish(producer, sessions: [.init(id: id, name: "Fixture", state: .failed, backend: .native)]))
            XCTAssertEqual(try store.read(expected: process)?.sessions.first?.backend, .native)
            let retried = DesktopAppSession(id: id, name: "Fixture", state: .running, backend: .scrcpy)
            XCTAssertTrue(try store.publish(producer, sessions: [retried]))
            let snapshot = try XCTUnwrap(store.read(expected: process))
            XCTAssertEqual(snapshot.backend, .native, "Requested wrapper identity must remain stable across fallback")
            XCTAssertEqual(snapshot.sessions, [retried])
            XCTAssertEqual(snapshot.sessions.first?.backend, .scrcpy)
            XCTAssertNotEqual(retried, DesktopAppSession(id: id, name: "Fixture", state: .running, backend: .native))

            // Older presentation payloads omit this optional field.
            let url = try payload(store)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var rows = try XCTUnwrap(object["sessions"] as? [[String: Any]])
            rows[0].removeValue(forKey: "backend"); object["sessions"] = rows
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            XCTAssertEqual(try store.read(expected: process)?.sessions,
                           [DesktopAppSession(id: id, name: "Fixture", state: .running)])
        }
    }

    func testSessionBoundsAndValidationPreserveLastGoodSnapshot() throws {
        try fixture { store, process in
            let producer = try begin(store, process)
            let session = DesktopAppSession(id: UUID(), name: "Valid", state: .running)
            XCTAssertTrue(try store.publish(producer, sessions: [session]))
            XCTAssertThrowsError(try store.publish(producer, sessions: [session, session]))
            XCTAssertThrowsError(try store.publish(producer, sessions: (0..<33).map { _ in .init(id: UUID(), name: "Many", state: .starting) }))
            XCTAssertThrowsError(try store.publish(producer, sessions: [.init(id: UUID(), name: String(repeating: "x", count: 513), state: .starting)]))
            XCTAssertThrowsError(try store.publish(producer, sessions: [.init(id: UUID(), name: "line\nbreak", state: .starting)]))
            XCTAssertThrowsError(try store.begin(process: process, serial: "bad serial", packageName: "dev.good", backend: .native))
            XCTAssertThrowsError(try store.begin(process: process, serial: "emulator-5580", packageName: "bad;package", backend: .native))
            XCTAssertEqual(try store.read(expected: process)?.sessions, [session])
        }
    }

    func testMalformedAndOversizedPayloadRejected() throws {
        try fixture { store, process in
            _ = try begin(store, process)
            let url = try payload(store)
            try Data(repeating: 0x20, count: 65_537).write(to: url)
            XCTAssertThrowsError(try store.read(expected: process))
            try Data("{}".utf8).write(to: url)
            XCTAssertThrowsError(try store.read(expected: process))
        }
    }

    func testSavedProcessReuseAndUnvalidatedMetadataDoNotBecomeTrusted() throws {
        try fixture { store, process in
            _ = try begin(store, process)
            let url = try payload(store)
            let original = try Data(contentsOf: url)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var savedProcess = try XCTUnwrap(object["process"] as? [String: Any])
            var owner = try XCTUnwrap(savedProcess["owner"] as? [String: Any])
            owner["start"] = process.owner.start + 1
            savedProcess["owner"] = owner; object["process"] = savedProcess
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            XCTAssertNil(try store.read(expected: process))

            object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            object["packageName"] = "not a package"
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            XCTAssertThrowsError(try store.read(expected: process))

            object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            savedProcess = try XCTUnwrap(object["process"] as? [String: Any])
            savedProcess["bundleIdentifier"] = "app.droidbridge.other"
            object["process"] = savedProcess
            try JSONSerialization.data(withJSONObject: object).write(to: url)
            XCTAssertThrowsError(try store.read(expected: process))
        }
    }

    func testPayloadSymlinkAndHardlinkRejectedWithoutTouchingTarget() throws {
        try fixture { store, process in
            let producer = try begin(store, process)
            let url = try payload(store)
            let target = store.root.appendingPathComponent("outside-target")
            let bytes = try Data(contentsOf: url)
            try bytes.write(to: target)
            XCTAssertEqual(chmod(target.path, 0o600), 0)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            XCTAssertThrowsError(try store.read(expected: process))
            XCTAssertThrowsError(try store.remove(producer))
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            try FileManager.default.removeItem(at: url)
            XCTAssertEqual(link(target.path, url.path), 0)
            XCTAssertThrowsError(try store.read(expected: process))
            XCTAssertEqual(try Data(contentsOf: target), bytes)
        }
    }

    func testPrivateRootAndParentSymlinkEnforced() throws {
        try fixture { store, process in
            _ = try begin(store, process)
            XCTAssertEqual(chmod(store.root.path, 0o755), 0)
            XCTAssertThrowsError(try store.read(expected: process))
            XCTAssertEqual(chmod(store.root.path, 0o700), 0)
            let alias = store.root.appendingPathComponent("alias")
            let target = store.root.appendingPathComponent("target", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
            let linkedStore = DesktopAppSessionStore(root: alias.appendingPathComponent("child"))
            XCTAssertThrowsError(try begin(linkedStore, process))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        }
    }

    func testNonRegularLockRejectedWithoutBlocking() throws {
        try fixture { store, process in
            _ = try begin(store, process)
            let lock = store.root.appendingPathComponent(".lock")
            try FileManager.default.removeItem(at: lock)
            XCTAssertEqual(mkfifo(lock.path, 0o600), 0)
            XCTAssertThrowsError(try store.read(expected: process))
        }
    }

    func testContendedLockHasBoundedWaitAndCanBeRetried() throws {
        try fixture { store, process in
            _ = try begin(store, process)
            let descriptor = open(store.root.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            let started = DispatchTime.now().uptimeNanoseconds
            XCTAssertThrowsError(try store.read(expected: process))
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
            XCTAssertLessThan(elapsed, 3, "A hung publisher must not stall the consumer indefinitely")
            XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
            XCTAssertNotNil(try store.read(expected: process))
        }
    }

    func testCancelledReaderDoesNotWaitForContendedLockDeadline() async throws {
        let root = URL(fileURLWithPath: "/private/tmp/desktop-app-session-cancellation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DesktopAppSessionStore(root: root)
        let process = DesktopAppProcess(owner: try XCTUnwrap(CompanionBrokerOwner.live(getpid())),
                                        bundleURL: URL(fileURLWithPath: "/Applications/Registry Fixture.app"),
                                        bundleIdentifier: "app.droidbridge.wrapper.dev.fixture")
        _ = try begin(store, process)
        let descriptor = open(root.appendingPathComponent(".lock").path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let reader = Task.detached { try store.read(expected: process) }
        try await Task.sleep(for: .milliseconds(100))
        let cancelledAt = DispatchTime.now().uptimeNanoseconds
        reader.cancel()
        do {
            _ = try await reader.value
            XCTFail("Cancelled reader unexpectedly acquired a held lock")
        } catch is CancellationError {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - cancelledAt) / 1_000_000_000
            XCTAssertLessThan(elapsed, 0.75, "Cancellation must bypass the one-second lock deadline")
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }

    func testConcurrentReadsNeverObservePartialPublication() throws {
        try fixture { store, process in
            let producer = try begin(store, process)
            let lock = NSLock()
            var failures = [String]()
            DispatchQueue.concurrentPerform(iterations: 40) { index in
                do {
                    let session = DesktopAppSession(id: UUID(), name: "Session \(index)", state: .running)
                    guard try store.publish(producer, sessions: [session]),
                          let value = try store.read(expected: process), value.generation == producer.generation,
                          value.sessions.count == 1 else { throw BridgeError.message("Incomplete atomic snapshot") }
                } catch { lock.lock(); failures.append(String(describing: error)); lock.unlock() }
            }
            XCTAssertEqual(failures, [])
        }
    }
}
