import Foundation
import Darwin
import Security

/// Small same-user control messages. Screen frames, PCM and phone credentials never cross this API.
public enum CompanionBrokerIPC {
    public static var serviceName: String { "dev.droidbridge.companion.broker" + (CompanionQAScope.current.map { ".qa." + $0.serviceSuffix } ?? "") }
    public static let maximumBytes = 262_144
    public static var directory: URL { if let scope = CompanionQAScope.current { return scope.brokerDirectory }; return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DroidBridge/CompanionBroker", isDirectory: true) }
    public static var nonceURL: URL { directory.appendingPathComponent("ipc-nonce") }
    public static func prepareDirectory(_ url: URL = directory) throws {
        var st = stat()
        if lstat(url.path, &st) == 0 {
            guard st.st_uid == geteuid(), (st.st_mode & S_IFMT) == S_IFDIR, st.st_mode & 0o077 == 0 else { throw CompanionBoundaryError("unsafe_ipc_directory", "Companion storage must be a private directory owned by this user.") }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard lstat(url.path, &st) == 0, st.st_uid == geteuid(), (st.st_mode & S_IFMT) == S_IFDIR, st.st_mode & 0o077 == 0 else { throw CompanionBoundaryError("unsafe_ipc_directory", "Companion storage is unavailable.") }
        }
    }
    public static func nonce(create: Bool = false) throws -> String {
        try prepareDirectory()
        if create {
            let fd = open(nonceURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            if fd >= 0 {
                defer { close(fd) }
                var random = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw CompanionBoundaryError("random_unavailable", "Secure random generation failed.") }
                let bytes = Array(Data(random).base64EncodedString().utf8)
                guard write(fd, bytes, bytes.count) == bytes.count else { throw CompanionBoundaryError("ipc_unavailable", "Companion IPC setup failed.") }
            } else if errno != EEXIST { throw CompanionBoundaryError("ipc_unavailable", "Companion IPC setup failed.") }
        }
        let fd = open(nonceURL.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw CompanionBoundaryError("broker_unavailable", "Start DroidBridge to install the companion connection service.", retryable: true) }
        defer { close(fd) }
        var st = stat(); guard fstat(fd, &st) == 0, st.st_uid == geteuid(), st.st_mode & S_IFMT == S_IFREG, st.st_mode & 0o077 == 0, st.st_size == 44 else { throw CompanionBoundaryError("unsafe_ipc_nonce", "Companion IPC credentials have unsafe permissions.") }
        var bytes = [UInt8](repeating: 0, count: 45)
        guard read(fd, &bytes, bytes.count) == 44, let value = String(bytes: bytes.prefix(44), encoding: .utf8) else { throw CompanionBoundaryError("unsafe_ipc_nonce", "Companion IPC credentials are invalid.") }
        return value
    }
    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

public struct CompanionBrokerRequest: Codable, Sendable {
    public let version: Int
    public let requestID: UUID
    public let nonce: String
    public let operation: String
    public let payload: [String: CompanionJSON]
    public init(operation: String, payload: [String: CompanionJSON] = [:], requestID: UUID = UUID(), nonce: String) {
        version = 1; self.requestID = requestID; self.nonce = nonce; self.operation = operation; self.payload = payload
    }
}
public struct CompanionBrokerFailure: Codable, Sendable {
    public let code: String; public let message: String; public let retryable: Bool
    public init(_ error: CompanionBoundaryError) { code = error.code; message = String(error.message.prefix(512)); retryable = error.retryable }
}
public struct CompanionBrokerReply: Codable, Sendable {
    public let requestID: UUID
    public let status: String
    public let data: [String: CompanionJSON]
    public let error: CompanionBrokerFailure?
    public init(requestID: UUID, status: String = "ok", data: [String: CompanionJSON] = [:], error: CompanionBoundaryError? = nil) {
        self.requestID = requestID; self.status = error == nil ? status : "error"; self.data = data; self.error = error.map(CompanionBrokerFailure.init)
    }
}
@objc public protocol CompanionBrokerXPCProtocol {
    func exchange(_ request: Data, reply: @escaping (Data) -> Void)
}

/// Keeps one XPC connection so process identity and owner generation remain stable.
public actor CompanionBrokerIPCClient {
    private var connection: NSXPCConnection?
    private var connectionGeneration = UUID()
    private let serviceName: String
    private let explicitNonce: String?
    public init(serviceName: String = CompanionBrokerIPC.serviceName) { self.serviceName = serviceName; explicitNonce = nil }
    public init(endpoint: NSXPCListenerEndpoint, nonce: String) {
        serviceName = CompanionBrokerIPC.serviceName; explicitNonce = nonce
        let c = NSXPCConnection(listenerEndpoint: endpoint)
        c.remoteObjectInterface = NSXPCInterface(with: CompanionBrokerXPCProtocol.self); c.resume(); connection = c
    }
    public func request(operation: String, payload: [String: CompanionJSON] = [:], requestID: UUID = UUID()) async throws -> CompanionBrokerReply {
        try Task.checkCancellation()
        let request = CompanionBrokerRequest(operation: operation, payload: payload, requestID: requestID, nonce: try explicitNonce ?? CompanionBrokerIPC.nonce())
        let bytes = try JSONEncoder().encode(request)
        guard bytes.count <= CompanionBrokerIPC.maximumBytes else { throw CompanionBoundaryError("payload_too_large", "Companion operation exceeds its byte limit.") }
        if connection == nil {
            let c = NSXPCConnection(machServiceName: serviceName)
            c.remoteObjectInterface = NSXPCInterface(with: CompanionBrokerXPCProtocol.self)
            let generation = UUID(); connectionGeneration = generation
            c.interruptionHandler = { [weak self] in Task { await self?.clearConnection(generation) } }
            c.invalidationHandler = { [weak self] in Task { await self?.clearConnection(generation) } }
            c.resume(); connection = c
        }
        guard let connection else { throw CompanionBoundaryError("broker_unavailable", "Companion service is unavailable.", retryable: true) }
        let gate = CompanionBrokerReplyGate()
        let output: Data = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in gate.fail() } as? CompanionBrokerXPCProtocol
                guard let proxy else { gate.fail(); return }
                proxy.exchange(bytes) { gate.finish($0) }
                DispatchQueue.global().asyncAfter(deadline: .now() + 35) { gate.fail() }
            }
        }, onCancel: {
            gate.cancel()
            Task.detached { [weak self] in _ = try? await self?.request(operation: "cancel", payload: ["request_id": .string(requestID.uuidString)]) }
        })
        guard output.count <= CompanionBrokerIPC.maximumBytes else { throw CompanionBoundaryError("response_too_large", "Companion service response exceeds its byte limit.") }
        let result = try JSONDecoder().decode(CompanionBrokerReply.self, from: output)
        guard result.requestID == requestID else { throw CompanionBoundaryError("receipt_mismatch", "Companion service returned an unrelated receipt.") }
        if let error = result.error { throw CompanionBoundaryError(error.code, error.message, retryable: error.retryable) }
        return result
    }
    public func icon(deviceID: String, hash: String) async throws -> Data {
        var result = Data(); var offset = 0
        repeat {
            let response = try await request(operation: "icon", payload: ["device_id": .string(deviceID), "hash": .string(hash), "offset": .number(Double(offset))])
            guard let encoded = response.data["bytes"]?.string, let bytes = Data(base64Encoded: encoded), bytes.count <= 65_536,
                  let total = response.data["total_bytes"]?.number, total >= 0, total <= 262_144,
                  let next = response.data["next_offset"]?.number, next == Double(offset + bytes.count), Int(next) <= Int(total), !bytes.isEmpty else { throw CompanionBoundaryError("invalid_icon", "Invalid companion icon chunk.") }
            result.append(bytes); offset += bytes.count
            if offset == Int(total) { break }
        } while offset < 262_144
        guard CompanionClient.sha256(result) == hash else { throw CompanionBoundaryError("invalid_icon", "Companion icon integrity check failed.") }
        return result
    }
    private func clearConnection(_ generation: UUID) { if connectionGeneration == generation { connection?.invalidate(); connection = nil; connectionGeneration = UUID() } }
    public func invalidate() { connection?.invalidate(); connection = nil; connectionGeneration = UUID() }
}
private final class CompanionBrokerReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var completed = false
    private var cancellation = false
    func install(_ value: CheckedContinuation<Data, Error>) {
        lock.lock()
        if completed { lock.unlock(); value.resume(throwing: CancellationError()); return }
        continuation = value; lock.unlock()
    }
    func finish(_ data: Data) { lock.lock(); guard !completed else { lock.unlock(); return }; completed = true; let c = continuation; continuation = nil; lock.unlock(); c?.resume(returning: data) }
    func fail() { lock.lock(); guard !completed else { lock.unlock(); return }; completed = true; let c = continuation; continuation = nil; lock.unlock(); c?.resume(throwing: CompanionBoundaryError("broker_unavailable", "Companion service did not respond. Retry the connection.", retryable: true)) }
    func cancel() { lock.lock(); guard !completed else { lock.unlock(); return }; completed = true; cancellation = true; let c = continuation; continuation = nil; lock.unlock(); c?.resume(throwing: CancellationError()) }
}
