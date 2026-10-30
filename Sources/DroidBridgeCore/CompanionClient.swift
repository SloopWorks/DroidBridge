import Foundation
import CryptoKit
import ImageIO
import Security

/// Companion control plane only. Video/audio never travel through this client.
public actor CompanionClient {
    public let baseURL: URL
    private let serverPin: String
    private var credential: String?
    private var expectedDeviceID: UUID?
    private var commandBodies: [UUID: (Date, [String: CompanionJSON], Int)] = [:]
    private var usedCommandIDs: [UUID: Date] = [:]
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public static let jsonLimit = 262_144
    public static let chunkLimit = 65_536

    public init(baseURL: URL, serverPin: String? = nil, credential: String? = nil) throws {
        guard baseURL.scheme == "https", baseURL.host == "127.0.0.1", baseURL.port != nil,
              baseURL.user == nil, baseURL.password == nil, baseURL.query == nil,
              baseURL.fragment == nil, baseURL.path.isEmpty || baseURL.path == "/" else {
            throw CompanionBoundaryError("unsafe_endpoint", "Companion transport requires an owned loopback ADB forward.")
        }
        guard let serverPin else { throw CompanionBoundaryError("missing_server_pin", "Scan or paste the complete pairing link from the phone, including its server identity.") }
        try Self.validateServerPin(serverPin)
        if let credential { try Self.validateSecret(credential) }
        self.serverPin = serverPin; self.baseURL = baseURL; self.credential = credential
        encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase; encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
    }
    public func setCredential(_ value: String?) throws {
        if let value { try Self.validateSecret(value) }
        credential = value
    }
    public func hello() async throws -> CompanionHello {
        let value: CompanionHello = try await json("GET", "/v1/hello", authenticated: false)
        guard value.protocolMin > 0, value.protocolMin <= value.protocolMax, value.protocolMin <= 1, value.protocolMax >= 1,
              UUID(uuidString: value.deviceId) != nil, value.deviceName.utf8.count <= 256, value.capabilities.count <= 32,
              value.capabilities.allSatisfy({ $0.utf8.count <= 64 }), value.permissions?.count ?? 0 <= 32 else {
            throw CompanionBoundaryError("unsupported_protocol", "This companion protocol is unsupported. Update both applications.")
        }
        if let expectedDeviceID, UUID(uuidString: value.deviceId) != expectedDeviceID { throw CompanionBoundaryError("identity_changed", "This connection belongs to another companion installation.") }
        return value
    }
    public func setExpectedDeviceID(_ deviceID: String) throws {
        guard let value = UUID(uuidString: deviceID) else { throw CompanionBoundaryError("invalid_identity", "Invalid companion installation identity.") }; expectedDeviceID = value
    }
    public func identity() async throws -> CompanionIdentity {
        let value: CompanionIdentity = try await json("GET", "/v1/identity")
        guard let id = UUID(uuidString: value.deviceId), UUID(uuidString: value.trustId) != nil, value.protocolVersion == 1, expectedDeviceID == nil || expectedDeviceID == id else { throw CompanionBoundaryError("identity_changed", "Authenticated companion identity does not match this connection.") }; return value
    }
    public func beginPair(secret: String, macID: UUID, name: String, requestID: UUID = UUID()) async throws -> CompanionPairing {
        try Self.validateSecret(secret)
        guard name.utf8.count <= 128 else { throw CompanionBoundaryError("invalid_name", "Mac name is too long.") }
        let result: CompanionPairing = try await json("POST", "/v1/pair", body: ["request_id": .string(requestID.uuidString), "pairing_secret": .string(secret), "mac_id": .string(macID.uuidString), "mac_name": .string(name)], authenticated: false)
        try validatePairing(result); return result
    }
    public func pollPair(id: String, secret: String) async throws -> CompanionPairing {
        try Self.validateID(id); try Self.validateSecret(secret)
        let result: CompanionPairing = try await json("GET", "/v1/pair/\(id)", authenticated: false, authorization: "Pairing \(secret)")
        try validatePairing(result); return result
    }
    public func catalog(cursor: String? = nil) async throws -> CompanionCatalogPage {
        let result: CompanionCatalogPage = try await json("GET", "/v1/catalog", query: ["limit": "64", "cursor": cursor])
        guard result.items.count <= 64 else { throw CompanionBoundaryError("oversized_catalog", "Companion catalog exceeds its page limit.") }
        for app in result.items { try Self.validateApp(app) }
        return result
    }
    public func catalogChanges(after: String) async throws -> CompanionCatalogDelta {
        let result: CompanionCatalogDelta = try await json("GET", "/v1/catalog/changes", query: ["after": after])
        guard result.items.count <= 4096, result.deleted.count <= 4096 else { throw CompanionBoundaryError("oversized_catalog", "Companion delta exceeds its limit.") }
        for app in result.items { try Self.validateApp(app) }
        for package in result.deleted { try Self.validatePackage(package) }
        return result
    }
    public func events(after: Int64 = 0, epoch: String? = nil, waitMS: Int = 25_000) async throws -> CompanionEventPage {
        let value: CompanionEventPage = try await json("GET", "/v1/events", query: ["after": String(max(0, after)), "epoch": epoch, "limit": "64", "wait_ms": String(max(0, min(25_000, waitMS)))], timeout: 30)
        guard value.events.count <= 64, UUID(uuidString: value.epoch) != nil, value.nextSequence >= 0 else {
            throw CompanionBoundaryError("invalid_events", "Companion event page is invalid.")
        }
        var previous: Int64 = value.resetRequired ? -1 : after
        for event in value.events {
            guard event.sequence > previous, event.sequence <= value.nextSequence, UUID(uuidString: event.eventId) != nil else { throw CompanionBoundaryError("invalid_events", "Companion events are out of sequence.") }
            previous = event.sequence
        }
        return value
    }
    public func sendCommand(kind: String, payload: [String: CompanionJSON], requestID: UUID = UUID()) async throws -> CompanionReceipt {
        guard Self.commandKinds.contains(kind) else { throw CompanionBoundaryError("unsupported_command", "Unsupported companion command.") }
        try Self.validateCommand(kind, payload)
        let now = Date()
        commandBodies = commandBodies.filter { $0.value.0 > now }
        usedCommandIDs = usedCommandIDs.filter { $0.value > now.addingTimeInterval(-86_400) }
        let body: [String: CompanionJSON]
        if let existing = commandBodies[requestID] {
            guard existing.1["kind"] == .string(kind), existing.1["payload"] == .object(payload) else { throw CompanionBoundaryError("request_conflict", "This command ID already belongs to different content.") }
            body = existing.1
        } else {
            guard usedCommandIDs[requestID] == nil else { throw CompanionBoundaryError("request_expired", "This command has expired. Start a new deliberate action.") }
            guard commandBodies.count < 512, usedCommandIDs.count < 4096 else { throw CompanionBoundaryError("command_capacity", "Wait for pending companion commands to expire.") }
            let expiry = now.addingTimeInterval(30)
            body = ["request_id": .string(requestID.uuidString), "kind": .string(kind), "payload": .object(payload), "expires_at": .string(ISO8601DateFormatter().string(from: expiry))]
            let count = try encoder.encode(body).count
            guard count <= Self.jsonLimit, commandBodies.values.reduce(0, { $0 + $1.2 }) + count <= 1_048_576 else { throw CompanionBoundaryError("command_capacity", "Pending companion command payloads exceed the memory budget.") }
            commandBodies[requestID] = (expiry, body, count); usedCommandIDs[requestID] = now
        }
        return try await json("POST", "/v1/commands", body: body)
    }
    public func acknowledge(commandID: String, status: String, result: [String: CompanionJSON] = [:], message: String? = nil) async throws {
        try Self.validateID(commandID)
        guard ["applied", "rejected", "unknown"].contains(status) else { throw CompanionBoundaryError("invalid_status", "Invalid command receipt status.") }
        var body: [String: CompanionJSON] = ["request_id": .string(commandID), "status": .string(status), "result": .object(result)]
        if let message { body["message"] = .string(String(message.prefix(512))) }
        let _: CompanionJSON = try await json("POST", "/v1/commands/\(commandID)/receipt", body: body)
    }
    public func publishState(_ state: [String: CompanionJSON]) async throws {
        var value = state; value["request_id"] = .string(UUID().uuidString)
        let _: CompanionJSON = try await json("POST", "/v1/state", body: value)
    }
    public func diagnostics() async throws -> [String: CompanionJSON] { try await json("GET", "/v1/diagnostics") }
    public func trustedMacs() async throws -> [CompanionTrust] {
        struct List: Decodable { let items: [CompanionTrust] }
        let result: List = try await json("GET", "/v1/trust")
        guard result.items.count <= 8 else { throw CompanionBoundaryError("invalid_trust", "Companion trust list exceeds its limit.") }
        return result.items
    }
    public func revoke(trustID: String) async throws {
        try Self.validateID(trustID)
        let _: CompanionJSON = try await json("DELETE", "/v1/trust/\(trustID)")
    }
    public func icon(hash: String) async throws -> Data {
        try Self.validateHash(hash)
        let (data, _) = try await raw("GET", "/v1/icons/\(hash).png", limit: 262_144, expectedMIME: "image/png")
        guard Self.sha256(data) == hash, data.count >= 24, Array(data.prefix(8)) == [137,80,78,71,13,10,26,10] else { throw CompanionBoundaryError("invalid_icon", "Companion icon integrity check failed.") }
        let width = data[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let height = data[20..<24].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard (1...512).contains(width), (1...512).contains(height) else { throw CompanionBoundaryError("invalid_icon", "Companion icon dimensions exceed the limit.") }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetStatus(source) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.width == Int(width), image.height == Int(height) else { throw CompanionBoundaryError("invalid_icon", "Companion icon is not a complete valid PNG.") }
        return data
    }
    public func beginTransfer(_ transfer: CompanionTransfer, requestID: UUID = UUID()) async throws -> CompanionTransferStatus {
        try Self.validateID(transfer.transferId); try Self.validateHash(transfer.sha256)
        guard (0...52_428_800).contains(transfer.size), transfer.displayName.utf8.count <= 255, !transfer.displayName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              transfer.mimeType.utf8.count <= 128, transfer.mimeType.range(of: "^[A-Za-z0-9!#$&^_.+-]+/[A-Za-z0-9!#$&^_.+-]+$", options: .regularExpression) != nil, ["mac_to_phone", "phone_to_mac"].contains(transfer.direction) else {
            throw CompanionBoundaryError("invalid_transfer", "Companion transfer exceeds its size or metadata limit.")
        }
        let bytes = try encoder.encode(transfer)
        var body = try decoder.decode([String: CompanionJSON].self, from: bytes)
        body["request_id"] = .string(requestID.uuidString)
        return try await json("POST", "/v1/transfers", body: body)
    }
    public func transferStatus(id: String) async throws -> CompanionTransferStatus {
        try Self.validateID(id); return try await json("GET", "/v1/transfers/\(id)")
    }
    public func uploadChunk(id: String, index: Int, data: Data) async throws -> CompanionTransferStatus {
        try Self.validateID(id)
        guard index >= 0, index < 800, data.count <= Self.chunkLimit else { throw CompanionBoundaryError("invalid_chunk", "Invalid companion transfer chunk.") }
        let (bytes, responseID) = try await rawJSON("PUT", "/v1/transfers/\(id)/chunks/\(index)", body: data, headers: ["Content-Type": "application/octet-stream", "X-Chunk-SHA256": Self.sha256(data)], limit: Self.jsonLimit, timeout: 30)
        return try decodeEnvelope(CompanionTransferStatus.self, data: bytes, requestID: responseID)
    }
    public func downloadChunk(id: String, index: Int) async throws -> Data {
        try Self.validateID(id)
        guard index >= 0, index < 800 else { throw CompanionBoundaryError("invalid_chunk", "Invalid companion transfer chunk.") }
        let (data, response) = try await raw("GET", "/v1/transfers/\(id)/chunks/\(index)", limit: Self.chunkLimit, timeout: 30, expectedMIME: "application/octet-stream")
        guard response.value(forHTTPHeaderField: "X-Chunk-SHA256") == Self.sha256(data) else { throw CompanionBoundaryError("invalid_chunk", "Companion transfer chunk integrity check failed.") }
        return data
    }
    public func commitTransfer(id: String) async throws -> CompanionTransferStatus {
        try Self.validateID(id); return try await json("POST", "/v1/transfers/\(id)/commit", body: ["request_id": .string(UUID().uuidString)], timeout: 30)
    }
    /// The caller invokes this only after verifying the complete received file's
    /// size and SHA-256. This is a completion receipt, never optimistic progress.
    public func transferReceipt(id: String, acceptedBytes: Int64, sha256: String, status: String = "downloaded", requestID: UUID = UUID()) async throws -> CompanionTransferStatus {
        try Self.validateID(id); try Self.validateHash(sha256)
        guard status == "downloaded", (0...52_428_800).contains(acceptedBytes) else { throw CompanionBoundaryError("invalid_transfer", "Only a verified complete file may be acknowledged.") }
        return try await json("POST", "/v1/transfers/\(id)/receipt", body: ["request_id": .string(requestID.uuidString), "status": .string(status), "accepted_bytes": .number(Double(acceptedBytes)), "sha256": .string(sha256)])
    }
    public func cancelTransfer(id: String) async throws {
        try Self.validateID(id); let _: CompanionJSON = try await json("DELETE", "/v1/transfers/\(id)")
    }
    private func json<T: Decodable>(_ method: String, _ path: String, query: [String: String?] = [:], body: [String: CompanionJSON]? = nil, authenticated: Bool = true, authorization: String? = nil, timeout: Double = 5) async throws -> T {
        let data = try body.map { try encoder.encode($0) }
        guard data?.count ?? 0 <= Self.jsonLimit else { throw CompanionBoundaryError("payload_too_large", "Companion request exceeds its payload limit.") }
        let (bytes, responseID) = try await rawJSON(method, path, query: query, body: data, headers: ["Content-Type": "application/json"], authenticated: authenticated, authorization: authorization, limit: Self.jsonLimit, timeout: timeout)
        return try decodeEnvelope(T.self, data: bytes, requestID: responseID)
    }
    private func decodeEnvelope<T: Decodable>(_ type: T.Type, data: Data, requestID: String) throws -> T {
        try Self.validateJSON(data)
        let envelope = try decoder.decode(CompanionEnvelope<T>.self, from: data)
        guard envelope.protocolVersion == 1 else { throw CompanionBoundaryError("unsupported_protocol", "Unsupported companion response protocol.") }
        guard envelope.requestId == requestID else { throw CompanionBoundaryError("request_mismatch", "Companion response does not match this request.") }
        if let error = envelope.error { throw CompanionBoundaryError(error.code, error.message, retryable: error.retryable ?? false) }
        guard let result = envelope.data else { throw CompanionBoundaryError("invalid_response", "Companion response omitted its data.") }
        return result
    }
    private func rawJSON(_ method: String, _ path: String, query: [String: String?] = [:], body: Data? = nil, headers: [String: String] = [:], authenticated: Bool = true, authorization: String? = nil, limit: Int, timeout: Double = 5) async throws -> (Data, String) {
        let requestID: String
        if let body, let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let id = object["request_id"] as? String { try Self.validateID(id); requestID = id } else { requestID = UUID().uuidString }
        let (data, _) = try await raw(method, path, query: query, body: body, headers: headers, authenticated: authenticated, authorization: authorization, limit: limit, timeout: timeout, requestID: requestID)
        return (data, requestID)
    }
    private func raw(_ method: String, _ path: String, query: [String: String?] = [:], body: Data? = nil, headers: [String: String] = [:], authenticated: Bool = true, authorization: String? = nil, limit: Int, timeout: Double = 5, expectedMIME: String = "application/json", requestID: String = UUID().uuidString) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = query.sorted { $0.key < $1.key }.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        var request = URLRequest(url: components.url!); request.httpMethod = method; request.httpBody = body
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(requestID, forHTTPHeaderField: "X-Request-ID")
        request.setValue("close", forHTTPHeaderField: "Connection")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        else if authenticated {
            guard let credential else { throw CompanionBoundaryError("not_paired", "Pair this Mac with the phone first.") }
            try Self.validateSecret(credential)
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        }
        let (bytes, response) = try await CompanionBoundedRequest.run(request, limit: limit, serverPin: serverPin)
        guard (200...299).contains(response.statusCode) else {
            try Self.validateJSON(bytes)
            if let failure = try? decoder.decode(CompanionEnvelope<CompanionJSON>.self, from: bytes) {
                guard failure.protocolVersion == 1 else { throw CompanionBoundaryError("unsupported_protocol", "Unsupported companion response protocol.") }
                guard failure.requestId == requestID else { throw CompanionBoundaryError("request_mismatch", "Companion response does not match this request.") }
                if let error = failure.error {
                throw CompanionBoundaryError(error.code, String(error.message.prefix(512)), retryable: error.retryable ?? false)
                }
            }
            throw CompanionBoundaryError("http_\(response.statusCode)", "Companion request failed (HTTP \(response.statusCode)).", retryable: response.statusCode >= 500)
        }
        guard response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == expectedMIME else { throw CompanionBoundaryError("invalid_mime", "Companion response content type is invalid.") }
        return (bytes, response)
    }
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func validateServerPin(_ value: String) throws {
        guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CompanionBoundaryError("invalid_server_pin", "The phone server identity is invalid. Scan a new pairing link.") }
    }
    public static func validateSecret(_ value: String) throws {
        guard value.utf8.count == 43, value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { throw CompanionBoundaryError("invalid_secret", "Invalid companion pairing credential.") }
    }
    private static func validateID(_ value: String) throws { guard UUID(uuidString: value) != nil else { throw CompanionBoundaryError("invalid_id", "Invalid companion identifier.") } }
    private static func validateHash(_ value: String) throws { guard value.utf8.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CompanionBoundaryError("invalid_hash", "Invalid companion content hash.") } }
    private static func validateApp(_ app: CompanionApp) throws {
        try validatePackage(app.packageName)
        guard app.label.utf8.count <= 256, app.activityName?.utf8.count ?? 0 <= 512 else { throw CompanionBoundaryError("invalid_app", "Companion application metadata is invalid.") }
        if let hash = app.iconSha256 { try validateHash(hash) }
    }
    private func validatePairing(_ value: CompanionPairing) throws {
        guard ["pending", "approved", "denied", "expired"].contains(value.status) else { throw CompanionBoundaryError("invalid_pairing", "Invalid companion pairing status.") }
        if let id = value.pairingId { try Self.validateID(id) }
        if value.status == "approved" {
            guard let credential = value.credential, let trust = value.trustId, let device = value.deviceId else { throw CompanionBoundaryError("invalid_pairing", "Approved pairing omitted its identity.") }
            try Self.validateSecret(credential); try Self.validateID(trust); try Self.validateID(device)
            if let expectedDeviceID, UUID(uuidString: device) != expectedDeviceID { throw CompanionBoundaryError("identity_changed", "Pairing was approved by another device.") }
        }
    }
    private static func validatePackage(_ value: String) throws {
        guard value.utf8.count <= 255, value.range(of: "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$", options: .regularExpression) != nil else { throw CompanionBoundaryError("invalid_app", "Companion application identity is invalid.") }
    }
    private static func validateJSON(_ data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else { throw CompanionBoundaryError("invalid_json", "Companion JSON is not valid UTF-8.") }
        var depth = 0, quoted = false, escaped = false
        for byte in data {
            if quoted { if escaped { escaped = false } else if byte == 92 { escaped = true } else if byte == 34 { quoted = false }; continue }
            if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; if depth > 24 { throw CompanionBoundaryError("invalid_json", "Companion JSON nesting exceeds the limit.") } }
            else if byte == 125 || byte == 93 { depth -= 1 }
        }
    }
    private static func validateCommand(_ kind: String, _ payload: [String: CompanionJSON]) throws {
        func text(_ key: String, _ limit: Int) throws -> String {
            guard let value = payload[key]?.string, value.utf8.count <= limit else { throw CompanionBoundaryError("invalid_command", "Companion command payload is invalid.") }; return value
        }
        switch kind {
        case "clipboard_text", "share_text": _ = try text("text", 65_536)
        case "share_url":
            let value = try text("url", 8192)
            guard let url = URLComponents(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw CompanionBoundaryError("invalid_command", "Only HTTP and HTTPS links can be shared.") }
        case "notification_reply": _ = try text("text", 4096); fallthrough
        case "dismiss_notification": _ = try text("notification_key", 1024); _ = try text("action_id", 128)
        case "set_profile": guard ["balanced", "responsive", "battery"].contains(try text("profile", 32)) else { throw CompanionBoundaryError("invalid_command", "Invalid performance profile.") }
        case "set_export": try validatePackage(try text("package_name", 255)); guard payload["selected"]?.bool != nil else { throw CompanionBoundaryError("invalid_command", "Export choice must be true or false.") }
        case "open_app": try validatePackage(try text("package_name", 255))
        case "stop_session": try validateID(try text("session_id", 36))
        case "set_audio_route": guard ["mac", "phone", "mac_and_phone"].contains(try text("route", 32)) else { throw CompanionBoundaryError("invalid_command", "Invalid audio route.") }
        default: break
        }
    }
    private static let commandKinds: Set<String> = ["open_app", "stop_session", "set_audio_route", "set_profile", "clipboard_text", "share_text", "share_url", "notification_reply", "dismiss_notification", "forget_mac", "diagnostics_request", "set_export", "notification_preferences"]
}

private struct CompanionRemoteError: Decodable { let code: String; let message: String; let retryable: Bool? }
private struct CompanionEnvelope<T: Decodable>: Decodable {
    let protocolVersion: Int; let requestId: String; let data: T?; let error: CompanionRemoteError?
    enum CodingKeys: String, CodingKey { case protocolVersion = "protocol", requestId, data, error }
}

/// Enforces the byte cap as data arrives, instead of allocating an unbounded URLSession response.
private final class CompanionBoundedRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var bytes = Data()
    private let limit: Int
    private let serverPin: String
    private let expectedHost: String
    private let expectedPort: Int
    private var serverAuthenticated = false
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var failure: Error?
    private var session: URLSession?
    private let stateLock = NSLock()
    private var cancelled = false
    init(limit: Int, serverPin: String, url: URL) { self.limit = limit; self.serverPin = serverPin; expectedHost = url.host!; expectedPort = url.port! }
    static func run(_ request: URLRequest, limit: Int, serverPin: String) async throws -> (Data, HTTPURLResponse) {
        let operation = CompanionBoundedRequest(limit: limit, serverPin: serverPin, url: request.url!)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
                config.tlsMinimumSupportedProtocolVersion = .TLSv12
                config.connectionProxyDictionary = [:]; config.timeoutIntervalForResource = request.timeoutInterval
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: operation, delegateQueue: queue)
                operation.stateLock.lock()
                if operation.cancelled {
                    operation.stateLock.unlock(); session.invalidateAndCancel(); continuation.resume(throwing: CancellationError()); return
                }
                operation.continuation = continuation; operation.session = session
                let task = session.dataTask(with: request)
                operation.stateLock.unlock(); task.resume()
            }
        }, onCancel: {
            operation.stateLock.lock(); operation.cancelled = true
            let session = operation.session; operation.stateLock.unlock()
            session?.invalidateAndCancel()
        })
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if failure != nil { completionHandler(.cancelAuthenticationChallenge, nil); return }
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.host == expectedHost, space.port == expectedPort,
              let trust = space.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], (1...4).contains(chain.count),
              let leaf = chain.first else {
            failure = CompanionBoundaryError("server_authentication_failed", "The phone's TLS identity could not be verified.")
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        guard CompanionClient.sha256(SecCertificateCopyData(leaf) as Data) == serverPin else {
            failure = CompanionBoundaryError("server_pin_mismatch", "The phone server identity changed. No pairing secret or credential was sent.")
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        // A pinned private leaf is the sole anchor. System CAs and hostname
        // exceptions cannot substitute a different certificate for this phone.
        var trustError: CFError?
        guard SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, expectedHost as CFString)) == errSecSuccess,
              SecTrustEvaluateWithError(trust, &trustError) else {
            failure = CompanionBoundaryError("server_authentication_failed", "The pinned phone certificate is invalid or expired (trust code \(trustError.map { CFErrorGetCode($0) } ?? 0)).")
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        serverAuthenticated = true
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        failure = CompanionBoundaryError("redirect_refused", "Companion redirects are not permitted."); completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard serverAuthenticated else { failure = CompanionBoundaryError("server_authentication_failed", "Companion TLS authentication did not complete."); completionHandler(.cancel); return }
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= Int64(limit) else {
            failure = CompanionBoundaryError("response_too_large", "Companion response exceeds its payload limit."); completionHandler(.cancel); return
        }
        guard http.allHeaderFields.reduce(0, { $0 + String(describing: $1.key).utf8.count + String(describing: $1.value).utf8.count + 4 }) <= 16_384 else {
            failure = CompanionBoundaryError("response_too_large", "Companion response headers exceed their limit."); completionHandler(.cancel); return
        }
        self.response = http; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= limit - bytes.count else { failure = CompanionBoundaryError("response_too_large", "Companion response exceeds its payload limit."); dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        stateLock.lock()
        let continuation = self.continuation; self.continuation = nil; self.session = nil
        let wasCancelled = cancelled; stateLock.unlock()
        session.finishTasksAndInvalidate()
        if wasCancelled { continuation?.resume(throwing: CancellationError()) }
        else if let error = failure ?? error {
            if !serverAuthenticated, failure == nil { continuation?.resume(throwing: CompanionBoundaryError("server_authentication_failed", "The phone did not establish an authenticated TLS connection (transport code \((error as NSError).code)).")) }
            else { continuation?.resume(throwing: error) }
        }
        else if let response { continuation?.resume(returning: (bytes, response)) }
        else { continuation?.resume(throwing: CompanionBoundaryError("invalid_response", "Companion did not return an HTTP response.")) }
    }
}
