import XCTest
@testable import DroidBridgeCore

#if DEBUG
/// Real pinned TLS responses and production broker read fences. No Android,
/// GUI, notification permission, LaunchAgent or production catalog is touched.
final class CompanionCatalogReadScopeTests: XCTestCase {
    private struct Fixture {
        let root: URL, paths: ManagedAppsPaths, broker: CompanionBrokerEngine, owner: CompanionBrokerOwner, peer: BrokerAdmissionTLSPeer
        func call(_ operation: String, _ payload: [String: CompanionJSON] = [:]) async -> CompanionBrokerReply {
            await broker.exchange(.init(operation: operation, payload: payload, nonce: "catalog-scope-test"), owner: owner)
        }
        func payload(expectedTrust: String?) -> [String: CompanionJSON] {
            var value: [String: CompanionJSON] = ["device_id": .string(peer.deviceID), "after": .string(String(repeating: "a", count: 64))]
            if let expectedTrust { value["expected_trust_id"] = .string(expectedTrust) }
            return value
        }
        func connect() async throws {
            let reply = await call("connect", ["serial": .string("qa-catalog-scope")])
            if let error = reply.error { throw CompanionBoundaryError(error.code, error.message, retryable: error.retryable) }
        }
        func waitForBlocked() async throws {
            let deadline = CompanionClock.nowMS() + 3000
            while !peer.blockedRequestSeen, CompanionClock.nowMS() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(peer.blockedRequestSeen)
            guard peer.blockedRequestSeen else { throw CompanionBoundaryError("test_timeout", "Catalog request did not reach the real TLS peer") }
        }
    }
    private func fixture(blockedPath: String = "", _ action: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-read-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try BrokerAdmissionTLSPeer(blockedPath: blockedPath)
        defer { peer.releaseBlocked(); peer.close(); try? CompanionCredentialStore.remove(deviceID: peer.deviceID) }
        try CompanionCredentialStore.save(.init(deviceID: peer.deviceID, trustID: peer.trustID, credential: String(repeating: "A", count: 43), serverPin: peer.serverPin))
        let state: [String: Any] = ["macID": UUID().uuidString, "devices": [["deviceID": peer.deviceID, "name": "Catalog read scope fixture", "aliases": ["qa-catalog-scope"], "preferredSerial": "qa-catalog-scope", "trustID": peer.trustID, "epoch": peer.deviceID, "sequence": 0, "profile": "balanced", "exportSelection": [:], "enabled": true]], "registry": ["hosts": [], "sessions": [], "commands": []], "inbox": []]
        let file = root.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: state).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let paths = ManagedAppsPaths(privateRoot: root.appendingPathComponent("Managed.noindex"), activeRoot: root.appendingPathComponent("Apps"))
        let broker = CompanionBrokerEngine(directory: root, managedPaths: paths, testingHooks: .init(endpoint: { _ in peer.url }))
        await broker.start()
        let context = Fixture(root: root, paths: paths, broker: broker, owner: try XCTUnwrap(CompanionBrokerOwner.live(getpid())), peer: peer)
        do { try await context.connect(); try await action(context); await broker.shutdown() }
        catch { peer.releaseBlocked(); await broker.shutdown(); throw error }
    }
    func testWrongOrMalformedExpectedTrustRejectsBeforeCatalogHTTP() async throws {
        try await fixture { context in
            for operation in ["catalog", "catalog_changes", "export_selection_get"] {
                let mismatch = await context.call(operation, context.payload(expectedTrust: UUID().uuidString))
                XCTAssertEqual(mismatch.error?.code, "trust_changed")
                XCTAssertTrue(mismatch.data.isEmpty)
                let malformed = await context.call(operation, context.payload(expectedTrust: "not-a-uuid"))
                XCTAssertEqual(malformed.error?.code, "invalid_id")
            }
            XCTAssertFalse(context.peer.requestedPaths.contains { $0.hasPrefix("/v1/catalog") })
        }
    }
    func testWrongExpectedTrustFailsBeforeLocalExportPolicyRead() async throws {
        try await fixture { context in
            let url = CompanionExportPolicy.url(paths: context.paths), original = try Data(contentsOf: url)
            defer { try? original.write(to: url, options: .atomic) }
            try Data("deliberately corrupt private QA export policy".utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let wrong = await context.call("export_selection_get", context.payload(expectedTrust: UUID().uuidString))
            XCTAssertEqual(wrong.error?.code, "trust_changed", "The stale context must refuse before parsing local policy")
            XCTAssertTrue(wrong.data.isEmpty)
            let matching = await context.call("export_selection_get", context.payload(expectedTrust: context.peer.trustID))
            XCTAssertNotNil(matching.error, "The same scope reaches and detects the malformed test policy")
            XCTAssertNotEqual(matching.error?.code, "trust_changed")
        }
    }
    func testMatchingAndLegacyCatalogReadsRemainCompatible() async throws {
        try await fixture { context in
            for expected in [context.peer.trustID, nil] as [String?] {
                for operation in ["catalog", "catalog_changes", "export_selection_get"] {
                    let reply = await context.call(operation, context.payload(expectedTrust: expected))
                    XCTAssertNil(reply.error)
                    if operation == "export_selection_get" { XCTAssertNotNil(reply.data["selection"]?.object) }
                    else { XCTAssertEqual(reply.data["generation"]?.string, String(repeating: "c", count: 64)); XCTAssertEqual(reply.data["items"]?.array, []) }
                }
            }
        }
    }
    func testExactCatalogReadReplayAfterForgetRechecksAuthorityInsteadOfReturningCachedData() async throws {
        try await fixture { context in
            let requests = ["catalog", "catalog_changes", "export_selection_get"].map { operation in
                CompanionBrokerRequest(operation: operation, payload: context.payload(expectedTrust: context.peer.trustID), nonce: "catalog-scope-test")
            }
            for request in requests {
                let original = await context.broker.exchange(request, owner: context.owner)
                XCTAssertNil(original.error, request.operation)
                XCTAssertFalse(original.data.isEmpty, "The initial authorized read must produce data before replay is tested")
            }
            let catalogRequests = context.peer.requestedPaths.filter { $0.hasPrefix("/v1/catalog") }.count
            XCTAssertEqual(catalogRequests, 2)
            let forgotten = await context.call("forget", ["device_id": .string(context.peer.deviceID)])
            XCTAssertNil(forgotten.error)
            for request in requests {
                // Keep the exact UUID, operation, payload and owner. A new UUID
                // would exercise perform's preflight but miss a receipt bypass.
                let replay = await context.broker.exchange(request, owner: context.owner)
                XCTAssertEqual(replay.error?.code, "trust_changed", request.operation)
                XCTAssertTrue(replay.data.isEmpty, "An exact read replay must not disclose data from the forgotten trust")
            }
            XCTAssertEqual(context.peer.requestedPaths.filter { $0.hasPrefix("/v1/catalog") }.count, catalogRequests,
                           "Stale expected trust must refuse before another catalog HTTP request")
        }
    }
    func testDelayedCatalogAfterForgetNeverReturnsOldTrustDataEvenForLegacyReader() async throws {
        for operation in ["catalog", "catalog_changes"] {
            let path = operation == "catalog" ? "/v1/catalog" : "/v1/catalog/changes"
            try await fixture(blockedPath: path) { context in
                let pending = Task { await context.call(operation, context.payload(expectedTrust: nil)) }
                do {
                    try await context.waitForBlocked()
                    let forgotten = await context.call("forget", ["device_id": .string(context.peer.deviceID)])
                    XCTAssertNil(forgotten.error)
                    context.peer.releaseBlocked()
                    let stale = await pending.value
                    XCTAssertNotNil(stale.error)
                    XCTAssertTrue(["trust_changed", "cancelled"].contains(stale.error?.code ?? ""))
                    XCTAssertTrue(stale.data.isEmpty, "A formerly valid network response cannot be relabeled as current trust")
                } catch { context.peer.releaseBlocked(); _ = await pending.value; throw error }
            }
        }
    }
    func testDelayedCatalogAfterTransportReplacementCannotPublishIntoNewConnection() async throws {
        for operation in ["catalog", "catalog_changes"] {
            let path = operation == "catalog" ? "/v1/catalog" : "/v1/catalog/changes"
            try await fixture(blockedPath: path) { context in
                let pending = Task { await context.call(operation, context.payload(expectedTrust: context.peer.trustID)) }
                do {
                    try await context.waitForBlocked()
                    let disconnected = await context.call("disconnect", ["device_id": .string(context.peer.deviceID)])
                    XCTAssertNil(disconnected.error)
                    let reconnect = Task { try await context.connect() }
                    context.peer.releaseBlocked()
                    let stale = await pending.value
                    try await reconnect.value
                    XCTAssertNotNil(stale.error); XCTAssertTrue(stale.data.isEmpty)
                    let fresh = await context.call(operation, context.payload(expectedTrust: context.peer.trustID))
                    XCTAssertNil(fresh.error)
                    XCTAssertEqual(fresh.data["generation"]?.string, String(repeating: "c", count: 64))
                } catch { context.peer.releaseBlocked(); _ = await pending.value; throw error }
            }
        }
    }
}
#endif
