import Foundation
import Security
import LocalAuthentication
import DroidBridgeCore

/// Isolated ad-hoc update experiment. Never admitted without a random QA scope.
@main struct CompanionKeychainUpdateVerification {
    struct Input: Decodable { let mode: String; let record: CompanionCredentialRecord }
    static func emit(_ value: [String: String]) { FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) + Data([10])) }
    static func main() {
        var statusBefore: OSStatus = errSecNotAvailable
        do {
            #if NO_KEYCHAIN_UI
            guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { throw CompanionBoundaryError("noninteractive_policy_failed", "Could not require noninteractive Keychain access.") }
            #endif
            guard let scope = CompanionQAScope.current else { throw CompanionBoundaryError("qa_required", "An isolated private QA root is required.") }
            var input = Data()
            while let bytes = try FileHandle.standardInput.read(upToCount: 4096), !bytes.isEmpty {
                guard input.count + bytes.count <= 8192 else { throw CompanionBoundaryError("input_too_large", "Bounded experiment input exceeded.") }; input.append(bytes)
            }
            let value = try JSONDecoder().decode(Input.self, from: input)
            try value.record.validate()
            // Enter the real Core store first so its process policy is applied.
            // This random absent QA account cannot disclose another record.
            _ = try CompanionCredentialStore.load(deviceID: UUID().uuidString)
            let context = LAContext(); context.interactionNotAllowed = true
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "dev.sloopworks.DroidBridge.companion.v1" + scope.keychainServiceSuffix,
                kSecAttrAccount as String: value.record.deviceID.lowercased(), kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationContext as String: context]
            var raw: CFTypeRef?
            statusBefore = SecItemCopyMatching(query as CFDictionary, &raw)
            switch value.mode {
            case "save": try CompanionCredentialStore.save(value.record)
            case "load":
                guard try CompanionCredentialStore.load(deviceID: value.record.deviceID) == value.record else { throw CompanionBoundaryError("record_mismatch", "QA record did not match.") }
            case "delete": try CompanionCredentialStore.remove(deviceID: value.record.deviceID)
            default: throw CompanionBoundaryError("invalid_operation", "Invalid QA action.")
            }
            raw = nil
            let statusAfter = SecItemCopyMatching(query as CFDictionary, &raw)
            #if GENERATION_B
            let generation = "B"
            #else
            let generation = "A"
            #endif
            emit(["status": "ok", "generation": generation, "mode": value.mode,
                  "keychain_status_before": String(statusBefore), "keychain_status_after": String(statusAfter)])
        } catch let error as CompanionBoundaryError { emit(["status": "error", "code": error.code, "keychain_status_before": String(statusBefore)]) }
        catch { emit(["status": "error", "code": "experiment_failed"]) }
    }
}
