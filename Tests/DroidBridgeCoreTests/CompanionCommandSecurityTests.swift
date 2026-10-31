import XCTest
@testable import DroidBridgeCore

/// Independent device-free regressions for command identity and truthful outcomes.
final class CompanionCommandSecurityTests: XCTestCase {
    private func fixture(_ operation: (CompanionBrokerEngine, CompanionBrokerOwner, String, String, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("command-security-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
        let devices: [[String: Any]] = [first, second].enumerated().map { index, id in
            ["deviceID": id, "name": "Independent command fixture", "aliases": ["qa-command-\(index)"], "preferredSerial": "qa-command-\(index)", "trustID": UUID().uuidString, "sequence": 0, "profile": "balanced", "exportSelection": [:], "enabled": true]
        }
        let state: [String: Any] = ["macID": UUID().uuidString, "devices": devices, "registry": ["hosts": [], "sessions": [], "commands": []], "inbox": []]
        let stateURL = root.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        let paths = ManagedAppsPaths(privateRoot: root.appendingPathComponent("Managed.noindex"), activeRoot: root.appendingPathComponent("Apps"))
        let engine = CompanionBrokerEngine(directory: root, automaticReconnect: false, managedPaths: paths)
        await engine.start()
        let owner = try XCTUnwrap(CompanionBrokerOwner.live(getpid()))
        do { try await operation(engine, owner, first, second, stateURL); await engine.shutdown() }
        catch { await engine.shutdown(); throw error }
    }
    private func send(_ engine: CompanionBrokerEngine, _ owner: CompanionBrokerOwner, device: String, kind: String, id: UUID) async -> CompanionBrokerReply {
        await engine.exchange(.init(operation: "host_command", payload: ["device_id": .string(device), "kind": .string(kind), "payload": .object([:])], requestID: id, nonce: "independent-test"), owner: owner)
    }
    private func freshSend(_ original: CompanionBrokerEngine, _ owner: CompanionBrokerOwner, stateURL: URL, device: String, kind: String, id: UUID) async -> CompanionBrokerReply {
        await original.shutdown()
        let root = stateURL.deletingLastPathComponent()
        let engine = CompanionBrokerEngine(directory: root, automaticReconnect: false, managedPaths: .init(privateRoot: root.appendingPathComponent("Managed.noindex"), activeRoot: root.appendingPathComponent("Apps")))
        await engine.start()
        let result = await send(engine, owner, device: device, kind: kind, id: id)
        await engine.shutdown()
        return result
    }
    private func check(_ engine: CompanionBrokerEngine, _ owner: CompanionBrokerOwner, device: String, kind: String, id: UUID, fails: Bool) async {
        let response = await send(engine, owner, device: device, kind: kind, id: id)
        if fails { XCTAssertNotNil(response.error) } else { XCTAssertNil(response.error) }
    }
    private func register(_ engine: CompanionBrokerEngine, _ owner: CompanionBrokerOwner, device: String, sessions: [CompanionJSON] = []) async throws {
        let result = await engine.exchange(.init(operation: "session_publish", payload: ["device_id": .string(device), "serial": .string("qa-command-0"), "generation": .number(1), "command_protocol": .number(2), "role": .string("launcher"), "sessions": .array(sessions)], nonce: "independent-test"), owner: owner)
        XCTAssertNil(result.error)
    }
    func testStopAllIdentityCannotBeReusedForAnotherPhone() async throws {
        try await fixture { engine, owner, first, second, stateURL in
            let id = UUID()
            await self.check(engine, owner, device: first, kind: "stop_all", id: id, fails: false)
            let conflict = await self.freshSend(engine, owner, stateURL: stateURL, device: second, kind: "stop_all", id: id)
            XCTAssertNotNil(conflict.error, "An existing aggregate belongs to its original phone")
        }
    }
    func testStopAllIdentityCannotBeReusedAsDifferentKind() async throws {
        try await fixture { engine, owner, first, _, stateURL in
            try await self.register(engine, owner, device: first)
            let id = UUID()
            await self.check(engine, owner, device: first, kind: "stop_all", id: id, fails: false)
            let conflict = await self.freshSend(engine, owner, stateURL: stateURL, device: first, kind: "diagnostics_request", id: id)
            XCTAssertNotNil(conflict.error)
        }
    }
    func testOrdinaryCommandIdentityCannotBecomeStopAll() async throws {
        try await fixture { engine, owner, first, _, stateURL in
            try await self.register(engine, owner, device: first)
            let id = UUID()
            await self.check(engine, owner, device: first, kind: "diagnostics_request", id: id, fails: false)
            let conflict = await self.freshSend(engine, owner, stateURL: stateURL, device: first, kind: "stop_all", id: id)
            XCTAssertNotNil(conflict.error)
        }
    }
    func testAggregateChildIdentityCannotBecomeAggregateParent() async throws {
        try await fixture { engine, owner, first, _, stateURL in
            let session = UUID()
            try await self.register(engine, owner, device: first, sessions: [.object(["session_id": .string(session.uuidString), "package_name": .string("dev.droidbridge.testapp"), "label": .string("Fixture"), "backend": .string("native"), "phase": .string("running")])])
            await self.check(engine, owner, device: first, kind: "stop_all", id: UUID(), fails: false)
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
            let parents = try XCTUnwrap(state["stopAll"] as? [[String: Any]])
            let child = try XCTUnwrap((parents.first?["children"] as? [String])?.first.flatMap(UUID.init(uuidString:)))
            await self.check(engine, owner, device: first, kind: "stop_all", id: child, fails: true)
        }
    }
    func testExactAggregateRetryDoesNotCaptureNewSessions() async throws {
        try await fixture { engine, owner, first, _, stateURL in
            let id = UUID()
            await self.check(engine, owner, device: first, kind: "stop_all", id: id, fails: false)
            try await self.register(engine, owner, device: first, sessions: [.object(["session_id": .string(UUID().uuidString), "package_name": .string("dev.droidbridge.testapp"), "label": .string("Later session"), "backend": .string("native"), "phase": .string("running")])])
            let retry = await self.freshSend(engine, owner, stateURL: stateURL, device: first, kind: "stop_all", id: id)
            XCTAssertNil(retry.error)
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
            let parents = try XCTUnwrap(state["stopAll"] as? [[String: Any]])
            XCTAssertEqual(parents.count, 1)
            XCTAssertEqual((parents.first?["children"] as? [String])?.count, 0, "Exact retry must retain the immutable original session cohort")
        }
    }
    func testActualXPCAdmissionGrantsExecutionOnlyOnceAcrossBothRetryIdentities() async throws {
        try await fixture { engine, _, first, _, stateURL in
            await engine.shutdown()
            let root = stateURL.deletingLastPathComponent(), nonce = UUID().uuidString
            let service = CompanionBrokerService(directory: root, nonce: nonce, automaticReconnect: false, managedPaths: .init(privateRoot: root.appendingPathComponent("Managed.noindex"), activeRoot: root.appendingPathComponent("Apps")))
            let listener = NSXPCListener.anonymous(); listener.delegate = service; listener.resume()
            defer { listener.invalidate() }
            let client = CompanionBrokerIPCClient(endpoint: listener.endpoint, nonce: nonce)
            do {
                var ready = false
                for _ in 0..<20 {
                    do { _ = try await client.request(operation: "status"); ready = true; break }
                    catch { try await Task.sleep(nanoseconds: 5_000_000) }
                }
                XCTAssertTrue(ready)
                _ = try await client.request(operation: "session_publish", payload: ["device_id": .string(first), "serial": .string("qa-command-0"), "generation": .number(1), "command_protocol": .number(2), "role": .string("launcher"), "sessions": .array([])])
                let queued = try await client.request(operation: "host_command", payload: ["device_id": .string(first), "kind": .string("diagnostics_request"), "payload": .object([:])])
                let id = try XCTUnwrap(queued.data["request_id"]?.string)
                let payload: [String: CompanionJSON] = ["command_id": .string(id), "generation": .number(1)]
                let ipcID = UUID()
                let admission = try await client.request(operation: "command_admit", payload: payload, requestID: ipcID)
                XCTAssertEqual(admission.data["execution_granted"]?.bool, true)
                let exactRetry = try await client.request(operation: "command_admit", payload: payload, requestID: ipcID)
                XCTAssertEqual(exactRetry.data["execution_granted"]?.bool, false, "The IPC receipt cache must not replay an effect grant")
                let distinctRetry = try await client.request(operation: "command_admit", payload: payload)
                XCTAssertEqual(distinctRetry.data["execution_granted"]?.bool, false, "A new IPC identity must not readmit the same command")
                _ = try await client.request(operation: "command_ack", payload: ["command_id": .string(id), "generation": .number(1), "status": .string("applied"), "result": .object([:])])
                let terminal = try await client.request(operation: "command_admit", payload: payload)
                XCTAssertEqual(terminal.data["status"]?.string, "applied")
                XCTAssertEqual(terminal.data["execution_granted"]?.bool, false)
                await client.invalidate(); await service.shutdown()
            } catch { await client.invalidate(); await service.shutdown(); throw error }
        }
    }

    func testUnknownAggregateOutcomeSurvivesChildReceiptEviction() async throws {
        try await assertAggregateStatus(childPresent: true, persistedTerminal: nil)
        try await assertAggregateStatus(childPresent: false, persistedTerminal: "unknown")
    }
    func testMissingChildCrashGapSettlesUnknownWithoutRequeue() async throws {
        try await assertAggregateStatus(childPresent: false, persistedTerminal: nil)
    }
    private func assertAggregateStatus(childPresent: Bool, persistedTerminal: String?) async throws {
        try await fixture { engine, owner, first, _, stateURL in
            await engine.shutdown()
            let parent = UUID().uuidString.lowercased(), child = UUID().uuidString.lowercased()
            var registry = CompanionBrokerRegistry()
            try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: first, serial: "qa-command-0", values: [])
            if childPresent {
                _ = try registry.enqueue(id: child, deviceID: first, kind: "diagnostics_request", payload: [:])
                _ = try registry.admit(id: child, owner: owner, generation: 1)
                _ = try registry.acknowledge(id: child, owner: owner, generation: 1, status: "unknown", result: ["code": .string("test_crash_ambiguity")])
            }
            var state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
            state["registry"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(registry))
            var row: [String: Any] = ["id": parent, "deviceID": first, "children": [child], "expires": Date().timeIntervalSinceReferenceDate, "delivered": persistedTerminal != nil, "phoneReceipt": false]
            if let persistedTerminal { row["terminalStatus"] = persistedTerminal }
            state["stopAll"] = [row]
            try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            let root = stateURL.deletingLastPathComponent()
            let restarted = CompanionBrokerEngine(directory: root, automaticReconnect: false, managedPaths: .init(privateRoot: root.appendingPathComponent("Managed.noindex"), activeRoot: root.appendingPathComponent("Apps")))
            await restarted.start()
            let status = await restarted.exchange(.init(operation: "command_status", payload: ["device_id": .string(first), "request_id": .string(parent)], nonce: "independent-test"), owner: owner)
            XCTAssertNil(status.error)
            XCTAssertEqual(status.data["status"]?.string, "unknown", "Ambiguous child evidence cannot become rejection or renewed acceptance")
            XCTAssertEqual(status.data["result"]?.object?["sessions"]?.number, 1, "Aggregate scope is the immutable original child cohort")
            let pending = await restarted.exchange(.init(operation: "command_poll", payload: ["generation": .number(1)], nonce: "independent-test"), owner: owner)
            XCTAssertTrue(pending.data["commands"]?.array?.isEmpty == true)
            await restarted.shutdown()
        }
    }

    #if DEBUG
    func testRealTLSDelayedAdmissionCannotGrantAfterForgetOrShutdown() async throws {
        for forget in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("command-admission-race-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let id = UUID().uuidString.lowercased()
            let peer = try BrokerAdmissionTLSPeer(blockedPath: "/v1/commands/\(id)/receipt")
            defer { peer.releaseBlocked(); peer.close(); try? CompanionCredentialStore.remove(deviceID: peer.deviceID) }
            let owner = try XCTUnwrap(CompanionBrokerOwner.live(getpid()))
            try CompanionCredentialStore.save(.init(deviceID: peer.deviceID, trustID: peer.trustID, credential: String(repeating: "A", count: 43), serverPin: peer.serverPin))
            var registry = CompanionBrokerRegistry()
            try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: peer.deviceID, serial: "qa-admission", values: [])
            _ = try registry.enqueue(id: id, deviceID: peer.deviceID, kind: "diagnostics_request", payload: [:])
            let state: [String: Any] = ["macID": UUID().uuidString, "devices": [["deviceID": peer.deviceID, "name": "Delayed admission fixture", "aliases": ["qa-admission"], "preferredSerial": "qa-admission", "trustID": peer.trustID, "sequence": 0, "profile": "balanced", "exportSelection": [:], "enabled": true]], "registry": try JSONSerialization.jsonObject(with: JSONEncoder().encode(registry)), "inbox": []]
            let stateURL = root.appendingPathComponent("state.json")
            try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
            let paths = ManagedAppsPaths(privateRoot: root.appendingPathComponent("Managed.noindex"), activeRoot: root.appendingPathComponent("Apps"))
            let engine = CompanionBrokerEngine(directory: root, managedPaths: paths, testingHooks: .init(endpoint: { _ in peer.url }))
            await engine.start()
            let connected = await engine.exchange(.init(operation: "connect", payload: ["serial": .string("qa-admission")], nonce: "independent-test"), owner: owner)
            XCTAssertNil(connected.error)
            let admitted = Task { await engine.exchange(.init(operation: "command_admit", payload: ["command_id": .string(id), "generation": .number(1)], nonce: "independent-test"), owner: owner) }
            let deadline = CompanionClock.nowMS() + 3000
            while !peer.blockedRequestSeen, CompanionClock.nowMS() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(peer.blockedRequestSeen)
            if forget {
                let forgotten = await engine.exchange(.init(operation: "forget", payload: ["device_id": .string(peer.deviceID)], nonce: "independent-test"), owner: owner)
                XCTAssertNil(forgotten.error)
            } else { await engine.shutdown() }
            peer.releaseBlocked()
            let late = await admitted.value
            XCTAssertNotEqual(late.data["execution_granted"]?.bool, true, "A superseded admission cannot grant an effect after its awaited phone receipt")
            await engine.shutdown()
        }
    }
    #endif

    func testLegacyWireOwnerRetainsDashboardButCannotPollOrReceiveActions() async throws {
        try await fixture { engine, owner, first, _, _ in
            let session = UUID().uuidString
            // An older executable omits command_protocol entirely.
            let published = await engine.exchange(.init(operation: "session_publish", payload: ["device_id": .string(first), "serial": .string("qa-command-0"), "generation": .number(1), "role": .string("launcher"), "sessions": .array([.object(["session_id": .string(session), "package_name": .string("dev.droidbridge.testapp"), "label": .string("Legacy running window"), "backend": .string("native"), "phase": .string("running")])])], nonce: "independent-test"), owner: owner)
            XCTAssertNil(published.error, "Old windows may continue publishing dashboard state")
            let status = await engine.exchange(.init(operation: "status", nonce: "independent-test"), owner: owner)
            XCTAssertTrue(status.data["sessions"]?.array?.contains { $0.object?["session_id"]?.string == session } == true)
            let poll = await engine.exchange(.init(operation: "command_poll", payload: ["generation": .number(1)], nonce: "independent-test"), owner: owner)
            XCTAssertEqual(poll.error?.code, "owner_update_required")
            let action = await self.send(engine, owner, device: first, kind: "diagnostics_request", id: UUID())
            XCTAssertEqual(action.error?.code, "owner_update_required")
        }
    }
    func testPersistedMissingCapabilityCannotBeAssignedOrReceiveAdmittedWork() throws {
        let first = UUID().uuidString, owner = CompanionBrokerOwner(pid: 101, start: 1000)
        var registry = CompanionBrokerRegistry()
        try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: first, serial: "qa-command-0", values: [])
        let id = UUID().uuidString
        _ = try registry.enqueue(id: id, deviceID: first, kind: "diagnostics_request", payload: [:])
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(registry)) as! [String: Any]
        var hosts = encoded["hosts"] as! [[String: Any]]; hosts[0].removeValue(forKey: "commandProtocol"); encoded["hosts"] = hosts
        registry = try JSONDecoder().decode(CompanionBrokerRegistry.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertEqual(registry.hosts.count, 1)
        XCTAssertTrue(registry.poll(owner: owner, generation: 1).isEmpty)
        XCTAssertThrowsError(try registry.admit(id: id, owner: owner, generation: 1))
        XCTAssertThrowsError(try registry.enqueue(id: UUID().uuidString, deviceID: first, kind: "diagnostics_request", payload: [:])) { error in
            XCTAssertEqual((error as? CompanionBoundaryError)?.code, "owner_update_required")
        }
    }
    func testCompatibleLauncherNeverReroutesStopFromLegacyWindowOwner() throws {
        let first = UUID().uuidString, session = UUID().uuidString
        let legacy = CompanionBrokerOwner(pid: 101, start: 1000), current = CompanionBrokerOwner(pid: 102, start: 1001)
        var registry = CompanionBrokerRegistry()
        try registry.publish(owner: legacy, generation: 1, role: "wrapper", deviceID: first, serial: "qa-command-0", values: [["session_id": .string(session), "package_name": .string("dev.droidbridge.testapp"), "label": .string("Legacy window"), "backend": .string("native"), "phase": .string("running")]], commandProtocol: 1)
        try registry.publish(owner: current, generation: 1, role: "launcher", deviceID: first, serial: "qa-command-0", values: [])
        let open = try registry.enqueue(id: UUID().uuidString, deviceID: first, kind: "open_app", payload: [:])
        XCTAssertEqual(open.owner, current)
        XCTAssertThrowsError(try registry.enqueue(id: UUID().uuidString, deviceID: first, kind: "stop_session", payload: ["session_id": .string(session)])) { error in
            XCTAssertEqual((error as? CompanionBoundaryError)?.code, "owner_update_required")
        }
        XCTAssertEqual(registry.sessions.first?.owner, legacy)
        XCTAssertEqual(registry.commands.count, 1, "No stop is redirected to a process that does not own the window")
    }

    func testPublishingAnotherPhoneDoesNotInvalidateSameProcessCommandGeneration() throws {
        var registry = CompanionBrokerRegistry()
        let owner = CompanionBrokerOwner(pid: 101, start: 1000), first = UUID().uuidString, second = UUID().uuidString
        try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: first, serial: "qa-first", values: [])
        let id = UUID().uuidString
        _ = try registry.enqueue(id: id, deviceID: first, kind: "diagnostics_request", payload: [:])
        try registry.publish(owner: owner, generation: 2, role: "launcher", deviceID: second, serial: "qa-second", values: [])
        registry.prune(live: { _ in true })
        XCTAssertEqual(registry.commands.first?.status, "accepted", "Generations are fenced within each phone's owner registration")
        XCTAssertEqual(registry.poll(owner: owner, generation: 1).count, 1)
    }
    func testAnotherPhoneHostCannotKeepMissingOwnersAdmittedCommandAlive() throws {
        var registry = CompanionBrokerRegistry()
        let owner = CompanionBrokerOwner(pid: 101, start: 1000), first = UUID().uuidString, second = UUID().uuidString
        try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: first, serial: "qa-first", values: [["session_id": .string(UUID().uuidString), "package_name": .string("dev.droidbridge.testapp"), "label": .string("Former phone owner"), "backend": .string("native"), "phase": .string("running")]])
        try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: second, serial: "qa-second", values: [])
        let id = UUID().uuidString
        _ = try registry.enqueue(id: id, deviceID: first, kind: "diagnostics_request", payload: [:])
        _ = try registry.admit(id: id, owner: owner, generation: 1)
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(registry)) as! [String: Any]
        encoded["hosts"] = (encoded["hosts"] as! [[String: Any]]).filter { $0["deviceID"] as? String != first }
        registry = try JSONDecoder().decode(CompanionBrokerRegistry.self, from: JSONSerialization.data(withJSONObject: encoded))
        registry.prune(live: { _ in true })
        XCTAssertEqual(registry.commands.first?.status, "unknown")
        XCTAssertTrue(registry.sessions.isEmpty, "Another phone registration cannot preserve the missing owner dashboard")
        XCTAssertTrue(registry.poll(owner: owner, generation: 1).isEmpty)
    }
    func testLegacyAcceptedRowsSettleUnknownAndNeverResumeBeforeTheirDeadline() throws {
        for mode in ["legacy_protocol", "missing_capability", "missing_deadline"] {
            var registry = CompanionBrokerRegistry()
            let owner = CompanionBrokerOwner(pid: 101, start: 1000), first = UUID().uuidString
            try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: first, serial: "qa-first", values: [])
            let id = UUID().uuidString
            _ = try registry.enqueue(id: id, deviceID: first, kind: "diagnostics_request", payload: [:])
            var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(registry)) as! [String: Any]
            if mode == "missing_deadline" {
                var commands = encoded["commands"] as! [[String: Any]]; commands[0].removeValue(forKey: "continuousDeadline"); encoded["commands"] = commands
            } else {
                var hosts = encoded["hosts"] as! [[String: Any]]
                if mode == "legacy_protocol" { hosts[0]["commandProtocol"] = 1 } else { hosts[0].removeValue(forKey: "commandProtocol") }
                encoded["hosts"] = hosts
            }
            registry = try JSONDecoder().decode(CompanionBrokerRegistry.self, from: JSONSerialization.data(withJSONObject: encoded))
            registry.prune(live: { _ in true })
            XCTAssertEqual(registry.commands.first?.status, "unknown", mode)
            XCTAssertEqual(registry.commands.first?.result["code"]?.string, "legacy_owner_outcome_unknown", mode)
            XCTAssertTrue(registry.poll(owner: owner, generation: 1).isEmpty)
            let retry = try registry.enqueue(id: id, deviceID: first, kind: "diagnostics_request", payload: [:])
            XCTAssertEqual(retry.status, "unknown", "Exact retry cannot reopen legacy work")
        }
    }

}
