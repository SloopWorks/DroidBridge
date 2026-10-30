import XCTest
import Foundation
import Security
@testable import DroidBridgeCore

#if DEBUG
private final class CleanupSecurityFaults: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = Set<String>()
    private var counts: [String: Int] = [:]
    func arm(_ names: Set<String>) { lock.lock(); armed = names; lock.unlock() }
    func count(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[name, default: 0] }
    func check(_ name: String) throws {
        lock.lock(); let fail = armed.contains(name); if fail { counts[name, default: 0] += 1 }; lock.unlock()
        if fail { throw CompanionBoundaryError("security_fault_" + name, "Independent deterministic cleanup fault") }
    }
}

/// Actual pinned-TLS control peer, private broker state and random QA credential.
/// The DEBUG forward is deliberately local-only; these are not ADB/device tests.
final class CompanionCleanupSecurityTests: XCTestCase {
    func testShutdownDuringAuthenticatedIdentityCannotPublishLateAdmission() async throws {
        try await assertShutdownPreventsAdmission(blockedPath: "/v1/identity")
    }
    func testShutdownDuringPinnedHelloCannotSendStoredBearerOrPublishAdmission() async throws {
        try await assertShutdownPreventsAdmission(blockedPath: "/v1/hello")
    }
    private func assertShutdownPreventsAdmission(blockedPath: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shutdown-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let peer = try BrokerAdmissionTLSPeer(blockedPath: blockedPath)
        defer { peer.releaseBlocked(); peer.close(); try? CompanionCredentialStore.remove(deviceID: peer.deviceID) }
        let paths = ManagedAppsPaths(privateRoot: directory.appendingPathComponent("Managed.noindex"), activeRoot: directory.appendingPathComponent("Apps"))
        try CompanionCredentialStore.save(.init(deviceID: peer.deviceID, trustID: peer.trustID, credential: String(repeating: "A", count: 43), serverPin: peer.serverPin))
        let state: [String: Any] = ["macID": UUID().uuidString, "devices": [["deviceID": peer.deviceID, "name": "Before shutdown", "aliases": ["qa-shutdown"], "preferredSerial": "qa-shutdown", "trustID": peer.trustID, "sequence": 0, "profile": "balanced", "exportSelection": [:], "enabled": true]], "registry": ["hosts": [], "sessions": [], "commands": []], "inbox": []]
        let stateURL = directory.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        let broker = CompanionBrokerEngine(directory: directory, managedPaths: paths, testingHooks: .init(endpoint: { _ in peer.url }))
        await broker.start()
        let owner = try XCTUnwrap(CompanionBrokerOwner.live(getpid()))
        let connection = Task { await broker.exchange(.init(operation: "connect", payload: ["serial": .string("qa-shutdown")], nonce: "independent-test"), owner: owner) }
        let deadline = Date().addingTimeInterval(3)
        while !peer.blockedRequestSeen, Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(peer.blockedRequestSeen)
        await broker.shutdown()
        let committedAtShutdown = try Data(contentsOf: stateURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: CompanionExportPolicy.url(paths: paths).path))
        peer.releaseBlocked()
        let result = await connection.value
        XCTAssertNotNil(result.error)
        if blockedPath == "/v1/hello" { XCTAssertEqual(peer.requestedPaths, ["/v1/hello"], "A stopped broker must not send a saved bearer to the identity route") }
        XCTAssertEqual(try Data(contentsOf: stateURL), committedAtShutdown, "A late TLS response must not write state after shutdown")
        XCTAssertFalse(FileManager.default.fileExists(atPath: CompanionExportPolicy.url(paths: paths).path), "A stopped broker cannot publish a new alias authority")
        await broker.shutdown()
    }

    func testLegacyCredentialForAnotherPhoneCannotBlockHealthyNewAlias() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("credential-cohort-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let peer = try BrokerAdmissionTLSPeer()
        let staleID = "00000000-0000-4000-8000-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").suffix(12)).lowercased()
        defer { peer.close(); try? CompanionCredentialStore.remove(deviceID: peer.deviceID); try? CompanionCredentialStore.remove(deviceID: staleID) }
        try CompanionCredentialStore.save(.init(deviceID: peer.deviceID, trustID: peer.trustID, credential: String(repeating: "A", count: 43), serverPin: peer.serverPin))
        let legacyQuery: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.sloopworks.DroidBridge.companion.v1" + (CompanionQAScope.current?.keychainServiceSuffix ?? ""),
            kSecAttrAccount as String: staleID, kSecValueData as String: Data(String(repeating: "B", count: 43).utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        XCTAssertEqual(SecItemAdd(legacyQuery as CFDictionary, nil), errSecSuccess)
        let healthy: [String: Any] = ["deviceID": peer.deviceID, "name": "Healthy stored phone", "aliases": ["qa-old-healthy"], "preferredSerial": "qa-old-healthy", "trustID": peer.trustID, "sequence": 0, "profile": "balanced", "exportSelection": [:], "enabled": true]
        let stale: [String: Any] = ["deviceID": staleID, "name": "Legacy stored phone", "aliases": ["qa-legacy"], "preferredSerial": "qa-legacy", "trustID": UUID().uuidString, "sequence": 0, "profile": "battery", "exportSelection": ["dev.droidbridge.testapp": false], "enabled": true]
        let state: [String: Any] = ["macID": UUID().uuidString, "devices": [stale, healthy], "registry": ["hosts": [], "sessions": [], "commands": []], "inbox": []]
        let stateURL = directory.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        let paths = ManagedAppsPaths(privateRoot: directory.appendingPathComponent("Managed.noindex"), activeRoot: directory.appendingPathComponent("Apps"))
        let broker = CompanionBrokerEngine(directory: directory, managedPaths: paths, testingHooks: .init(endpoint: { _ in peer.url }))
        await broker.start()
        let owner = try XCTUnwrap(CompanionBrokerOwner.live(getpid()))
        let connected = await broker.exchange(.init(operation: "connect", payload: ["serial": .string("qa-new-healthy")], nonce: "independent-test"), owner: owner)
        XCTAssertNil(connected.error, "A separate stale phone credential must not block this healthy pinned identity")
        XCTAssertEqual(connected.data["paired"], .bool(true))
        let status = await broker.exchange(.init(operation: "status", nonce: "independent-test"), owner: owner)
        let staleStatus = status.data["devices"]?.array?.compactMap(\.object).first { $0["device_id"]?.string == staleID }
        XCTAssertEqual(staleStatus?["connection_error"], .string("re_pair_required"))
        XCTAssertEqual(staleStatus?["profile"], .string("battery"), "Repair status must preserve unrelated settings")
        XCTAssertTrue(status.data["devices"]?.array?.contains { $0.object?["device_id"]?.string == staleID } == true, "A failed credential must not delete its saved device history")
        _ = await broker.exchange(.init(operation: "forget", payload: ["device_id": .string(peer.deviceID)], nonce: "independent-test"), owner: owner)
        await broker.shutdown()
    }

    func testForgetPersistenceFailureRetainsForwardAndRetriesCleanupBeforeStorageRecovery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let peer = try BrokerAdmissionTLSPeer()
        defer { peer.close(); try? CompanionCredentialStore.remove(deviceID: peer.deviceID) }
        let paths = ManagedAppsPaths(privateRoot: directory.appendingPathComponent("Managed.noindex"), activeRoot: directory.appendingPathComponent("Apps"))
        try ManagedAppCatalog(paths: paths).bindCompanionExportAuthority(deviceID: peer.deviceID, trustID: peer.trustID, aliases: ["emulator-5580"])
        let state: [String: Any] = ["macID": UUID().uuidString, "devices": [["deviceID": peer.deviceID, "name": "Independent TLS cleanup peer", "aliases": ["emulator-5580"], "preferredSerial": "emulator-5580", "sequence": 0, "profile": "balanced", "exportSelection": [:], "enabled": false]], "registry": ["hosts": [], "sessions": [], "commands": []], "inbox": []]
        let stateURL = directory.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        let faults = CleanupSecurityFaults()
        let hooks = CompanionBrokerTestingHooks(endpoint: { _ in peer.url }, fault: { try faults.check($0) })
        let broker = CompanionBrokerEngine(directory: directory, managedPaths: paths, testingHooks: hooks)
        await broker.start()
        let owner = try XCTUnwrap(CompanionBrokerOwner.live(getpid()))
        // Keep the real TLS connection unapproved so no background event
        // poller can consume the deliberately armed persistence fault first.
        let connected = await broker.exchange(.init(operation: "begin_pair", payload: ["serial": .string("emulator-5580"), "expected_device_id": .string(peer.deviceID), "server_pin": .string(peer.serverPin), "secret": .string(String(repeating: "A", count: 43))], nonce: "independent-test"), owner: owner)
        XCTAssertNil(connected.error)
        XCTAssertEqual(connected.data["status"], .string("pending"))
        faults.arm(["persist_before_write", "forward_close"])
        let forgotten = await broker.exchange(.init(operation: "forget", payload: ["device_id": .string(peer.deviceID)], nonce: "independent-test"), owner: owner)
        XCTAssertNotNil(forgotten.error, "A failed journal publication must not be reported as successful Forget")
        let retainedAfterPersistFailure = await broker.retiringForwardCount
        XCTAssertGreaterThan(retainedAfterPersistFailure, 0, "Failed persistence must not discard cleanup ownership")
        let failedCleanupDeadline = Date().addingTimeInterval(3)
        while faults.count("forward_close") == 0, Date() < failedCleanupDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertGreaterThan(faults.count("forward_close"), 0, "Maintenance must attempt cleanup even while storage is unavailable")
        let retainedAfterCloseFailure = await broker.retiringForwardCount
        XCTAssertGreaterThan(retainedAfterCloseFailure, 0, "A refused close must retain its exact owner")
        faults.arm([])
        let retiredDeadline = Date().addingTimeInterval(3)
        while await broker.retiringForwardCount > 0, Date() < retiredDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let remaining = await broker.retiringForwardCount
        XCTAssertEqual(remaining, 0, "Cleanup must retry after a transient failure clears")
        XCTAssertNil(try CompanionCredentialStore.load(deviceID: peer.deviceID))
        await broker.shutdown()
    }
}
#endif
