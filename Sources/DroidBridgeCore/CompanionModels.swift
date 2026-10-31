import Foundation
import Darwin

/// Sleep-inclusive local time for bounded command admission. Wall clocks are
/// display metadata only; the boot UUID prevents persisted ticks reviving after
/// a restart of the Mac.
public enum CompanionClock {
    private static let millisecondsPerTick: Double = {
        var scale = mach_timebase_info_data_t()
        guard mach_timebase_info(&scale) == KERN_SUCCESS, scale.denom > 0 else { return .nan }
        return Double(scale.numer) / Double(scale.denom) / 1_000_000
    }()
    public static func nowMS() -> Double { Double(mach_continuous_time()) * millisecondsPerTick }
    public static let bootID: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, (1...128).contains(size) else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0,
              let id = UUID(uuidString: String(cString: bytes)) else { return "" }
        return id.uuidString.lowercased()
    }()
}

public struct CompanionCommandDeadline: Codable, Equatable, Sendable {
    public let bootID: String
    public let issuedMS: Double
    public let expiresMS: Double
    public init(issuedMS: Double, expiresMS: Double, bootID: String = CompanionClock.bootID) throws {
        guard UUID(uuidString: bootID) != nil, issuedMS.isFinite, expiresMS.isFinite,
              issuedMS >= 0, expiresMS > issuedMS, expiresMS - issuedMS <= 30_000 else {
            throw CompanionBoundaryError("invalid_deadline", "Companion command deadline is invalid.")
        }
        self.bootID = bootID.lowercased(); self.issuedMS = issuedMS; self.expiresMS = expiresMS
    }
    public var isValid: Bool { isValid(nowMS: CompanionClock.nowMS(), bootID: CompanionClock.bootID) }
    public var remainingMS: Double { remainingMS(nowMS: CompanionClock.nowMS(), bootID: CompanionClock.bootID) }
    public func isValid(nowMS: Double, bootID: String) -> Bool {
        UUID(uuidString: self.bootID) != nil && UUID(uuidString: self.bootID) == UUID(uuidString: bootID) &&
        issuedMS.isFinite && expiresMS.isFinite && nowMS.isFinite && issuedMS >= 0 && nowMS >= issuedMS &&
        expiresMS > nowMS && expiresMS - issuedMS > 0 && expiresMS - issuedMS <= 30_000
    }
    public func remainingMS(nowMS: Double, bootID: String) -> Double { isValid(nowMS: nowMS, bootID: bootID) ? expiresMS - nowMS : 0 }
}

/// A pinned hello's sample is taken between local send and receive. At receive
/// the phone is at least uptimeMS and at most uptimeMS+RTT (+1ms quantization).
/// Samples are scoped to the installation, service epoch and this TLS client.
struct CompanionPeerClockAnchor: Sendable {
    let deviceID: UUID
    let epoch: UUID
    let uptimeMS: Double
    let wallMS: Double
    let receivedMS: Double
    let roundTripMS: Double
    let notificationScopeV2: Bool
    init(hello: CompanionHello, sentMS: Double, receivedMS: Double) throws {
        guard hello.capabilities.contains("clock_anchor_v1"), let deviceID = UUID(uuidString: hello.deviceId),
              let rawEpoch = hello.clockEpoch, let epoch = UUID(uuidString: rawEpoch),
              let uptime = hello.serverUptimeMs, uptime >= 0, uptime <= 9_007_199_254_620_991,
              let wall = hello.serverTime, wall >= 0, wall <= 9_007_199_254_740,
              sentMS.isFinite, receivedMS.isFinite, sentMS >= 0, receivedMS >= sentMS,
              receivedMS - sentMS <= 2_000 else { throw CompanionBoundaryError("clock_unavailable", "A fresh bounded phone clock sample is unavailable. Update both applications or reconnect.", retryable: true) }
        self.deviceID = deviceID; self.epoch = epoch; uptimeMS = Double(uptime); wallMS = Double(wall) * 1000
        self.receivedMS = receivedMS; roundTripMS = receivedMS - sentMS
        notificationScopeV2 = hello.capabilities.contains("notification_scope_v2")
    }
    func elapsed(nowMS: Double) throws -> Double {
        guard nowMS.isFinite, nowMS >= receivedMS, nowMS - receivedMS <= 30_000 else { throw CompanionBoundaryError("clock_stale", "The phone clock sample expired. Refresh the connection.", retryable: true) }
        return nowMS - receivedMS
    }
    func outgoing(nowMS: Double) throws -> (issued: Int64, expires: Int64) {
        let lower = uptimeMS + (try elapsed(nowMS: nowMS))
        let issued = Int64(max(0, lower.rounded(.down) - 1))
        return (issued, issued + 30_000)
    }
    func remaining(epoch: String, issuedMS: Double?, expiresMS: Double, maximumMS: Double, nowMS: Double) throws -> Double {
        guard UUID(uuidString: epoch) == self.epoch, expiresMS.isFinite,
              maximumMS > 0, maximumMS <= 120_000 else { throw CompanionBoundaryError("clock_epoch_changed", "The phone restarted or this action belongs to an older clock epoch. Start a new deliberate action.") }
        let lower = uptimeMS + (try elapsed(nowMS: nowMS)), upper = lower + roundTripMS + 1
        if let issuedMS {
            guard issuedMS.isFinite, issuedMS >= 0, issuedMS <= lower, expiresMS > issuedMS,
                  expiresMS - issuedMS <= maximumMS else { throw CompanionBoundaryError("command_expired", "The phone command has an invalid or future time budget.") }
        }
        let remaining = expiresMS - upper
        guard remaining > 0, expiresMS - lower <= maximumMS else { throw CompanionBoundaryError("command_expired", "This phone action expired before it could be applied.") }
        return min(remaining, maximumMS)
    }
    func pairingCodeRemaining(expiresSeconds: Double, nowMS: Double) throws -> Double {
        let elapsed = try elapsed(nowMS: nowMS)
        // QR wall time is compared only with this pinned phone's wall snapshot,
        // never the Mac's wall clock. One second covers integer quantization.
        let remaining = expiresSeconds * 1000 - (wallMS + elapsed + roundTripMS + 1000)
        guard expiresSeconds.isFinite, expiresSeconds.rounded(.down) == expiresSeconds,
              remaining > 0, expiresSeconds * 1000 - (wallMS + elapsed) <= 120_000 else {
            throw CompanionBoundaryError("pairing_expired", "Open a new pairing link on the phone. Its pairing window is expired or changed.")
        }
        return remaining
    }
}

/// Bounded JSON values crossing the companion boundary. Never interpreted as shell input.
public enum CompanionJSON: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: CompanionJSON]), array([CompanionJSON]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .bool(x) }
        else if let x = try? c.decode(Double.self) { self = .number(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode([String: CompanionJSON].self) { self = .object(x) }
        else { self = .array(try c.decode([CompanionJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let x) = self { return x }; return nil }
    public var object: [String: CompanionJSON]? { if case .object(let x) = self { return x }; return nil }
    public var array: [CompanionJSON]? { if case .array(let x) = self { return x }; return nil }
    public var bool: Bool? { if case .bool(let x) = self { return x }; return nil }
    public var number: Double? { if case .number(let x) = self { return x }; return nil }
}

public struct CompanionHello: Codable, Sendable {
    public let deviceId: String
    public let deviceName: String
    public let protocolMin: Int
    public let protocolMax: Int
    public let capabilities: [String]
    public let permissions: [String: String]?
    public let pairingAvailable: Bool?
    public let catalogRevision: String?
    public let clockEpoch: String?
    public let serverUptimeMs: Int64?
    public let serverTime: Int64?
}
public struct CompanionIdentity: Codable, Sendable {
    public let deviceId: String
    public let trustId: String
    public let protocolVersion: Int
    enum CodingKeys: String, CodingKey { case deviceId, trustId; case protocolVersion = "protocol" }
}
public struct CompanionPairing: Codable, Sendable {
    public let pairingId: String?
    public let status: String
    public let expiresAt: String?
    public let credential: String?
    public let trustId: String?
    public let deviceId: String?
    public let capabilities: [String]?
    public let comparisonCode: String?
    public let clockEpoch: String?
    public let expiresUptimeMs: Int64?
}
public struct CompanionApp: Codable, Sendable, Identifiable {
    public let packageName: String
    public let label: String
    public let activityName: String?
    public let iconSha256: String?
    public let versionCode: Int64?
    public let launchable: Bool?
    public let exportToMac: Bool?
    public var id: String { packageName }

    /// Shared wire validation for the transport and visible catalog consumer.
    /// Labels use Unicode scalars; optional activity identities use UTF-8 bytes
    /// and must be omitted by the producer rather than truncated.
    public func validateMetadata() throws {
        do { try AndroidDiscovery.validatePackage(packageName) }
        catch { throw CompanionBoundaryError("invalid_app", "Companion application identity is invalid.") }
        guard label.unicodeScalars.count <= 256, activityName?.utf8.count ?? 0 <= 512 else {
            throw CompanionBoundaryError("invalid_app", "Companion application metadata is invalid.")
        }
        if let hash = iconSha256 {
            guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw CompanionBoundaryError("invalid_hash", "Invalid companion content hash.")
            }
        }
    }
}
public struct CompanionCatalogPage: Codable, Sendable {
    public let generation: String
    public let items: [CompanionApp]
    public let nextCursor: String?
}
public struct CompanionCatalogDelta: Codable, Sendable {
    public let generation: String
    public let items: [CompanionApp]
    public let deleted: [String]
}
public struct CompanionEvent: Codable, Sendable {
    public let sequence: Int64
    public let eventId: String
    public let kind: String
    public let createdAt: String?
    public let payload: [String: CompanionJSON]
    public var targetTrustId: String? = nil
}
public struct CompanionEventPage: Codable, Sendable {
    public let epoch: String
    public let events: [CompanionEvent]
    public let nextSequence: Int64
    public let resetRequired: Bool
}
public struct CompanionReceipt: Codable, Sendable {
    public let requestId: String?
    public let status: String
    public let result: [String: CompanionJSON]?
    public let message: String?
}
public struct CompanionTrust: Codable, Sendable, Identifiable {
    public let trustId: String
    public let macId: String?
    public let macName: String
    public let lastUsed: String?
    public var id: String { trustId }
}
public struct CompanionTransfer: Codable, Sendable, Identifiable {
    public let transferId: String
    public let direction: String
    public let displayName: String
    public let mimeType: String
    public let size: Int64
    public let sha256: String
    public var id: String { transferId }
    public init(transferId: String = UUID().uuidString, direction: String, displayName: String, mimeType: String, size: Int64, sha256: String) {
        self.transferId = transferId; self.direction = direction; self.displayName = displayName
        self.mimeType = mimeType; self.size = size; self.sha256 = sha256
    }
}
public struct CompanionTransferStatus: Codable, Sendable {
    public let transferId: String
    public let nextIndex: Int
    public let acceptedBytes: Int64
    public let status: String
    public let committed: Bool
    private enum CodingKeys: String, CodingKey { case transferId, nextIndex, acceptedBytes, status, committed }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        transferId = try c.decode(String.self, forKey: .transferId)
        nextIndex = try c.decode(Int.self, forKey: .nextIndex)
        acceptedBytes = try c.decode(Int64.self, forKey: .acceptedBytes)
        committed = try c.decodeIfPresent(Bool.self, forKey: .committed) ?? false
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? (committed ? "committed" : "receiving")
        guard UUID(uuidString: transferId) != nil, (0...800).contains(nextIndex), (0...52_428_800).contains(acceptedBytes) else { throw CompanionBoundaryError("invalid_transfer", "Invalid companion transfer state.") }
    }
}
public struct CompanionBoundaryError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let retryable: Bool
    public var errorDescription: String? { message }
    public init(_ code: String, _ message: String, retryable: Bool = false) {
        self.code = code; self.message = message; self.retryable = retryable
    }
}
