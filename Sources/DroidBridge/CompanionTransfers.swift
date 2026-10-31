import AppKit
import CryptoKit
import Darwin
import UniformTypeIdentifiers
import DroidBridgeCore

private actor CompanionTransferFile {
    private var handle: FileHandle?
    func metadata(_ url: URL) throws -> (Int64, String) {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let count = values.fileSize, count >= 0, count <= 52_428_800 else { throw CompanionBoundaryError("file_too_large", "Choose a regular file no larger than 50 MiB.") }
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var digest = SHA256(), total = 0
        while let bytes = try input.read(upToCount: 65_536), !bytes.isEmpty { try Task.checkCancellation(); digest.update(data: bytes); total += bytes.count; guard total <= 52_428_800 else { throw CompanionBoundaryError("file_changed", "The file grew beyond the transfer limit.") } }
        guard total == count else { throw CompanionBoundaryError("file_changed", "The file changed. Choose it again.") }
        return (Int64(total), digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    func openRead(_ url: URL) throws { handle = try FileHandle(forReadingFrom: url) }
    func openWrite(_ url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CompanionBoundaryError("file_unavailable", "Unable to stage the received file.") }
        handle = try FileHandle(forWritingTo: url)
    }
    func read() throws -> Data { try handle?.read(upToCount: 65_536) ?? Data() }
    func write(_ data: Data) throws { try handle?.write(contentsOf: data) }
    func close() { try? handle?.close(); handle = nil }
    func publish(_ stage: URL, destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CompanionBoundaryError("destination_exists", "A file already exists at that destination. Choose a different name.") }
        try FileManager.default.moveItem(at: stage, to: destination)
        // Preserve the downloaded-file trust boundary. Content is never opened
        // or executed by reception, regardless of its reported extension/MIME.
        let value = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));DroidBridge;"
        _ = value.withCString { setxattr(destination.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
    }
    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

@MainActor final class CompanionTransfers {
    let broker: CompanionBrokerIPCClient
    private var task: Task<Void, Never>?
    private var transferID: String?
    private var deviceID: String?
    private var pendingReceipt: (device: String, id: String, bytes: Int64, hash: String, request: UUID)?
    private(set) var confirmationPending = false
    private(set) var running = false
    private(set) var message = "Files stay local to the paired phone and Mac. Maximum 50 MiB per file."
    var onChange: (() -> Void)?
    init(broker: CompanionBrokerIPCClient) { self.broker = broker }

    func send(_ source: URL, device: String) {
        begin(device: device) { [broker] id, file, progress in
            let metadata = try await file.metadata(source)
            try Task.checkCancellation()
            _ = try await broker.request(operation: "transfer_begin", payload: ["device_id": .string(device), "transfer_id": .string(id), "direction": .string("mac_to_phone"), "display_name": .string(String(source.lastPathComponent.prefix(255))), "mime_type": .string(UTType(filenameExtension: source.pathExtension)?.preferredMIMEType ?? "application/octet-stream"), "size": .number(Double(metadata.0)), "sha256": .string(metadata.1)])
            try await file.openRead(source)
            var total: Int64 = 0, index = 0
            while true {
                try Task.checkCancellation()
                let bytes = try await file.read(); if bytes.isEmpty { break }
                guard total + Int64(bytes.count) <= metadata.0 else { throw CompanionBoundaryError("file_changed", "The selected file changed while sending.") }
                let receipt = try await broker.request(operation: "transfer_chunk", payload: ["device_id": .string(device), "transfer_id": .string(id), "index": .number(Double(index)), "bytes": .string(bytes.base64EncodedString())])
                guard receipt.data["accepted_bytes"]?.number == Double(total + Int64(bytes.count)) else { throw CompanionBoundaryError("transfer_receipt_mismatch", "The phone did not confirm the expected received byte count.") }
                total += Int64(bytes.count); index += 1; await progress(total, metadata.0)
                await Task.yield()
            }
            await file.close()
            guard total == metadata.0 else { throw CompanionBoundaryError("file_changed", "The selected file changed while sending.") }
            try Task.checkCancellation()
            let result = try await broker.request(operation: "transfer_commit", payload: ["device_id": .string(device), "transfer_id": .string(id)])
            guard result.data["committed"]?.bool == true, result.data["accepted_bytes"]?.number == Double(metadata.0), result.data["transfer_id"]?.string.flatMap(UUID.init(uuidString:)) == UUID(uuidString: id) else { throw CompanionBoundaryError("transfer_not_committed", "The phone did not confirm this complete file and byte count.") }
            return "File received and verified on the phone. Open its Received Files screen to save it."
        }
    }
    func receive(_ metadata: [String: CompanionJSON], destination: URL, device: String) {
        guard let id = metadata["transfer_id"]?.string, UUID(uuidString: id) != nil,
              let size = metadata["size"]?.number, size.isFinite, size >= 0, size <= 52_428_800, size.rounded() == size,
              let hash = metadata["sha256"]?.string, hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { message = "The phone supplied invalid file metadata."; onChange?(); return }
        begin(device: device, id: id) { [weak self, broker] id, file, progress in
            let stage = destination.deletingLastPathComponent().appendingPathComponent(".droidbridge-transfer-\(UUID().uuidString).partial")
            do {
                try await file.openWrite(stage)
                var total = 0, index = 0
                while total < Int(size) {
                    try Task.checkCancellation()
                    let reply = try await broker.request(operation: "transfer_download", payload: ["device_id": .string(device), "transfer_id": .string(id), "index": .number(Double(index))])
                    guard let encoded = reply.data["bytes"]?.string, let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= 65_536, total + bytes.count <= Int(size) else { throw CompanionBoundaryError("invalid_chunk", "The received file chunk was invalid.") }
                    try await file.write(bytes); total += bytes.count; index += 1; await progress(Int64(total), Int64(size)); await Task.yield()
                }
                await file.close()
                let actual = try await file.metadata(stage)
                guard actual.0 == Int64(size), actual.1 == hash else { throw CompanionBoundaryError("file_integrity_failed", "The received file did not match its declared size and SHA-256. It was not saved.") }
                try Task.checkCancellation(); try await file.publish(stage, destination: destination)
                let request = UUID()
                do {
                    let receipt = try await broker.request(operation: "transfer_receipt", payload: ["device_id": .string(device), "transfer_id": .string(id), "accepted_bytes": .number(size), "sha256": .string(hash), "status": .string("downloaded")], requestID: request)
                    try Self.verifyDownloadReceipt(receipt.data, id: id, bytes: Int64(size))
                    return "File saved after size and SHA-256 verification; the phone confirmed completion. It was not opened."
                } catch {
                    await self?.savePendingReceipt(device: device, id: id, bytes: Int64(size), hash: hash, request: request)
                    return "File saved and verified locally. Phone confirmation is pending; use Retry File Confirmation. The file will not be downloaded again."
                }
            } catch { await file.close(); await file.remove(stage); throw error }
        }
    }
    private func savePendingReceipt(device: String, id: String, bytes: Int64, hash: String, request: UUID) { pendingReceipt = (device, id, bytes, hash, request); confirmationPending = true }
    func retryConfirmation() {
        guard task == nil, let receipt = pendingReceipt else { return }
        running = true; message = "Confirming the already saved file with the phone…"; onChange?()
        task = Task { [weak self, broker] in
            do {
                let reply = try await broker.request(operation: "transfer_receipt", payload: ["device_id": .string(receipt.device), "transfer_id": .string(receipt.id), "accepted_bytes": .number(Double(receipt.bytes)), "sha256": .string(receipt.hash), "status": .string("downloaded")], requestID: receipt.request)
                try Self.verifyDownloadReceipt(reply.data, id: receipt.id, bytes: receipt.bytes)
                self?.pendingReceipt = nil; self?.confirmationPending = false; self?.message = "The phone confirmed the previously saved file. No file was downloaded or opened again."
            } catch { self?.message = "File is saved locally; phone confirmation remains pending. Reconnect the phone and retry confirmation." }
            self?.running = false; self?.task = nil; self?.onChange?()
        }
    }
    private nonisolated static func verifyDownloadReceipt(_ data: [String: CompanionJSON], id: String, bytes: Int64) throws {
        guard data["transfer_id"]?.string.flatMap(UUID.init(uuidString:)) == UUID(uuidString: id), data["accepted_bytes"]?.number == Double(bytes), data["status"]?.string == "downloaded" else { throw CompanionBoundaryError("transfer_receipt_mismatch", "The phone did not confirm this exact saved file.") }
    }
    private func begin(device: String, id: String = UUID().uuidString.lowercased(), action: @escaping @Sendable (String, CompanionTransferFile, @escaping @Sendable (Int64, Int64) async -> Void) async throws -> String) {
        guard task == nil, pendingReceipt == nil else { message = pendingReceipt != nil ? "Confirm the previous saved file with the phone before starting another transfer. It is already saved locally." : "Wait for the current transfer or cancel it first."; onChange?(); return }
        running = true; message = "Preparing file…"; transferID = id; deviceID = device; onChange?()
        let file = CompanionTransferFile()
        task = Task { [weak self] in
            do {
                let owner = self
                let result = try await action(id, file) { count, total in await owner?.updateProgress(count, total: total) }
                self?.message = result
            } catch { self?.message = error is CancellationError ? "Transfer cancelled. Partial received content was removed." : error.localizedDescription }
            await file.close()
            self?.running = false; self?.task = nil; self?.transferID = nil; self?.deviceID = nil; self?.onChange?()
        }
    }
    private func updateProgress(_ count: Int64, total: Int64) { message = "Transferring \(count) of \(total) bytes · \(total == 0 ? 100 : count * 100 / total)%"; onChange?() }
    func cancel() {
        guard task != nil else { return }
        task?.cancel()
        if let transferID, let deviceID { Task { _ = try? await broker.request(operation: "transfer_cancel", payload: ["device_id": .string(deviceID), "transfer_id": .string(transferID)]) } }
    }
    func shutdown() { cancel(); onChange = nil }
}
