import Foundation
import CryptoKit
import Darwin

/// Presentation only. A record never grants authority to launch, control or terminate a process.
public struct DesktopAppProcess: Codable, Equatable, Sendable {
    public let owner: CompanionBrokerOwner
    public let bundleURL: URL
    public let bundleIdentifier: String
    public init(owner: CompanionBrokerOwner, bundleURL: URL, bundleIdentifier: String) {
        self.owner = owner; self.bundleURL = bundleURL; self.bundleIdentifier = bundleIdentifier
    }
    /// NSRunningApplication and Bundle may differ only in the URL directory hint.
    /// That URL spelling does not change the observed application identity.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.owner == rhs.owner && lhs.bundleIdentifier == rhs.bundleIdentifier &&
            lhs.bundleURL.standardizedFileURL.path == rhs.bundleURL.standardizedFileURL.path
    }
}

public struct DesktopAppSession: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case starting, running, stopping, stopped, failed, recovering, waitingForDevice
    }
    public let id: UUID
    public let name: String
    public let state: State
    /// Actual session backend; the snapshot backend remains the wrapper's launch identity.
    public let backend: BackendKind?
    public init(id: UUID, name: String, state: State, backend: BackendKind? = nil) {
        self.id = id; self.name = name; self.state = state; self.backend = backend
    }
}

public struct DesktopAppSessionSnapshot: Codable, Equatable, Sendable {
    public let process: DesktopAppProcess
    public let generation: UUID
    public let serial: String
    public let packageName: String
    public let backend: BackendKind
    public let sessions: [DesktopAppSession]
    public let updatedAt: Date
}

public struct DesktopAppSessionProducer: Sendable {
    public let process: DesktopAppProcess
    public let generation: UUID
    fileprivate let serial: String
    fileprivate let packageName: String
    fileprivate let backend: BackendKind
}

/// Synchronous file I/O: call from a detached task or another non-main executor.
/// Each application has one bounded snapshot; consumers supply the exact identity
/// obtained from NSRunningApplication and never enumerate untrusted registry files.
public struct DesktopAppSessionStore: Sendable {
    public let root: URL
    private static let maximumBytes = 65_536
    public init(root: URL? = nil) {
        self.root = root ?? (CompanionQAScope.current?.root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DroidBridge", isDirectory: true))
            .appendingPathComponent("DesktopAppSessions", isDirectory: true)
    }

    public func begin(process: DesktopAppProcess, serial: String, packageName: String, backend: BackendKind) throws -> DesktopAppSessionProducer {
        try validate(process)
        try AndroidDiscovery.validateSerial(serial); try AndroidDiscovery.validatePackage(packageName)
        guard process.owner == CompanionBrokerOwner.live(getpid()) else { throw failure("Only the current wrapper may publish its presentation.") }
        let producer = DesktopAppSessionProducer(process: process, generation: UUID(), serial: serial, packageName: packageName, backend: backend)
        try locked { directory in
            if let previous = try load(directory, process: process), previous.process.owner != process.owner, previous.process.owner.isAlive {
                throw failure("Another running wrapper already owns this presentation.")
            }
            try save(snapshot(producer, sessions: []), directory: directory)
        }
        return producer
    }

    /// Returns false for an obsolete producer. Late callbacks cannot overwrite a successor.
    @discardableResult public func publish(_ producer: DesktopAppSessionProducer, sessions: [DesktopAppSession]) throws -> Bool {
        guard producer.process.owner == CompanionBrokerOwner.live(getpid()) else { return false }
        let value = snapshot(producer, sessions: sessions)
        try validate(value)
        return try locked { directory in
            guard let current = try load(directory, process: producer.process), matches(current, producer) else { return false }
            try save(value, directory: directory); return true
        }
    }

    @discardableResult public func remove(_ producer: DesktopAppSessionProducer) throws -> Bool {
        guard producer.process.owner == CompanionBrokerOwner.live(getpid()) else { return false }
        return try locked { directory in
            guard let current = try load(directory, process: producer.process), matches(current, producer) else { return false }
            guard unlinkat(directory, filename(producer.process), 0) == 0 else { throw failure("Cannot remove wrapper presentation.") }
            return true
        }
    }

    /// A reused PID, different bundle URL/identifier or exited process cannot match.
    public func read(expected: DesktopAppProcess) throws -> DesktopAppSessionSnapshot? {
        try validate(expected)
        guard expected.owner.isAlive else { return nil }
        return try locked { directory in
            guard let current = try load(directory, process: expected), current.process == expected, expected.owner.isAlive else { return nil }
            return current
        }
    }

    private func snapshot(_ producer: DesktopAppSessionProducer, sessions: [DesktopAppSession]) -> DesktopAppSessionSnapshot {
        .init(process: producer.process, generation: producer.generation, serial: producer.serial,
              packageName: producer.packageName, backend: producer.backend, sessions: sessions, updatedAt: Date())
    }
    private func matches(_ snapshot: DesktopAppSessionSnapshot, _ producer: DesktopAppSessionProducer) -> Bool {
        snapshot.process == producer.process && snapshot.generation == producer.generation
    }
    private func validate(_ process: DesktopAppProcess) throws {
        let path = process.bundleURL.path
        guard process.owner.pid > 0, process.owner.start > 0, process.bundleURL.isFileURL,
              path.hasPrefix("/"), path.utf8.count <= 2048, process.bundleURL.standardizedFileURL.path == path,
              process.bundleURL.pathExtension == "app", process.bundleIdentifier.utf8.count <= 255,
              process.bundleIdentifier.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]*$"#, options: .regularExpression) != nil else {
            throw failure("Invalid wrapper identity.")
        }
    }
    private func validate(_ snapshot: DesktopAppSessionSnapshot) throws {
        try validate(snapshot.process)
        try AndroidDiscovery.validateSerial(snapshot.serial); try AndroidDiscovery.validatePackage(snapshot.packageName)
        guard snapshot.sessions.count <= 32, Set(snapshot.sessions.map(\.id)).count == snapshot.sessions.count,
              snapshot.sessions.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.utf8.count <= 512 && !$0.name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }),
              snapshot.updatedAt.timeIntervalSince1970.isFinite, snapshot.updatedAt.timeIntervalSince1970 > 0,
              snapshot.updatedAt.timeIntervalSinceNow <= 30 else { throw failure("Invalid wrapper session presentation.") }
    }
    private func filename(_ process: DesktopAppProcess) -> String {
        let identity = process.bundleURL.path + "\n" + process.bundleIdentifier
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func locked<T>(_ body: (Int32) throws -> T) throws -> T {
        try Task.checkCancellation()
        let directory = try openPrivateDirectory()
        defer { close(directory) }
        let lock = openat(directory, ".lock", O_RDWR | O_CREAT | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw failure("Cannot open wrapper presentation lock.") }
        defer { close(lock) }
        try validateFile(lock)
        let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
        try Task.checkCancellation()
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            try Task.checkCancellation()
            guard errno == EWOULDBLOCK || errno == EINTR,
                  DispatchTime.now().uptimeNanoseconds < deadline else {
                throw failure("Wrapper presentation is busy. Try again shortly.")
            }
            usleep(10_000)
        }
        defer { flock(lock, LOCK_UN) }
        return try body(directory)
    }

    /// Walk with descriptor-relative operations so a symlink or renamed parent
    /// cannot redirect publication outside the selected private storage root.
    private func openPrivateDirectory() throws -> Int32 {
        let path = root.path
        let components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard root.isFileURL, path.hasPrefix("/"), path.utf8.count <= 2048,
              !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw failure("Invalid wrapper presentation directory.")
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure("Cannot open wrapper presentation root.") }
        do {
            for (index, component) in components.enumerated() {
                if mkdirat(descriptor, component, 0o700) != 0 && errno != EEXIST { throw failure("Cannot create wrapper presentation directory.") }
                let child = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw failure("Wrapper presentation directories cannot be symbolic links.") }
                close(descriptor); descriptor = child
                if index == components.count - 1 {
                    var info = stat()
                    guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
                        throw failure("Wrapper presentation directory must be private to this user.")
                    }
                }
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }
    private func validateFile(_ descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_mode & 0o777 == 0o600, info.st_nlink == 1, info.st_size >= 0, info.st_size <= Self.maximumBytes else {
            throw failure("Unsafe or oversized wrapper presentation file.")
        }
    }
    private func load(_ directory: Int32, process: DesktopAppProcess) throws -> DesktopAppSessionSnapshot? {
        let descriptor = openat(directory, filename(process), O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw failure("Cannot read wrapper presentation.") }
        defer { close(descriptor) }
        try validateFile(descriptor)
        var bytes = [UInt8](repeating: 0, count: Self.maximumBytes + 1)
        var count = 0
        while count < bytes.count {
            let remaining = bytes.count - count
            let amount = bytes.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress!.advanced(by: count), remaining) }
            if amount < 0, errno == EINTR { continue }
            guard amount >= 0 else { throw failure("Cannot read wrapper presentation bytes.") }
            if amount == 0 { break }
            count += amount
        }
        guard count <= Self.maximumBytes else { throw failure("Wrapper presentation exceeds its size limit.") }
        let value = try JSONDecoder().decode(DesktopAppSessionSnapshot.self, from: Data(bytes.prefix(count)))
        try validate(value)
        guard filename(value.process) == filename(process) else { throw failure("Wrapper presentation identity does not match its file.") }
        return value
    }
    private func save(_ value: DesktopAppSessionSnapshot, directory: Int32) throws {
        try validate(value)
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= Self.maximumBytes else { throw failure("Wrapper presentation exceeds its size limit.") }
        let temporary = "." + UUID().uuidString + ".tmp"
        let descriptor = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw failure("Cannot create wrapper presentation.") }
        defer { close(descriptor); unlinkat(directory, temporary, 0) }
        var count = 0
        while count < bytes.count {
            let amount = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: count), bytes.count - count) }
            if amount < 0, errno == EINTR { continue }
            guard amount > 0 else { throw failure("Cannot write wrapper presentation.") }
            count += amount
        }
        guard fsync(descriptor) == 0, renameat(directory, temporary, directory, filename(value.process)) == 0 else {
            throw failure("Cannot publish wrapper presentation atomically.")
        }
    }
    private func failure(_ message: String) -> BridgeError { .message(message) }
}
