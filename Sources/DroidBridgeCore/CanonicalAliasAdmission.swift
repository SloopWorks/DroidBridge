import Foundation
import Darwin
import CryptoKit

/// Local authenticated alias metadata only. No companion request is made on the
/// launch path. A shared descriptor pins the chosen transport through teardown.
public final class CanonicalAliasLease: @unchecked Sendable {
    private let descriptor: Int32
    public let identity: String
    public let serial: String
    public let lockURL: URL
    public let gateURL: URL
    fileprivate init(descriptor: Int32, identity: String, serial: String, lockURL: URL, gateURL: URL) { self.descriptor = descriptor; self.identity = identity; self.serial = serial; self.lockURL = lockURL; self.gateURL = gateURL }
    public var supervisorArguments: [String] { ["--alias-lock", lockURL.path, "--alias-gate", gateURL.path, "--alias-serial", serial] }
    deinit { close(descriptor) }
}
public enum CanonicalAliasAdmission {
    private struct Fingerprint: Equatable {
        let inode: UInt64; let size: Int64; let seconds: Int; let nanoseconds: Int; let mode: UInt16; let uid: UInt32
    }
    private static let cacheLock = NSLock()
    private static var cache: [String: (Fingerprint, CompanionExportPolicy.Document)] = [:]
    private static func document(_ paths: ManagedAppsPaths) throws -> CompanionExportPolicy.Document {
        let url = CompanionExportPolicy.url(paths: paths)
        var st = stat()
        if lstat(url.path, &st) != 0 {
            if errno == ENOENT { return CompanionExportPolicy.Document() }
            return try CompanionExportPolicy.read(url)
        }
        let fingerprint = Fingerprint(inode: st.st_ino, size: st.st_size, seconds: st.st_mtimespec.tv_sec, nanoseconds: st.st_mtimespec.tv_nsec, mode: st.st_mode, uid: st.st_uid)
        cacheLock.lock()
        if let entry = cache[url.path], entry.0 == fingerprint { cacheLock.unlock(); return entry.1 }
        cacheLock.unlock()
        let document = try CompanionExportPolicy.read(url)
        cacheLock.lock()
        if cache.count >= 8 { cache.removeAll() }
        cache[url.path] = (fingerprint, document); cacheLock.unlock()
        return document
    }
    static func serialIdentity(_ serial: String) -> String {
        var bytes = Array(SHA256.hash(data: Data(("DroidBridge standalone transport v1:" + serial).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        let text = bytes.map { String(format: "%02x", $0) }.joined()
        return String(text.prefix(8)) + "-" + String(text.dropFirst(8).prefix(4)) + "-" + String(text.dropFirst(12).prefix(4)) + "-" + String(text.dropFirst(16).prefix(4)) + "-" + String(text.dropFirst(20))
    }
    public static func identity(for serial: String, paths: ManagedAppsPaths = .userDefault) throws -> String? {
        try AndroidDiscovery.validateSerial(serial)
        let document = try document(paths)
        for (id, device) in document.devices where device.aliases.contains(serial) { return device.captureIdentity ?? id }
        return nil
    }
    public static func groups(paths: ManagedAppsPaths = .userDefault) throws -> [String: [String]] {
        let document = try document(paths)
        var result: [String: [String]] = [:]
        for (id, device) in document.devices { result[device.captureIdentity ?? id, default: []] += device.aliases }
        return result.mapValues { Array(Set($0)).sorted() }
    }
    static func directory(_ paths: ManagedAppsPaths) -> URL { paths.privateRoot.appendingPathComponent("AliasCapture.noindex", isDirectory: true) }
    static func lockURL(_ identity: String, paths: ManagedAppsPaths) -> URL { directory(paths).appendingPathComponent(identity.lowercased() + ".lock") }
    static func file(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CompanionBoundaryError("alias_storage_unavailable", "The shared phone connection lock is unavailable.") }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600 else { close(fd); throw CompanionBoundaryError("unsafe_alias_storage", "The shared phone connection lock has unsafe ownership.") }
        return fd
    }
    /// Catalog callers already own their catalog lock. Stream callers never take
    /// that lock, preserving a single catalog -> alias-gate lock order.
    static func withPolicyFence<T>(paths: ManagedAppsPaths, _ operation: () throws -> T) throws -> T {
        try CompanionBrokerIPC.prepareDirectory(directory(paths))
        let gate = try file(directory(paths).appendingPathComponent("gate.lock")); defer { close(gate) }
        while flock(gate, LOCK_EX) != 0 { if errno != EINTR { throw CompanionBoundaryError("alias_gate_unavailable", "The phone connection policy lock is unavailable.") } }
        defer { flock(gate, LOCK_UN) }
        return try operation()
    }
    static func requireDrained(_ identities: Set<String>, paths: ManagedAppsPaths) throws {
        var descriptors: [Int32] = []; defer { descriptors.forEach { close($0) } }
        for identity in identities.sorted() {
            let fd = try file(lockURL(identity, paths: paths)); descriptors.append(fd)
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CompanionBoundaryError("transport_in_use", "Close all app windows and audio sessions on this phone before changing its connection identity.", retryable: true) }
        }
    }
    public static func acquire(serial: String, paths: ManagedAppsPaths = .userDefault) async throws -> CanonicalAliasLease? {
        try AndroidDiscovery.validateSerial(serial)
        // Standalone transports also pin a local deterministic lease. First
        // pairing must drain them before canonical identity can replace it.
        _ = try identity(for: serial, paths: paths)
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) {
            try withPolicyFence(paths: paths) {
                let identity = try identity(for: serial, paths: paths) ?? serialIdentity(serial)
                let url = lockURL(identity, paths: paths), fd = try file(url)
                do {
                    if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                        let bytes = Array(serial.utf8)
                        guard ftruncate(fd, 0) == 0, pwrite(fd, bytes, bytes.count, 0) == bytes.count, flock(fd, LOCK_SH) == 0 else { throw CompanionBoundaryError("alias_storage_unavailable", "Cannot pin this phone connection.") }
                    } else {
                        guard errno == EWOULDBLOCK || errno == EAGAIN, flock(fd, LOCK_SH | LOCK_NB) == 0 else { throw CompanionBoundaryError("alias_gate_unavailable", "Cannot inspect the active phone connection.") }
                        var bytes = [UInt8](repeating: 0, count: 256)
                        let count = pread(fd, &bytes, bytes.count, 0)
                        guard count == serial.utf8.count, Array(bytes.prefix(max(0, count))) == Array(serial.utf8) else { throw CompanionBoundaryError("transport_in_use", "This phone already has Mac apps or audio on another USB/Wi-Fi connection. Close those sessions before switching connections.", retryable: true) }
                    }
                    return CanonicalAliasLease(descriptor: fd, identity: identity, serial: serial, lockURL: url, gateURL: directory(paths).appendingPathComponent("gate.lock"))
                } catch { close(fd); throw error }
            }
        }.value
    }
    public static func audioKey(for serial: String, paths: ManagedAppsPaths = .userDefault) throws -> String {
        let key = try identity(for: serial, paths: paths) ?? serial
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
