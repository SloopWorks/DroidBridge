import Foundation
import Darwin

public final class CompanionBrokerService: NSObject, NSXPCListenerDelegate {
    private let engine: CompanionBrokerEngine
    private let testNonce: String?
    public override convenience init() { self.init(directory: CompanionBrokerIPC.directory) }
    public init(directory: URL, nonce: String? = nil, automaticReconnect: Bool = true, managedPaths: ManagedAppsPaths = .userDefault) {
        engine = CompanionBrokerEngine(directory: directory, automaticReconnect: automaticReconnect, managedPaths: managedPaths); testNonce = nonce
        super.init()
        Task { await engine.start() }
    }
    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid(), let owner = CompanionBrokerOwner.live(connection.processIdentifier) else { return false }
        connection.exportedInterface = NSXPCInterface(with: CompanionBrokerXPCProtocol.self)
        connection.exportedObject = CompanionBrokerEndpoint(engine: engine, owner: owner, nonce: testNonce)
        connection.resume(); return true
    }
    public func shutdown() async { await engine.shutdown() }
}
private final class CompanionBrokerEndpoint: NSObject, CompanionBrokerXPCProtocol {
    let engine: CompanionBrokerEngine; let owner: CompanionBrokerOwner; let nonce: String?
    init(engine: CompanionBrokerEngine, owner: CompanionBrokerOwner, nonce: String?) { self.engine = engine; self.owner = owner; self.nonce = nonce }
    func exchange(_ request: Data, reply: @escaping (Data) -> Void) {
        guard request.count <= CompanionBrokerIPC.maximumBytes else { reply(Self.failure("payload_too_large")); return }
        Task {
            let result: CompanionBrokerReply
            do {
                let input = try JSONDecoder().decode(CompanionBrokerRequest.self, from: request)
                guard input.version == 1, input.operation.utf8.count <= 64,
                      CompanionBrokerIPC.constantTimeEqual(input.nonce, try nonce ?? CompanionBrokerIPC.nonce()), owner.isAlive else { throw CompanionBoundaryError("unauthorized_ipc", "Companion IPC authentication failed.") }
                result = await engine.exchange(input, owner: owner)
            } catch {
                result = .init(requestID: (try? JSONDecoder().decode(CompanionBrokerRequest.self, from: request).requestID) ?? UUID(), error: error as? CompanionBoundaryError ?? .init("invalid_request", "Invalid companion service request."))
            }
            let output = (try? JSONEncoder().encode(result)) ?? Self.failure("encoding_failed")
            reply(output.count <= CompanionBrokerIPC.maximumBytes ? output : Self.failure("response_too_large", requestID: result.requestID))
        }
    }
    static func failure(_ code: String, requestID: UUID = UUID()) -> Data { (try? JSONEncoder().encode(CompanionBrokerReply(requestID: requestID, error: .init(code, "Companion service rejected the request.")))) ?? Data() }
}
private struct BrokerDevice: Codable {
    let deviceID: String
    var name: String
    var aliases: [String]
    var preferredSerial: String
    var trustID: String?
    var epoch: String?
    var sequence: Int64
    var profile: String
    var exportSelection: [String: Bool]
    var enabled: Bool = true
    var lastError: String? = nil
    var catalogChangeToken: String? = nil
    var lastCatalogEventID: String? = nil
}
private struct BrokerInbox: Codable {
    let id: String; let deviceID: String; let kind: String; let created: Date
    var payload: [String: CompanionJSON]
    var trustID: String? = nil
}
private struct BrokerStopAll: Codable {
    let id: String; let deviceID: String; let children: [String]; let expires: Date; var delivered: Bool; let phoneReceipt: Bool?
    var terminalStatus: String? = nil
}
private struct BrokerPendingAdmission: Codable {
    let id: UUID; let deviceID: String; let trustID: String; let serverPin: String; let serial: String; let expires: Date
    var deadlineBootID: String? = nil
    var deadlineMS: Double? = nil
    var phase: String
}
private struct BrokerStorage: Codable {
    var macID = UUID()
    var devices: [BrokerDevice] = []
    var registry = CompanionBrokerRegistry()
    var inbox: [BrokerInbox] = []
    var stopAll: [BrokerStopAll] = []
    var hostApplication: CompanionBrokerHostApplication?
    var localCommands: [String] = []
    var pendingAdmissions: [BrokerPendingAdmission] = []
    enum CodingKeys: String, CodingKey { case macID, devices, registry, inbox, stopAll, hostApplication, localCommands, pendingAdmissions }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        macID = try c.decode(UUID.self, forKey: .macID); devices = try c.decode([BrokerDevice].self, forKey: .devices)
        registry = try c.decode(CompanionBrokerRegistry.self, forKey: .registry); inbox = try c.decode([BrokerInbox].self, forKey: .inbox)
        stopAll = try c.decodeIfPresent([BrokerStopAll].self, forKey: .stopAll) ?? []
        hostApplication = try c.decodeIfPresent(CompanionBrokerHostApplication.self, forKey: .hostApplication)
        localCommands = try c.decodeIfPresent([String].self, forKey: .localCommands) ?? []
        pendingAdmissions = try c.decodeIfPresent([BrokerPendingAdmission].self, forKey: .pendingAdmissions) ?? []
    }
}
private enum BrokerOwnedForward {
    case adb(CompanionForward)
    #if DEBUG
    case test(URL)
    #endif
    var baseURL:URL {
        switch self {
        case .adb(let forward):return forward.baseURL
        #if DEBUG
        case .test(let url):return url
        #endif
        }
    }
    func close() async throws {
        switch self {
        case .adb(let forward):try await forward.close()
        #if DEBUG
        case .test:break
        #endif
        }
    }
}
private struct BrokerTransport {
    let serial: String; let hello: CompanionHello; let forward: BrokerOwnedForward; let client: CompanionClient; let generation: UUID; let serverPin: String
    var verified: Bool
    var admissionExpiryMS = CompanionClock.nowMS() + 120_000
}
private struct BrokerPair {
    let id: String; let serial: String; let secret: String; let deviceID: String; let expires: Date
    let expiresContinuousMS: Double
    let deadlineBootID: String
    var isValid: Bool { deadlineBootID == CompanionClock.bootID && CompanionClock.nowMS() < expiresContinuousMS }
    let comparisonCode: String
    let macName: String
    let transportGeneration: UUID
    let serverPin: String
    let trustEpoch: UUID
}
private struct BrokerIPCCached {
    let request: CompanionBrokerRequest; let owner: CompanionBrokerOwner; let reply: CompanionBrokerReply; let created: Date
}
/// Sole phone connection/credential owner. Persistent work survives GUI termination.
public actor CompanionBrokerEngine {
    private var storage = BrokerStorage()
    private var transports: [String: BrokerTransport] = [:]
    private var connecting = Set<String>()
    private var pairings: [String: BrokerPair] = [:]
    private var pollers: [String: Task<Void, Never>] = [:]
    private var pollerTokens: [String: UUID] = [:]
    private var maintenance: Task<Void, Never>?
    private var receiptDelivery: Task<Void, Never>?
    private var receiptDeliveryGeneration: UUID?
    private var receiptRetry: [String: (attempt: Int, nextMS: Double)] = [:]
    private var retiringForwards: [UUID: BrokerOwnedForward] = [:]
    private var startingForwards: [UUID: BrokerOwnedForward] = [:]
    private var forwardRetries: [UUID: (attempt: Int, next: Date)] = [:]
    private var forwardReaper: Task<Void, Never>?
    #if DEBUG
    var retiringForwardCount: Int { retiringForwards.count }
    #endif
    private var receipts: [UUID: BrokerIPCCached] = [:]
    private var pending = Set<UUID>()
    private var cancelled = Set<UUID>()
    private let scheduler = BrokerScheduler()
    private var persistenceFailure = false
    private var persistedBytes: Data?
    private var persistedFingerprint: CompanionBrokerJournal.Fingerprint?
    private var stopping = false
    private var shutdownFinished = false
    private var iconCache: [String: Data] = [:]
    private var iconCacheOrder: [String] = []
    private var reconnectAttempts: [String: Int] = [:]
    private var retryAfter: [String: Date] = [:]
    private var lastDiscovery = Date.distantPast
    private var publishedStates:[String:(Date,String)] = [:]
    private var trustEpochs: [String: UUID] = [:]
    private var hostBootstrap: Task<Void, Error>?
    private var audioStatuses: [String: (CompanionBrokerOwner, Int64, Date, [String: CompanionJSON])] = [:]
    private let catalog: ManagedAppCatalog
    private let directory: URL
    private let automaticReconnect: Bool
    private var initialized = false
    private var ownerLease: Int32 = -1
    #if DEBUG
    private var testingHooks:CompanionBrokerTestingHooks?
    init(directory:URL,automaticReconnect:Bool=false,managedPaths:ManagedAppsPaths,testingHooks:CompanionBrokerTestingHooks) {self.directory=directory;self.automaticReconnect=automaticReconnect;catalog=ManagedAppCatalog(paths:managedPaths);self.testingHooks=testingHooks}
    #endif
    public init(directory: URL = CompanionBrokerIPC.directory, automaticReconnect: Bool = true, managedPaths: ManagedAppsPaths = .userDefault) { self.directory = directory; self.automaticReconnect = automaticReconnect; catalog = ManagedAppCatalog(paths: managedPaths) }
    private var storageURL: URL { directory.appendingPathComponent("state.json") }
    public func start() async {
        do {
            try CompanionBrokerIPC.prepareDirectory(directory)
            if directory == CompanionBrokerIPC.directory { _ = try CompanionBrokerIPC.nonce(create: true) }
            ownerLease = open(directory.appendingPathComponent("owner.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            var ownerInfo = stat()
            guard ownerLease >= 0, fstat(ownerLease, &ownerInfo) == 0, ownerInfo.st_uid == geteuid(), ownerInfo.st_mode & S_IFMT == S_IFREG, ownerInfo.st_mode & 0o077 == 0, flock(ownerLease, LOCK_EX | LOCK_NB) == 0 else { throw CompanionBoundaryError("broker_already_running", "Another companion broker already owns this user session.") }
            let fd = open(storageURL.path, O_RDONLY | O_NOFOLLOW)
            if fd >= 0 {
                defer { close(fd) }; var st = stat()
                guard fstat(fd, &st) == 0, st.st_uid == geteuid(), st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o077 == 0, st.st_size <= 4_194_304 else { throw CompanionBoundaryError("unsafe_broker_state", "Companion state has unsafe ownership or size.") }
                let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
                storage = try JSONDecoder().decode(BrokerStorage.self, from: data)
                guard storage.devices.count <= 32, storage.inbox.count <= 64, storage.pendingAdmissions.count <= 32, storage.registry.sessions.count <= 128 else { throw CompanionBoundaryError("invalid_broker_state", "Companion state exceeds its bounds.") }
                storage.registry.prune()
            } else if errno != ENOENT { throw CompanionBoundaryError("unsafe_broker_state", "Companion state could not be opened safely.") }
            // Persist the Mac identity before any phone can approve it.
            try persist()
        } catch { persistenceFailure = true }
        if automaticReconnect && !persistenceFailure { try? await CompanionForward.recoverAbandoned(adbPath: Toolchain().adb) }
        initialized = true
        maintenance = Task { [weak self] in
            while !Task.isCancelled {
                await self?.maintain()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    public func shutdown() async {
        stopping = true; maintenance?.cancel(); receiptDelivery?.cancel(); for task in pollers.values { task.cancel() }; pollers.removeAll(); pollerTokens.removeAll()
        await receiptDelivery?.value; receiptDelivery = nil
        for serial in Array(transports.keys) { _ = removeTransport(serial: serial) }
        for (generation, forward) in startingForwards { retiringForwards[generation] = forward }
        startingForwards.removeAll()
        let deadline = Date().addingTimeInterval(10)
        for (generation, forward) in retiringForwards {
            guard Date() < deadline else { break }
            _ = await retireForward(forward, generation: generation)
        }
        shutdownFinished = true
        releaseStoppedOwner()
    }
    private func releaseStoppedOwner() {
        guard stopping, shutdownFinished, pending.isEmpty else { return }
        if ownerLease >= 0 { flock(ownerLease, LOCK_UN); close(ownerLease); ownerLease = -1 }
    }
    public func exchange(_ input: CompanionBrokerRequest, owner: CompanionBrokerOwner) async -> CompanionBrokerReply {
        guard initialized else { return .init(requestID: input.requestID, error: .init("broker_starting", "Companion service is starting. Retry shortly.", retryable: true)) }
        guard !stopping else { return .init(requestID: input.requestID, error: .init("broker_stopping", "Companion service is stopping. Retry after it restarts.", retryable: true)) }
        let currentCatalogRead = ["catalog", "catalog_changes", "export_selection_get"].contains(input.operation)
        if let receipt = receipts[input.requestID] {
            guard receipt.owner == owner, receipt.request.operation == input.operation, receipt.request.payload == input.payload else { return .init(requestID: input.requestID, error: .init("request_conflict", "A request identity was reused with different content.")) }
            // An execution grant is a one-time delivery, not a replayable
            // receipt. Recompute canonical state without granting it again.
            // Catalog reads must also re-evaluate current pairing authority.
            if input.operation != "command_admit", !currentCatalogRead { return receipt.reply }
        }
        guard !pending.contains(input.requestID), pending.count < 64 else { return .init(requestID: input.requestID, error: .init("request_pending", "Companion request is already running or the service is busy.", retryable: true)) }
        guard !persistenceFailure else { return .init(requestID: input.requestID, error: .init("broker_storage_unavailable", "Companion state is unavailable. Existing Android windows remain usable.")) }
        pending.insert(input.requestID)
        let result: CompanionBrokerReply
        do {
            let data = try await perform(input.operation, input.payload, requestID: input.requestID, owner: owner)
            result = .init(requestID: input.requestID, data: data)
        } catch {
            result = .init(requestID: input.requestID, error: error as? CompanionBoundaryError ?? .init("operation_failed", "Companion operation failed. Retry or inspect connection status.", retryable: true))
        }
        pending.remove(input.requestID)
        releaseStoppedOwner()
        receipts[input.requestID] = .init(request: input, owner: owner, reply: result, created: Date())
        // Never retain pairing secrets, shared text or file chunks in the local retry cache.
        if currentCatalogRead || ["begin_pair", "clipboard_send", "share_send", "transfer_chunk", "notification_reply"].contains(input.operation) { receipts.removeValue(forKey: input.requestID) }
        if receipts.count > 512 { for key in receipts.sorted(by: { $0.value.created < $1.value.created }).prefix(receipts.count - 512).map(\.key) { receipts.removeValue(forKey: key) } }
        return result
    }
    private func perform(_ operation: String, _ p: [String: CompanionJSON], requestID: UUID, owner: CompanionBrokerOwner) async throws -> [String: CompanionJSON] {
        if operation == "status" { return status() }
        if operation == "host_register" {
            let path = try string(p, "app_path")
            let host = try await Task.detached(priority: .utility) { try CompanionBrokerHostApplication.register(path: path, owner: owner) }.value
            guard !stopping else { throw CancellationError() }
            guard owner.isAlive else { throw CompanionBoundaryError("host_exited", "The registering Mac application exited.") }
            storage.hostApplication = host
            try persist(); return ["status": .string("registered")]
        }
        if operation == "cancel" { let id = try uuid(p, "request_id"); cancelled.insert(UUID(uuidString: id)!); if cancelled.count > 512, let oldest = cancelled.first { cancelled.remove(oldest) }; return ["status": .string("cancellation_requested")] }
        if operation == "connect" || operation == "retry" { return try await connect(serial: string(p, "serial")) }
        if operation == "begin_pair" { return try await beginPair(p) }
        if operation == "poll_pair" { return try await pollPair(p) }
        if operation == "session_publish" {
            let deviceID = try uuid(p, "device_id"), serial = try string(p, "serial")
            guard let device = storage.devices.first(where: { $0.deviceID == deviceID }), device.trustID != nil, device.enabled, device.aliases.contains(serial) else { throw CompanionBoundaryError("unverified_alias", "Connect and pair this phone before publishing companion sessions.") }
            let generation = try integer(p, "generation")
            let commandProtocol = p["command_protocol"] == nil ? 1 : try integer(p, "command_protocol")
            guard [1, 2].contains(commandProtocol) else { throw CompanionBoundaryError("owner_update_required", "This Mac process uses an unsupported command protocol. Update DroidBridge and its wrappers.") }
            try storage.registry.publish(owner: owner, generation: generation, role: string(p, "role"), deviceID: deviceID, serial: serial, values: (p["sessions"]?.array ?? []).compactMap(\.object), commandProtocol: Int(commandProtocol))
            if let audio = p["audio_status"]?.object {
                guard let route = audio["route"]?.string, ["mac", "phone", "mac_and_phone"].contains(route), let phase = audio["phase"]?.string, ["phone", "starting", "ready", "shared", "failed", "unavailable"].contains(phase), (audio["message"]?.string?.utf8.count ?? 0) <= 2048 else { throw CompanionBoundaryError("invalid_audio_status", "Invalid Mac audio status metadata.") }
                audioStatuses[deviceID] = (owner, generation, Date(), audio)
            }
            try persist(); await publish(deviceID); return ["status": .string("published"), "generation": .number(Double(generation))]
        }
        if operation == "command_poll" {
            storage.registry.prune()
            let generation = try integer(p, "generation")
            guard storage.registry.supportsCommandProtocol(owner: owner, generation: generation) else { throw CompanionBoundaryError("owner_update_required", "Open the updated DroidBridge app and update or recreate older wrappers before controlling their sessions.") }
            return ["commands": try json(storage.registry.poll(owner: owner, generation: generation))]
        }
        if operation == "command_admit" {
            let commandID = try uuid(p, "command_id")
            let generation = try integer(p, "generation")
            let deviceID = storage.registry.commands.first(where: { $0.id == commandID })?.deviceID
            let admissionTrust = storage.devices.first(where: { $0.deviceID == deviceID && $0.enabled })?.trustID
            guard admissionTrust != nil else { throw CompanionBoundaryError("trust_changed", "The phone is no longer enabled and paired for this command.") }
            let wasAdmitted = storage.registry.commands.first(where: { $0.id == commandID })?.admitted == true
            let receipt = try storage.registry.admit(id: commandID, owner: owner, generation: generation)
            try persist()
            if receipt.status == "accepted", receipt.admitted == true, !storage.localCommands.contains(receipt.id) {
                let parent = storage.stopAll.first(where: { $0.children.contains(receipt.id) })
                if parent?.phoneReceipt != false, let transport = verified(receipt.deviceID) {
                    let phoneID = parent?.id ?? receipt.id
                    try await control(deviceID:receipt.deviceID) { try await transport.client.acknowledge(commandID: phoneID, status: "admitted") }
                }
            }
            guard !stopping else { throw CancellationError() }
            storage.registry.prune()
            guard let current = storage.registry.commands.first(where: { $0.id == commandID }) else { throw CompanionBoundaryError("receipt_unavailable", "The command receipt is no longer available.") }
            let currentTrust = storage.devices.first(where: { $0.deviceID == deviceID && $0.enabled })?.trustID
            let ownerPresent = storage.registry.hosts.contains { $0.owner == owner && $0.generation == generation && $0.deviceID == deviceID && $0.commandProtocol == 2 }
            let executionGranted = !wasAdmitted && current.status == "accepted" && current.admitted == true &&
                current.owner == owner && current.generation == generation && ownerPresent &&
                currentTrust == admissionTrust && current.continuousDeadline?.isValid == true
            try persist()
            return ["status": .string(current.status), "admitted": .bool(current.admitted == true), "execution_granted": .bool(executionGranted), "result": .object(current.result)]
        }
        if operation == "command_ack" {
            let receipt = try storage.registry.acknowledge(id: uuid(p, "command_id"), owner: owner, generation: integer(p, "generation"), status: string(p, "status"), result: p["result"]?.object ?? [:])
            try persist()
            if storage.stopAll.contains(where: { $0.children.contains(receipt.id) }) { await finishStopAll() }
            else if !storage.localCommands.contains(receipt.id), let transport = verified(receipt.deviceID) { try await control(deviceID:receipt.deviceID) { try await transport.client.acknowledge(commandID: receipt.id, status: receipt.status, result: receipt.result) }; storage.registry.markReceiptDelivered(id: receipt.id); try persist() }
            return ["status": .string(receipt.status), "result": .object(receipt.result)]
        }
        let deviceID = try uuid(p, "device_id")
        if operation == "host_command" {
            let commandID = requestID.uuidString.lowercased()
            if storage.registry.commands.contains(where: { $0.id == commandID }) || storage.stopAll.contains(where: { $0.id == commandID }) {
                guard storage.localCommands.contains(commandID) else { throw CompanionBoundaryError("request_conflict", "A phone command identity cannot be reused for a local action.") }
            }
            guard storage.devices.contains(where: { $0.deviceID == deviceID && $0.trustID != nil }) else { throw CompanionBoundaryError("unpaired_device", "Pair this phone before controlling its Mac sessions.") }
            let kind = try string(p, "kind"), payload = p["payload"]?.object ?? [:]
            guard ["open_app", "stop_session", "stop_all", "set_audio_route", "retry_audio", "set_profile", "set_screen_power", "set_export", "diagnostics_request"].contains(kind) else { throw CompanionBoundaryError("unsupported_command", "Unsupported Mac session action.") }
            if kind == "stop_all" { try await enqueueStopAll(id: commandID, deviceID: deviceID, deadline: Date().addingTimeInterval(30), phoneReceipt: false); markLocalCommand(requestID); try persist(); return ["request_id": .string(commandID), "status": .string("accepted")] }
            let receipt = try await enqueueHost(id: requestID.uuidString, deviceID: deviceID, kind: kind, payload: payload)
            markLocalCommand(requestID)
            try persist()
            return ["request_id": .string(receipt.id), "status": .string(receipt.status), "result": .object(receipt.result)]
        }
        if operation == "recover_pairing" { return try await recoverPairing(deviceID) }
        if operation == "forget" {
            guard storage.devices.contains(where: { $0.deviceID == deviceID }) || storage.pendingAdmissions.contains(where: { $0.deviceID == deviceID }) else { throw CompanionBoundaryError("unknown_device", "This companion installation is not saved on this Mac.") }
            trustEpochs[deviceID] = UUID()
            try CompanionCredentialStore.remove(deviceID: deviceID)
            for pending in storage.pendingAdmissions where pending.deviceID == deviceID { try CompanionPendingCredentialStore.remove(id:pending.id) }
            storage.pendingAdmissions.removeAll { $0.deviceID == deviceID }
            try catalog.forgetCompanionExportAuthority(deviceID: deviceID)
            if let index = storage.devices.firstIndex(where: { $0.deviceID == deviceID }) {
                storage.devices[index].trustID = nil; storage.devices[index].enabled = false; storage.devices[index].lastError = "pairing_forgotten"
                storage.devices[index].epoch = nil; storage.devices[index].sequence = 0
                storage.devices[index].catalogChangeToken = nil; storage.devices[index].lastCatalogEventID = nil
            }
            storage.registry.revoke(deviceID: deviceID)
            audioStatuses.removeValue(forKey: deviceID)
            pairings = pairings.filter { $0.value.deviceID != deviceID }
            pollers.removeValue(forKey: deviceID)?.cancel()
            let owned = transports.values.filter { UUID(uuidString: $0.hello.deviceId)?.uuidString.lowercased() == deviceID }
            for transport in owned { removeTransport(serial: transport.serial) }
            try persist()
            var cleanupPending = false
            for transport in owned { if !(await retireForward(transport)) { cleanupPending = true } }
            return ["status": .string("forgotten"), "cleanup_pending": .bool(cleanupPending), "needs_phone_revoke": .bool(true), "retained": .string("App settings, wrappers and accepted export choices are retained. Revoke this old Mac trust on the phone, then approve a fresh pairing link.")]
        }
        if operation == "disconnect" {
            if let i = storage.devices.firstIndex(where: { $0.deviceID == deviceID }) { storage.devices[i].enabled = false; try persist() }
            if let device = storage.devices.first(where: { $0.deviceID == deviceID }), let transport = removeTransport(serial: device.preferredSerial) { pollers.removeValue(forKey: deviceID)?.cancel(); _ = await retireForward(transport) }
            return ["status": .string("disconnected")]
        }
        if operation == "command_status" {
            let id = try uuid(p, "request_id")
            if let parent = storage.stopAll.first(where: { $0.id.lowercased() == id && $0.deviceID == deviceID }) {
                let children = storage.registry.commands.filter { parent.children.contains($0.id) }
                let status = stopAllStatus(parent: parent, children: children) ?? "accepted"
                return ["request_id": .string(id), "status": .string(status), "result": .object(["sessions": .number(Double(parent.children.count))])]
            }
            guard let command = storage.registry.commands.first(where: { $0.id.lowercased() == id && $0.deviceID == deviceID }) else { throw CompanionBoundaryError("receipt_unavailable", "This Mac command receipt is unavailable.", retryable: true) }
            return ["request_id": .string(command.id), "status": .string(command.status), "result": .object(command.result)]
        }
        if ["catalog", "catalog_changes", "export_selection_get"].contains(operation), p["expected_trust_id"] != nil {
            let expected = try uuid(p, "expected_trust_id")
            guard storage.devices.contains(where: { $0.deviceID == deviceID && $0.trustID == expected }) else { throw CompanionBoundaryError("trust_changed", "The catalog belongs to an older phone pairing. Refresh the connection.") }
        }
        if operation == "export_selection_get" { return ["selection": .object(try catalog.companionExportSelection(deviceID: deviceID).mapValues(CompanionJSON.bool))] }
        if operation == "inbox_list" {
            let all = storage.inbox.filter { $0.deviceID == deviceID }
            var start = 0
            if let after = p["after_id"]?.string { guard let index = all.firstIndex(where: { $0.id == after }) else { throw CompanionBoundaryError("stale_cursor", "The inbox changed; refresh it.") }; start = index + 1 }
            var items: [BrokerInbox] = []
            for item in all.dropFirst(start).prefix(16) {
                guard ((try? JSONEncoder().encode(items + [item]).count) ?? Int.max) <= 180_224 else { break }
                items.append(item)
            }
            let next: CompanionJSON = start + items.count < all.count ? items.last.map { .string($0.id) } ?? .null : .null
            return ["items": try json(items), "next_cursor": next]
        }
        if operation == "inbox_clear" {
            let id = p["item_id"]?.string
            storage.inbox.removeAll { $0.deviceID == deviceID && (id == nil || $0.id == id) }; try persist(); return ["status": .string("cleared")]
        }
        guard let transport = verified(deviceID) else { throw CompanionBoundaryError("phone_unavailable", "Connect the paired phone to use this feature.", retryable: true) }
        let client = transport.client
        switch operation {
        case "catalog", "catalog_changes":
            guard let trust = storage.devices.first(where: { $0.deviceID == deviceID })?.trustID else { throw CompanionBoundaryError("trust_changed", "The phone pairing changed before catalog discovery.") }
            let epoch = trustEpochs[deviceID], generation = transport.generation
            let result = try await control(deviceID: deviceID) {
                try self.checkCatalogReadScope(deviceID: deviceID, trustID: trust, epoch: epoch, generation: generation)
                let value: [String: CompanionJSON]
                if operation == "catalog" { value = try Self.object(await client.catalog(cursor: p["cursor"]?.string)) }
                else { value = try Self.object(await client.catalogChanges(after: selfString(p, "after"))) }
                try self.checkCatalogReadScope(deviceID: deviceID, trustID: trust, epoch: epoch, generation: generation)
                return value
            }
            try checkCatalogReadScope(deviceID: deviceID, trustID: trust, epoch: epoch, generation: generation)
            return result
        case "icon":
            let hash = try string(p, "hash"), key = deviceID + ":" + hash
            let bytes: Data
            if let cached = iconCache[key] { bytes = cached }
            else {
                if let disk = try? readDiskIcon(hash) { bytes = disk }
                else { bytes = try await bulk(deviceID:deviceID) { try await client.icon(hash: hash) }; try? writeDiskIcon(bytes, hash: hash) }
                while iconCache.values.reduce(0, { $0 + $1.count }) + bytes.count > 4_194_304, let oldest = iconCacheOrder.first { iconCache.removeValue(forKey: oldest); iconCacheOrder.removeFirst() }
                iconCache[key] = bytes; iconCacheOrder.append(key)
            }
            let offset = p["offset"] == nil ? 0 : Int(try integer(p, "offset"))
            guard offset >= 0, offset < bytes.count else { throw CompanionBoundaryError("invalid_offset", "Invalid icon chunk offset.") }
            let end = min(bytes.count, offset + 65_536)
            return ["bytes": .string(bytes[offset..<end].base64EncodedString()), "total_bytes": .number(Double(bytes.count)), "next_offset": .number(Double(end))]
        case "trust_list": return ["items": try await control(deviceID:deviceID) { try Self.value(await client.trustedMacs()) }]
        case "revoke":
            let id = try uuid(p, "trust_id"); try await control(deviceID:deviceID) { try await client.revoke(trustID: id) }
            if storage.devices.first(where: { $0.deviceID == deviceID })?.trustID == id { try CompanionCredentialStore.remove(deviceID: deviceID); if let i = storage.devices.firstIndex(where: { $0.deviceID == deviceID }) { storage.devices[i].trustID = nil; storage.devices[i].catalogChangeToken = nil; storage.devices[i].lastCatalogEventID = nil }; storage.inbox.removeAll { $0.deviceID == deviceID }; storage.registry.revoke(deviceID: deviceID); try persist(); return try await perform("disconnect", p, requestID: requestID, owner: owner) }
            return ["status": .string("revoked")]
        case "diagnostics": return try await control(deviceID:deviceID) { try await client.diagnostics() }
        case "profile_get": return ["profile": .string(storage.devices.first(where: { $0.deviceID == deviceID })?.profile ?? "balanced")]
        case "profile_set":
            markLocalCommand(requestID)
            let profile = try string(p, "profile"); guard ["balanced", "responsive", "battery"].contains(profile) else { throw CompanionBoundaryError("invalid_profile", "Unsupported performance profile.") }
            _ = try await control(deviceID:deviceID) { try await client.sendCommand(kind: "set_profile", payload: ["profile": .string(profile)], requestID: requestID) }
            if let i = storage.devices.firstIndex(where: { $0.deviceID == deviceID }) { storage.devices[i].profile = profile; try persist() }
            _ = try await enqueueHost(id: requestID.uuidString, deviceID: deviceID, kind: "set_profile", payload: ["profile": .string(profile)]); try persist()
            return ["status": .string("accepted"), "profile": .string(profile)]
        case "export_selection_set":
            markLocalCommand(requestID)
            let package = try string(p, "package_name"); try AndroidDiscovery.validatePackage(package)
            guard let selected = p["selected"]?.bool, let i = storage.devices.firstIndex(where: { $0.deviceID == deviceID }), storage.devices[i].exportSelection.count < 4096 || storage.devices[i].exportSelection[package] != nil else { throw CompanionBoundaryError("invalid_selection", "Invalid app export selection.") }
            let response = try await control(deviceID:deviceID) { try await client.sendCommand(kind: "set_export", payload: ["package_name": .string(package), "selected": .bool(selected)], requestID: requestID) }
            guard response.status == "applied", let result = response.result, result["package_name"]?.string == package, result["selected"]?.bool == selected,
                  result["request_id"]?.string.flatMap(UUID.init(uuidString:)) == requestID else { throw CompanionBoundaryError("invalid_selection_receipt", "The phone did not confirm this exact export selection.") }
            let receipt = try await applyExport(deviceID: deviceID, id: requestID.uuidString, payload: result)
            return ["request_id": .string(requestID.uuidString.lowercased()), "status": .string(receipt?.status ?? "applied"), "result": .object(receipt?.result ?? ["stale": .bool(true)])]
        case "notification_preferences", "notification_reply", "notification_dismiss":
            let expectedTrust = try uuid(p, "expected_trust_id")
            let epoch = trustEpochs[deviceID]
            guard storage.devices.contains(where: { $0.deviceID == deviceID && $0.enabled && $0.trustID == expectedTrust }) else { throw CompanionBoundaryError("trust_changed", "The phone pairing changed. Inspect its current state before changing notification sharing.") }
            guard transport.hello.capabilities.contains("notification_scope_v2") else { throw CompanionBoundaryError("companion_update_required", "Update the Android companion before controlling notification sharing or actions.") }
            var payload = p["payload"]?.object ?? [:]
            if let supplied = payload["expected_trust_id"]?.string, UUID(uuidString: supplied)?.uuidString.lowercased() != expectedTrust { throw CompanionBoundaryError("trust_changed", "The notification action belongs to a different pairing.") }
            payload["expected_trust_id"] = .string(expectedTrust)
            let kind = operation == "notification_dismiss" ? "dismiss_notification" : operation
            func hasOrigin() -> Bool {
                operation == "notification_preferences" || self.storage.inbox.contains { $0.deviceID == deviceID && $0.kind == "notification_posted" && $0.trustID == expectedTrust && $0.payload["notification_key"] == payload["notification_key"] && $0.payload["action_id"] == payload["action_id"] }
            }
            guard hasOrigin() else { throw CompanionBoundaryError("notification_unavailable", "This notification belongs to an older pairing or action. Refresh the notification list.") }
            #if DEBUG
            try await testingHooks?.checkpoint("notification_preferences_pre_lane", deviceID)
            #endif
            return try await control(deviceID: deviceID) {
                guard !self.stopping, self.trustEpochs[deviceID] == epoch,
                      self.storage.devices.contains(where: { $0.deviceID == deviceID && $0.enabled && $0.trustID == expectedTrust }),
                      self.verified(deviceID)?.generation == transport.generation else { throw CompanionBoundaryError("trust_changed", "The phone pairing changed before the notification action was admitted.") }
                guard hasOrigin() else { throw CompanionBoundaryError("notification_unavailable", "This notification was replaced before the action was admitted.") }
                let result = try await client.sendCommand(kind: kind, payload: payload, requestID: requestID)
                guard !self.stopping, self.trustEpochs[deviceID] == epoch,
                      self.storage.devices.contains(where: { $0.deviceID == deviceID && $0.enabled && $0.trustID == expectedTrust }),
                      self.verified(deviceID)?.generation == transport.generation else { throw CompanionBoundaryError("notification_outcome_unknown", "Notification sharing may have changed before pairing authority changed. Inspect the phone's current sharing state before retrying.") }
                return try Self.object(result)
            }
        case "clipboard_send", "share_send", "command":
            let kind: String
            switch operation { case "clipboard_send": kind = "clipboard_text"; default: kind = try string(p, "kind") }
            let payload = p["payload"]?.object ?? [:]
            if operation == "command" { guard ["open_app", "stop_session", "set_audio_route", "set_profile", "diagnostics_request", "share_text", "share_url"].contains(kind) else { throw CompanionBoundaryError("unsupported_command", "Unsupported companion command.") } }
            return try await control(deviceID:deviceID) { try Self.object(await client.sendCommand(kind: kind, payload: payload, requestID: requestID)) }
        case "transfer_begin":
            let transfer = CompanionTransfer(transferId: try uuid(p, "transfer_id"), direction: try string(p, "direction"), displayName: try string(p, "display_name"), mimeType: try string(p, "mime_type"), size: try integer(p, "size"), sha256: try string(p, "sha256"))
            return try await control(deviceID:deviceID) { try Self.object(await client.beginTransfer(transfer, requestID: requestID)) }
        case "transfer_status": return try await control(deviceID:deviceID) { try Self.object(await client.transferStatus(id: selfString(p, "transfer_id"))) }
        case "transfer_chunk":
            guard let data = Data(base64Encoded: try string(p, "bytes")), data.count <= CompanionClient.chunkLimit else { throw CompanionBoundaryError("invalid_chunk", "File chunk exceeds its limit.") }
            try checkCancelled(requestID)
            let reply = try await bulk(deviceID:deviceID) { try Self.object(await client.uploadChunk(id: selfString(p, "transfer_id"), index: Int(selfInteger(p, "index")), data: data)) }
            try checkCancelled(requestID); return reply
        case "transfer_download":
            let data = try await bulk(deviceID:deviceID) { try await client.downloadChunk(id: selfString(p, "transfer_id"), index: Int(selfInteger(p, "index"))) }
            return ["bytes": .string(data.base64EncodedString())]
        case "transfer_commit": return try await bulk(deviceID:deviceID) { try Self.object(await client.commitTransfer(id: selfString(p, "transfer_id"))) }
        case "transfer_receipt":
            let id = try uuid(p, "transfer_id"), size = try integer(p, "accepted_bytes"), hash = try string(p, "sha256"), status = try string(p, "status")
            return try await control(deviceID:deviceID) { try Self.object(await client.transferReceipt(id: id, acceptedBytes: size, sha256: hash, status: status, requestID: requestID)) }
        case "transfer_cancel": try await control(deviceID:deviceID) { try await client.cancelTransfer(id: selfString(p, "transfer_id")) }; return ["status": .string("cancelled")]
        case "delivery": return try await CompanionReleaseMetadata.fetch().brokerPayload
        default: throw CompanionBoundaryError("unsupported_operation", "Unsupported companion service operation.")
        }
    }
    private struct Enrollment {
        let deviceID: String
        let serverPin: String
        let candidateID: UUID?
        init(deviceID:String,serverPin:String,candidateID:UUID? = nil) { self.deviceID = deviceID; self.serverPin = serverPin; self.candidateID = candidateID }
    }
    private func connect(serial: String, enrollment: Enrollment? = nil) async throws -> [String: CompanionJSON] {
        guard !stopping else { throw CancellationError() }
        try AndroidDiscovery.validateSerial(serial)
        if let scope = CompanionQAScope.current, scope.serial != serial {
            #if DEBUG
            // Internal compiled harness only: one recorded loopback TLS alias;
            // storage remains bound to the unchanged owned emulator QA scope.
            let aliases=testingHooks?.qaAdditionalSerials ?? []
            let permitted=aliases.count==1 && aliases.contains(serial) && serial.range(of:"^127\\.0\\.0\\.1:[0-9]{1,5}$",options:.regularExpression) != nil && UInt16(serial.split(separator:":").last ?? "0") != nil
            guard permitted else {throw CompanionBoundaryError("qa_serial_refused","This isolated verification scope only admits its owned emulator.")}
            #else
            throw CompanionBoundaryError("qa_serial_refused", "This isolated verification scope only admits its owned emulator.")
            #endif
        }
        if let current = transports[serial] {
            if let enrollment {
                guard current.serverPin == enrollment.serverPin, UUID(uuidString: current.hello.deviceId)?.uuidString.lowercased() == enrollment.deviceID else { throw CompanionBoundaryError("server_pin_mismatch", "Disconnect the existing companion connection before explicitly pairing a different installation identity.") }
            }
            return ["device_id": .string(current.hello.deviceId), "paired": .bool(current.verified), "hello": try json(current.hello)]
        }
        guard !connecting.contains(serial), transports.count + connecting.count < 32 else { throw CompanionBoundaryError("connection_busy", "A companion connection is already starting or the device limit was reached.", retryable: true) }
        connecting.insert(serial); defer { connecting.remove(serial) }
        // The pin comes exclusively from explicit enrollment or previously
        // approved Keychain records. Public hello never teaches us a pin.
        var candidates: [(String, String, CompanionCredentialRecord?, UUID)] = []
        var credentialFailure: CompanionBoundaryError?
        if let enrollment {
            var record: CompanionCredentialRecord?
            do {
                if let candidateID = enrollment.candidateID { record = try CompanionPendingCredentialStore.load(id:candidateID)?.record }
                else {
                    guard !storage.pendingAdmissions.contains(where: { $0.deviceID == enrollment.deviceID && $0.phase != "committed" }) else { throw CompanionBoundaryError("pairing_admission_pending", "Finish the approved pairing recovery or Forget it before starting a fresh phone link.") }
                    record = try CompanionCredentialStore.load(deviceID: enrollment.deviceID)
                }
            }
            catch let error as CompanionBoundaryError where error.code == "re_pair_required" { record = nil }
            if record?.serverPin != enrollment.serverPin { record = nil }
            candidates.append((enrollment.deviceID, enrollment.serverPin, record, trustEpoch(enrollment.deviceID)))
        } else {
            // Known aliases are fast. For a new USB/TLS-Wi-Fi alias, try the
            // bounded saved pin cohort; a wrong pin receives no HTTP bytes.
            guard !storage.pendingAdmissions.contains(where: { $0.serial == serial && $0.phase != "committed" }) else { throw CompanionBoundaryError("pairing_admission_pending", "This approved pairing needs explicit recovery. It will not reconnect automatically.") }
            let trusted = storage.devices.filter { device in device.trustID != nil && !storage.pendingAdmissions.contains(where: { $0.deviceID == device.deviceID && $0.phase != "committed" }) }
            let known = trusted.filter { $0.aliases.contains(serial) }
            let devices = (known.isEmpty ? trusted : known).sorted { $0.deviceID < $1.deviceID }
            var repairStateChanged = false
            for device in devices {
                do {
                    guard let record = try CompanionCredentialStore.load(deviceID: device.deviceID) else { throw CompanionBoundaryError("re_pair_required", "Saved companion trust is missing. Forget that pairing and approve a fresh phone link.") }
                    candidates.append((record.deviceID.lowercased(), record.serverPin, record, trustEpoch(record.deviceID.lowercased())))
                } catch {
                    let failure = error as? CompanionBoundaryError ?? CompanionBoundaryError("credential_unavailable", "Saved companion trust could not be read. Forget the affected pairing and approve a fresh phone link.")
                    credentialFailure = credentialFailure ?? failure
                    if let index = storage.devices.firstIndex(where: { $0.deviceID == device.deviceID }), storage.devices[index].lastError != failure.code {
                        storage.devices[index].lastError = failure.code; repairStateChanged = true
                    }
                    // One old ad-hoc ACL or pinless record cannot prevent another
                    // installation from proving its independently saved TLS pin.
                }
            }
            if repairStateChanged { try persist() }
        }
        if candidates.isEmpty, let credentialFailure { throw credentialFailure }
        guard !candidates.isEmpty else { throw CompanionBoundaryError("missing_server_pin", "Open a pairing window on the phone, then scan or paste its complete pairing link. No phone request was sent.") }
        let forward:BrokerOwnedForward
        #if DEBUG
        if let endpoint=testingHooks?.endpoint {forward = .test(try await endpoint(serial))}
        else {forward = .adb(try CompanionForward.reserve(serial:serial,adbPath:Toolchain().adb))}
        #else
        forward = .adb(try CompanionForward.reserve(serial:serial,adbPath:Toolchain().adb))
        #endif
        let allocation = UUID()
        startingForwards[allocation] = forward
        do {
            if case .adb(let reserved) = forward { try await reserved.establish() }
            guard !stopping else { throw CancellationError() }
            var lastError: Error = CompanionBoundaryError("server_pin_mismatch", "The phone certificate does not match any approved installation. Pair explicitly to trust a new installation.")
            for (expectedID, pin, record, epoch) in candidates {
                let client = try CompanionClient(baseURL: forward.baseURL, serverPin: pin)
                try await client.setExpectedDeviceID(expectedID)
                let hello: CompanionHello
                do { hello = try await control(deviceID:expectedID) { try await client.hello() } }
                catch {
                    lastError = error
                    if (error as? CompanionBoundaryError)?.code == "server_pin_mismatch" { continue }
                    throw error
                }
                #if DEBUG
                try await testingHooks?.checkpoint("hello_received",serial)
                #endif
                guard !stopping, startingForwards[allocation] != nil else { throw CancellationError() }
                guard trustEpochs[expectedID] == epoch else { throw CompanionBoundaryError("trust_changed", "Pairing was forgotten while connecting. Pair explicitly again.") }
                guard let canonical = UUID(uuidString: hello.deviceId)?.uuidString.lowercased(), canonical == expectedID else { throw CompanionBoundaryError("identity_mismatch", "The pinned phone certificate returned a different installation identity.") }
                var transport = BrokerTransport(serial: serial, hello: hello, forward: forward, client: client, generation: allocation, serverPin: pin, verified: false)
                if let record {
                    try await client.setCredential(record.credential)
                    guard trustEpochs[expectedID] == epoch else {throw CompanionBoundaryError("trust_changed","Pairing changed before authentication.")}
                    let identity = try await control(deviceID:expectedID) { try await client.identity() }
                    guard !stopping, startingForwards[allocation] != nil else { throw CancellationError() }
                    guard UUID(uuidString: identity.deviceId)?.uuidString.lowercased() == canonical,
                          UUID(uuidString: identity.trustId) == UUID(uuidString: record.trustID) else { throw CompanionBoundaryError("identity_mismatch", "The authenticated phone trust changed. Pair explicitly again.") }
                    try await client.setExpectedDeviceID(canonical)
                    guard !stopping, startingForwards[allocation] != nil else { throw CancellationError() }
                    transport.verified = true
                    guard trustEpochs[expectedID] == epoch else { throw CompanionBoundaryError("trust_changed", "Pairing changed while authenticating.") }
                    try await admit(transport, deviceID: canonical, trustID: identity.trustId, explicitRePair: enrollment != nil, candidateID: enrollment?.candidateID)
                    guard trustEpochs[expectedID] == epoch else { throw CompanionBoundaryError("trust_changed", "Pairing changed while connecting.") }
                }
                guard !stopping else { throw CancellationError() }
                transports[serial] = transport
                startingForwards.removeValue(forKey: allocation)
                if transport.verified { reconnectAttempts[canonical] = 0; retryAfter.removeValue(forKey: canonical); startPoller(canonical) }
                return ["device_id": .string(canonical), "paired": .bool(transport.verified), "hello": try json(hello)]
            }
            throw lastError
        } catch {
            startingForwards.removeValue(forKey: allocation)
            _ = await retireForward(forward, generation: allocation)
            throw error
        }
    }
    private func trustEpoch(_ deviceID: String) -> UUID {
        if let current = trustEpochs[deviceID] { return current }
        let current = UUID(); trustEpochs[deviceID] = current; return current
    }
    private func admit(_ transport: BrokerTransport, deviceID: String, trustID: String, explicitRePair: Bool = false, candidateID: UUID? = nil) async throws {
        guard !stopping else { throw CancellationError() }
        storage.registry.prune()
        let original = storage
        var next = storage
        var previous: BrokerTransport?
        let inheritedProfile=next.devices.filter {$0.deviceID != deviceID && $0.aliases.contains(transport.serial) && $0.trustID == nil}.sorted {$0.deviceID<$1.deviceID}.first?.profile
        for other in next.devices.indices where next.devices[other].deviceID != deviceID && next.devices[other].aliases.contains(transport.serial) {
            guard explicitRePair, next.devices[other].trustID == nil, try catalog.companionExportWasForgotten(deviceID: next.devices[other].deviceID) else { throw CompanionBoundaryError("alias_owned", "This connection belongs to a saved phone installation. Explicitly forget its pairing on this Mac before approving a new installation.") }
            next.devices[other].aliases.removeAll { $0 == transport.serial }
        }
        if let i = next.devices.firstIndex(where: { $0.deviceID == deviceID }) {
            let oldSerial = next.devices[i].preferredSerial
            if oldSerial != transport.serial, let existing = transports[oldSerial] {
                guard !storage.registry.sessions.contains(where: { $0.deviceID == deviceID && !["stopped", "failed"].contains($0.phase) }) else { throw CompanionBoundaryError("transport_in_use", "This phone already has Mac sessions on its other connection. Close those sessions before switching USB or Wi-Fi.") }
                previous = existing
            }
            if !next.devices[i].aliases.contains(transport.serial) { guard next.devices[i].aliases.count < 8 else { throw CompanionBoundaryError("alias_capacity", "This phone has too many saved transport aliases.") }; next.devices[i].aliases.append(transport.serial) }
            if next.devices[i].trustID != trustID { next.devices[i].lastCatalogEventID = nil }
            next.devices[i].preferredSerial = transport.serial; next.devices[i].name = transport.hello.deviceName; next.devices[i].trustID = trustID; next.devices[i].enabled = true; next.devices[i].lastError = nil
        } else {
            guard next.devices.count < 32 else { throw CompanionBoundaryError("device_capacity", "The companion device limit was reached.") }
            next.devices.append(.init(deviceID: deviceID, name: transport.hello.deviceName, aliases: [transport.serial], preferredSerial: transport.serial, trustID: trustID, epoch: nil, sequence: 0, profile: inheritedProfile ?? "balanced", exportSelection: [:]))
        }
        guard let current = next.devices.firstIndex(where: { $0.deviceID == deviceID }) else { throw CompanionBoundaryError("invalid_identity", "Missing paired device identity.") }
        // A successful authenticated reconnect may follow missed package events.
        // This is a cached invalidation hint, never a catalog read from status.
        next.devices[current].catalogChangeToken = UUID().uuidString.lowercased()
        // This independently locked atomic policy is authoritative if the broker
        // crashes before its cache commit. No live broker state changes on refusal.
        #if DEBUG
        try testingHooks?.fault("policy_bind")
        #endif
        try catalog.bindCompanionExportAuthority(deviceID: deviceID, trustID: trustID, aliases: next.devices[current].aliases, allowingForgottenAliasTransfer: explicitRePair)
        next.devices[current].exportSelection = try catalog.companionExportSelection(deviceID: deviceID)
        if let candidateID {
            #if DEBUG
            try testingHooks?.fault("candidate_finalize")
            #endif
            try CompanionPendingCredentialStore.finalize(id:candidateID,deviceID:deviceID,trustID:trustID,serverPin:transport.serverPin)
            if let pending = next.pendingAdmissions.firstIndex(where: { $0.id == candidateID }) { next.pendingAdmissions[pending].phase = "committed" }
        }
        storage = next
        do { try persist() } catch { storage = original; throw error }
        if let previous, transports[previous.serial]?.generation == previous.generation {
            removeTransport(serial: previous.serial); pollers.removeValue(forKey: deviceID)?.cancel(); _ = await retireForward(previous)
        }
    }
    private func clearCommittedCandidate(_ id:UUID) throws {
        guard !stopping else { throw CancellationError() }
        try CompanionPendingCredentialStore.remove(id:id)
        storage.pendingAdmissions.removeAll { $0.id == id }; try persist()
    }
    private func recoverPairing(_ deviceID:String) async throws -> [String:CompanionJSON] {
        guard let pending = storage.pendingAdmissions.first(where: { $0.deviceID == deviceID }) else { throw CompanionBoundaryError("no_pending_pairing", "There is no approved pairing to recover.") }
        if pending.phase == "committed" { try clearCommittedCandidate(pending.id); return ["status":.string("approved"),"device_id":.string(deviceID)] }
        guard pending.deadlineBootID == CompanionClock.bootID, let deadlineMS = pending.deadlineMS, deadlineMS > CompanionClock.nowMS(), let candidate = try CompanionPendingCredentialStore.load(id:pending.id), candidate.record.deviceID == deviceID, candidate.record.trustID == pending.trustID.lowercased(), candidate.record.serverPin == pending.serverPin else { throw CompanionBoundaryError("pairing_recovery_expired", "This pending pairing cannot be recovered. Forget it on this Mac, revoke the old trust on the phone, then approve a fresh link.") }
        trustEpochs[deviceID] = UUID(); pairings = pairings.filter { $0.value.deviceID != deviceID }
        if let current = removeTransport(serial:pending.serial) { guard await retireForward(current) else { throw CompanionBoundaryError("forward_cleanup_pending", "The old pairing connection is still closing. Retry recovery shortly.",retryable:true) } }
        _ = try await connect(serial:pending.serial,enrollment:.init(deviceID:deviceID,serverPin:pending.serverPin,candidateID:pending.id))
        try clearCommittedCandidate(pending.id)
        return ["status":.string("approved"),"device_id":.string(deviceID)]
    }
    private func beginPair(_ p: [String: CompanionJSON]) async throws -> [String: CompanionJSON] {
        let serial = try string(p, "serial"), secret = try string(p, "secret"); try CompanionClient.validateSecret(secret)
        guard let pin = p["server_pin"]?.string else { throw CompanionBoundaryError("missing_server_pin", "Scan or paste the complete pairing link from the phone.") }; try CompanionClient.validateServerPin(pin)
        let expectedID = try uuid(p, "expected_device_id")
        guard let pairingExpires = p["pairing_expires"]?.number, pairingExpires.isFinite, pairingExpires.rounded() == pairingExpires else { throw CompanionBoundaryError("invalid_pairing", "The complete phone pairing link expiry is required.") }
        let epoch = trustEpoch(expectedID)
        guard !storage.pendingAdmissions.contains(where: { $0.deviceID == expectedID && $0.phase != "committed" }) else { throw CompanionBoundaryError("pairing_admission_pending", "Finish the approved pairing recovery or Forget it before using a fresh phone link.") }
        if let pending = transports[serial], !pending.verified,
           pending.serverPin != pin || UUID(uuidString: pending.hello.deviceId)?.uuidString.lowercased() != expectedID {
            removeTransport(serial: serial)
            pairings = pairings.filter { $0.value.serial != serial }
            guard await retireForward(pending) else { throw CompanionBoundaryError("forward_cleanup_pending", "The previous pairing connection is still closing. Retry shortly.", retryable: true) }
        }
        _ = try await connect(serial: serial, enrollment: .init(deviceID: expectedID, serverPin: pin))
        #if DEBUG
        try await testingHooks?.checkpoint("before_pair_transport_bind",serial)
        #endif
        guard let transport = transports[serial], let canonical = UUID(uuidString: transport.hello.deviceId)?.uuidString.lowercased() else { throw CompanionBoundaryError("phone_unavailable", "Connect the phone first.") }
        // Actor reentrancy may replace an unapproved connection while connect()
        // suspends. Bind the secret to the original QR pin, not only public UUID.
        guard transport.serverPin == pin, canonical == expectedID, trustEpochs[expectedID] == epoch else { throw CompanionBoundaryError("pairing_superseded", "The pairing server identity changed. Start a new phone pairing window.") }
        if let expected = p["expected_device_id"]?.string, UUID(uuidString: expected)?.uuidString.lowercased() != canonical { throw CompanionBoundaryError("identity_mismatch", "The pairing QR belongs to a different Android installation.") }
        let qrDeadline = try await control(deviceID:expectedID) { try await transport.client.validatePairingCodeExpiry(expiresSeconds: pairingExpires) }
        guard !stopping, transports[serial]?.generation == transport.generation, trustEpochs[expectedID] == epoch, qrDeadline > CompanionClock.nowMS() else { throw CompanionBoundaryError("pairing_expired", "The phone pairing link expired or changed.") }
        let response = try await control(deviceID:expectedID) { try await transport.client.beginPair(secret: secret, macID: storage.macID, name: Host.current().localizedName ?? "Mac") }
        guard transports[serial]?.generation == transport.generation else { throw CompanionBoundaryError("pairing_superseded", "The pairing connection changed. Start a new pairing window.") }
        guard let rawID = response.pairingId, let id = UUID(uuidString: rawID)?.uuidString.lowercased() else { throw CompanionBoundaryError("invalid_pairing", "The phone did not return a pairing request.") }
        let phoneDeadline = try await control(deviceID:expectedID) { try await transport.client.pairingExpiryMS(response) }
        let expiresContinuous = min(qrDeadline, phoneDeadline)
        guard !stopping, transports[serial]?.generation == transport.generation, trustEpochs[expectedID] == epoch, expiresContinuous > CompanionClock.nowMS() else { throw CompanionBoundaryError("pairing_expired", "Open a new pairing window on the phone.") }
        let expiry = Date().addingTimeInterval((expiresContinuous - CompanionClock.nowMS()) / 1000)
        let rawExpiry = ISO8601DateFormatter().string(from: expiry)
        let comparison = response.comparisonCode ?? String(CompanionClient.sha256(Data((secret + ":" + storage.macID.uuidString).utf8)).prefix(8)).uppercased()
        guard comparison.range(of: "^[A-F0-9]{8}$", options: .regularExpression) != nil else { throw CompanionBoundaryError("invalid_pairing", "The phone returned an invalid comparison code.") }
        let name = Host.current().localizedName ?? "Mac"
        pairings[id] = .init(id: id, serial: serial, secret: secret, deviceID: canonical, expires: expiry, expiresContinuousMS: expiresContinuous, deadlineBootID: CompanionClock.bootID, comparisonCode: comparison, macName: name, transportGeneration: transport.generation, serverPin: transport.serverPin, trustEpoch: epoch)
        return ["pairing_id": .string(id), "status": .string(response.status), "device_id": .string(canonical), "comparison_code": .string(comparison), "mac_name": .string(name), "expires_at": .string(rawExpiry), "expires_continuous_ms": .number(expiresContinuous), "deadline_boot_id": .string(CompanionClock.bootID)]
    }
    private func pollPair(_ p: [String: CompanionJSON]) async throws -> [String: CompanionJSON] {
        let id = try uuid(p, "pairing_id")
        guard let pair = pairings[id], pair.isValid, var transport = transports[pair.serial],
              transport.generation == pair.transportGeneration, transport.serverPin == pair.serverPin, trustEpochs[pair.deviceID] == pair.trustEpoch,
              UUID(uuidString: transport.hello.deviceId)?.uuidString.lowercased() == pair.deviceID else { pairings.removeValue(forKey: id); throw CompanionBoundaryError("pairing_expired", "Open a new pairing window on the phone.") }
        let response = try await control(deviceID:pair.deviceID) { try await transport.client.pollPair(id: id, secret: pair.secret) }
        guard pair.isValid, transports[pair.serial]?.generation == pair.transportGeneration, trustEpochs[pair.deviceID] == pair.trustEpoch else { throw CompanionBoundaryError("pairing_superseded", "The pairing connection changed. Start a new pairing window.") }
        guard response.pairingId.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() == pair.id else { throw CompanionBoundaryError("invalid_pairing", "The phone returned a different pairing request.") }
        if response.status == "approved" {
            guard let credential = response.credential, let responseID = response.deviceId, UUID(uuidString: responseID)?.uuidString.lowercased() == pair.deviceID, let trust = response.trustId else { throw CompanionBoundaryError("invalid_pairing", "Phone pairing identity did not match.") }
            try await transport.client.setCredential(credential)
            let identity = try await control(deviceID:pair.deviceID) { try await transport.client.identity() }
            guard pair.isValid, transports[pair.serial]?.generation == pair.transportGeneration, trustEpochs[pair.deviceID] == pair.trustEpoch else { throw CompanionBoundaryError("pairing_superseded", "The pairing connection changed. Start a new pairing window.") }
            guard UUID(uuidString: identity.deviceId)?.uuidString.lowercased() == pair.deviceID, identity.trustId == trust else { throw CompanionBoundaryError("identity_mismatch", "The approved phone identity did not match.") }
            try await transport.client.setExpectedDeviceID(pair.deviceID)
            guard !stopping, transports[pair.serial]?.generation == pair.transportGeneration, trustEpochs[pair.deviceID] == pair.trustEpoch else { throw CancellationError() }
            let candidateID = try uuid(p, "pairing_id")
            let candidateUUID = UUID(uuidString:candidateID)!
            let record = try CompanionCredentialRecord(deviceID:pair.deviceID,trustID:trust,credential:credential,serverPin:transport.serverPin)
            if !storage.pendingAdmissions.contains(where: { $0.id == candidateUUID }) {
                guard storage.pendingAdmissions.count < 32 else { throw CompanionBoundaryError("admission_capacity", "Recover or Forget an earlier pending pairing before adding another.") }
                storage.pendingAdmissions.append(.init(id:candidateUUID,deviceID:pair.deviceID,trustID:trust,serverPin:transport.serverPin,serial:pair.serial,expires:Date().addingTimeInterval(600),deadlineBootID:CompanionClock.bootID,deadlineMS:CompanionClock.nowMS()+600_000,phase:"staged"))
                try persist()
            }
            guard let pending = storage.pendingAdmissions.first(where: { $0.id == candidateUUID }) else { throw CompanionBoundaryError("candidate_unavailable", "The pending pairing journal is unavailable.") }
            #if DEBUG
            try testingHooks?.fault("candidate_stage")
            #endif
            try CompanionPendingCredentialStore.stage(.init(record:record,expires:pending.expires),id:candidateUUID)
            transport.verified = true; try await admit(transport, deviceID: pair.deviceID, trustID: trust, explicitRePair: true,candidateID:candidateUUID)
            try clearCommittedCandidate(candidateUUID)
            guard pair.isValid, transports[pair.serial]?.generation == pair.transportGeneration, trustEpochs[pair.deviceID] == pair.trustEpoch else { throw CompanionBoundaryError("pairing_superseded", "The pairing connection changed. Reconnect explicitly.") }
            transports[pair.serial] = transport
            pairings.removeValue(forKey: id); startPoller(pair.deviceID)
        }
        // Pairing credential is deliberately omitted from IPC replies.
        return ["pairing_id": .string(id), "status": .string(response.status), "device_id": .string(pair.deviceID), "comparison_code": .string(pair.comparisonCode), "mac_name": .string(pair.macName), "expires_at": .string(ISO8601DateFormatter().string(from: pair.expires)), "expires_continuous_ms": .number(pair.expiresContinuousMS), "deadline_boot_id": .string(pair.deadlineBootID)]
    }
    private func startPoller(_ deviceID: String) {
        pollers.removeValue(forKey: deviceID)?.cancel()
        pollerTokens.removeValue(forKey: deviceID)
        guard let generation = verified(deviceID)?.generation else { return }
        let token = UUID(); pollerTokens[deviceID] = token
        pollers[deviceID] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.ownsPoller(deviceID, generation: generation, token: token) else { return }
                do { try await self.poll(deviceID, expectedGeneration: generation) }
                catch {
                    guard !Task.isCancelled else { return }
                    await self.pollFailed(deviceID, error: error, expectedGeneration: generation, token: token)
                    return
                }
            }
        }
    }
    private func ownsPoller(_ deviceID: String, generation: UUID, token: UUID) -> Bool {
        !stopping && pollerTokens[deviceID] == token && verified(deviceID)?.generation == generation
    }
    private func poll(_ deviceID: String, expectedGeneration: UUID) async throws {
        guard let transport = verified(deviceID), transport.generation == expectedGeneration,
              let device = storage.devices.first(where: { $0.deviceID == deviceID }) else { throw CompanionBoundaryError("phone_unavailable", "Phone disconnected.") }
        let page = try await transport.client.events(after: device.sequence, epoch: device.epoch)
        #if DEBUG
        try await testingHooks?.checkpoint("events_received", deviceID)
        #endif
        guard verified(deviceID)?.generation == transport.generation, !Task.isCancelled else { throw CancellationError() }
        guard let index = storage.devices.firstIndex(where: { $0.deviceID == deviceID }) else { return }
        if page.resetRequired || (storage.devices[index].epoch != nil && storage.devices[index].epoch != page.epoch) {
            // A discontinuous stream cannot prove old notifications are still
            // active. Clear only their local projections before fresh events;
            // never dismiss on Android or discard explicit shares/files.
            storage.inbox.removeAll { $0.deviceID == deviceID && $0.kind == "notification_posted" }
            storage.devices[index].sequence = 0; storage.devices[index].epoch = page.epoch
            storage.devices[index].catalogChangeToken = UUID().uuidString.lowercased()
        }
        for event in page.events {
            guard verified(deviceID)?.generation == transport.generation, !Task.isCancelled else { throw CancellationError() }
            await receive(event, deviceID: deviceID, transport: transport)
            guard verified(deviceID)?.generation == transport.generation, !Task.isCancelled else { throw CancellationError() }
            storage.devices[index].sequence = event.sequence; storage.devices[index].epoch = page.epoch; try persist()
        }
        storage.devices[index].sequence = page.nextSequence; storage.devices[index].epoch = page.epoch; try persist()
        if page.events.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
    }
    private func receive(_ event: CompanionEvent, deviceID: String, transport: BrokerTransport) async {
        if event.kind == "command" {
            let payload = event.payload["payload"]?.object ?? [:], kind = event.payload["kind"]?.string ?? "", id = event.payload["request_id"]?.string ?? event.eventId
            do {
                guard !storage.localCommands.contains(id.lowercased()) else { throw CompanionBoundaryError("request_conflict", "A local command identity cannot be reused for a phone action.") }
                let budget = try await control(deviceID:deviceID) { try await transport.client.phoneCommandDeadline(event.payload) }
                guard !stopping, verified(deviceID)?.generation == transport.generation, budget.isValid else { throw CompanionBoundaryError("command_expired", "The phone command expired or its connection changed.") }
                if ["share_text", "share_url", "clipboard_text"].contains(kind) {
                    guard let text = payload["text"]?.string, text.utf8.count <= (kind == "share_url" ? 8192 : 65_536) else { throw CompanionBoundaryError("invalid_content", "Shared text exceeds its limit.") }
                    if kind == "share_url" { guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw CompanionBoundaryError("invalid_url", "Only HTTP and HTTPS links can be received.") } }
                    if !storage.inbox.contains(where: { $0.id == id }) { storage.inbox.append(.init(id: id, deviceID: deviceID, kind: kind, created: Date(), payload: payload)); boundInbox(); try persist() }
                    try await control(deviceID:deviceID) { try await transport.client.acknowledge(commandID: id, status: "applied", result: ["state": .string("received_inbox")]) }
                    return
                }
                if kind == "stop_all" { try await enqueueStopAll(id: id, deviceID: deviceID, continuousDeadline: budget); return }
                if kind == "set_export" {
                    if let receipt = try await applyExport(deviceID: deviceID, id: id, payload: payload, continuousDeadline: budget), receipt.status != "accepted" { try await control(deviceID:deviceID) { try await transport.client.acknowledge(commandID: id, status: receipt.status, result: receipt.result) } }
                    return
                }
                guard ["open_app", "stop_session", "stop_all", "set_audio_route", "retry_audio", "set_profile", "set_screen_power", "set_export", "diagnostics_request"].contains(kind) else { throw CompanionBoundaryError("unsupported_command", "The phone requested an unsupported Mac action.") }
                let receipt = try await enqueueHost(id: id, deviceID: deviceID, kind: kind, payload: payload, continuousDeadline: budget)
                try persist()
                if receipt.status != "accepted" { try await control(deviceID:deviceID) { try await transport.client.acknowledge(commandID: id, status: receipt.status, result: receipt.result) } }
            } catch {
                try? await control(deviceID:deviceID) { try await transport.client.acknowledge(commandID: id, status: (error as? CompanionBoundaryError)?.code == "selection_outcome_unknown" ? "unknown" : "rejected", result: ["code": .string((error as? CompanionBoundaryError)?.code ?? "host_unavailable")]) }
            }
        } else if event.kind == "catalog_preferences" {
            guard let id = event.payload["request_id"]?.string else { return }
            do { _ = try await applyExport(deviceID: deviceID, id: id, payload: event.payload) }
            catch {
                // Accepted policy remains authoritative, but an unavailable host is an explicit failed receipt.
                guard !storage.localCommands.contains(id.lowercased()) else { return }
                try? await control(deviceID:deviceID) { try await transport.client.acknowledge(commandID: id, status: (error as? CompanionBoundaryError)?.code == "selection_outcome_unknown" ? "unknown" : "rejected", result: ["code": .string((error as? CompanionBoundaryError)?.code ?? "export_apply_failed")]) }
            }
        } else if event.kind == "catalog_changed" {
            guard let index = storage.devices.firstIndex(where: { $0.deviceID == deviceID && $0.enabled && $0.trustID != nil }),
                  event.targetTrustId == nil || event.targetTrustId.flatMap(UUID.init(uuidString:))?.uuidString.lowercased() == storage.devices[index].trustID,
                  let eventID = UUID(uuidString: event.eventId)?.uuidString.lowercased(),
                  storage.devices[index].lastCatalogEventID != eventID else { return }
            storage.devices[index].lastCatalogEventID = eventID
            storage.devices[index].catalogChangeToken = UUID().uuidString.lowercased()
        } else if ["clipboard", "clipboard_text", "share", "share_text", "share_url", "file_shared", "notification_posted", "notification_removed"].contains(event.kind) {
            guard !storage.inbox.contains(where: { $0.id == event.eventId }) else { return }
            if event.kind == "notification_posted" || event.kind == "notification_removed" {
                guard let origin = event.targetTrustId.flatMap(UUID.init(uuidString:))?.uuidString.lowercased(),
                      storage.devices.contains(where: { $0.deviceID == deviceID && $0.enabled && $0.trustID == origin }) else { return }
                let key = event.payload["notification_key"]?.string
                storage.inbox.removeAll { $0.deviceID == deviceID && $0.kind == "notification_posted" && $0.payload["notification_key"]?.string == key }
                if event.kind == "notification_removed" { return }
            }
            storage.inbox.append(.init(id: event.eventId, deviceID: deviceID, kind: event.kind, created: Date(), payload: event.payload, trustID: event.kind == "notification_posted" ? event.targetTrustId?.lowercased() : nil))
            boundInbox()
        }
    }
    private func pollFailed(_ deviceID: String, error: Error, expectedGeneration: UUID, token: UUID) async {
        guard !stopping, pollerTokens[deviceID] == token,
              let current = verified(deviceID), current.generation == expectedGeneration,
              let transport = removeTransport(serial: current.serial) else { return }
        pollerTokens.removeValue(forKey: deviceID)
        pollers.removeValue(forKey: deviceID)
        let code = (error as? CompanionBoundaryError)?.code ?? "connection_lost"
        if ["unauthorized", "trust_revoked", "http_401"].contains(code) {
            storage.inbox.removeAll { $0.deviceID == deviceID && $0.kind == "notification_posted" }
        }
        if let i = storage.devices.firstIndex(where: { $0.deviceID == deviceID }) { storage.devices[i].lastError = code; try? persist() }
        _ = await retireForward(transport)
    }
    /// Register cleanup ownership synchronously, before any fallible journal or
    /// asynchronous boundary can discard the active transport.
    @discardableResult private func removeTransport(serial: String) -> BrokerTransport? {
        guard let transport = transports.removeValue(forKey: serial) else { return nil }
        retiringForwards[transport.generation] = transport.forward
        return transport
    }
    private func retireForward(_ transport: BrokerTransport) async -> Bool {
        await retireForward(transport.forward, generation: transport.generation)
    }
    private func retireForward(_ forward: BrokerOwnedForward, generation: UUID) async -> Bool {
        retiringForwards[generation] = forward
        if let retry = forwardRetries[generation], retry.next > Date() { return false }
        do {
            #if DEBUG
            try testingHooks?.fault("forward_close")
            #endif
            try await forward.close()
            retiringForwards.removeValue(forKey: generation); forwardRetries.removeValue(forKey: generation)
            return true
        } catch {
            let attempt = min(6, (forwardRetries[generation]?.attempt ?? 0) + 1)
            forwardRetries[generation] = (attempt, Date().addingTimeInterval(min(30, pow(2, Double(attempt - 1)))))
            return false
        }
    }
    private func deliverTerminalReceipts(generation: UUID) async {
        defer { if receiptDeliveryGeneration == generation { receiptDelivery = nil; receiptDeliveryGeneration = nil } }
        for receipt in storage.registry.commands.filter({ command in command.status != "accepted" && command.receiptDelivered != true && (receiptRetry[command.id]?.nextMS ?? 0) <= CompanionClock.nowMS() && !storage.localCommands.contains(command.id) && !storage.stopAll.contains(where: { $0.children.contains(command.id) }) }).prefix(8) {
            guard !stopping, !Task.isCancelled else { return }
            guard let transport = verified(receipt.deviceID) else { continue }
            do {
                try await control(deviceID:receipt.deviceID) {
                    guard !stopping, !Task.isCancelled, receiptDeliveryGeneration == generation, verified(receipt.deviceID)?.generation == transport.generation else { throw CancellationError() }
                    try await transport.client.acknowledge(commandID: receipt.id, status: receipt.status, result: receipt.result)
                }
                guard !stopping, !Task.isCancelled, receiptDeliveryGeneration == generation, verified(receipt.deviceID)?.generation == transport.generation else { return }
                storage.registry.markReceiptDelivered(id: receipt.id); try persist(); receiptRetry.removeValue(forKey: receipt.id)
            } catch {
                guard !stopping, !Task.isCancelled, receiptDeliveryGeneration == generation else { return }
                let attempt = min(6, (receiptRetry[receipt.id]?.attempt ?? 0) + 1)
                receiptRetry[receipt.id] = (attempt, CompanionClock.nowMS() + min(30_000, pow(2, Double(attempt - 1)) * 1000))
            }
        }
    }
    private func maintain() async {
        // Slow offline cleanup must not block healthy phones' state publication.
        if forwardReaper == nil, !retiringForwards.isEmpty {
            forwardReaper = Task { [weak self] in
                guard let self else { return }
                await self.reapForwards()
            }
        }
        guard !stopping, !persistenceFailure else { return }
        for pending in storage.pendingAdmissions where pending.phase=="committed" {try? clearCommittedCandidate(pending.id)}
        storage.registry.prune(); await finishStopAll()
        guard !stopping, !persistenceFailure else { return }
        pairings = pairings.filter { $0.value.isValid }
        if receiptDelivery == nil {
            let generation = UUID(); receiptDeliveryGeneration = generation
            receiptRetry = receiptRetry.filter { id, _ in storage.registry.commands.contains(where: { $0.id == id }) }
            receiptDelivery = Task { [weak self] in await self?.deliverTerminalReceipts(generation: generation) }
        }
        for (serial, transport) in transports.filter({ !$0.value.verified && $0.value.admissionExpiryMS <= CompanionClock.nowMS() }) {
            guard let current = transports[serial], current.generation == transport.generation, !current.verified, current.admissionExpiryMS <= CompanionClock.nowMS() else { continue }
            removeTransport(serial: serial)
            pairings = pairings.filter { $0.value.serial != serial }
            _ = await retireForward(transport)
        }
        receipts = receipts.filter { Date().timeIntervalSince($0.value.created) < 86_400 }
        try? persist()
        guard !persistenceFailure else { return }
        for device in storage.devices where verified(device.deviceID) != nil {
            let profile=CompanionPerformanceProfile(rawValue:device.profile) ?? .balanced
            if Date().timeIntervalSince(publishedStates[device.deviceID]?.0 ?? .distantPast)>=profile.statusInterval {await publish(device.deviceID)}
        }
        // Discovery is read-only and serial-specific connection admission remains authenticated.
        guard automaticReconnect, !storage.devices.isEmpty, Date().timeIntervalSince(lastDiscovery) >= 2 else { return }
        lastDiscovery = Date()
        if let devices = try? await AndroidDiscovery().devices() {
            let scoped = CompanionQAScope.current?.filterDevices(devices) ?? devices
            let available = Set(scoped.filter { $0.state == "device" }.map(\.serial))
            for device in storage.devices where device.enabled && transports[device.preferredSerial] == nil && available.contains(device.preferredSerial) && (retryAfter[device.deviceID] ?? .distantPast) <= Date() {
                do { _ = try await connect(serial: device.preferredSerial) }
                catch {
                    if let i = storage.devices.firstIndex(where: { $0.deviceID == device.deviceID }) { storage.devices[i].lastError = (error as? CompanionBoundaryError)?.code ?? "connection_lost"; try? persist() }
                    let attempt = min(5, (reconnectAttempts[device.deviceID] ?? 0) + 1)
                    reconnectAttempts[device.deviceID] = attempt
                    retryAfter[device.deviceID] = Date().addingTimeInterval(min(30, pow(2, Double(attempt))) + Double.random(in: 0...0.5))
                }
            }
        }
    }
    private func reapForwards() async {
        let due = retiringForwards.filter { (forwardRetries[$0.key]?.next ?? .distantPast) <= Date() }.prefix(4)
        for (generation, forward) in due { _ = await retireForward(forward, generation: generation) }
        forwardReaper = nil
    }
    private func publish(_ deviceID: String) async {
        guard let transport = verified(deviceID) else { return }
        let sessions: [CompanionJSON] = storage.registry.sessions.filter { $0.deviceID == deviceID }.map {
            .object(["session_id": .string($0.sessionID), "package_name": .string($0.package), "label": .string($0.label), "backend": .string($0.backend), "phase": .string($0.phase)])
        }
        let currentRoute = (try? DeviceAudioPreferences.loadRoutes()[transport.serial]) ?? .mac
        let route = currentRoute == .macAndPhone ? "mac_and_phone" : currentRoute.rawValue
        var state: [String: CompanionJSON] = ["sessions": .array(sessions), "audio_route": .string(route), "profile": .string(storage.devices.first(where: { $0.deviceID == deviceID })?.profile ?? "balanced"), "connection_state": .string("connected")]
        if let audio = audioStatuses[deviceID], Date().timeIntervalSince(audio.2) <= 10, storage.registry.hosts.contains(where: { $0.owner == audio.0 && $0.generation == audio.1 && $0.deviceID == deviceID }) { state["audio_status"] = .object(audio.3) }
        else { state["audio_status"] = .object(["phase": .string("unavailable"), "message": .string("No live Mac session owner has reported audio output status.")]) }
        let stateEncoder=JSONEncoder();stateEncoder.outputFormatting=[.sortedKeys]
        let encoded=(try? stateEncoder.encode(CompanionJSON.object(state))) ?? Data()
        let fingerprint=CompanionClient.sha256(encoded)
        let unchanged=transport.hello.capabilities.contains("state_heartbeat") && publishedStates[deviceID]?.1==fingerprint
        do {
            do {try await control(deviceID:deviceID) {try await transport.client.publishState(unchanged ? ["unchanged":.bool(true)] : state)}}
            catch let error as CompanionBoundaryError where unchanged && error.code=="snapshot_required" {try await control(deviceID:deviceID) {try await transport.client.publishState(state)}}
            publishedStates[deviceID]=(Date(),fingerprint)
        } catch { /* Preserve last successful state/cadence for an explicit retry. */ }
    }
    private func markLocalCommand(_ id: UUID) {
        let value = id.uuidString.lowercased()
        if !storage.localCommands.contains(value) { storage.localCommands.append(value) }
        if storage.localCommands.count > 512 { storage.localCommands.removeFirst(storage.localCommands.count - 512) }
    }
    private func ensureLauncher(_ deviceID: String) async throws {
        storage.registry.prune()
        if storage.registry.hosts.contains(where: { $0.deviceID == deviceID && $0.role == "launcher" && $0.commandProtocol == 2 && $0.owner.isAlive }) { return }
        if storage.registry.hosts.contains(where: { $0.deviceID == deviceID && $0.role == "launcher" && $0.commandProtocol != 2 && $0.owner.isAlive }) { throw CompanionBoundaryError("owner_update_required", "Quit the older DroidBridge launcher and open the updated installed application before phone control.") }
        if let boot = hostBootstrap { try await boot.value }
        else {
            guard let host = storage.hostApplication else { throw CompanionBoundaryError("launcher_not_registered", "Open the installed DroidBridge application once to enable phone launch.") }
            let boot = Task {
                try await Task.detached(priority: .utility) { try host.revalidate() }.value
                _ = try await ProcessRunner.run("/usr/bin/open", arguments: host.openArguments(), timeout: 5)
                let deadline = CompanionClock.nowMS() + 20_000
                while CompanionClock.nowMS() < deadline {
                    try Task.checkCancellation()
                    self.storage.registry.prune()
                    if self.storage.registry.hosts.contains(where: { $0.deviceID == deviceID && $0.role == "launcher" && $0.commandProtocol == 2 && $0.owner.isAlive }) { return }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                throw CompanionBoundaryError("launcher_start_timeout", "DroidBridge opened but did not become ready for this phone. Open the Mac app and retry.", retryable: true)
            }
            hostBootstrap = boot
            do { try await boot.value; hostBootstrap = nil } catch { hostBootstrap = nil; throw error }
        }
        guard storage.registry.hosts.contains(where: { $0.deviceID == deviceID && $0.role == "launcher" && $0.commandProtocol == 2 && $0.owner.isAlive }) else { throw CompanionBoundaryError("launcher_unavailable", "The updated Mac launcher is unavailable for this phone.", retryable: true) }
    }
    private func enqueueHost(id: String, deviceID: String, kind: String, payload: [String: CompanionJSON], deadline: Date? = nil, continuousDeadline: CompanionCommandDeadline? = nil) async throws -> CompanionBrokerCommand {
        guard !storage.stopAll.contains(where: { $0.id == id.lowercased() }) else { throw CompanionBoundaryError("request_conflict", "A stop-all command identity cannot be reused for another action.") }
        let budget = try continuousDeadline ?? CompanionCommandDeadline(issuedMS: CompanionClock.nowMS(), expiresMS: CompanionClock.nowMS() + 29_999)
        if ["open_app", "set_export"].contains(kind) { try await ensureLauncher(deviceID) }
        guard !stopping else { throw CancellationError() }
        guard !storage.stopAll.contains(where: { $0.id == id.lowercased() }) else { throw CompanionBoundaryError("request_conflict", "A stop-all command identity cannot be reused for another action.") }
        return try storage.registry.enqueue(id: id, deviceID: deviceID, kind: kind, payload: payload, deadline: deadline, continuousDeadline: budget)
    }
    private func applyExport(deviceID: String, id: String, payload: [String: CompanionJSON], deadline: Date? = nil, continuousDeadline: CompanionCommandDeadline? = nil) async throws -> CompanionBrokerCommand? {
        guard !storage.stopAll.contains(where: { $0.id == id.lowercased() }) else { throw CompanionBoundaryError("request_conflict", "A stop-all command identity cannot be reused for an export action.") }
        let budget = try continuousDeadline ?? CompanionCommandDeadline(issuedMS: CompanionClock.nowMS(), expiresMS: CompanionClock.nowMS() + 29_999)
        guard let deviceIndex = storage.devices.firstIndex(where: { $0.deviceID == deviceID }), let trust = storage.devices[deviceIndex].trustID,
              let selected = payload["selected"]?.bool, let package = payload["package_name"]?.string else { throw CompanionBoundaryError("invalid_selection", "Missing export selection identity.") }
        let revision = try integer(payload, "selection_revision")
        let canonical: [String: CompanionJSON] = ["package_name": .string(package), "selected": .bool(selected), "selection_revision": .number(Double(revision))]
        if let prior = storage.registry.commands.first(where: { $0.id == id.lowercased() }) {
            guard prior.deviceID == deviceID, prior.kind == "set_export", prior.payload == canonical else { throw CompanionBoundaryError("request_conflict", "An export command identity was reused.") }
            return prior
        }
        do { try await CoreAvailabilityAuthority.requireCompanionPolicySafe() }
        catch { throw CompanionBoundaryError("availability_update_required", "Open DroidBridge on the Mac and finish Spotlight setup to update its availability service before changing exported apps.", retryable: true) }
        guard !stopping else { throw CancellationError() }
        guard !storage.stopAll.contains(where: { $0.id == id.lowercased() }) else { throw CompanionBoundaryError("request_conflict", "A stop-all command identity cannot be reused for an export action.") }
        guard storage.devices.first(where: { $0.deviceID == deviceID })?.trustID == trust else { throw CompanionBoundaryError("trust_changed", "Pairing authority changed while applying app visibility.") }
        guard budget.isValid else { throw CompanionBoundaryError("command_expired", "App selection expired before admission.") }
        let outcome = try catalog.applyCompanionExportOutcome(deviceID: deviceID, trustID: trust, packageName: package, selected: selected, revision: revision)
        do {
            let selection = try catalog.companionExportSelection(deviceID: deviceID)
            if storage.devices[deviceIndex].exportSelection != selection {
                storage.devices[deviceIndex].catalogChangeToken = UUID().uuidString.lowercased()
            }
            storage.devices[deviceIndex].exportSelection = selection
            try persist()
        } catch { throw CompanionBoundaryError("selection_outcome_unknown", "The selection may be saved, but its Mac receipt could not be published. Inspect its state before a new explicit retry.") }
        // An equal policy revision without its exact broker receipt is a crash
        // gap, not permission to repeat wrapper materialization.
        if outcome == .replayed {
            let receipt = try storage.registry.recordCommittedIntent(id: id, deviceID: deviceID, kind: "set_export", payload: canonical, ambiguous: true)
            try persist(); return receipt
        }
        guard outcome != .stale else { let rejected = try storage.registry.reject(id: id, deviceID: deviceID, kind: "set_export", payload: canonical, code: "stale_selection"); try persist(); return rejected }
        do {
            // Selection publication is already durable admission. A later host
            // readiness/expiry failure cannot undo it or truthfully reject it.
            if !storage.localCommands.contains(id.lowercased()), let transport = verified(deviceID) {
                try await control(deviceID:deviceID) { try await transport.client.acknowledge(commandID: id, status: "admitted") }
            }
            let receipt = try await enqueueHost(id: id, deviceID: deviceID, kind: "set_export", payload: canonical, deadline: deadline, continuousDeadline: budget)
            storage.registry.markIntentCommitted(id: id)
            try persist(); return receipt
        } catch {
            let receipt = try storage.registry.recordCommittedIntent(id: id, deviceID: deviceID, kind: "set_export", payload: canonical)
            do { try persist() } catch { throw CompanionBoundaryError("selection_outcome_unknown", "The selection was saved but its final receipt is unavailable.") }
            return receipt
        }
    }
    private func enqueueStopAll(id: String, deviceID: String, deadline: Date? = nil, continuousDeadline: CompanionCommandDeadline? = nil, phoneReceipt: Bool = true) async throws {
        let budget = try continuousDeadline ?? CompanionCommandDeadline(issuedMS: CompanionClock.nowMS(), expiresMS: CompanionClock.nowMS() + 29_999)
        let expiry = deadline ?? Date().addingTimeInterval(budget.remainingMS / 1000)
        let id = UUID(uuidString: id)?.uuidString.lowercased() ?? id
        guard UUID(uuidString: id) != nil else { throw CompanionBoundaryError("invalid_command", "Invalid stop-all command identity.") }
        guard !storage.registry.commands.contains(where: { $0.id == id }) else { throw CompanionBoundaryError("request_conflict", "A command identity cannot be reused for stop-all.") }
        if let previous = storage.stopAll.first(where: { $0.id == id }) {
            guard previous.deviceID == deviceID, (previous.phoneReceipt != false) == phoneReceipt else { throw CompanionBoundaryError("request_conflict", "A stop-all identity was reused with another device or origin.") }
        }
        if !storage.stopAll.contains(where: { $0.id == id }) {
            if storage.stopAll.count >= 64 {
                guard let removable = storage.stopAll.firstIndex(where: { $0.delivered }) else { throw CompanionBoundaryError("command_capacity", "Too many stop-all receipts are pending.") }
                storage.stopAll.remove(at: removable)
            }
            let sessions = storage.registry.sessions.filter { $0.deviceID == deviceID && !["stopped", "failed"].contains($0.phase) }
            guard storage.registry.commands.filter({ $0.status == "accepted" }).count + sessions.count <= 64 else { throw CompanionBoundaryError("command_capacity", "Too many Mac commands are pending.") }
            let original = storage.registry
            var children: [String] = []
            do {
                for session in sessions {
                    let child = UUID().uuidString.lowercased()
                    _ = try storage.registry.enqueue(id: child, deviceID: deviceID, kind: "stop_session", payload: ["session_id": .string(session.sessionID)], continuousDeadline: budget)
                    children.append(child)
                }
            } catch { storage.registry = original; throw error }
            storage.stopAll.append(.init(id: id, deviceID: deviceID, children: children, expires: expiry, delivered: false, phoneReceipt: phoneReceipt))
            try persist()
        }
        await finishStopAll()
    }
    private func readDiskIcon(_ hash: String) throws -> Data? {
        guard hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw CompanionBoundaryError("invalid_hash", "Invalid icon content hash.") }
        let url = directory.appendingPathComponent("icons", isDirectory: true).appendingPathComponent(hash + ".png")
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }; defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_uid == geteuid(), st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o077 == 0, st.st_size > 0, st.st_size <= 262_144 else { return nil }
        let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).readToEnd() ?? Data()
        guard CompanionClient.sha256(bytes) == hash else { return nil }
        return bytes
    }
    private func writeDiskIcon(_ bytes: Data, hash: String) throws {
        guard hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil, bytes.count <= 262_144, CompanionClient.sha256(bytes) == hash else { return }
        let folder = directory.appendingPathComponent("icons", isDirectory: true)
        try CompanionBrokerIPC.prepareDirectory(folder)
        var entries: [(URL, Int64, Date)] = []
        for entry in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
            guard entry.lastPathComponent.range(of: "^[a-f0-9]{64}\\.png$", options: .regularExpression) != nil else { continue }
            var st = stat(); guard lstat(entry.path, &st) == 0, st.st_uid == geteuid(), st.st_mode & S_IFMT == S_IFREG, st.st_size <= 262_144 else { continue }
            entries.append((entry, st.st_size, Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))))
            guard entries.count <= 256 else { return }
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where entries.count >= 256 || total + Int64(bytes.count) > 67_108_864 {
            try FileManager.default.removeItem(at: entry.0); total -= entry.1; entries.removeAll { $0.0 == entry.0 }
        }
        let url = folder.appendingPathComponent(hash + ".png")
        try bytes.write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func stopAllStatus(parent: BrokerStopAll, children: [CompanionBrokerCommand]) -> String? {
        if let terminal = parent.terminalStatus, ["applied", "rejected", "unknown"].contains(terminal) { return terminal }
        guard children.allSatisfy({ $0.status != "accepted" }) else { return nil }
        // A pruned or legacy missing child is unavailable evidence, never a
        // reason to revive the action or leave its parent accepted forever.
        guard children.count == parent.children.count else { return "unknown" }
        return children.contains(where: { $0.status == "unknown" }) ? "unknown" : (children.allSatisfy({ $0.status == "applied" }) ? "applied" : "rejected")
    }
    private func finishStopAll() async {
        for parent in storage.stopAll where !parent.delivered {
            let children = storage.registry.commands.filter { parent.children.contains($0.id) }
            guard let status = stopAllStatus(parent: parent, children: children) else { continue }
            do {
                if let index = storage.stopAll.firstIndex(where: { $0.id == parent.id && $0.deviceID == parent.deviceID && $0.children == parent.children }) {
                    storage.stopAll[index].terminalStatus = status
                    try persist()
                } else { continue }
                if parent.phoneReceipt != false {
                    guard let transport = verified(parent.deviceID) else { continue }
                    try await control(deviceID:parent.deviceID) { try await transport.client.acknowledge(commandID: parent.id, status: status, result: ["sessions": .number(Double(parent.children.count))]) }
                }
                if let index = storage.stopAll.firstIndex(where: { $0.id == parent.id && $0.deviceID == parent.deviceID && $0.children == parent.children }) { storage.stopAll[index].delivered = true; try persist() }
            } catch { /* Receipt remains durable and retries without repeating host actions. */ }
        }
    }
    private func boundInbox() {
        while storage.inbox.count > 64 || ((try? JSONEncoder().encode(storage.inbox).count) ?? Int.max) > 2_097_152 { if storage.inbox.isEmpty { break }; storage.inbox.removeFirst() }
    }
    private func status() -> [String: CompanionJSON] {
        let devices: [CompanionJSON] = storage.devices.map { device in
            .object(["device_id": .string(device.deviceID), "device_name": .string(device.name), "serial": .string(device.preferredSerial), "aliases": .array(device.aliases.map(CompanionJSON.string)), "connected": .bool(verified(device.deviceID) != nil), "paired": .bool(device.trustID != nil), "connection_error": device.lastError.map(CompanionJSON.string) ?? .null, "enabled": .bool(device.enabled), "profile": .string(device.profile), "trust_id": device.trustID.map(CompanionJSON.string) ?? .null, "catalog_change_token": device.trustID == nil ? .null : device.catalogChangeToken.map(CompanionJSON.string) ?? .null, "capabilities": .array(verified(device.deviceID)?.hello.capabilities.map(CompanionJSON.string) ?? [])])
        }
        return ["devices": .array(devices), "sessions": (try? json(storage.registry.sessions)) ?? .array([]), "broker_version": .number(1), "pending_pairings": .array(storage.pendingAdmissions.map { .object(["device_id":.string($0.deviceID),"serial":.string($0.serial),"phase":.string($0.phase),"expires":.number($0.expires.timeIntervalSinceReferenceDate)]) })]
    }
    private func verified(_ deviceID: String) -> BrokerTransport? { guard let serial = storage.devices.first(where: { $0.deviceID == deviceID })?.preferredSerial, let transport = transports[serial], transport.verified else { return nil }; return transport }
    private func persist() throws {
        guard !stopping else { throw CancellationError() }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let bytes = try encoder.encode(storage)
        guard bytes.count <= 4_194_304 else { throw CompanionBoundaryError("broker_storage_capacity", "Companion storage reached its bounded capacity.") }
        if bytes == persistedBytes, let persistedFingerprint, CompanionBrokerJournal.fingerprint(storageURL) == persistedFingerprint { return }
        do {
            let fingerprint = try CompanionBrokerJournal.write(bytes, to: storageURL) { point in
                #if DEBUG
                try testingHooks?.fault(point)
                #endif
            }
            persistedBytes = bytes; persistedFingerprint = fingerprint
        }
        catch { persistenceFailure = true; throw error }
    }
    private func checkCancelled(_ requestID: UUID) throws { if cancelled.remove(requestID) != nil { throw CompanionBoundaryError("cancelled", "Companion operation was cancelled.") } }
    private func checkCatalogReadScope(deviceID: String, trustID: String, epoch: UUID?, generation: UUID) throws {
        try Task.checkCancellation()
        guard !stopping, trustEpochs[deviceID] == epoch, verified(deviceID)?.generation == generation,
              storage.devices.contains(where: { $0.deviceID == deviceID && $0.enabled && $0.trustID == trustID }) else {
            throw CompanionBoundaryError("trust_changed", "The phone connection or pairing changed during catalog discovery. Refresh the connection.")
        }
    }
    private func control<T>(deviceID:String,_ body: () async throws -> T) async throws -> T {
        guard !stopping else { throw CancellationError() }
        let canonical=UUID(uuidString:deviceID)?.uuidString.lowercased() ?? deviceID
        try await scheduler.acquire(bulk:false,group:canonical)
        do {try Task.checkCancellation();guard !stopping else {throw CancellationError()};let value=try await body();await scheduler.release(bulk:false,group:canonical);return value}
        catch {await scheduler.release(bulk:false,group:canonical);throw error}
    }
    private func bulk<T>(deviceID:String,_ body: () async throws -> T) async throws -> T {
        guard !stopping else { throw CancellationError() }
        let profile=CompanionPerformanceProfile(rawValue:storage.devices.first(where:{$0.deviceID==deviceID})?.profile ?? "balanced") ?? .balanced
        try await scheduler.acquire(bulk:true,group:deviceID,limit:profile.assetConcurrency)
        do {try Task.checkCancellation();guard !stopping else {throw CancellationError()};let value=try await body();await scheduler.release(bulk:true,group:deviceID);return value} catch {await scheduler.release(bulk:true,group:deviceID);throw error}
    }
    private func string(_ p: [String: CompanionJSON], _ key: String) throws -> String { try selfString(p, key) }
    private func integer(_ p: [String: CompanionJSON], _ key: String) throws -> Int64 { try selfInteger(p, key) }
    private func uuid(_ p: [String: CompanionJSON], _ key: String) throws -> String { let value = try string(p, key); guard let id = UUID(uuidString: value) else { throw CompanionBoundaryError("invalid_id", "Invalid companion identifier.") }; return id.uuidString.lowercased() }
    private func json<T: Encodable>(_ value: T) throws -> CompanionJSON { try Self.value(value) }
    private static func value<T: Encodable>(_ value: T) throws -> CompanionJSON { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return try JSONDecoder().decode(CompanionJSON.self, from: e.encode(value)) }
    private static func object<T: Encodable>(_ value: T) throws -> [String: CompanionJSON] { try Self.value(value).object ?? [:] }
}
private func selfString(_ p: [String: CompanionJSON], _ key: String) throws -> String { guard let value = p[key]?.string, value.utf8.count <= 131_072 else { throw CompanionBoundaryError("invalid_request", "Missing or oversized companion field: \(key).") }; return value }
private func selfInteger(_ p: [String: CompanionJSON], _ key: String) throws -> Int64 { guard let value = p[key]?.number, value.isFinite, value.rounded() == value, value >= 0, value <= Double(Int64.max - 1024) else { throw CompanionBoundaryError("invalid_request", "Invalid companion numeric field: \(key).") }; return Int64(value) }
