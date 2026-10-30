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
}
public struct CompanionBrokerCommand: Codable, Sendable {
    public let id: String
    public let deviceID: String
    public let kind: String
    public let payload: [String: CompanionJSON]
    public let owner: CompanionBrokerOwner
    public let generation: Int64
    public let expires: Date
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
        for i in commands.indices where commands[i].deviceID == deviceID && commands[i].status == "accepted" { commands[i].status = "rejected"; commands[i].result = ["code": .string("trust_revoked")] }
    }
    public mutating func prune(now: Date = Date(), live: (CompanionBrokerOwner) -> Bool = { $0.isAlive }) {
        hosts.removeAll { !live($0.owner) }
        sessions.removeAll { session in !hosts.contains { $0.owner == session.owner && $0.generation == session.generation } }
        for index in commands.indices where commands[index].status == "accepted" {
            if commands[index].expires <= now || !hosts.contains(where: { $0.owner == commands[index].owner && $0.generation == commands[index].generation }) { commands[index].status = "rejected"; commands[index].result = ["code": .string("owner_expired")] }
        }
        if commands.count > 512 { commands.removeFirst(commands.count - 512) }
    }
    public mutating func publish(owner: CompanionBrokerOwner, generation: Int64, role: String, deviceID: String, serial: String, values: [[String: CompanionJSON]], now: Date = Date()) throws {
        guard generation >= 1, ["launcher", "wrapper"].contains(role), values.count <= 32, UUID(uuidString: deviceID) != nil else { throw CompanionBoundaryError("invalid_registry", "Invalid companion session registration.") }
        try AndroidDiscovery.validateSerial(serial)
        let previous = hosts.first { $0.owner == owner && $0.deviceID == deviceID }
        if let previous, generation < previous.generation { throw CompanionBoundaryError("stale_owner", "Companion session owner generation has expired.") }
        guard hosts.contains(where: { $0.owner == owner && $0.deviceID == deviceID }) || hosts.count < 64 else { throw CompanionBoundaryError("registry_capacity", "Companion session registry is full.") }
        var parsed: [CompanionBrokerSession] = []
        for value in values {
            guard let id = value["session_id"]?.string, UUID(uuidString: id) != nil, let package = value["package"]?.string ?? value["package_name"]?.string,
                  let backend = value["backend"]?.string, ["native", "scrcpy"].contains(backend), let phase = value["phase"]?.string,
                  ["starting", "running", "stopping", "stopped", "failed", "reconnecting"].contains(phase), let label = value["label"]?.string, label.count <= 256 else { throw CompanionBoundaryError("invalid_session", "Invalid companion session metadata.") }
            try AndroidDiscovery.validatePackage(package)
            guard !parsed.contains(where: { $0.sessionID == id }), !sessions.contains(where: { $0.sessionID == id && $0.owner != owner }) else { throw CompanionBoundaryError("session_conflict", "A companion session belongs to another live process.") }
            parsed.append(.init(sessionID: id, deviceID: deviceID, serial: serial, package: package, label: label, backend: backend, phase: phase, owner: owner, generation: generation))
        }
        guard sessions.filter({ $0.owner != owner || $0.deviceID != deviceID }).count + parsed.count <= 128,
              sessions.filter({ $0.deviceID == deviceID && $0.owner != owner }).count + parsed.count <= 32 else { throw CompanionBoundaryError("registry_capacity", "Companion session registry is full.") }
        hosts.removeAll { $0.owner == owner && $0.deviceID == deviceID }
        sessions.removeAll { $0.owner == owner && $0.deviceID == deviceID }
        hosts.append(.init(owner: owner, generation: generation, role: role, deviceID: deviceID, serial: serial, updated: now)); sessions += parsed
        for i in commands.indices where commands[i].owner == owner && commands[i].generation != generation && commands[i].status == "accepted" { commands[i].status = "rejected"; commands[i].result = ["code": .string("stale_owner")] }
    }
    public mutating func enqueue(id: String, deviceID: String, kind: String, payload: [String: CompanionJSON], deadline: Date? = nil, now: Date = Date()) throws -> CompanionBrokerCommand {
        guard deadline == nil || (deadline! > now && deadline!.timeIntervalSince(now) <= 31) else { throw CompanionBoundaryError("command_expired", "Companion command expired.") }
        let id = UUID(uuidString: id)?.uuidString.lowercased() ?? id
        guard UUID(uuidString: id) != nil else { throw CompanionBoundaryError("invalid_command", "Invalid companion command identity.") }
        if let previous = commands.first(where: { $0.id == id }) {
            guard previous.kind == kind, previous.payload == payload, previous.deviceID == deviceID else { throw CompanionBoundaryError("request_conflict", "A command identity was reused with different content.") }
            return previous
        }
        guard commands.filter({ $0.status == "accepted" }).count < 64 else { throw CompanionBoundaryError("command_capacity", "Too many companion commands are pending.") }
        let host: CompanionBrokerHost?
        if kind == "stop_session" {
            guard let sessionID = payload["session_id"]?.string, let session = sessions.first(where: { $0.deviceID == deviceID && $0.sessionID == sessionID }) else { throw CompanionBoundaryError("session_unavailable", "The requested Mac session is no longer available.") }
            host = hosts.first { $0.owner == session.owner && $0.generation == session.generation }
        } else {
            host = hosts.filter { $0.deviceID == deviceID }.sorted { ($0.role == "launcher" ? 0 : 1, $0.owner.pid) < ($1.role == "launcher" ? 0 : 1, $1.owner.pid) }.first
            if kind == "open_app", host?.role != "launcher" { throw CompanionBoundaryError("launcher_unavailable", "Open DroidBridge on the Mac to launch another app.") }
        }
        guard let host else { throw CompanionBoundaryError("owner_unavailable", "No Mac application currently owns this phone's sessions.") }
        let command = CompanionBrokerCommand(id: id, deviceID: deviceID, kind: kind, payload: payload, owner: host.owner, generation: host.generation, expires: deadline ?? now.addingTimeInterval(30), status: "accepted", result: [:])
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
        commands.append(receipt); if commands.count > 512 { commands.removeFirst(commands.count - 512) }; return receipt
    }
    public func poll(owner: CompanionBrokerOwner, generation: Int64, now: Date = Date()) -> [CompanionBrokerCommand] {
        Array(commands.filter { $0.owner == owner && $0.generation == generation && $0.status == "accepted" && $0.expires > now }.prefix(16))
    }
    public mutating func acknowledge(id: String, owner: CompanionBrokerOwner, generation: Int64, status: String, result: [String: CompanionJSON], now: Date = Date()) throws -> CompanionBrokerCommand {
        let id = UUID(uuidString: id)?.uuidString.lowercased() ?? id
        guard ["applied", "rejected"].contains(status), let i = commands.firstIndex(where: { $0.id == id }), commands[i].owner == owner, commands[i].generation == generation,
              hosts.contains(where: { $0.owner == owner && $0.generation == generation }), commands[i].expires > now else { throw CompanionBoundaryError("stale_owner", "This command no longer belongs to the calling process.") }
        if commands[i].status != "accepted" {
            guard commands[i].status == status, commands[i].result == result else { throw CompanionBoundaryError("receipt_conflict", "A completed command cannot be changed.") }
        } else { commands[i].status = status; commands[i].result = result }
        return commands[i]
    }
}
