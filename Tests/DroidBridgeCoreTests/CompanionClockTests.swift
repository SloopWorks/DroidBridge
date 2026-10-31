import XCTest
@testable import DroidBridgeCore

final class CompanionClockTests: XCTestCase {
    let device = UUID(), epoch = UUID(), boot = UUID().uuidString.lowercased()
    func hello(wall: Int64 = 1_800_000_000, uptime: Int64 = 100_000, epoch: UUID? = nil) throws -> CompanionHello {
        let bytes = try JSONSerialization.data(withJSONObject: ["device_id": device.uuidString, "device_name": "Clock fixture", "protocol_min": 1, "protocol_max": 1, "capabilities": ["clock_anchor_v1"], "server_time": wall, "server_uptime_ms": uptime, "clock_epoch": (epoch ?? self.epoch).uuidString])
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(CompanionHello.self, from: bytes)
    }
    func testPinnedTLSIdentityChangeRejectsClockBeforeCommand() async throws {
        let unexpected = UUID().uuidString, epoch = self.epoch.uuidString
        let peer = try CompanionTLSFixture { request in
            Self.reply(["device_id": unexpected, "device_name": "Changed identity", "protocol_min": 1, "protocol_max": 1, "capabilities": ["clock_anchor_v1"], "clock_epoch": epoch, "server_time": 1800000000, "server_uptime_ms": 100000], request)
        }; defer { peer.close() }
        let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: String(repeating: "A", count: 43))
        try await client.setExpectedDeviceID(device.uuidString)
        do { _ = try await client.sendCommand(kind: "clipboard_text", payload: ["text": .string("synthetic")]); XCTFail("Changed identity admitted a clock") }
        catch { XCTAssertEqual((error as? CompanionBoundaryError)?.code, "identity_changed") }
        XCTAssertTrue(peer.request.hasPrefix("GET /v1/hello")); XCTAssertFalse(peer.request.contains("synthetic"))
    }
    func testActualTLSEpochResetCannotRefreshCanonicalRequestExpiry() async throws {
        let device = device.uuidString, epochs = ClockFixtureEpochs(), id = UUID()
        let peer = try CompanionTLSFixture(maximumRequests: 3, requestResponse: { request, raw in
            if raw.hasPrefix("GET /v1/hello") {
                return Self.reply(["device_id": device, "device_name": "Clock fixture", "protocol_min": 1, "protocol_max": 1, "capabilities": ["clock_anchor_v1"], "clock_epoch": epochs.next(), "server_time": 1800000000, "server_uptime_ms": 100000], request)
            }
            return Self.reply(["request_id": id.uuidString, "status": "applied"], request)
        }, response: { _ in Data() }); defer { peer.close() }
        let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: String(repeating: "A", count: 43))
        try await client.setExpectedDeviceID(device)
        _ = try await client.sendCommand(kind: "clipboard_text", payload: ["text": .string("synthetic")], requestID: id)
        _ = try await client.hello()
        do { _ = try await client.sendCommand(kind: "clipboard_text", payload: ["text": .string("synthetic")], requestID: id); XCTFail("Old identity was assigned a fresh expiry") }
        catch { XCTAssertEqual((error as? CompanionBoundaryError)?.code, "request_expired") }
        XCTAssertTrue(peer.request.hasPrefix("GET /v1/hello"), "Expired retry must fail before additional transport")
    }
    func testActualTLSCancelledClockSamplingNeverPostsEffect() async throws {
        let device = device.uuidString, epoch = epoch.uuidString
        let peer = try CompanionTLSFixture(delay: 0.15) { request in Self.reply(["device_id": device, "device_name": "Clock fixture", "protocol_min": 1, "protocol_max": 1, "capabilities": ["clock_anchor_v1"], "clock_epoch": epoch, "server_time": 1800000000, "server_uptime_ms": 100000], request) }; defer { peer.close() }
        let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: String(repeating: "A", count: 43))
        try await client.setExpectedDeviceID(device)
        let task = Task { try await client.sendCommand(kind: "clipboard_text", payload: ["text": .string("synthetic")]) }
        try await Task.sleep(nanoseconds: 20_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled clock sampling returned success") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(peer.request.contains("POST /v1/commands")); XCTAssertFalse(peer.request.contains("synthetic"))
    }
    func testActualTLSLocalExpiryNeverReissuesSameRequestID() async throws {
        let device = device.uuidString, epoch = epoch.uuidString, id = UUID()
        let peer = try CompanionTLSFixture(maximumRequests: 2, requestResponse: { request, raw in
            if raw.hasPrefix("GET /v1/hello") { return Self.reply(["device_id": device, "device_name": "Clock fixture", "protocol_min": 1, "protocol_max": 1, "capabilities": ["clock_anchor_v1"], "clock_epoch": epoch, "server_time": 1800000000, "server_uptime_ms": 100000], request) }
            return Self.reply(["request_id": id.uuidString, "status": "applied"], request)
        }, response: { _ in Data() }); defer { peer.close() }
        let client = try CompanionClient(baseURL: peer.url, serverPin: peer.serverPin, credential: String(repeating: "A", count: 43))
        try await client.setExpectedDeviceID(device)
        _ = try await client.sendCommand(kind: "clipboard_text", payload: ["text": .string("synthetic")], requestID: id)
        let original = peer.request
        try await Task.sleep(nanoseconds: 30_100_000_000)
        do { _ = try await client.sendCommand(kind: "clipboard_text", payload: ["text": .string("synthetic")], requestID: id); XCTFail("Expired request was revived") }
        catch { XCTAssertEqual((error as? CompanionBoundaryError)?.code, "request_expired") }
        XCTAssertEqual(peer.request, original)
    }
    private static func reply(_ data: [String: Any], _ request: String) -> Data {
        CompanionTLSFixture.response(try! JSONSerialization.data(withJSONObject: ["protocol": 1, "request_id": request, "data": data]))
    }
    func testWallClockSkewAndJumpNeverChangesCommandBudget() throws {
        for skew in [-86_400, -7, 0, 7, 86_400] as [Int64] {
            let anchor = try CompanionPeerClockAnchor(hello: hello(wall: 1_800_000_000 + skew), sentMS: 1000, receivedMS: 1100)
            let body = try anchor.outgoing(nowMS: 1105)
            XCTAssertEqual(body.issued, 100004); XCTAssertEqual(body.expires - body.issued, 30000)
            let remaining = try anchor.remaining(epoch: epoch.uuidString, issuedMS: 99999, expiresMS: 129999, maximumMS: 30000, nowMS: 1105)
            XCTAssertEqual(remaining, 29893)
        }
    }
    func testFreshnessRTTAndServiceEpochFailClosed() throws {
        XCTAssertThrowsError(try CompanionPeerClockAnchor(hello: hello(), sentMS: 0, receivedMS: 2001))
        XCTAssertThrowsError(try CompanionPeerClockAnchor(hello: hello(), sentMS: 10, receivedMS: 9))
        let anchor = try CompanionPeerClockAnchor(hello: hello(), sentMS: 1000, receivedMS: 1001)
        XCTAssertThrowsError(try anchor.outgoing(nowMS: 1000))
        XCTAssertNoThrow(try anchor.outgoing(nowMS: 31001))
        XCTAssertThrowsError(try anchor.outgoing(nowMS: 31002))
        XCTAssertThrowsError(try anchor.remaining(epoch: UUID().uuidString, issuedMS: 99999, expiresMS: 129999, maximumMS: 30000, nowMS: 1001))
    }
    func testFutureExpiredAndWidenedPeerBudgetsRejected() throws {
        let anchor = try CompanionPeerClockAnchor(hello: hello(), sentMS: 1000, receivedMS: 1100)
        XCTAssertThrowsError(try anchor.remaining(epoch: epoch.uuidString, issuedMS: 100001, expiresMS: 130000, maximumMS: 30000, nowMS: 1100))
        XCTAssertThrowsError(try anchor.remaining(epoch: epoch.uuidString, issuedMS: 99999, expiresMS: 130000, maximumMS: 30000, nowMS: 1100))
        XCTAssertThrowsError(try anchor.remaining(epoch: epoch.uuidString, issuedMS: 99999, expiresMS: 100101, maximumMS: 30000, nowMS: 1100))
        XCTAssertThrowsError(try anchor.remaining(epoch: epoch.uuidString, issuedMS: 99999, expiresMS: .infinity, maximumMS: 30000, nowMS: 1100))
        XCTAssertEqual(try anchor.remaining(epoch: epoch.uuidString, issuedMS: 99999, expiresMS: 100102, maximumMS: 30000, nowMS: 1100), 1)
    }
    func testPairingUsesPinnedPhoneWallSnapshotAndKeepsOriginalWindow() throws {
        for skew in [-86400, 0, 86400] as [Int64] {
            let wall: Int64 = 1_800_000_000 + skew
            let anchor = try CompanionPeerClockAnchor(hello: hello(wall: wall), sentMS: 1000, receivedMS: 1100)
            XCTAssertEqual(try anchor.pairingCodeRemaining(expiresSeconds: Double(wall + 120), nowMS: 1100), 118900)
            XCTAssertEqual(try anchor.pairingCodeRemaining(expiresSeconds: Double(wall + 120), nowMS: 2100), 117900)
            XCTAssertThrowsError(try anchor.pairingCodeRemaining(expiresSeconds: Double(wall), nowMS: 1100))
            XCTAssertThrowsError(try anchor.pairingCodeRemaining(expiresSeconds: Double(wall + 121), nowMS: 1100))
        }
        let jumped = try CompanionPeerClockAnchor(hello: hello(wall: 1_800_086_400), sentMS: 1000, receivedMS: 1100)
        XCTAssertThrowsError(try jumped.pairingCodeRemaining(expiresSeconds: 1_800_000_120, nowMS: 1100), "A changed phone wall clock requires a fresh QR; it must not reset its original 120s window")
    }
    func testLocalDeadlineSurvivesWallChangeButNeverBootResetOrExpiry() throws {
        let deadline = try CompanionCommandDeadline(issuedMS: 1000, expiresMS: 31000, bootID: boot)
        XCTAssertTrue(deadline.isValid(nowMS: 1000, bootID: boot))
        XCTAssertFalse(deadline.isValid(nowMS: 999, bootID: boot))
        XCTAssertFalse(deadline.isValid(nowMS: 31000, bootID: boot))
        XCTAssertFalse(deadline.isValid(nowMS: 1001, bootID: UUID().uuidString))
        XCTAssertThrowsError(try CompanionCommandDeadline(issuedMS: 1000, expiresMS: 31001, bootID: boot))
        let restored = try JSONDecoder().decode(CompanionCommandDeadline.self, from: JSONEncoder().encode(deadline))
        XCTAssertFalse(restored.isValid(nowMS: 1001, bootID: UUID().uuidString))
        XCTAssertFalse(CompanionClock.bootID.isEmpty)
    }
    func testStructuralQRParsingDoesNotTrustMacWallClock() throws {
        let uri = "droidbridge://pair?secret=\(String(repeating: "A", count: 43))&expires=1800000120&device_id=\(device)&server_pin=\(String(repeating: "a", count: 64))"
        for skew in [-86400, 86400] as [Double] { XCTAssertNoThrow(try CompanionPairCode(uri, now: Date(timeIntervalSince1970: 1_800_000_000 + skew))) }
    }
    func testAdmissionAllowsTruthfulLateAckButCannotReviveOrRepoll() throws {
        var registry = CompanionBrokerRegistry(); let owner = CompanionBrokerOwner(pid: 111, start: 222)
        try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: device.uuidString, serial: "emulator-5580", values: [])
        let deadline = try CompanionCommandDeadline(issuedMS: 1000, expiresMS: 31000, bootID: boot), id = UUID().uuidString
        _ = try registry.enqueue(id: id, deviceID: device.uuidString, kind: "open_app", payload: [:], continuousDeadline: deadline, nowMS: 1000, bootID: boot)
        XCTAssertThrowsError(try registry.acknowledge(id: id, owner: owner, generation: 1, status: "applied", result: [:], nowMS: 1001, bootID: boot))
        _ = try registry.admit(id: id, owner: owner, generation: 1, nowMS: 1001, bootID: boot)
        XCTAssertTrue(registry.poll(owner: owner, generation: 1, nowMS: 1002, bootID: boot).isEmpty)
        registry.prune(live: { _ in true }, nowMS: 40000, bootID: boot)
        XCTAssertEqual(registry.commands.first?.status, "accepted")
        _ = try registry.acknowledge(id: id, owner: owner, generation: 1, status: "applied", result: [:], nowMS: 40000, bootID: boot)
        XCTAssertEqual(try registry.admit(id: id, owner: owner, generation: 1, nowMS: 50000, bootID: boot).status, "applied")
        XCTAssertThrowsError(try registry.acknowledge(id: id, owner: owner, generation: 1, status: "rejected", result: [:], nowMS: 50000, bootID: boot))
    }
    func testOwnerLossAdmittedUnknownAndQueuedExpiredNeverReopens() throws {
        var registry = CompanionBrokerRegistry(); let owner = CompanionBrokerOwner(pid: 111, start: 222)
        try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: device.uuidString, serial: "emulator-5580", values: [])
        let deadline = try CompanionCommandDeadline(issuedMS: 1000, expiresMS: 31000, bootID: boot)
        let first = UUID().uuidString, second = UUID().uuidString
        for id in [first, second] { _ = try registry.enqueue(id: id, deviceID: device.uuidString, kind: "open_app", payload: [:], continuousDeadline: deadline, nowMS: 1000, bootID: boot) }
        _ = try registry.admit(id: first, owner: owner, generation: 1, nowMS: 1001, bootID: boot)
        registry.prune(live: { _ in true }, nowMS: 40000, bootID: boot)
        XCTAssertEqual(registry.commands.last?.status, "rejected")
        registry.prune(live: { _ in false }, nowMS: 40001, bootID: boot)
        XCTAssertEqual(registry.commands.first?.status, "unknown")
        XCTAssertThrowsError(try registry.admit(id: first, owner: owner, generation: 1, nowMS: 1002, bootID: boot))
    }
    func testHungLiveAdmittedOwnersBecomeUnknownWithoutRequeueAndFreeCapacity() throws {
        var registry = CompanionBrokerRegistry(); let owner = CompanionBrokerOwner(pid: 111, start: 222)
        try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: device.uuidString, serial: "emulator-5580", values: [])
        let deadline = try CompanionCommandDeadline(issuedMS: 1000, expiresMS: 31000, bootID: boot)
        for _ in 0..<64 {
            let id = UUID().uuidString
            _ = try registry.enqueue(id: id, deviceID: device.uuidString, kind: "open_app", payload: [:], continuousDeadline: deadline, nowMS: 1000, bootID: boot)
            _ = try registry.admit(id: id, owner: owner, generation: 1, nowMS: 1001, bootID: boot)
        }
        registry.prune(live: { _ in true }, nowMS: 121001, bootID: boot)
        XCTAssertTrue(registry.commands.allSatisfy { $0.status == "unknown" })
        XCTAssertTrue(registry.poll(owner: owner, generation: 1, nowMS: 121002, bootID: boot).isEmpty)
        let next = try CompanionCommandDeadline(issuedMS: 121002, expiresMS: 151002, bootID: boot)
        XCTAssertNoThrow(try registry.enqueue(id: UUID().uuidString, deviceID: device.uuidString, kind: "open_app", payload: [:], continuousDeadline: next, nowMS: 121002, bootID: boot))
    }
    func testCommittedSelectionQueuedExpiryAndOwnerRejectionPreserveIntent() throws {
        for rejectedByOwner in [false, true] {
            var registry = CompanionBrokerRegistry(); let owner = CompanionBrokerOwner(pid: 111, start: 222), id = UUID().uuidString
            try registry.publish(owner: owner, generation: 1, role: "launcher", deviceID: device.uuidString, serial: "emulator-5580", values: [])
            let deadline = try CompanionCommandDeadline(issuedMS: 1000, expiresMS: 31000, bootID: boot)
            _ = try registry.enqueue(id: id, deviceID: device.uuidString, kind: "set_export", payload: [:], continuousDeadline: deadline, nowMS: 1000, bootID: boot)
            registry.markIntentCommitted(id: id)
            if rejectedByOwner {
                _ = try registry.admit(id: id, owner: owner, generation: 1, nowMS: 1001, bootID: boot)
                _ = try registry.acknowledge(id: id, owner: owner, generation: 1, status: "rejected", result: ["code": .string("wrapper_failed")], nowMS: 40000, bootID: boot)
            } else { registry.prune(live: { _ in true }, nowMS: 40000, bootID: boot) }
            XCTAssertEqual(registry.commands.first?.status, "applied")
            XCTAssertEqual(registry.commands.first?.result["materialization_pending"]?.bool, true)
            let canonical = try registry.enqueue(id: id, deviceID: device.uuidString, kind: "set_export", payload: [:], continuousDeadline: deadline, nowMS: 50000, bootID: boot)
            XCTAssertEqual(canonical.status, "applied", "A canonical expired retry returns history without reopening work")
        }
    }
    func testCrashGapReplayedSelectionRecordsUnknownWithoutWrapperWork() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clock-intent-gap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ManagedAppsPaths(privateRoot: root.appendingPathComponent("Managed.noindex"), activeRoot: root.appendingPathComponent("Apps"))
        let catalog = ManagedAppCatalog(paths: paths), trust = UUID().uuidString, package = "com.example.test"
        try catalog.bindCompanionExportAuthority(deviceID: device.uuidString, trustID: trust, aliases: ["emulator-5580"])
        XCTAssertEqual(try catalog.applyCompanionExportOutcome(deviceID: device.uuidString, trustID: trust, packageName: package, selected: true, revision: 1), .committed)
        // Crash lost the broker row. The policy revision survives and must not
        // be treated as a second materialization admission.
        XCTAssertEqual(try catalog.applyCompanionExportOutcome(deviceID: device.uuidString, trustID: trust, packageName: package, selected: true, revision: 1), .replayed)
        var registry = CompanionBrokerRegistry()
        let receipt = try registry.recordCommittedIntent(id: UUID().uuidString, deviceID: device.uuidString, kind: "set_export", payload: ["package_name": .string(package), "selected": .bool(true), "selection_revision": .number(1)], ambiguous: true)
        XCTAssertEqual(receipt.status, "unknown")
        XCTAssertEqual(receipt.result["materialization_pending"]?.bool, true)
        XCTAssertEqual(receipt.result["wrapper_created"]?.bool, false)
        XCTAssertTrue(registry.poll(owner: receipt.owner, generation: receipt.generation).isEmpty)
        XCTAssertEqual(try catalog.applyCompanionExportOutcome(deviceID: device.uuidString, trustID: trust, packageName: package, selected: true, revision: 2), .committed, "A deliberate successor revision may retry derived wrapper work")
    }
    func testCommittedIntentPendingReceiptIsCanonicalAndCannotClaimWrapper() throws {
        var registry = CompanionBrokerRegistry(); let id = UUID().uuidString
        let payload: [String: CompanionJSON] = ["selected": .bool(true)]
        let receipt = try registry.recordCommittedIntent(id: id, deviceID: device.uuidString, kind: "set_export", payload: payload)
        XCTAssertEqual(receipt.status, "applied")
        XCTAssertEqual(receipt.result["intent_committed"]?.bool, true)
        XCTAssertEqual(receipt.result["wrapper_created"]?.bool, false)
        XCTAssertEqual(receipt.result["materialization_pending"]?.bool, true)
        XCTAssertEqual(try registry.recordCommittedIntent(id: id, deviceID: device.uuidString, kind: "set_export", payload: payload).result, receipt.result)
        XCTAssertThrowsError(try registry.recordCommittedIntent(id: id, deviceID: device.uuidString, kind: "set_export", payload: [:]))
    }
}

private final class ClockFixtureEpochs: @unchecked Sendable {
    private let lock = NSLock()
    func next() -> String { lock.lock(); defer { lock.unlock() }; return UUID().uuidString }
}
