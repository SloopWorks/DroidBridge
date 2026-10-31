import Foundation
import DroidBridgeCore

/// Test-only scoped public IPC driver. A bounded JSON-line protocol retains the
/// same NSXPC connection for exact request-ID replay tests. It never reads the
/// private broker journal, credential or Keychain and performs no ADB operation.
@main struct CompanionBrokerRPC {
    static func main() async throws {
        _ = try CompanionQAScope.parse(arguments: CommandLine.arguments)
        guard CompanionQAScope.current != nil else { throw CompanionBoundaryError("qa_scope_required", "An explicitly owned emulator QA scope is required.") }
        let client = CompanionBrokerIPCClient()
        while let line = readLine() {
            do {
                guard line.utf8.count <= 65_536 else { throw CompanionBoundaryError("input_too_large", "Test request exceeds its bound.") }
                let value = try JSONDecoder().decode([String: CompanionJSON].self, from: Data(line.utf8))
                guard let operation = value["operation"]?.string, ["status", "catalog", "catalog_changes", "export_selection_get", "export_selection_set", "command_status", "inbox_list", "diagnostics", "notification_preferences", "notification_reply", "notification_dismiss"].contains(operation) else { throw CompanionBoundaryError("unsupported_test_operation", "This driver permits only catalog/notification acceptance operations.") }
                let id: UUID
                if let raw = value["request_id"]?.string { guard let parsed = UUID(uuidString: raw) else { throw CompanionBoundaryError("invalid_request", "Invalid test request identity") }; id = parsed }
                else { id = UUID() }
                let reply = try await client.request(operation: operation, payload: value["payload"]?.object ?? [:], requestID: id)
                let bytes = try JSONEncoder().encode(reply)
                FileHandle.standardOutput.write(bytes + Data([10]))
            } catch {
                let failure = error as? CompanionBoundaryError
                let data: [String: CompanionJSON] = ["status": .string("error"), "error": .object(["code": .string(failure?.code ?? "driver_error"), "message": .string(String(error.localizedDescription.prefix(512)))])]
                FileHandle.standardOutput.write((try JSONEncoder().encode(data)) + Data([10]))
            }
        }
        await client.invalidate()
    }
}
