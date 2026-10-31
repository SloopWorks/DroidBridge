import Foundation
import DroidBridgeCore

/// Test driver only. Secrets enter through bounded stdin, never argv or output.
@main struct CompanionClientVerification {
    struct Input: Decodable {
        let operation: String
        let baseURL: String
        let serverPin: String
        let deviceID: String?
        let trustID: String?
        let credential: String?
        let pairingSecret: String?
        let macID: String?
    }
    static func emit(_ value: [String: String]) {
        let data = try! JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        FileHandle.standardOutput.write(data + Data([10]))
    }
    static func main() async {
        do {
            var bytes = Data()
            while let block = try FileHandle.standardInput.read(upToCount: 4096), !block.isEmpty {
                guard bytes.count + block.count <= 8192 else { throw CompanionBoundaryError("probe_input_too_large", "Bounded test input exceeded.") }; bytes.append(block)
            }
            let input = try JSONDecoder().decode(Input.self, from: bytes)
            guard let url = URL(string: input.baseURL), ["hello", "pair", "reconnect"].contains(input.operation) else { throw CompanionBoundaryError("invalid_probe", "Invalid test operation.") }
            let client = try CompanionClient(baseURL: url, serverPin: input.serverPin)
            if let id = input.deviceID { try await client.setExpectedDeviceID(id) }
            switch input.operation {
            case "hello":
                let hello = try await client.hello()
                emit(["status": "ok", "operation": input.operation, "device_id": hello.deviceId])
            case "pair":
                guard let secret = input.pairingSecret, let raw = input.macID, let mac = UUID(uuidString: raw), input.deviceID != nil else { throw CompanionBoundaryError("invalid_probe", "Pair test needs explicit installation identity.") }
                _ = try await client.hello()
                let result = try await client.beginPair(secret: secret, macID: mac, name: "DroidBridge TLS verification")
                emit(["status": "ok", "operation": input.operation, "pairing_status": result.status])
            default:
                guard let credential = input.credential, let id = input.deviceID, let trust = input.trustID else { throw CompanionBoundaryError("invalid_probe", "Reconnect test needs explicit trust identity.") }
                try await client.setCredential(credential)
                let identity = try await client.identity()
                guard UUID(uuidString: identity.deviceId) == UUID(uuidString: id), UUID(uuidString: identity.trustId) == UUID(uuidString: trust) else { throw CompanionBoundaryError("identity_mismatch", "Test identity changed.") }
                emit(["status": "ok", "operation": input.operation])
            }
        } catch let error as CompanionBoundaryError { emit(["status": "error", "code": error.code]) }
        catch { emit(["status": "error", "code": "probe_failed"]) }
    }
}
