import Foundation
import Darwin

public struct CompanionBrokerOwner: Codable, Equatable, Sendable {
    public let pid: Int32
    public let start: UInt64
    public init(pid: Int32, start: UInt64) { self.pid = pid; self.start = start }
    public static func live(_ pid: Int32) -> Self? {
        var info = proc_bsdinfo()
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard count == MemoryLayout<proc_bsdinfo>.size, info.pbi_uid == geteuid() else { return nil }
        return .init(pid: pid, start: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec)
    }
    public var isAlive: Bool { Self.live(pid) == self }
}
public struct CompanionBrokerSession: Codable, Sendable {
    public let sessionID: String
    public let deviceID: String
    public let serial: String
    public let package: String
    public let label: String
    public let backend: String
    public let phase: String
    public let owner: CompanionBrokerOwner
    public let generation: Int64
}
public struct CompanionBrokerHost: Codable, Sendable {
    public let owner: CompanionBrokerOwner
    public let generation: Int64
    public let role: String
    public let deviceID: String
    public let serial: String
    public var updated: Date
    /// Absent in older persisted/running owners. Those owners may publish
    /// dashboard facts, but cannot receive commands with new admission rules.
    public var commandProtocol: Int? = nil
}
public struct CompanionBrokerCommand: Codable, Sendable {
    public let id: String
    public let deviceID: String
    public let kind: String
    public let payload: [String: CompanionJSON]
    public let owner: CompanionBrokerOwner
    public let generation: Int64
    public let expires: Date
    public var continuousDeadline: CompanionCommandDeadline? = nil
    public var admitted: Bool? = nil
    public var admittedAtMS: Double? = nil
    public var intentCommitted: Bool? = nil
    public var receiptDelivered: Bool? = nil
    public var status: String
    public var result: [String: CompanionJSON]
}
/// Pure fenced registry; the broker supplies authenticated IPC identities, never caller-reported PIDs.
public struct CompanionBrokerRegistry: Codable, Sendable {
    public private(set) var hosts: [CompanionBrokerHost] = []
    public private(set) var sessions: [CompanionBrokerSession] = []
    public private(set) var commands: [CompanionBrokerCommand] = []
    public init() {}
    public mutating func revoke(deviceID: String) {
        hosts.removeAll { $0.deviceID == deviceID }; sessions.removeAll { $0.deviceID == deviceID }
        for i in commands.indices where commands[i].deviceID == deviceID && commands[i].status == "accepted" { commands[i].status = commands[i].admitted == true || commands[i].intentCommitted == true ? "unknown" : "rejected"; commands[i].result = ["code": .string("trust_revoked")] }
    }
    public mutating func prune(now: Date = Date(), live: (CompanionBrokerOwner) -> Bool = { $0.isAlive }, nowMS: Double = CompanionClock.nowMS(), bootID: String = CompanionClock.bootID) {
        hosts.removeAll { !live($0.owner) }
        sessions.removeAll { session in !hosts.contains { $0.owner == session.owner && $0.generation == session.generation && $0.deviceID == session.deviceID } }
        for index in commands.indices where commands[index].status == "accepted" {
            let exactHost = hosts.first(where: { $0.owner == commands[index].owner && $0.generation == commands[index].generation && $0.deviceID == commands[index].deviceID })
            let ownerPresent = exactHost != nil
            let sameBoot = commands[index].continuousDeadline.map { UUID(uuidString: $0.bootID) == UUID(uuidString: bootID) && UUID(uuidString: bootID) != nil } ?? false
            if commands[index].continuousDeadline == nil || (exactHost != nil && exactHost?.commandProtocol != 2) {
                // An older executable may already have received this row and
                // cannot be forced to honor the new admission protocol.
                commands[index].status = "unknown"; commands[index].result = ["code": .string("legacy_owner_outcome_unknown")]
            } else if commands[index].admitted == true {
                if !ownerPresent || !sameBoot || commands[index].admittedAtMS.map({ !($0.isFinite && nowMS >= $0 && nowMS - $0 < 120_000) }) != false { commands[index].status = "unknown"; commands[index].result = ["code": .string("admitted_outcome_unknown")] }
            } else if commands[index].continuousDeadline?.isValid(nowMS: nowMS, bootID: bootID) != true || !ownerPresent {
                commands[index].status = commands[index].intentCommitted == true ? "applied" : "rejected"; commands[index].result = commands[index].intentCommitted == true ? Self.pendingIntentResult : ["code": .string("owner_expired")]
            }
        }
        trimTerminalReceipts()
    }
    public mutating func publish(owner: CompanionBrokerOwner, generation: Int64, role: String, deviceID: String, serial: String, values: [[String: CompanionJSON]], now: Date = Date(), commandProtocol: Int = 2) throws {
        guard generation >= 1, [1, 2].contains(commandProtocol), ["launcher", "wrapper"].contains(role), values.count <= 32, UUID(uuidString: deviceID) != nil else { throw CompanionBoundaryError("invalid_registry", "Invalid companion session registration.") }
        try AndroidDiscovery.validateSerial(serial)
        let previous = hosts.first { $0.owner == owner && $0.deviceID == deviceID }
        if let previous, generation < previous.generation { throw CompanionBoundaryError("stale_owner", "Companion session owner generation has expired.") }
        guard hosts.contains(where: { $0.owner == owner && $0.deviceID == deviceID }) || hosts.count < 64 else { throw CompanionBoundaryError("registry_capacity", "Companion session registry is full.") }
        var parsed: [CompanionBrokerSession] = []
        for value in values {
            guard let id = value["session_id"]?.string, UUID(uuidString: id) != nil, let package = value["package"]?.string ?? value["package_name"]?.string,
                  let backend = value["backend"]?.string, ["native", "scrcpy"].contains(backend), let phase = value["phase"]?.string,
                  ["starting", "running", "stopping", "stopped", "failed", "reconnecting"].contains(phase), let label = value["label"]?.string, label.unicodeScalars.count <= 256 else { throw CompanionBoundaryError("invalid_session", "Invalid companion session metadata.") }
            try AndroidDiscovery.validatePackage(package)
            guard !parsed.contains(where: { $0.sessionID == id }), !sessions.contains(where: { $0.sessionID == id && $0.owner != owner }) else { throw CompanionBoundaryError("session_conflict", "A companion session belongs to another live process.") }
            parsed.append(.init(sessionID: id, deviceID: deviceID, serial: serial, package: package, label: label, backend: backend, phase: phase, owner: owner, generation: generation))
        }
        guard sessions.filter({ $0.owner != owner || $0.deviceID != deviceID }).count + parsed.count <= 128,
              sessions.filter({ $0.deviceID == deviceID && $0.owner != owner }).count + parsed.count <= 32 else { throw CompanionBoundaryError("registry_capacity", "Companion session registry is full.") }
        hosts.removeAll { $0.owner == owner && $0.deviceID == deviceID }
        sessions.removeAll { $0.owner == owner && $0.deviceID == deviceID }
        hosts.append(.init(owner: owner, generation: generation, role: role, deviceID: deviceID, serial: serial, updated: now, commandProtocol: commandProtocol)); sessions += parsed
        for i in commands.indices where commands[i].owner == owner && commands[i].deviceID == deviceID && commands[i].generation != generation && commands[i].status == "accepted" { commands[i].status = commands[i].admitted == true ? "unknown" : (commands[i].intentCommitted == true ? "applied" : "rejected"); commands[i].result = commands[i].intentCommitted == true && commands[i].admitted != true ? Self.pendingIntentResult : ["code": .string("stale_owner")] }
    }
    public mutating func enqueue(id: String, deviceID: String, kind: String, payload: [String: CompanionJSON], deadline: Date? = nil, continuousDeadline: CompanionCommandDeadline? = nil, now: Date = Date(), nowMS: Double = CompanionClock.nowMS(), bootID: String = CompanionClock.bootID) throws -> CompanionBrokerCommand {
        let id = UUID(uuidString: id)?.uuidString.lowercased() ?? id
        guard UUID(uuidString: id) != nil else { throw CompanionBoundaryError("invalid_command", "Invalid companion command identity.") }
        if let previous = commands.first(where: { $0.id == id }) {
            guard previous.kind == kind, previous.payload == payload, previous.deviceID == deviceID else { throw CompanionBoundaryError("request_conflict", "A command identity was reused with different content.") }
            return previous
        }
        let budget: CompanionCommandDeadline
        if let continuousDeadline { budget = continuousDeadline }
        else {
            let duration = deadline.map { $0.timeIntervalSince(now) * 1000 } ?? 30_000
            guard duration > 0, duration <= 30_000 else { throw CompanionBoundaryError("command_expired", "Companion command expired.") }
            budget = try CompanionCommandDeadline(issuedMS: nowMS, expiresMS: nowMS + duration, bootID: bootID)
        }
        guard budget.isValid(nowMS: nowMS, bootID: bootID) else { throw CompanionBoundaryError("command_expired", "Companion command expired.") }
        guard commands.filter({ $0.status == "accepted" }).count < 64 else { throw CompanionBoundaryError("command_capacity", "Too many companion commands are pending.") }
        let host: CompanionBrokerHost?
        if kind == "stop_session" {
            guard let sessionID = payload["session_id"]?.string, let session = sessions.first(where: { $0.deviceID == deviceID && $0.sessionID == sessionID }) else { throw CompanionBoundaryError("session_unavailable", "The requested Mac session is no longer available.") }
            host = hosts.first { $0.owner == session.owner && $0.generation == session.generation && $0.deviceID == deviceID && $0.commandProtocol == 2 }
        } else {
            host = hosts.filter { $0.deviceID == deviceID && $0.commandProtocol == 2 }.sorted { ($0.role == "launcher" ? 0 : 1, $0.owner.pid) < ($1.role == "launcher" ? 0 : 1, $1.owner.pid) }.first
            if kind == "open_app", host?.role != "launcher" { throw CompanionBoundaryError(hosts.contains(where: { $0.deviceID == deviceID && $0.commandProtocol != 2 }) ? "owner_update_required" : "launcher_unavailable", "Open the updated DroidBridge launcher on the Mac to launch another app.") }
        }
        guard let host else { throw CompanionBoundaryError(hosts.contains(where: { $0.deviceID == deviceID && $0.commandProtocol != 2 }) ? "owner_update_required" : "owner_unavailable", "Open the updated DroidBridge app and update or recreate older wrappers before controlling their sessions.") }
        let command = CompanionBrokerCommand(id: id, deviceID: deviceID, kind: kind, payload: payload, owner: host.owner, generation: host.generation, expires: deadline ?? now.addingTimeInterval(budget.remainingMS(nowMS: nowMS, bootID: bootID) / 1000), continuousDeadline: budget, admitted: false, status: "accepted", result: [:])
        commands.append(command); return command
    }
    @discardableResult
    public mutating func reject(id: String, deviceID: String, kind: String, payload: [String: CompanionJSON], code: String) throws -> CompanionBrokerCommand {
        guard let uuid = UUID(uuidString: id), let owner = CompanionBrokerOwner.live(getpid()) else { throw CompanionBoundaryError("invalid_command", "Invalid companion command identity.") }
        let id = uuid.uuidString.lowercased()
        if let previous = commands.first(where: { $0.id == id }) {
            guard previous.deviceID == deviceID, previous.kind == kind, previous.payload == payload else { throw CompanionBoundaryError("request_conflict", "A command identity was reused with different content.") }; return previous
        }
        let receipt = CompanionBrokerCommand(id: id, deviceID: deviceID, kind: kind, payload: payload, owner: owner, generation: 0, expires: Date(), status: "rejected", result: ["code": .string(code)])
        commands.append(receipt); trimTerminalReceipts(); return receipt
    }
    /// A committed selection intent remains applied even if its derived wrapper
    /// could not be materialized. A new explicit request may retry that work.
    public mutating func recordCommittedIntent(id: String, deviceID: String, kind: String, payload: [String: CompanionJSON], ambiguous: Bool = false) throws -> CompanionBrokerCommand {
        let initial = try reject(id: id, deviceID: deviceID, kind: kind, payload: payload, code: "materialization_pending")
        guard let index = commands.firstIndex(where: { $0.id == initial.id }) else { throw CompanionBoundaryError("receipt_missing", "The committed selection receipt is unavailable.") }
        if commands[index].status == "rejected", commands[index].result["code"]?.string == "materialization_pending" {
            commands[index].status = ambiguous ? "unknown" : "applied"; commands[index].admitted = true
            commands[index].intentCommitted = true
            commands[index].result = Self.pendingIntentResult
        }
        return commands[index]
    }
    /// Durable owner admission precedes effects. Retrying an admitted identity
    /// returns its canonical state; it never creates a second execution.
    public mutating func admit(id: String, owner: CompanionBrokerOwner, generation: Int64, nowMS: Double = CompanionClock.nowMS(), bootID: String = CompanionClock.bootID) throws -> CompanionBrokerCommand {
        let id = UUID(uuidString: id)?.uuidString.lowercased() ?? id
        guard let index = commands.firstIndex(where: { $0.id == id }), commands[index].owner == owner,
              commands[index].generation == generation, hosts.contains(where: { $0.owner == owner && $0.generation == generation && $0.deviceID == commands[index].deviceID && $0.commandProtocol == 2 }) else { throw CompanionBoundaryError("stale_owner", "This command no longer belongs to a compatible calling process.") }
        if commands[index].status != "accepted" || commands[index].admitted == true { return commands[index] }
        guard commands[index].continuousDeadline?.isValid(nowMS: nowMS, bootID: bootID) == true else { throw CompanionBoundaryError("command_expired", "This command expired before owner admission.") }
        commands[index].admitted = true
        commands[index].admittedAtMS = nowMS
        return commands[index]
    }
    public func poll(owner: CompanionBrokerOwner, generation: Int64, now: Date = Date(), nowMS: Double = CompanionClock.nowMS(), bootID: String = CompanionClock.bootID) -> [CompanionBrokerCommand] {
        Array(commands.filter { command in command.owner == owner && command.generation == generation && command.status == "accepted" && command.admitted != true && command.continuousDeadline?.isValid(nowMS: nowMS, bootID: bootID) == true && hosts.contains(where: { $0.owner == owner && $0.generation == generation && $0.deviceID == command.deviceID && $0.commandProtocol == 2 }) }.prefix(16))
    }
    public func supportsCommandProtocol(owner: CompanionBrokerOwner, generation: Int64) -> Bool { hosts.contains { $0.owner == owner && $0.generation == generation && $0.commandProtocol == 2 } }
    public mutating func acknowledge(id: String, owner: CompanionBrokerOwner, generation: Int64, status: String, result: [String: CompanionJSON], now: Date = Date(), nowMS: Double = CompanionClock.nowMS(), bootID: String = CompanionClock.bootID) throws -> CompanionBrokerCommand {
        let id = UUID(uuidString: id)?.uuidString.lowercased() ?? id
        guard ["applied", "rejected", "unknown"].contains(status), let i = commands.firstIndex(where: { $0.id == id }), commands[i].owner == owner, commands[i].generation == generation,
              hosts.contains(where: { $0.owner == owner && $0.generation == generation }),
              (commands[i].admitted == true && commands[i].continuousDeadline?.bootID == bootID) || (status == "rejected" && commands[i].continuousDeadline?.isValid(nowMS: nowMS, bootID: bootID) == true) else { throw CompanionBoundaryError("stale_owner", "This command no longer belongs to the calling process.") }
        if commands[i].status != "accepted" {
            guard (commands[i].status == status && commands[i].result == result) || (commands[i].intentCommitted == true && status == "rejected" && commands[i].status == "applied" && commands[i].result == Self.pendingIntentResult) else { throw CompanionBoundaryError("receipt_conflict", "A completed command cannot be changed.") }
        } else if commands[i].intentCommitted == true && status == "rejected" { commands[i].status = "applied"; commands[i].result = Self.pendingIntentResult }
        else { commands[i].status = status; commands[i].result = result }
        return commands[i]
    }
    public mutating func markIntentCommitted(id: String) {
        if let index = commands.firstIndex(where: { $0.id == id.lowercased() }) { commands[index].intentCommitted = true }
    }
    public mutating func markReceiptDelivered(id: String) {
        if let index = commands.firstIndex(where: { $0.id == id.lowercased() }) { commands[index].receiptDelivered = true }
    }
    private static let pendingIntentResult: [String: CompanionJSON] = ["intent_committed": .bool(true), "materialization_pending": .bool(true), "wrapper_created": .bool(false), "phase": .string("selection_saved_wrapper_pending"), "retryable": .bool(true)]
    private mutating func trimTerminalReceipts() {
        while commands.count > 512, let index = commands.firstIndex(where: { $0.status != "accepted" }) { commands.remove(at: index) }
    }
}
