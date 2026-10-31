import Foundation
import CryptoKit
import DroidBridgeCore

/// Real installed broker / phone benchmarks. Requires explicit isolated QA scope.
/// Credentials remain in the broker; output contains only timings and byte counts.
@main struct CompanionPerformanceVerification {
    struct Sample: Codable, Sendable {
        let start: Double
        let end: Double
        var milliseconds: Double { (end - start) * 1000 }
    }
    struct Transfer: Codable, Sendable { let start: Double; let end: Double; let bytes: Int; let hashVerified: Bool }
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    static func sample(_ client: CompanionBrokerIPCClient, _ operation: String, _ payload: [String: CompanionJSON]) async throws -> Sample {
        let start = now(); _ = try await client.request(operation: operation, payload: payload)
        return Sample(start: start, end: now())
    }
    static func group(_ samples: [Sample]) -> [String: CompanionJSON] {
        let sorted = samples.map(\.milliseconds).sorted()
        guard !sorted.isEmpty else { return ["n": .number(0), "p50_ms": .null, "p95_ms": .null] }
        func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, max(0, Int(ceil(Double(sorted.count) * p)) - 1))] }
        return ["n": .number(Double(sorted.count)), "p50_ms": .number(percentile(0.5)), "p95_ms": .number(percentile(0.95)), "maximum_ms": .number(sorted.last!), "samples_ms": .array(samples.map { .number($0.milliseconds) })]
    }
    static func download(_ client: CompanionBrokerIPCClient, device: String, transfer: String, size: Int, hash: String) async throws -> Transfer {
        let start = now(); var total = 0, index = 0, digest = SHA256()
        while total < size {
            let reply = try await client.request(operation: "transfer_download", payload: ["device_id": .string(device), "transfer_id": .string(transfer), "index": .number(Double(index))])
            guard let encoded = reply.data["bytes"]?.string, let data = Data(base64Encoded: encoded), !data.isEmpty, data.count <= 65_536, total + data.count <= size else { throw CompanionBoundaryError("invalid_test_chunk", "Actual bulk read returned an invalid chunk.") }
            digest.update(data: data); total += data.count; index += 1
        }
        let verified = digest.finalize().map { String(format: "%02x", $0) }.joined() == hash
        guard verified else { throw CompanionBoundaryError("test_hash_mismatch", "Actual bulk read did not match its fixture hash.") }
        return Transfer(start: start, end: now(), bytes: total, hashVerified: verified)
    }
    static func main() async throws {
        guard let scope = try CompanionQAScope.parse(arguments: CommandLine.arguments) else { throw CompanionBoundaryError("qa_required", "Pass the explicit owned QA root and emulator serial.") }
        let client = CompanionBrokerIPCClient()
        let status = try await client.request(operation: "status")
        guard let device = status.data["devices"]?.array?.compactMap(\.object).first(where: { $0["serial"]?.string == scope.serial && $0["connected"]?.bool == true && $0["paired"]?.bool == true }), let id = device["device_id"]?.string else { throw CompanionBoundaryError("qa_phone_unavailable", "Pair the owned QA phone in the installed application first.") }
        let payload: [String: CompanionJSON] = ["device_id": .string(id)]
        let inbox = try await client.request(operation: "inbox_list", payload: payload)
        guard let metadata = inbox.data["items"]?.array?.compactMap(\.object).first(where: { $0["kind"]?.string == "file_shared" && $0["payload"]?.object?["size"]?.number == 2_097_152 })?["payload"]?.object,
              let transfer = metadata["transfer_id"]?.string, let hash = metadata["sha256"]?.string else { throw CompanionBoundaryError("qa_file_required", "Share the deterministic 2 MiB Android fixture and retain its inbox entry first.") }
        for _ in 0..<3 { _ = try await client.request(operation: "catalog", payload: payload) }
        var catalog: [Sample] = [], idle: [Sample] = [], local: [Sample] = []
        for _ in 0..<20 { catalog.append(try await sample(client, "catalog", payload)) }
        for _ in 0..<30 { idle.append(try await sample(client, "diagnostics", payload)) }
        for _ in 0..<50 { local.append(try await sample(client, "status", [:])) }
        var overlaps: [Sample] = [], transfers: [Transfer] = []
        for _ in 0..<3 {
            let bulk = Task { try await download(client, device: id, transfer: transfer, size: 2_097_152, hash: hash) }
            var controls: [Sample] = []
            for _ in 0..<60 { controls.append(try await sample(client, "diagnostics", payload)) }
            let completed = try await bulk.value; transfers.append(completed)
            overlaps += controls.filter { $0.start >= completed.start && $0.end <= completed.end }
        }
        var reconnect: [Sample] = []
        for _ in 0..<5 {
            _ = try await client.request(operation: "disconnect", payload: payload)
            reconnect.append(try await sample(client, "connect", ["serial": .string(scope.serial)]))
        }
        guard !overlaps.isEmpty else { throw CompanionBoundaryError("no_test_overlap", "No measured control request completed entirely during an actual transfer.") }
        let encodedTransfers = try JSONDecoder().decode(CompanionJSON.self, from: JSONEncoder().encode(transfers))
        let results: [String: CompanionJSON] = ["passed": .bool(true), "serial": .string(scope.serial), "boundary": .string("One persistent public NSXPC client to the actual installed broker; diagnostics/catalog include pinned HTTPS to the real Android companion. Reconnect includes owned ADB forward and stored-pin authentication. p95 uses nearest rank; no synthetic traffic or credentials."), "catalog_warmed": .object(group(catalog)), "diagnostics_idle": .object(group(idle)), "local_status_idle": .object(group(local)), "diagnostics_during_real_2mib_download": .object(group(overlaps)), "reconnect": .object(group(reconnect)), "actual_transfers": encodedTransfers]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileHandle.standardOutput.write(contentsOf: encoder.encode(results))
        await client.invalidate()
    }
}
