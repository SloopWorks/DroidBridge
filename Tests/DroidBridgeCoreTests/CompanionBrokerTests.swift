import XCTest
@testable import DroidBridgeCore

final class CompanionBrokerTests: XCTestCase {
    let device = UUID().uuidString.lowercased()
    let owner = CompanionBrokerOwner(pid: 101, start: 1000)
    let other = CompanionBrokerOwner(pid: 102, start: 1001)
    func session(_ id: UUID = UUID(), package: String = "dev.droidbridge.testapp") -> [String: CompanionJSON] {
        ["session_id": .string(id.uuidString), "package_name": .string(package), "label": .string("Test"), "backend": .string("native"), "phase": .string("running")]
    }
    func testOwnerKernelIdentityAndProcessReuse() {
        let live = CompanionBrokerOwner.live(getpid())
        XCTAssertNotNil(live); XCTAssertTrue(live!.isAlive)
        XCTAssertFalse(CompanionBrokerOwner(pid: getpid(), start: live!.start + 1).isAlive)
    }
    func testGenerationCannotRegressOrReassignSession() throws {
        var registry = CompanionBrokerRegistry(); let id = UUID()
        try registry.publish(owner: owner, generation: 2, role: "wrapper", deviceID: device, serial: "emulator-5580", values: [session(id)])
        XCTAssertThrowsError(try registry.publish(owner: owner, generation: 1, role: "wrapper", deviceID: device, serial: "emulator-5580", values: []))
        XCTAssertThrowsError(try registry.publish(owner: other, generation: 3, role: "wrapper", deviceID: device, serial: "emulator-5580", values: [session(id)]))
        XCTAssertEqual(registry.sessions.count, 1)
    }
    func testSessionValidationDoesNotPartiallyReplace() throws {
        var registry = CompanionBrokerRegistry()
        try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: device, serial: "emulator-5580", values: [session()])
        XCTAssertThrowsError(try registry.publish(owner: owner, generation: 2, role: "launcher", deviceID: device, serial: "emulator-5580", values: [session(package: "$(touch /tmp/x)")]))
        XCTAssertEqual(registry.hosts.first?.generation, 1)
        XCTAssertEqual(registry.sessions.count, 1)
    }
    func testPhoneSessionCapacityIsGlobalAcrossProcesses() throws {
        var registry = CompanionBrokerRegistry()
        try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: device, serial: "emulator-5580", values: (0..<32).map { _ in session() })
        XCTAssertThrowsError(try registry.publish(owner: other, generation: 1, role: "wrapper", deviceID: device, serial: "emulator-5580", values: [session()]))
    }
    func testStopRoutesExactOwnerAndFencesAcknowledgement() throws {
        var registry = CompanionBrokerRegistry(); let id = UUID(); let command = UUID().uuidString
        try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: device, serial: "emulator-5580", values: [])
        try registry.publish(owner: other, generation: 4, role: "wrapper", deviceID: device, serial: "emulator-5580", values: [session(id)])
        let receipt = try registry.enqueue(id: command, deviceID: device, kind: "stop_session", payload: ["session_id": .string(id.uuidString)])
        XCTAssertEqual(receipt.owner, other); XCTAssertEqual(receipt.generation, 4)
        XCTAssertTrue(registry.poll(owner: owner, generation: 1).isEmpty)
        XCTAssertThrowsError(try registry.acknowledge(id: command, owner: owner, generation: 4, status: "applied", result: [:]))
        XCTAssertThrowsError(try registry.acknowledge(id: command, owner: other, generation: 3, status: "applied", result: [:]))
        _ = try registry.admit(id: command, owner: other, generation: 4)
        _ = try registry.acknowledge(id: command, owner: other, generation: 4, status: "applied", result: [:])
        XCTAssertTrue(registry.poll(owner: other, generation: 4).isEmpty)
        _ = try registry.acknowledge(id: command, owner: other, generation: 4, status: "applied", result: [:])
        XCTAssertThrowsError(try registry.acknowledge(id: command, owner: other, generation: 4, status: "rejected", result: [:]))
    }
    func testIdenticalRetryDoesNotReopenConflictingRetryRejected() throws {
        var registry = CompanionBrokerRegistry(); let id = UUID().uuidString
        try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: device, serial: "emulator-5580", values: [])
        let first = try registry.enqueue(id: id, deviceID: device, kind: "open_app", payload: ["package_name": .string("dev.test.app")])
        let retry = try registry.enqueue(id: id, deviceID: device, kind: "open_app", payload: ["package_name": .string("dev.test.app")])
        XCTAssertEqual(first.id, retry.id); XCTAssertEqual(registry.commands.count, 1)
        XCTAssertThrowsError(try registry.enqueue(id: id, deviceID: device, kind: "open_app", payload: ["package_name": .string("dev.other.app")]))
    }
    func testDeadOwnersAndExpiredCommandsCannotReceive() throws {
        var registry = CompanionBrokerRegistry(); let now = Date()
        try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: device, serial: "emulator-5580", values: [session()])
        _ = try registry.enqueue(id: UUID().uuidString, deviceID: device, kind: "open_app", payload: [:], now: now)
        registry.prune(now: now, live: { _ in false })
        XCTAssertTrue(registry.hosts.isEmpty); XCTAssertTrue(registry.sessions.isEmpty)
        XCTAssertEqual(registry.commands.first?.status, "rejected")
        XCTAssertTrue(registry.poll(owner: owner, generation: 1).isEmpty)
    }
    func testReplacementGenerationCancelsPriorMailbox() throws {
        var registry = CompanionBrokerRegistry()
        try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: device, serial: "emulator-5580", values: [])
        _ = try registry.enqueue(id: UUID().uuidString, deviceID: device, kind: "open_app", payload: [:])
        try registry.publish(owner: owner, generation: 2, role: "launcher", deviceID: device, serial: "emulator-5580", values: [])
        XCTAssertEqual(registry.commands.first?.status, "rejected")
        XCTAssertTrue(registry.poll(owner: owner, generation: 1).isEmpty)
    }
    func testRemoteExpiryNotExtendedAndFutureDeadlinesRejected() throws {
        var registry = CompanionBrokerRegistry(); let now = Date()
        try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: device, serial: "emulator-5580", values: [])
        XCTAssertThrowsError(try registry.enqueue(id: UUID().uuidString, deviceID: device, kind: "open_app", payload: [:], deadline: now.addingTimeInterval(-1), now: now))
        XCTAssertThrowsError(try registry.enqueue(id: UUID().uuidString, deviceID: device, kind: "open_app", payload: [:], deadline: now.addingTimeInterval(120), now: now))
        let command = try registry.enqueue(id: UUID().uuidString, deviceID: device, kind: "open_app", payload: [:], deadline: now.addingTimeInterval(3), now: now)
        XCTAssertEqual(command.expires, now.addingTimeInterval(3))
        XCTAssertTrue(registry.poll(owner: owner, generation: 1, nowMS: command.continuousDeadline!.expiresMS + 1).isEmpty)
    }
    func testOnlyRegisteredLauncherCanOpenAndNoCrossPhoneStop() throws {
        var registry = CompanionBrokerRegistry(); let id = UUID()
        try registry.publish(owner: owner, generation: 1, role: "wrapper", deviceID: device, serial: "emulator-5580", values: [session(id)])
        XCTAssertThrowsError(try registry.enqueue(id: UUID().uuidString, deviceID: device, kind: "open_app", payload: [:]))
        XCTAssertThrowsError(try registry.enqueue(id: UUID().uuidString, deviceID: UUID().uuidString, kind: "stop_session", payload: ["session_id": .string(id.uuidString)]))
    }
    func testMailboxBackpressureAndBoundedPolling() throws {
        var registry = CompanionBrokerRegistry()
        try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: device, serial: "emulator-5580", values: [])
        for _ in 0..<64 { _ = try registry.enqueue(id: UUID().uuidString, deviceID: device, kind: "open_app", payload: [:]) }
        XCTAssertEqual(registry.poll(owner: owner, generation: 1).count, 16)
        XCTAssertThrowsError(try registry.enqueue(id: UUID().uuidString, deviceID: device, kind: "open_app", payload: [:]))
    }
    func testActualAnonymousXPCRoundTripNonceCapsCancellationAndGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("droidbridge-broker-xpc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let device = UUID().uuidString.lowercased()
        let state: [String: Any] = ["macID": UUID().uuidString, "devices": [["deviceID": device, "name": "Owned fixture", "aliases": ["emulator-5580"], "preferredSerial": "emulator-5580", "trustID": UUID().uuidString, "sequence": 0, "profile": "balanced", "exportSelection": [:], "enabled": true]], "registry": ["hosts": [], "sessions": [], "commands": []], "inbox": []]
        let url = root.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: state).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let nonce = UUID().uuidString
        let service = CompanionBrokerService(directory: root, nonce: nonce, automaticReconnect: false)
        let listener = NSXPCListener.anonymous(); listener.delegate = service; listener.resume()
        defer { listener.invalidate() }
        let client = CompanionBrokerIPCClient(endpoint: listener.endpoint, nonce: nonce)
        var status: CompanionBrokerReply?
        for _ in 0..<20 {
            do { status = try await client.request(operation: "status"); break }
            catch { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertNotNil(status); XCTAssertEqual(status?.data["devices"]?.array?.count, 1)
        let bad = CompanionBrokerIPCClient(endpoint: listener.endpoint, nonce: "wrong")
        do { _ = try await bad.request(operation: "status"); XCTFail("Wrong nonce was admitted") }
        catch { XCTAssertEqual((error as? CompanionBoundaryError)?.code, "unauthorized_ipc") }
        let metadata: [String: CompanionJSON] = ["device_id": .string(device), "serial": .string("emulator-5580"), "generation": .number(2), "command_protocol": .number(2), "role": .string("launcher"), "sessions": .array([]), "pid": .number(999_999)]
        _ = try await client.request(operation: "session_publish", payload: metadata)
        var stale = metadata; stale["generation"] = .number(1)
        do { _ = try await client.request(operation: "session_publish", payload: stale); XCTFail("Stale generation was admitted") }
        catch { XCTAssertEqual((error as? CompanionBoundaryError)?.code, "stale_owner") }
        let cancellationID = UUID()
        let cancelled = try await client.request(operation: "cancel", payload: ["request_id": .string(cancellationID.uuidString)])
        XCTAssertEqual(cancelled.data["status"]?.string, "cancellation_requested")
        do { _ = try await client.request(operation: "status", payload: ["oversized": .string(String(repeating: "x", count: 262_144))]); XCTFail("Oversized IPC request admitted") }
        catch { XCTAssertEqual((error as? CompanionBoundaryError)?.code, "payload_too_large") }
        let queued = try await client.request(operation: "host_command", payload: ["device_id": .string(device), "kind": .string("set_profile"), "payload": .object(["profile": .string("balanced")])])
        let commandID = try XCTUnwrap(queued.data["request_id"]?.string)
        let polled = try await client.request(operation: "command_poll", payload: ["generation": .number(2)])
        let command = try XCTUnwrap(polled.data["commands"]?.array?.first?.object)
        XCTAssertNotNil(command["continuous_deadline"]?.object?["boot_id"]?.string)
        let admitted = try await client.request(operation: "command_admit", payload: ["command_id": .string(commandID), "generation": .number(2)])
        XCTAssertEqual(admitted.data["status"]?.string, "accepted"); XCTAssertEqual(admitted.data["admitted"]?.bool, true)
        let afterAdmission = try await client.request(operation: "command_poll", payload: ["generation": .number(2)])
        XCTAssertTrue(afterAdmission.data["commands"]?.array?.isEmpty == true)
        let completed = try await client.request(operation: "command_ack", payload: ["command_id": .string(commandID), "generation": .number(2), "status": .string("applied"), "result": .object([:])])
        XCTAssertEqual(completed.data["status"]?.string, "applied")
        let replay = try await client.request(operation: "command_admit", payload: ["command_id": .string(commandID), "generation": .number(2)])
        XCTAssertEqual(replay.data["status"]?.string, "applied", "A canonical admit retry returns history, not new work")
        let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let registry = persisted["registry"] as! [String: Any]
        let hosts = registry["hosts"] as! [[String: Any]]
        let owner = hosts.first!["owner"] as! [String: Any]
        XCTAssertEqual(owner["pid"] as? Int, Int(getpid()))
        await client.invalidate(); await bad.invalidate(); await service.shutdown()
    }
    func testActualXPCInFlightCancellationReturnsBeforeLateReply() async throws {
        let endpoint = DelayedBrokerTestEndpoint()
        let listener = NSXPCListener.anonymous(); listener.delegate = endpoint; listener.resume()
        defer { listener.invalidate() }
        let client = CompanionBrokerIPCClient(endpoint: listener.endpoint, nonce: "isolated-test-nonce")
        let operation = Task { try await client.request(operation: "status") }
        try await Task.sleep(nanoseconds: 30_000_000)
        let start = Date(); operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled operation returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        // The late callback must be harmless; cancellation is an explicit independent control request.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(endpoint.sawCancellation)
        await client.invalidate()
    }
    func testSignedHostValidationRejectsSubstitutionSymlinkAndWrongProcess() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("droidbridge-host-check-\(UUID().uuidString)")
        let app = root.appendingPathComponent("DroidBridge.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = macos.appendingPathComponent("DroidBridge")
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: executable.path)
        let plist: [String: String] = ["CFBundleIdentifier": "app.droidbridge.desktop", "CFBundleExecutable": "DroidBridge", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", app.path], timeout: 10)
        let registered = try CompanionBrokerHostApplication.validate(path: app.path)
        try registered.revalidate()
        XCTAssertEqual(registered.openArguments(scope: nil), ["-n", app.path])
        XCTAssertThrowsError(try CompanionBrokerHostApplication.register(path: app.path, owner: CompanionBrokerOwner.live(getpid())!))
        let alias = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: app)
        XCTAssertThrowsError(try CompanionBrokerHostApplication.validate(path: alias.path))
        // A changed executable cannot inherit the previously registered host trust.
        let handle = try FileHandle(forWritingTo: executable); try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        XCTAssertThrowsError(try registered.revalidate())
    }
    func testNonceConstantTimeComparisonAndEnvelopeCorrelation() throws {
        XCTAssertTrue(CompanionBrokerIPC.constantTimeEqual("abc", "abc")); XCTAssertFalse(CompanionBrokerIPC.constantTimeEqual("abc", "abd")); XCTAssertFalse(CompanionBrokerIPC.constantTimeEqual("a", "aa"))
        let request = CompanionBrokerRequest(operation: "status", nonce: "not-logged")
        let bytes = try JSONEncoder().encode(request); let decoded = try JSONDecoder().decode(CompanionBrokerRequest.self, from: bytes)
        XCTAssertEqual(request.requestID, decoded.requestID)
        let reply = CompanionBrokerReply(requestID: request.requestID, data: ["paired": .bool(true)])
        XCTAssertEqual(try JSONDecoder().decode(CompanionBrokerReply.self, from: JSONEncoder().encode(reply)).requestID, request.requestID)
    }
}

private final class DelayedBrokerTestEndpoint: NSObject, NSXPCListenerDelegate, CompanionBrokerXPCProtocol {
    private let lock = NSLock(); private var cancellation = false
    var sawCancellation: Bool { lock.lock(); defer { lock.unlock() }; return cancellation }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: CompanionBrokerXPCProtocol.self)
        connection.exportedObject = self; connection.resume(); return true
    }
    func exchange(_ bytes: Data, reply: @escaping (Data) -> Void) {
        let request = try! JSONDecoder().decode(CompanionBrokerRequest.self, from: bytes)
        if request.operation == "cancel" { lock.lock(); cancellation = true; lock.unlock() }
        let output = try! JSONEncoder().encode(CompanionBrokerReply(requestID: request.requestID))
        DispatchQueue.global().asyncAfter(deadline: .now() + (request.operation == "cancel" ? 0 : 0.3)) { reply(output) }
    }
}

extension CompanionBrokerTests {
    func testBrokerRejectsPinlessEnrollmentAndUnpinnedConnectBeforePhoneIO() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("broker-pin-gate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = CompanionBrokerEngine(directory: directory, automaticReconnect: false)
        await engine.start()
        let owner = try XCTUnwrap(CompanionBrokerOwner.live(getpid()))
        let secret = String(repeating: "A", count: 43)
        let values: [(String, [String: CompanionJSON], String)] = [
            ("connect", ["serial": .string("unpaired-owned-test")], "missing_server_pin"),
            ("begin_pair", ["serial": .string("unpaired-owned-test"), "secret": .string(secret)], "missing_server_pin"),
            ("begin_pair", ["serial": .string("unpaired-owned-test"), "secret": .string(secret), "server_pin": .string("bad")], "invalid_server_pin")
        ]
        for (operation, payload, code) in values {
            let request = CompanionBrokerRequest(operation: operation, payload: payload, nonce: "test")
            let reply = await engine.exchange(request, owner: owner)
            XCTAssertEqual(reply.requestID, request.requestID)
            XCTAssertEqual(reply.error?.code, code)
            XCTAssertFalse(reply.error?.message.contains(secret) ?? true)
        }
        await engine.shutdown()
    }
}

extension CompanionBrokerTests {
    func testMacIdentityPersistsBeforeAnyPhoneRequestAndUnsafeStateFailsClosed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("broker-durable-id-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = CompanionBrokerEngine(directory: directory, automaticReconnect: false)
        await first.start()
        let state = directory.appendingPathComponent("state.json")
        let initial = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])?["macID"] as? String)
        XCTAssertNotNil(UUID(uuidString: initial))
        await first.shutdown()
        let second = CompanionBrokerEngine(directory: directory, automaticReconnect: false)
        await second.start()
        let restored = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(contentsOf: state)) as? [String: Any])?["macID"] as? String)
        XCTAssertEqual(initial, restored)
        await second.shutdown()
        let target = directory.appendingPathComponent("must-not-replace")
        let sentinel = Data("preserved".utf8); try sentinel.write(to: target)
        try FileManager.default.removeItem(at: state)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: target)
        let unsafe = CompanionBrokerEngine(directory: directory, automaticReconnect: false)
        await unsafe.start()
        let request = CompanionBrokerRequest(operation: "status", nonce: "test")
        let reply = await unsafe.exchange(request, owner: try XCTUnwrap(CompanionBrokerOwner.live(getpid())))
        XCTAssertEqual(reply.error?.code, "broker_storage_unavailable")
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
        await unsafe.shutdown()
    }
}

extension CompanionBrokerTests {
    func testLocalForgetDeletesOnlyExactCredentialAndRetainsPolicyAndOtherPhone() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("broker-forget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let device = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
        defer { try? CompanionCredentialStore.remove(deviceID: device); try? CompanionCredentialStore.remove(deviceID: other) }
        let trust = UUID().uuidString.lowercased(), otherTrust = UUID().uuidString.lowercased()
        let credential = try CompanionCredentialRecord(deviceID: device, trustID: trust, credential: String(repeating: "A", count: 43), serverPin: String(repeating: "a", count: 64))
        let otherCredential = try CompanionCredentialRecord(deviceID: other, trustID: otherTrust, credential: String(repeating: "B", count: 43), serverPin: String(repeating: "b", count: 64))
        try CompanionCredentialStore.save(credential); try CompanionCredentialStore.save(otherCredential)
        let paths = ManagedAppsPaths(privateRoot: root.appendingPathComponent("Managed.noindex"), activeRoot: root.appendingPathComponent("Apps"))
        let catalog = ManagedAppCatalog(paths: paths)
        try catalog.bindCompanionExportAuthority(deviceID: device, trustID: trust, aliases: ["emulator-5580"])
        try catalog.applyCompanionExport(deviceID: device, trustID: trust, packageName: "com.example.hidden", selected: false, revision: 4)
        func peer(_ id: String, _ trust: String, _ serial: String) -> [String: Any] { ["deviceID": id, "name": "Owned test", "aliases": [serial], "preferredSerial": serial, "trustID": trust, "sequence": 22, "profile": "battery", "exportSelection": [:], "enabled": true] }
        let state: [String: Any] = ["macID": UUID().uuidString, "devices": [peer(device, trust, "emulator-5580"), peer(other, otherTrust, "emulator-5582")], "registry": ["hosts": [], "sessions": [], "commands": []], "inbox": []]
        let stateURL = root.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        let engine = CompanionBrokerEngine(directory: root, automaticReconnect: false, managedPaths: paths)
        await engine.start()
        let owner = try XCTUnwrap(CompanionBrokerOwner.live(getpid()))
        let request = CompanionBrokerRequest(operation: "forget", payload: ["device_id": .string(device)], nonce: "direct-test-only")
        let response = await engine.exchange(request, owner: owner)
        XCTAssertNil(response.error); XCTAssertEqual(response.data["status"]?.string, "forgotten")
        XCTAssertNil(try CompanionCredentialStore.load(deviceID: device)); XCTAssertEqual(try CompanionCredentialStore.load(deviceID: other), otherCredential)
        XCTAssertEqual(try catalog.companionExportSelection(deviceID: device), ["com.example.hidden": false])
        XCTAssertTrue(try catalog.companionExportWasForgotten(deviceID: device))
        let status = await engine.exchange(.init(operation: "status", nonce: "direct-test-only"), owner: owner)
        let devices = status.data["devices"]!.array!.compactMap(\.object)
        XCTAssertEqual(devices.first(where: { $0["device_id"]?.string == device })?["paired"]?.bool, false)
        XCTAssertEqual(devices.first(where: { $0["device_id"]?.string == device })?["profile"]?.string, "battery")
        XCTAssertEqual(devices.first(where: { $0["device_id"]?.string == other })?["paired"]?.bool, true)
        let replay = await engine.exchange(request, owner: owner)
        XCTAssertEqual(replay.data["status"]?.string, "forgotten")
        await engine.shutdown()
    }
}
