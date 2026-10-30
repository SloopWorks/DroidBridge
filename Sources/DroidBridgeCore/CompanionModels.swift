import Foundation

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
