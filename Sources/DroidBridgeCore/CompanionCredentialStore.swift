import Foundation
import Security
import LocalAuthentication

public struct CompanionCredentialRecord: Codable, Sendable, Equatable {
    public let version: Int
    public let deviceID: String
    public let trustID: String
    public let credential: String
    public let serverPin: String
    public init(deviceID: String, trustID: String, credential: String, serverPin: String) throws {
        version = 1; self.deviceID = deviceID.lowercased(); self.trustID = trustID.lowercased(); self.credential = credential; self.serverPin = serverPin
        try validate()
    }
    public func validate() throws {
        guard version == 1, UUID(uuidString: deviceID) != nil, UUID(uuidString: trustID) != nil else { throw CompanionBoundaryError("re_pair_required", "Companion trust metadata is invalid. Pair again using the phone's complete setup link.") }
        try CompanionClient.validateSecret(credential); try CompanionClient.validateServerPin(serverPin)
    }
}

/// Used only by the per-user broker; wrappers never receive companion credentials.
public enum CompanionCredentialStore {
    // The unsandboxed, ad-hoc distributed broker uses the login Keychain.
    // LAContext alone does not suppress its legacy ACL UI (verified on macOS26).
    // This public legacy API denies interaction for this broker process without
    // widening any item's ACL. Refuse work if that policy cannot be established.
    private static let noInteractionStatus = SecKeychainSetUserInteractionAllowed(false)
    private static var service: String { "dev.sloopworks.DroidBridge.companion.v1" + (CompanionQAScope.current?.keychainServiceSuffix ?? "") }
    private static func query(_ deviceID: String) throws -> [String: Any] {
        guard noInteractionStatus == errSecSuccess else { throw CompanionBoundaryError("credential_unavailable", "The companion service could not disable interactive Keychain access. Pairing has not started.") }
        guard let id = UUID(uuidString: deviceID) else { throw CompanionBoundaryError("invalid_identity", "Invalid companion installation identity.") }
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: id.uuidString.lowercased(), kSecUseAuthenticationContext as String: context]
    }
    public static func load(deviceID: String) throws -> CompanionCredentialRecord? {
        var request = try query(deviceID); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CompanionBoundaryError("credential_unavailable", "The companion credential is unavailable in Keychain. Unlock the login Keychain or pair again.")
        }
        guard data.count <= 4096, let value = try? JSONDecoder().decode(CompanionCredentialRecord.self, from: data) else { throw CompanionBoundaryError("re_pair_required", "This Mac has legacy unpinned companion trust. Revoke it on the phone and pair again using the complete setup link.") }
        try value.validate()
        guard UUID(uuidString: value.deviceID) == UUID(uuidString: deviceID) else { throw CompanionBoundaryError("re_pair_required", "The companion trust belongs to another phone installation.") }
        return value
    }
    public static func save(_ record: CompanionCredentialRecord) throws {
        try record.validate()
        var request = try query(record.deviceID)
        let bytes = try JSONEncoder().encode(record)
        let value: [String: Any] = [kSecValueData as String: bytes, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(request as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            request.merge(value) { _, new in new }
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw CompanionBoundaryError("credential_save_failed", "Could not save companion trust in Keychain.") }
        } else if status != errSecSuccess { throw CompanionBoundaryError("credential_save_failed", "Could not update companion trust in Keychain.") }
    }
    public static func remove(deviceID: String) throws {
        let status = SecItemDelete(try query(deviceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CompanionBoundaryError("credential_delete_failed", "Could not remove companion trust from Keychain.") }
    }
}
