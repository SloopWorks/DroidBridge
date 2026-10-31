import XCTest
@testable import DroidBridgeCore

#if DEBUG
private actor NotificationAdmissionProbe {
    private(set) var entered = false
    func mark() { entered = true }
}

private actor NotificationPollerGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    func enter() async throws {
        count += 1
        if count == 1 { await withCheckedContinuation { continuation = $0 }; throw CompanionBoundaryError("old_poller_fault", "Old poller released after replacement") }
    }
    func release() { continuation?.resume(); continuation = nil }
}

/// Real pinned HTTPS and production broker admission; no devices, banners or OS permission APIs.
final class CompanionNotificationSecurityTests: XCTestCase {
    private func fixture(blockedPath: String = "", gate: NotificationAdmissionProbe? = nil, pollerGate: NotificationPollerGate? = nil, inboxOrigin: String = "none", notificationScopeV2: Bool = true, retentionHistory: Bool = false,
                         _ action: (CompanionBrokerEngine, CompanionBrokerOwner, BrokerAdmissionTLSPeer) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notification-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let peer = try BrokerAdmissionTLSPeer(blockedPath: blockedPath, notificationScopeV2: notificationScopeV2)
        defer { peer.releaseBlocked(); peer.close(); try? CompanionCredentialStore.remove(deviceID: peer.deviceID) }
        try CompanionCredentialStore.save(.init(deviceID: peer.deviceID, trustID: peer.trustID, credential: String(repeating: "A", count: 43), serverPin: peer.serverPin))
        var inbox: [[String: Any]] = []
        if inboxOrigin != "none" {
            var row: [String: Any] = ["id": UUID().uuidString.lowercased(), "deviceID": peer.deviceID, "kind": "notification_posted", "created": Date().timeIntervalSinceReferenceDate, "payload": ["notification_key": "synthetic-key", "action_id": "synthetic-action", "can_reply": true]]
            if inboxOrigin != "legacy" { row["trustID"] = inboxOrigin == "current" ? peer.trustID : UUID().uuidString.lowercased() }
            inbox = [row]
        }
        if retentionHistory {
            inbox.append(["id": "retained-share", "deviceID": peer.deviceID, "kind": "share_text", "created": Date().timeIntervalSinceReferenceDate, "payload": ["text": "QA non-notification history"]])
            inbox.append(["id": "other-device-note", "deviceID": "6b00ca00-604d-436a-9fe8-fd4d6095fb60", "kind": "notification_posted", "created": Date().timeIntervalSinceReferenceDate, "payload": [:], "trustID": UUID().uuidString.lowercased()])
        }
        let state: [String: Any] = ["macID": UUID().uuidString, "devices": [["deviceID": peer.deviceID, "name": "Independent notification peer", "aliases": ["qa-notification"], "preferredSerial": "qa-notification", "trustID": peer.trustID, "epoch": peer.deviceID, "sequence": 0, "profile": "balanced", "exportSelection": [:], "enabled": true]], "registry": ["hosts": [], "sessions": [], "commands": []], "inbox": inbox]
        let file = root.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: state).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let hooks = CompanionBrokerTestingHooks(endpoint: { _ in peer.url }, checkpoint: { name, _ in
            if name == "notification_preferences_pre_lane" { await gate?.mark() }
            if name == "events_received" { try await pollerGate?.enter() }
        })
        let broker = CompanionBrokerEngine(directory: root, managedPaths: .init(privateRoot: root.appendingPathComponent("Managed.noindex"), activeRoot: root.appendingPathComponent("Apps")), testingHooks: hooks)
        await broker.start()
        let owner = try XCTUnwrap(CompanionBrokerOwner.live(getpid()))
        let connected = await broker.exchange(.init(operation: "connect", payload: ["serial": .string("qa-notification")], nonce: "security-test"), owner: owner)
        XCTAssertNil(connected.error)
        do { try await action(broker, owner, peer); await broker.shutdown() }
        catch { await broker.shutdown(); throw error }
    }
    private func preference(_ peer: BrokerAdmissionTLSPeer, expected: String?) -> [String: CompanionJSON] {
        var value: [String: CompanionJSON] = ["device_id": .string(peer.deviceID), "payload": .object(["enabled": .bool(true), "packages": .array([])])]
        if let expected { value["expected_trust_id"] = .string(expected) }
        return value
    }
    func testMissingAndMismatchedTrustNeverSendNotificationPreference() async throws {
        try await fixture { broker, owner, peer in
            for expected in [nil, UUID().uuidString] as [String?] {
                let result = await broker.exchange(.init(operation: "notification_preferences", payload: self.preference(peer, expected: expected), nonce: "security-test"), owner: owner)
                XCTAssertNotNil(result.error)
            }
            XCTAssertTrue(peer.commandBodies.isEmpty, "A stale or unbound notification intent must fail before the authenticated command")
        }
    }
    func testLegacyPhoneWithoutScopeCapabilityReceivesNoNotificationCommand() async throws {
        try await fixture(notificationScopeV2: false) { broker, owner, peer in
            let result = await broker.exchange(.init(operation: "notification_preferences", payload: self.preference(peer, expected: peer.trustID), nonce: "security-test"), owner: owner)
            XCTAssertEqual(result.error?.code, "companion_update_required")
            XCTAssertTrue(peer.commandBodies.isEmpty)
        }
    }
    func testAdmittedPreferenceCarriesExpectedTrustInCanonicalWirePayload() async throws {
        try await fixture { broker, owner, peer in
            let result = await broker.exchange(.init(operation: "notification_preferences", payload: self.preference(peer, expected: peer.trustID), nonce: "security-test"), owner: owner)
            XCTAssertNil(result.error)
            let command = try XCTUnwrap(peer.commandBodies.last)
            XCTAssertEqual(command["kind"] as? String, "notification_preferences")
            XCTAssertEqual((command["payload"] as? [String: Any])?["expected_trust_id"] as? String, peer.trustID)
        }
    }
    func testHistoricalNotificationActionsAreRefusedBeforeWire() async throws {
        for origin in ["legacy", "stale"] {
            try await fixture(inboxOrigin: origin) { broker, owner, peer in
                for operation in ["notification_reply", "notification_dismiss"] {
                    let result = await broker.exchange(.init(operation: operation, payload: ["device_id": .string(peer.deviceID), "expected_trust_id": .string(peer.trustID), "payload": .object(["notification_key": .string("synthetic-key"), "action_id": .string("synthetic-action"), "text": .string("QA reply")])], nonce: "security-test"), owner: owner)
                    XCTAssertEqual(result.error?.code, "notification_unavailable")
                }
                XCTAssertTrue(peer.commandBodies.isEmpty)
            }
        }
    }
    func testCurrentNotificationActionsCarryOriginalTrust() async throws {
        try await fixture(inboxOrigin: "current") { broker, owner, peer in
            for operation in ["notification_reply", "notification_dismiss"] {
                let result = await broker.exchange(.init(operation: operation, payload: ["device_id": .string(peer.deviceID), "expected_trust_id": .string(peer.trustID), "payload": .object(["notification_key": .string("synthetic-key"), "action_id": .string("synthetic-action"), "text": .string("QA reply")])], nonce: "security-test"), owner: owner)
                XCTAssertNil(result.error)
            }
            XCTAssertEqual(peer.commandBodies.count, 2)
            for command in peer.commandBodies { XCTAssertEqual((command["payload"] as? [String: Any])?["expected_trust_id"] as? String, peer.trustID) }
        }
    }
    func testEventResetAndEpochChangeInvalidateOnlyDeviceNotifications() async throws {
        for explicitReset in [true, false] {
            try await fixture(inboxOrigin: "current", retentionHistory: true) { broker, owner, peer in
                let epoch = explicitReset ? peer.deviceID : UUID().uuidString.lowercased()
                try peer.setEventPage(epoch: epoch, reset: explicitReset)
                let deadline = CompanionClock.nowMS() + 3000
                var items: [CompanionJSON] = []
                repeat {
                    let response = await broker.exchange(.init(operation: "inbox_list", payload: ["device_id": .string(peer.deviceID)], nonce: "security-test"), owner: owner)
                    XCTAssertNil(response.error)
                    items = response.data["items"]?.array ?? []
                    if !items.contains(where: { $0.object?["kind"]?.string == "notification_posted" }) { break }
                    try await Task.sleep(nanoseconds: 10_000_000)
                } while CompanionClock.nowMS() < deadline
                XCTAssertFalse(items.contains { $0.object?["kind"]?.string == "notification_posted" }, "A missed-removal stream cannot preserve actionable notification rows")
                XCTAssertTrue(items.contains { $0.object?["id"]?.string == "retained-share" }, "Notification reset must preserve shared content history")
                let other = await broker.exchange(.init(operation: "inbox_list", payload: ["device_id": .string("6b00ca00-604d-436a-9fe8-fd4d6095fb60")], nonce: "security-test"), owner: owner)
                XCTAssertNil(other.error)
                XCTAssertEqual(other.data["items"]?.array?.first?.object?["id"]?.string, "other-device-note", "Another phone's notification state cannot be removed")
            }
        }
    }
    func testAuthenticatedEventFailureInvalidatesOnlyDeviceNotifications() async throws {
        try await fixture(inboxOrigin: "current", retentionHistory: true) { broker, owner, peer in
            try peer.failEventAuthorization()
            let deadline = CompanionClock.nowMS() + 3000
            var items: [CompanionJSON] = []
            repeat {
                let response = await broker.exchange(.init(operation: "inbox_list", payload: ["device_id": .string(peer.deviceID)], nonce: "security-test"), owner: owner)
                XCTAssertNil(response.error)
                items = response.data["items"]?.array ?? []
                if !items.contains(where: { $0.object?["kind"]?.string == "notification_posted" }) { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            } while CompanionClock.nowMS() < deadline
            XCTAssertFalse(items.contains { $0.object?["kind"]?.string == "notification_posted" })
            XCTAssertTrue(items.contains { $0.object?["id"]?.string == "retained-share" })
            let other = await broker.exchange(.init(operation: "inbox_list", payload: ["device_id": .string("6b00ca00-604d-436a-9fe8-fd4d6095fb60")], nonce: "security-test"), owner: owner)
            XCTAssertEqual(other.data["items"]?.array?.first?.object?["id"]?.string, "other-device-note")
            let result = await broker.exchange(.init(operation: "notification_preferences", payload: self.preference(peer, expected: peer.trustID), nonce: "security-test"), owner: owner)
            XCTAssertEqual(result.error?.code, "phone_unavailable")
            XCTAssertTrue(peer.commandBodies.isEmpty)
        }
    }
    func testOldPollerFailureCannotRemoveReconnectedTransport() async throws {
        let gate = NotificationPollerGate()
        try await fixture(pollerGate: gate) { broker, owner, peer in
            let deadline = CompanionClock.nowMS() + 3000
            while await gate.count == 0, CompanionClock.nowMS() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            let firstCount = await gate.count
            XCTAssertEqual(firstCount, 1)
            let disconnected = await broker.exchange(.init(operation: "disconnect", payload: ["device_id": .string(peer.deviceID)], nonce: "security-test"), owner: owner)
            XCTAssertNil(disconnected.error)
            let reconnected = await broker.exchange(.init(operation: "connect", payload: ["serial": .string("qa-notification")], nonce: "security-test"), owner: owner)
            XCTAssertNil(reconnected.error)
            let nextDeadline = CompanionClock.nowMS() + 3000
            while await gate.count < 2, CompanionClock.nowMS() < nextDeadline { try await Task.sleep(nanoseconds: 5_000_000) }
            let replacementCount = await gate.count
            XCTAssertGreaterThanOrEqual(replacementCount, 2, "The successor must already receive real TLS events before the old failure resumes")
            await gate.release()
            try await Task.sleep(nanoseconds: 200_000_000)
            let result = await broker.exchange(.init(operation: "notification_preferences", payload: self.preference(peer, expected: peer.trustID), nonce: "security-test"), owner: owner)
            XCTAssertNil(result.error, "A cancelled old poller must not disconnect the current verified transport")
            XCTAssertEqual(peer.commandBodies.count, 1)
        }
    }
    func testQueuedPreferenceRevalidatesTrustBeforeEnteringWire() async throws {
        let gate = NotificationAdmissionProbe()
        try await fixture(blockedPath: "/v1/diagnostics", gate: gate) { broker, owner, peer in
            let blocker = Task { await broker.exchange(.init(operation: "diagnostics", payload: ["device_id": .string(peer.deviceID)], nonce: "security-test"), owner: owner) }
            let firstDeadline = CompanionClock.nowMS() + 3000
            while !peer.blockedRequestSeen, CompanionClock.nowMS() < firstDeadline { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(peer.blockedRequestSeen)
            let pending = Task { await broker.exchange(.init(operation: "notification_preferences", payload: self.preference(peer, expected: peer.trustID), nonce: "security-test"), owner: owner) }
            let secondDeadline = CompanionClock.nowMS() + 3000
            while !(await gate.entered), CompanionClock.nowMS() < secondDeadline { try await Task.sleep(nanoseconds: 5_000_000) }
            let admittedBeforeRevoke = await gate.entered
            XCTAssertTrue(admittedBeforeRevoke, "The preference must cross initial identity admission before the trust changes")
            let forgotten = await broker.exchange(.init(operation: "forget", payload: ["device_id": .string(peer.deviceID)], nonce: "security-test"), owner: owner)
            XCTAssertNil(forgotten.error)
            peer.releaseBlocked()
            _ = await blocker.value
            let result = await pending.value
            XCTAssertNotNil(result.error)
            XCTAssertTrue(peer.commandBodies.isEmpty, "Queued work cannot enable sharing after Forget changes its trust")
        }
    }
}
#endif
