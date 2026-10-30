import Foundation

/// User-requested installer metadata only. No phone content, credentials or
/// device identifiers enter this public GitHub request.
public struct CompanionReleaseMetadata: Codable, Sendable, Equatable {
    public static let currentVersion = "0.2.0"
    public static var manifestURL: URL { URL(string: "https://github.com/SloopWorks/DroidBridge/releases/download/v\(currentVersion)/release-manifest.json")! }
    public let version: String
    public let architecture: String
    public let minimumMacOS: String
    public let sizeBytes: Int64
    public let sha256: String
    public let signing: String
    public let downloadURL: String
    public let releaseURL: String
    enum CodingKeys: String, CodingKey {
        case version, architecture, sha256, signing
        case minimumMacOS = "minimum_macos", sizeBytes = "size_bytes", downloadURL = "download_url", releaseURL = "release_url"
    }
    public func validate() throws {
        guard version == Self.currentVersion, architecture == "arm64", minimumMacOS == "26.0",
              sizeBytes > 0, sizeBytes <= 268_435_456,
              sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              signing == "ad_hoc_not_notarized",
              downloadURL == "https://github.com/SloopWorks/DroidBridge/releases/download/v\(version)/DroidBridge-\(version)-arm64.dmg",
              releaseURL == "https://github.com/SloopWorks/DroidBridge/releases/tag/v\(version)" else {
            throw CompanionBoundaryError("invalid_release_metadata", "Official installer metadata did not match this release's version, platform or URL policy.")
        }
    }
    public static func fetch() async throws -> Self {
        let bytes = try await CompanionReleaseRequest.fetch(manifestURL)
        return try decode(bytes)
    }
    /// Release manifests are bounded, flat JSON objects. Reject duplicate keys
    /// before Foundation's decoder can silently choose one of their values.
    public static func decode(_ bytes: Data) throws -> Self {
        guard bytes.count <= 16_384, String(data: bytes, encoding: .utf8) != nil else {
            throw CompanionBoundaryError("invalid_release_metadata", "Release metadata exceeds its byte limit or is not valid UTF-8.")
        }
        let source = Array(bytes)
        var index = 0, depth = 0, keys = Set<String>()
        while index < source.count {
            let byte = source[index]
            if byte == 34 {
                let start = index; index += 1
                var escaped = false
                while index < source.count {
                    let value = source[index]; index += 1
                    if escaped { escaped = false }
                    else if value == 92 { escaped = true }
                    else if value == 34 { break }
                }
                var next = index
                while next < source.count && [9, 10, 13, 32].contains(source[next]) { next += 1 }
                if next < source.count && source[next] == 58 {
                    let key = try JSONDecoder().decode(String.self, from: Data(source[start..<index]))
                    guard keys.insert(key).inserted else { throw CompanionBoundaryError("invalid_release_metadata", "Release metadata contains a duplicate key.") }
                }
                continue
            }
            if byte == 123 { depth += 1 }
            else if byte == 125 { depth -= 1 }
            guard depth >= 0, depth <= 1, byte != 91, byte != 93 else {
                throw CompanionBoundaryError("invalid_release_metadata", "Release metadata must be a flat JSON object.")
            }
            index += 1
        }
        let metadata = try JSONDecoder().decode(Self.self, from: bytes)
        try metadata.validate(); return metadata
    }
    public var brokerPayload: [String: CompanionJSON] {
        ["version": .string(version), "architecture": .string(architecture), "minimum_macos": .string(minimumMacOS),
         "size_bytes": .number(Double(sizeBytes)), "sha256": .string(sha256), "signing": .string(signing),
         "download_url": .string(downloadURL), "release_url": .string(releaseURL),
         "installation": .string("Download on your Apple Silicon Mac running macOS 26 or later. Verify SHA-256, open the DMG and copy DroidBridge to Applications. This release is ad-hoc signed and not notarized; macOS may require explicit approval. The phone cannot install or approve Mac software. Nothing runs automatically.")]
    }
}

private final class CompanionReleaseRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var cancelled = false
    private var bytes = Data()
    private var failure: Error?
    private var redirects = 0
    private let maximumBytes = 16_384
    static func fetch(_ url: URL) async throws -> Data {
        let operation = CompanionReleaseRequest()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
                configuration.urlCredentialStorage = nil; configuration.urlCache = nil
                configuration.timeoutIntervalForResource = 10
                configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: configuration, delegate: operation, delegateQueue: queue)
                operation.lock.lock()
                if operation.cancelled { operation.lock.unlock(); session.invalidateAndCancel(); continuation.resume(throwing: CancellationError()); return }
                operation.continuation = continuation; operation.session = session
                operation.lock.unlock()
                var request = URLRequest(url: url, timeoutInterval: 10)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                session.dataTask(with: request).resume()
            }
        }, onCancel: {
            operation.lock.lock(); operation.cancelled = true; let session = operation.session; operation.lock.unlock()
            session?.invalidateAndCancel()
        })
    }
    private func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host ?? "")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, allowed(request.url) else { failure = CompanionBoundaryError("unsafe_release_redirect", "The official release redirected outside its approved HTTPS download hosts."); completionHandler(nil); return }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, allowed(response.url), response.expectedContentLength <= Int64(maximumBytes) else {
            failure = CompanionBoundaryError("release_metadata_unavailable", "This version's official installer metadata is unavailable. No download or installation was started.")
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= maximumBytes - bytes.count else { failure = CompanionBoundaryError("release_metadata_too_large", "Official release metadata exceeds its size limit."); dataTask.cancel(); return }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let continuation = self.continuation; self.continuation = nil; self.session = nil; let cancelled = self.cancelled; lock.unlock()
        session.finishTasksAndInvalidate()
        if cancelled { continuation?.resume(throwing: CancellationError()) }
        else if let error = failure ?? error { continuation?.resume(throwing: error) }
        else { continuation?.resume(returning: bytes) }
    }
}
