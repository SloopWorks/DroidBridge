import XCTest
@testable import DroidBridgeCore

#if DEBUG
/// Actual pinned HTTPS event ingestion and shipping broker state. No Android,
/// GUI, LaunchAgent or application metadata/index changes are performed.
final class CompanionCatalogSignalTests: XCTestCase {
    private struct Fixture {
        let root: URL, broker: CompanionBrokerEngine, owner: CompanionBrokerOwner, peer: BrokerAdmissionTLSPeer
        var file: URL { root.appendingPathComponent("state.json") }
        func call(_ operation: String, _ payload: [String: CompanionJSON] = [:]) async throws -> CompanionBrokerReply {
            let reply = await broker.exchange(.init(operation: operation, payload: payload, nonce: "catalog-signal-test"), owner: owner)
            if let error = reply.error { throw CompanionBoundaryError(error.code, error.message, retryable: error.retryable) }
            return reply
        }
        func device() async throws -> [String: CompanionJSON] {
            let reply = try await call("status")
            return try XCTUnwrap(reply.data["devices"]?.array?.compactMap(\.object).first { $0["device_id"]?.string == peer.deviceID })
        }
        func token() async throws -> String { let value = try await device(); return try XCTUnwrap(value["catalog_change_token"]?.string) }
        func diskDevice() throws -> [String: Any] {
            let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            return try XCTUnwrap((document["devices"] as? [[String: Any]])?.first { $0["deviceID"] as? String == peer.deviceID })
        }
        func waitUntil(_ predicate: () async throws -> Bool) async throws {
            let deadline = CompanionClock.nowMS() + 3000
            repeat {
                if try await predicate() { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while CompanionClock.nowMS() < deadline
            XCTFail("Catalog signal did not reach its bounded expected state")
            throw CompanionBoundaryError("test_timeout", "Catalog signal test timed out")
        }
        func connect() async throws { _ = try await call("connect", ["serial": .string("qa-catalog")]) }
    }
    private func fixture(_ action: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-signal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try BrokerAdmissionTLSPeer()
        defer { peer.close(); try? CompanionCredentialStore.remove(deviceID: peer.deviceID) }
        try CompanionCredentialStore.save(.init(deviceID: peer.deviceID, trustID: peer.trustID, credential: String(repeating: "A", count: 43), serverPin: peer.serverPin))
        // Deliberately legacy: neither new catalog field is present.
        let state: [String: Any] = ["macID": UUID().uuidString, "devices": [["deviceID": peer.deviceID, "name": "Catalog signal fixture", "aliases": ["qa-catalog"], "preferredSerial": "qa-catalog", "trustID": peer.trustID, "epoch": peer.deviceID, "sequence": 0, "profile": "balanced", "exportSelection": [:], "enabled": true]], "registry": ["hosts": [], "sessions": [], "commands": []], "inbox": [["id": "legacy-catalog-history", "deviceID": peer.deviceID, "kind": "catalog_changed", "created": Date().timeIntervalSinceReferenceDate, "payload": ["revision": "old history retained"]]]]
        let file = root.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: state).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let broker = CompanionBrokerEngine(directory: root, managedPaths: .init(privateRoot: root.appendingPathComponent("Managed.noindex"), activeRoot: root.appendingPathComponent("Apps")), testingHooks: .init(endpoint: { _ in peer.url }))
        await broker.start()
        let context = Fixture(root: root, broker: broker, owner: try XCTUnwrap(CompanionBrokerOwner.live(getpid())), peer: peer)
        do { try await action(context); await broker.shutdown() }
        catch { await broker.shutdown(); throw error }
    }
    private func catalogEvent(id: String, sequence: Int64) -> [String: Any] {
        ["sequence": sequence, "event_id": id, "kind": "catalog_changed", "payload": ["revision": "untrusted hint payload is never a catalog snapshot"]]
    }
    func testLegacyJournalAuthenticatedConnectSeedsPersistentTokenAndStatusNeverFetchesCatalog() async throws {
        try await fixture { context in
            let before = try await context.device()
            XCTAssertEqual(before["catalog_change_token"], .null)
            XCTAssertTrue(context.peer.requestedPaths.isEmpty)
            try await context.connect()
            let token = try await context.token()
            XCTAssertFalse(token.isEmpty); XCTAssertLessThanOrEqual(token.utf8.count, 128)
            for _ in 0..<8 { let observed = try await context.token(); XCTAssertEqual(observed, token) }
            XCTAssertEqual(try context.diskDevice()["catalogChangeToken"] as? String, token)
            XCTAssertFalse(context.peer.requestedPaths.contains { $0.hasPrefix("/v1/catalog") }, "Local status cannot silently fetch or derive a phone catalog")
        }
    }
    func testAuthenticatedEventAdvancesOncePersistsCursorAndDoesNotCrowdInbox() async throws {
        try await fixture { context in
            try await context.connect(); let original = try await context.token(), id = UUID().uuidString.lowercased()
            try context.peer.setCatalogEventPage(epoch: context.peer.deviceID, events: [self.catalogEvent(id: id, sequence: 1)])
            try await context.waitUntil { try await context.token() != original }
            let changed = try await context.token()
            try await context.waitUntil { (try context.diskDevice()["sequence"] as? NSNumber)?.int64Value == 1 }
            XCTAssertEqual(try context.diskDevice()["catalogChangeToken"] as? String, changed)
            // A canonical repeated event ID at a new cursor does not churn UI.
            try context.peer.setCatalogEventPage(epoch: context.peer.deviceID, events: [self.catalogEvent(id: id, sequence: 2)])
            try await context.waitUntil { (try context.diskDevice()["sequence"] as? NSNumber)?.int64Value == 2 }
            let deduplicated = try await context.token(); XCTAssertEqual(deduplicated, changed)
            let inbox = try await context.call("inbox_list", ["device_id": .string(context.peer.deviceID)])
            XCTAssertEqual(inbox.data["items"]?.array?.count, 1)
            XCTAssertEqual(inbox.data["items"]?.array?.first?.object?["id"]?.string, "legacy-catalog-history")
            XCTAssertFalse(context.peer.requestedPaths.contains { $0.hasPrefix("/v1/catalog") })
        }
    }
    func testResetReplayAndReconnectCannotCollapseToOldEventTokenAndForgetClearsAuthority() async throws {
        try await fixture { context in
            try await context.connect(); let initial = try await context.token(), id = UUID().uuidString.lowercased()
            let event = self.catalogEvent(id: id, sequence: 1)
            try context.peer.setCatalogEventPage(epoch: context.peer.deviceID, events: [event])
            try await context.waitUntil { try await context.token() != initial }
            let beforeReset = try await context.token()
            try context.peer.setCatalogEventPage(epoch: context.peer.deviceID, reset: true, events: [event])
            try await context.waitUntil { try await context.token() != beforeReset }
            let afterReset = try await context.token()
            try await Task.sleep(nanoseconds: 200_000_000)
            let stableAfterReset = try await context.token(); XCTAssertEqual(stableAfterReset, afterReset, "An acknowledged one-shot reset does not churn the token on every empty poll")
            _ = try await context.call("disconnect", ["device_id": .string(context.peer.deviceID)])
            try await context.connect()
            let reconnected = try await context.token(); XCTAssertNotEqual(reconnected, afterReset)
            _ = try await context.call("forget", ["device_id": .string(context.peer.deviceID)])
            let forgotten = try await context.device()
            XCTAssertEqual(forgotten["catalog_change_token"], .null)
            XCTAssertNil(try context.diskDevice()["lastCatalogEventID"])
        }
    }
    func testWrongTrustAndUnrelatedEventsCannotInvalidateCurrentCatalog() async throws {
        try await fixture { context in
            try await context.connect(); let initial = try await context.token()
            var wrong = self.catalogEvent(id: UUID().uuidString.lowercased(), sequence: 1)
            wrong["target_trust_id"] = UUID().uuidString.lowercased()
            try context.peer.setCatalogEventPage(epoch: context.peer.deviceID, events: [wrong])
            try await context.waitUntil { (try context.diskDevice()["sequence"] as? NSNumber)?.int64Value == 1 }
            let afterWrong = try await context.token(); XCTAssertEqual(afterWrong, initial)
            let noise: [String: Any] = ["sequence": 2, "event_id": UUID().uuidString, "kind": "unrelated_status", "payload": [:]]
            try context.peer.setCatalogEventPage(epoch: context.peer.deviceID, events: [noise])
            try await context.waitUntil { (try context.diskDevice()["sequence"] as? NSNumber)?.int64Value == 2 }
            let afterNoise = try await context.token(); XCTAssertEqual(afterNoise, initial, "An event cursor is not a catalog invalidation token")
            var current = self.catalogEvent(id: UUID().uuidString.lowercased(), sequence: 3)
            current["target_trust_id"] = context.peer.trustID
            try context.peer.setCatalogEventPage(epoch: context.peer.deviceID, events: [current])
            try await context.waitUntil { try await context.token() != initial }
        }
    }
    func testSelfRevocationClearsCatalogSignalAndDedupAuthority() async throws {
        try await fixture { context in
            try await context.connect()
            let id = UUID().uuidString.lowercased()
            try context.peer.setCatalogEventPage(epoch: context.peer.deviceID, events: [self.catalogEvent(id: id, sequence: 1)])
            try await context.waitUntil { try context.diskDevice()["lastCatalogEventID"] as? String == id }
            _ = try await context.call("revoke", ["device_id": .string(context.peer.deviceID), "trust_id": .string(context.peer.trustID)])
            let revoked = try await context.device()
            XCTAssertEqual(revoked["catalog_change_token"], .null)
            XCTAssertNil(try context.diskDevice()["lastCatalogEventID"])
        }
    }
    func testEpochDiscontinuityAdvancesTokenWithoutFetchingCatalog() async throws {
        try await fixture { context in
            try await context.connect(); let initial = try await context.token(), epoch = UUID().uuidString.lowercased()
            try context.peer.setCatalogEventPage(epoch: epoch, events: [], nextSequence: 0)
            try await context.waitUntil { try await context.token() != initial }
            try await context.waitUntil { try context.diskDevice()["epoch"] as? String == epoch }
            XCTAssertFalse(context.peer.requestedPaths.contains { $0.hasPrefix("/v1/catalog") })
        }
    }
}
#endif
