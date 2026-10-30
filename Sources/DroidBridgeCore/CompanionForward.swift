import Foundation
import Darwin

/// The broker owns the lease and exact forward for its entire connection lifetime.
public actor CompanionForward {
    public nonisolated let baseURL: URL
    public nonisolated let serial: String
    public nonisolated let port: UInt16
    private let adbPath: String
    private var lease: ScrcpyPortLease?
    private var closing: Task<Void, Error>?
    private var establishment: Task<Void, Error>?
    private let receipt: URL
    private init(serial: String, adbPath: String, lease: ScrcpyPortLease, receipt: URL) {
        self.serial = serial; self.adbPath = adbPath; self.lease = lease; self.port = lease.port; self.receipt = receipt
        baseURL = URL(string: "https://127.0.0.1:\(lease.port)")!
    }
    /// Reserve ownership before the first ADB side effect. The caller must keep
    /// this handle until establish and exact close have both completed.
    public static func reserve(serial: String, adbPath: String) throws -> CompanionForward {
        try validateSerial(serial)
        guard FileManager.default.isExecutableFile(atPath: adbPath) else { throw CompanionBoundaryError("adb_unavailable", "ADB is unavailable.") }
        let lease = try ScrcpyPortLease.acquire()
        let directory = try receiptDirectory()
        guard try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).count < 128 else { throw CompanionBoundaryError("forward_capacity", "Companion forward recovery must finish before another connection can start.") }
        let receipt = directory.appendingPathComponent(UUID().uuidString + ".json")
        let record = ForwardReceipt(owner: getpid(), serial: serial, port: lease.port)
        try JSONEncoder().encode(record).write(to: receipt, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
        return CompanionForward(serial: serial, adbPath: adbPath, lease: lease, receipt: receipt)
    }
    public func establish() async throws {
        if let establishment { return try await establishment.value }
        guard lease != nil, closing == nil else { throw CompanionBoundaryError("forward_closed", "This connection was closed before it could start.") }
        try Task.checkCancellation()
        let task = Task {
            _ = try await ProcessRunner.run(adbPath, arguments: ["-s", serial, "forward", "--no-rebind", "tcp:\(port)", "tcp:37841"], timeout: 5)
        }
        establishment = task
        try await task.value
        try Task.checkCancellation()
    }
    public func close() async throws {
        if let closing { return try await closing.value }
        guard lease != nil else { return }
        let task = Task {
            // Cancellation can race a command that already allocated a forward.
            // Always wait for that exact allocation before removing its tuple.
            if let establishment { _ = try? await establishment.value }
            try await Self.removeExact(adbPath: adbPath, record: ForwardReceipt(owner: getpid(), serial: serial, port: port))
            do { try FileManager.default.removeItem(at: receipt) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
            lease = nil
        }
        closing = task
        do { try await task.value; closing = nil }
        catch { closing = nil; throw error }
    }
    public static func recoverAbandoned(adbPath: String) async throws {
        let directory = try receiptDirectory()
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.prefix(128)
        for file in files {
            var metadata = stat()
            guard lstat(file.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_uid == getuid(), metadata.st_size <= 4096,
                  let record = try? JSONDecoder().decode(ForwardReceipt.self, from: Data(contentsOf: file)),
                  record.owner > 1, (46000...46063).contains(record.port),
                  (try? validateSerial(record.serial)) != nil else { continue }
            if kill(record.owner, 0) == 0 || errno != ESRCH { continue }
            // A live successor holding this port prevents abandoned-owner cleanup.
            let lockPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DroidBridge/StreamPorts.noindex/\(record.port).lock").path
            let descriptor = Darwin.open(lockPath, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
            guard descriptor >= 0 else { continue }
            defer { Darwin.close(descriptor) }
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { continue }
            defer { flock(descriptor, LOCK_UN) }
            try await removeExact(adbPath: adbPath, record: record)
            try FileManager.default.removeItem(at: file)
        }
    }
    private static func removeExact(adbPath: String, record: ForwardReceipt) async throws {
        let listing = try await ProcessRunner.run(adbPath, arguments: ["forward", "--list"], timeout: 5)
        let local = "tcp:\(record.port)"
        let matching = listing.output.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }.filter { $0.count == 3 && $0[1] == local }
        guard matching.contains([record.serial, local, "tcp:37841"]) else { return }
        _ = try await ProcessRunner.run(adbPath, arguments: ["-s", record.serial, "forward", "--remove", local], timeout: 5)
    }
    private static func receiptDirectory() throws -> URL {
        let directory = CompanionQAScope.current?.root.appendingPathComponent("CompanionForwards.noindex") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DroidBridge/CompanionForwards.noindex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else { throw CompanionBoundaryError("unsafe_storage", "Companion forward storage must be private and owned by this user.") }
        return directory
    }
    private static func validateSerial(_ serial: String) throws {
        guard serial.utf8.count <= 255, serial.range(of: "^[A-Za-z0-9_.:\\[\\]%-]+$", options: .regularExpression) != nil, !serial.hasPrefix("-") else { throw CompanionBoundaryError("invalid_serial", "Invalid Android transport identity.") }
    }
    private struct ForwardReceipt: Codable { let owner: Int32; let serial: String; let port: UInt16 }
}
