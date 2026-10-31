import Foundation
import Security
import LocalAuthentication

/// Candidate credentials are invisible to normal device-account reads. A durable
/// broker admission journal must name the candidate before staging begins.
public enum CompanionPendingCredentialStore {
    public struct Candidate: Codable, Sendable, Equatable {
        public let record: CompanionCredentialRecord
        public let expires: Date
        public init(record: CompanionCredentialRecord, expires: Date) { self.record = record; self.expires = expires }
    }
    private static let interactionStatus = SecKeychainSetUserInteractionAllowed(false)
    private static var service: String { "dev.sloopworks.DroidBridge.companion.pending.v1" + (CompanionQAScope.current?.keychainServiceSuffix ?? "") }
    private static func query(_ id: UUID) throws -> [String: Any] {
        guard interactionStatus == errSecSuccess else { throw CompanionBoundaryError("credential_unavailable", "Noninteractive candidate Keychain access is unavailable.") }
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id.uuidString.lowercased(),kSecUseAuthenticationContext as String:context]
    }
    public static func stage(_ value: Candidate, id: UUID) throws {
        try value.record.validate()
        guard value.expires > Date(), value.expires.timeIntervalSinceNow <= 601 else { throw CompanionBoundaryError("candidate_expired", "The approved pairing candidate expired. Forget it and pair again.") }
        if let prior = try load(id: id) { guard prior == value else { throw CompanionBoundaryError("candidate_conflict", "A pairing candidate cannot be replaced with different credentials.") }; return }
        var request = try query(id)
        request[kSecValueData as String] = try JSONEncoder().encode(value)
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(request as CFDictionary,nil) == errSecSuccess else { throw CompanionBoundaryError("candidate_save_failed", "Could not stage approved pairing credentials. Forget this pairing and try again.") }
    }
    public static func load(id: UUID) throws -> Candidate? {
        var request = try query(id); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result:CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary,&result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 8192 else { throw CompanionBoundaryError("candidate_unavailable", "Approved pairing recovery is unavailable in Keychain. Forget this pairing and approve a fresh phone link.") }
        let value = try JSONDecoder().decode(Candidate.self,from:data); try value.record.validate(); return value
    }
    public static func finalize(id: UUID, deviceID: String, trustID: String, serverPin: String) throws {
        guard let value = try load(id:id), value.expires > Date(), value.record.deviceID == deviceID.lowercased(), value.record.trustID == trustID.lowercased(), value.record.serverPin == serverPin else { throw CompanionBoundaryError("candidate_expired", "The approved pairing candidate changed or expired. Forget it and pair again.") }
        try CompanionCredentialStore.save(value.record)
    }
    public static func remove(id: UUID) throws {
        let status = SecItemDelete(try query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CompanionBoundaryError("candidate_delete_failed", "Could not remove the exact pairing candidate from Keychain.") }
    }
}
