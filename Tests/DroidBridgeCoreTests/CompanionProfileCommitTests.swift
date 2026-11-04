import XCTest
@testable import DroidBridgeCore

#if DEBUG
final class CompanionProfileCommitTests: XCTestCase {
    func testRevocationWhileQueuedCannotSendProfileThroughCapturedTransport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-queued-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = ManagedAppsPaths(privateRoot: directory.appendingPathComponent("Managed.noindex"), activeRoot: directory.appendingPathComponent("Apps"))
        let peer = try BrokerAdmissionTLSPeer(blockedPath: "/v1/diagnostics")
        defer { peer.releaseBlocked(); peer.close(); try? CompanionCredentialStore.remove(deviceID: peer.deviceID) }
        let owner = try XCTUnwrap(CompanionBrokerOwner.live(getpid())), id = UUID().uuidString.lowercased(), now = CompanionClock.nowMS()
        try CompanionCredentialStore.save(.init(deviceID: peer.deviceID, trustID: peer.trustID, credential: String(repeating: "A", count: 43), serverPin: peer.serverPin))
        let state: [String: Any] = ["macID": UUID().uuidString, "devices": [["deviceID": peer.deviceID, "name": "Owned queued profile fixture", "aliases": ["emulator-5580"], "preferredSerial": "emulator-5580", "trustID": peer.trustID, "sequence": 0, "profile": "balanced", "exportSelection": [:], "enabled": true]], "registry": ["hosts": [["owner": ["pid": owner.pid, "start": owner.start], "generation": 1, "role": "launcher", "deviceID": peer.deviceID, "serial": "emulator-5580", "updated": Date().timeIntervalSinceReferenceDate, "commandProtocol": 2]], "sessions": [], "commands": [["id": id, "deviceID": peer.deviceID, "kind": "set_profile", "payload": ["profile": "responsive"], "owner": ["pid": owner.pid, "start": owner.start], "generation": 1, "expires": Date().addingTimeInterval(30).timeIntervalSinceReferenceDate, "continuousDeadline": ["bootID": CompanionClock.bootID, "issuedMS": now, "expiresMS": now + 30000], "admitted": true, "admittedAtMS": now, "status": "accepted", "result": [:]]]], "inbox": []]
        let stateURL = directory.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        let broker = CompanionBrokerEngine(directory: directory, managedPaths: paths, testingHooks: .init(endpoint: { _ in peer.url }))
        await broker.start()
        let connected = await broker.exchange(.init(operation: "connect", payload: ["serial": .string("emulator-5580")], nonce: "test"), owner: owner)
        XCTAssertNil(connected.error)
        let blocker = Task { await broker.exchange(.init(operation: "diagnostics", payload: ["device_id": .string(peer.deviceID)], nonce: "test"), owner: owner) }
        for _ in 0..<300 { if peer.blockedRequestSeen { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(peer.blockedRequestSeen)
        let queued = Task { await broker.exchange(.init(operation: "command_profile_commit", payload: ["device_id": .string(peer.deviceID), "command_id": .string(id), "generation": .number(1)], nonce: "test"), owner: owner) }
        for _ in 0..<300 { if await broker.queuedControlCount > 0 { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let waiting = await broker.queuedControlCount; XCTAssertGreaterThan(waiting, 0)
        let forgotten = await broker.exchange(.init(operation: "forget", payload: ["device_id": .string(peer.deviceID)], nonce: "test"), owner: owner)
        XCTAssertNil(forgotten.error)
        peer.releaseBlocked(); _ = await blocker.value
        let result = await queued.value
        XCTAssertNotNil(result.error)
        XCTAssertFalse(peer.requestedPaths.contains("/v1/commands"), "A revoked queued command must not reach the phone")
        await broker.shutdown()
    }
    func testProfilePublicationRequiresExactAdmittedOwnerAndAppliedPhoneReceipt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("profile-commit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = ManagedAppsPaths(privateRoot: directory.appendingPathComponent("Managed.noindex"), activeRoot: directory.appendingPathComponent("Apps"))
        let peer = try BrokerAdmissionTLSPeer()
        defer { peer.close(); try? CompanionCredentialStore.remove(deviceID: peer.deviceID) }
        let owner = try XCTUnwrap(CompanionBrokerOwner.live(getpid())), id = UUID().uuidString.lowercased()
        try CompanionCredentialStore.save(.init(deviceID: peer.deviceID, trustID: peer.trustID, credential: String(repeating: "A", count: 43), serverPin: peer.serverPin))
        let now = CompanionClock.nowMS()
        let state: [String: Any] = ["macID": UUID().uuidString, "devices": [["deviceID": peer.deviceID, "name": "Owned profile fixture", "aliases": ["emulator-5580"], "preferredSerial": "emulator-5580", "trustID": peer.trustID, "sequence": 0, "profile": "balanced", "exportSelection": [:], "enabled": true]], "registry": ["hosts": [["owner": ["pid": owner.pid, "start": owner.start], "generation": 1, "role": "launcher", "deviceID": peer.deviceID, "serial": "emulator-5580", "updated": Date().timeIntervalSinceReferenceDate, "commandProtocol": 2]], "sessions": [], "commands": [["id": id, "deviceID": peer.deviceID, "kind": "run_preset", "payload": ["profile": "responsive"], "owner": ["pid": owner.pid, "start": owner.start], "generation": 1, "expires": Date().addingTimeInterval(30).timeIntervalSinceReferenceDate, "continuousDeadline": ["bootID": CompanionClock.bootID, "issuedMS": now, "expiresMS": now + 30000], "admitted": true, "admittedAtMS": now, "status": "accepted", "result": [:]]]], "inbox": []]
        let stateURL = directory.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        let broker = CompanionBrokerEngine(directory: directory, managedPaths: paths, testingHooks: .init(endpoint: { _ in peer.url }))
        await broker.start()
        let connect = await broker.exchange(.init(operation: "connect", payload: ["serial": .string("emulator-5580")], nonce: "test"), owner: owner)
        XCTAssertNil(connect.error)
        let payload: [String: CompanionJSON] = ["device_id": .string(peer.deviceID), "command_id": .string(id), "generation": .number(1)]
        var stale = payload; stale["generation"] = .number(2)
        let denied = await broker.exchange(.init(operation: "command_profile_commit", payload: stale, nonce: "test"), owner: owner)
        XCTAssertEqual(denied.error?.code, "stale_owner")
        try peer.setCommandStatus("unknown")
        let uncertain = await broker.exchange(.init(operation: "command_profile_commit", payload: payload, nonce: "test"), owner: owner)
        XCTAssertEqual(uncertain.error?.code, "profile_outcome_unknown")
        let status = await broker.exchange(.init(operation: "profile_get", payload: ["device_id": .string(peer.deviceID)], nonce: "test"), owner: owner)
        XCTAssertEqual(status.data["profile"]?.string, "balanced")
        await broker.shutdown()
    }
}
#endif
