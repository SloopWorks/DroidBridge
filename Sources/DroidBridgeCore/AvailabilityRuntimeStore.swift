import Foundation
import CryptoKit
import Darwin

/// Immutable availability runtimes, bounded to eight retained generations.
/// A single install lease spans verification, retirement and LaunchAgent update.
public enum AvailabilityRuntimeStore {
    public static let maximumGenerations = 8
    public static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func identity(helper: URL, adb: URL) throws -> String {
        let bytes = try digest(helper) + digest(adb) + ADBPortableRuntime.inventory(adb: adb).identitySuffix
        return String(SHA256.hash(data: Data(bytes.utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
    }
    public static func lock(parent: URL) async throws -> AvailabilityRuntimeLease {
        try await Task.detached(priority: .utility) {
            try privateDirectory(parent)
            return try AvailabilityRuntimeLease.acquire(url: parent.deletingLastPathComponent().appendingPathComponent("install.lock"), exclusive: true, wait: 15)
        }.value
    }
    /// Called by new helpers for their full lifetime. Historical helpers are
    /// protected by exact-file lsof checks and the current LaunchAgent pin.
    public static func holdRunning(executable: URL) throws -> AvailabilityRuntimeLease? {
        let generation = executable.deletingLastPathComponent()
        guard validIdentity(generation.lastPathComponent), generation.deletingLastPathComponent().lastPathComponent == "generations" else { return nil }
        let leases = generation.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("leases")
        try privateDirectory(leases)
        return try AvailabilityRuntimeLease.acquire(url: leases.appendingPathComponent(generation.lastPathComponent + ".lock"), exclusive: false, wait: 0)
    }
    public typealias Verify = @Sendable (URL) async throws -> Void
    public typealias InUse = @Sendable ([URL]) async throws -> Bool
    public static func prepare(parent: URL, helper: URL, adb: URL, preservedGeneration: URL?) async throws -> URL {
        let runtime = try ADBPortableRuntime.inventory(adb: adb)
        try await runtime.verifyLoadClosure()
        return try await prepare(parent: parent, helper: helper, adb: adb, preservedGeneration: preservedGeneration, verify: { try await verifySignature($0) }, inUse: { try await referenced($0) })
    }
    static func prepare(parent: URL, helper: URL, adb: URL, preservedGeneration: URL?, verify: Verify, inUse: InUse) async throws -> URL {
        let helper = helper.resolvingSymlinksInPath(), adb = adb.resolvingSymlinksInPath()
        let identity = try await Task.detached { try Self.identity(helper: helper, adb: adb) }.value
        let destination = parent.appendingPathComponent(identity)
        let fm = FileManager.default
        try privateDirectory(parent)
        try await recoverCrashLeft(parent: parent, preservedGeneration: preservedGeneration, verify: verify, inUse: inUse)
        if fm.fileExists(atPath: destination.path) {
            try validateGeneration(destination, identity: identity)
            for file in files(destination) where file.lastPathComponent != ADBPortableRuntime.manifestName { try await verify(file) }
            return destination
        }
        let entries = try boundedEntries(parent, maximum: 128)
        // Crash-left retirement/staging directories count toward the bound too;
        // an unknown entry is preserved and cannot silently create extra room.
        var retained = entries.count
        if retained >= maximumGenerations {
            for candidate in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard retained >= maximumGenerations else { break }
                guard candidate.standardizedFileURL.path != preservedGeneration?.standardizedFileURL.path,
                      validIdentity(candidate.lastPathComponent) else { continue }
                do {
                    try validateGeneration(candidate, identity: candidate.lastPathComponent)
                    for file in files(candidate) where file.lastPathComponent != ADBPortableRuntime.manifestName { try await verify(file) }
                    let leases = parent.deletingLastPathComponent().appendingPathComponent("leases")
                    try privateDirectory(leases)
                    let retirementLease = try AvailabilityRuntimeLease.acquire(url: leases.appendingPathComponent(candidate.lastPathComponent + ".lock"), exclusive: true, wait: 0)
                    defer { withExtendedLifetime(retirementLease) {} }
                    guard try await !inUse(files(candidate)) else { continue }
                    let retirement = try StageJournal(transaction: UUID(), generation: candidate.lastPathComponent, helper: SourceFile(candidate.appendingPathComponent("DroidBridgeAvailability")), adb: SourceFile(candidate.appendingPathComponent("adb")), additional: extraSources(adb: candidate.appendingPathComponent("adb")), kind: "retire")
                    let retirementURL = try writeJournal(retirement, parent: parent)
                    let retired = parent.appendingPathComponent(retirement.recoveringLeaf)
                    try fm.moveItem(at: candidate, to: retired)
                    do {
                        // lsof resolves file identity after rename: a mapped
                        // executable remains a reference to these exact inodes.
                        guard try await !inUse(files(retired)) else {
                            try fm.moveItem(at: retired, to: candidate); try fm.removeItem(at: retirementURL); continue
                        }
                        try validateGeneration(retired, identity: candidate.lastPathComponent)
                        try fm.removeItem(at: retired); try fm.removeItem(at: retirementURL); retained -= 1
                    } catch {
                        if !fm.fileExists(atPath: candidate.path) { try? fm.moveItem(at: retired, to: candidate) }
                        if fm.fileExists(atPath: candidate.path), !fm.fileExists(atPath: retired.path) { try? fm.removeItem(at: retirementURL) }
                        throw error
                    }
                } catch { continue } // Unknown/signature/busy states preserve bytes.
            }
        }
        guard retained < maximumGenerations else { throw BridgeError.message("Availability runtime capacity is full. All eight generations are current, running, unverified or awaiting recovery; no runtime was removed.") }
        let transaction = UUID()
        let journal = try StageJournal(transaction: transaction, generation: identity, helper: SourceFile(helper), adb: SourceFile(adb), additional: extraSources(adb: adb))
        let journalURL = try writeJournal(journal, parent: parent)
        let stage = parent.appendingPathComponent(journal.stageLeaf)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try fm.copyItem(at: helper, to: stage.appendingPathComponent("DroidBridgeAvailability"))
            try fm.copyItem(at: adb, to: stage.appendingPathComponent("adb"))
            for extra in journal.additional ?? [] { try fm.copyItem(at: URL(fileURLWithPath: extra.source.path), to: stage.appendingPathComponent(extra.name)) }
            try validateGeneration(stage, identity: identity)
            for file in files(stage) where file.lastPathComponent != ADBPortableRuntime.manifestName { try await verify(file) }
            try fm.moveItem(at: stage, to: destination)
            try fm.removeItem(at: journalURL)
        } catch {
            // A failed copy is not unconditional deletion authority. Its exact
            // journal/source-prefix proof and process checks must still pass.
            try? await recoverStage(journal, journalURL: journalURL, parent: parent, inUse: inUse)
            throw error
        }
        return destination
    }
    private struct SourceFile: Codable {
        let path: String
        let sha256: String
        let size: Int64
        init(_ url: URL) throws {
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size > 0,
                  metadata.st_size <= 64 * 1_048_576 else { throw BridgeError.message("Availability source file cannot be bounded.") }
            path = url.path; sha256 = try digest(url); size = Int64(metadata.st_size)
        }
    }
    private struct NamedSource: Codable { let name: String; let source: SourceFile }
    private static func extraSources(adb: URL) throws -> [NamedSource] {
        let runtime = try ADBPortableRuntime.inventory(adb: adb)
        return try runtime.extraFiles.map { NamedSource(name: $0.name, source: try SourceFile(runtime.directory.appendingPathComponent($0.name))) }
    }
    private struct StageJournal: Codable {
        let version: Int
        let transaction: UUID
        let generation: String
        let helper: SourceFile
        let adb: SourceFile
        let kind: String?
        let additional: [NamedSource]?
        var sources: [(String, SourceFile)] { [("DroidBridgeAvailability", helper), ("adb", adb)] + (additional ?? []).map { ($0.name, $0.source) } }
        func files(in directory: URL) -> [URL] { sources.map { directory.appendingPathComponent($0.0) } }
        var operation: String { kind ?? "stage" }
        var stageLeaf: String { operation == "retire" ? generation : ".staging-" + transaction.uuidString }
        var recoveringLeaf: String { operation == "retire" ? ".retiring-" + generation + "-" + transaction.uuidString : ".recovering-stage-" + transaction.uuidString }
        init(transaction: UUID, generation: String, helper: SourceFile, adb: SourceFile, additional: [NamedSource] = [], kind: String = "stage") {
            version = 1; self.transaction = transaction; self.generation = generation; self.helper = helper; self.adb = adb; self.kind = kind; self.additional = additional.isEmpty ? nil : additional
        }
        func validate() throws {
            guard version == 1, validIdentity(generation), ["stage", "retire"].contains(operation) else { throw BridgeError.message("Availability staging receipt is invalid.") }
            let extras = additional ?? []
            guard extras.count < ADBPortableRuntime.maximumFiles,
                  Set(extras.map(\.name)).count == extras.count,
                  extras.allSatisfy({ $0.name == ADBPortableRuntime.manifestName || ($0.name != "adb" && ADBPortableRuntime.validName($0.name)) }),
                  extras.isEmpty || extras.filter({ $0.name == ADBPortableRuntime.manifestName }).count == 1 else { throw BridgeError.message("Availability staging dependency inventory is invalid.") }
            var total: Int64 = 0
            for (_, source) in sources {
                let validHash = source.sha256.utf8.count == 64 && source.sha256.utf8.allSatisfy { byte in (48...57).contains(byte) || (97...102).contains(byte) }
                guard source.path.hasPrefix("/"), source.path.utf8.count <= 4096, source.size > 0, source.size <= 67_108_864, validHash else { throw BridgeError.message("Availability staging receipt source is invalid.") }
                total += source.size
                guard total <= ADBPortableRuntime.maximumTotalBytes + ADBPortableRuntime.maximumFileBytes else { throw BridgeError.message("Availability staging bytes exceed their budget.") }
            }
            let suffix = extras.sorted { $0.name < $1.name }.map { "\n\($0.name):\($0.source.sha256):\($0.source.size)" }.joined()
            let hash = String(SHA256.hash(data: Data((helper.sha256 + adb.sha256 + suffix).utf8)).map { String(format: "%02x", $0) }.joined().prefix(32))
            guard hash == generation else { throw BridgeError.message("Availability staging identity is invalid.") }
        }
    }
    private static func boundedEntries(_ directory: URL, maximum: Int) throws -> [URL] {
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil, options: [.skipsSubdirectoryDescendants], errorHandler: { _, _ in false }) else { throw BridgeError.message("Availability storage cannot be enumerated.") }
        var result: [URL] = []
        for case let entry as URL in iterator {
            guard result.count < maximum else { throw BridgeError.message("Availability storage exceeds its bounded recovery capacity.") }
            result.append(entry)
        }
        return result
    }
    private static func writeJournal(_ journal: StageJournal, parent: URL) throws -> URL {
        try journal.validate()
        let directory = parent.deletingLastPathComponent().appendingPathComponent("transactions")
        try privateDirectory(directory)
        guard try boundedEntries(directory, maximum: 17).count < 16 else { throw BridgeError.message("Availability staging recovery must finish before another installation.") }
        let url = directory.appendingPathComponent(journal.transaction.uuidString + ".json")
        let data = try JSONEncoder().encode(journal)
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BridgeError.message("Availability staging receipt cannot be created.") }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw BridgeError.message("Availability staging receipt write failed.") }; offset += written
            }
        }
        guard fsync(fd) == 0 else { throw BridgeError.message("Availability staging receipt durability failed.") }
        let directoryFD = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryFD >= 0 else { throw BridgeError.message("Availability receipt directory cannot be synchronized.") }
        defer { Darwin.close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw BridgeError.message("Availability receipt directory durability failed.") }
        return url
    }
    static func recoverCrashLeft(parent: URL, preservedGeneration: URL?, verify: Verify, inUse: InUse) async throws {
        let fm = FileManager.default
        let transactions = parent.deletingLastPathComponent().appendingPathComponent("transactions")
        if fm.fileExists(atPath: transactions.path) {
            try privateDirectory(transactions)
            for url in try boundedEntries(transactions, maximum: 32) {
                do {
                    let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    guard fd >= 0 else { continue }; defer { Darwin.close(fd) }
                    var metadata = stat()
                    guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(),
                          metadata.st_mode & 0o077 == 0, metadata.st_size > 0, metadata.st_size <= 65_536 else { continue }
                    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                    let journal = try JSONDecoder().decode(StageJournal.self, from: handle.read(upToCount: 65_537) ?? Data())
                    try journal.validate()
                    guard url.lastPathComponent == journal.transaction.uuidString + ".json" else { continue }
                    if journal.operation == "retire" { try await recoverRetirement(journal, journalURL: url, parent: parent, preservedGeneration: preservedGeneration, verify: verify, inUse: inUse) }
                    else { try await recoverStage(journal, journalURL: url, parent: parent, inUse: inUse) }
                } catch { continue }
            }
        }
        for retired in try boundedEntries(parent, maximum: 128) {
            let name = retired.lastPathComponent, prefix = ".retiring-"
            guard name.hasPrefix(prefix), name.count == prefix.count + 32 + 1 + 36 else { continue }
            let generation = String(name.dropFirst(prefix.count).prefix(32))
            guard validIdentity(generation), UUID(uuidString: String(name.suffix(36))) != nil else { continue }
            do {
                try validateGeneration(retired, identity: generation)
                for file in files(retired) where file.lastPathComponent != ADBPortableRuntime.manifestName { try await verify(file) }
                let original = parent.appendingPathComponent(generation)
                if original.path == preservedGeneration?.standardizedFileURL.path {
                    if !fm.fileExists(atPath: original.path) { try fm.moveItem(at: retired, to: original) }
                    continue
                }
                let leases = parent.deletingLastPathComponent().appendingPathComponent("leases")
                try privateDirectory(leases)
                let lease = try AvailabilityRuntimeLease.acquire(url: leases.appendingPathComponent(generation + ".lock"), exclusive: true, wait: 0)
                defer { withExtendedLifetime(lease) {} }
                guard try await !inUse(files(retired)) else { continue }
                // Revalidate immediately before removal; the installer lease
                // excludes every cooperative producer while this proof is used.
                try validateGeneration(retired, identity: generation)
                guard try await !inUse(files(retired)) else { continue }
                try fm.removeItem(at: retired)
            } catch { continue }
        }
    }
    private static func recoverRetirement(_ journal: StageJournal, journalURL: URL, parent: URL, preservedGeneration: URL?, verify: Verify, inUse: InUse) async throws {
        let fm = FileManager.default, original = parent.appendingPathComponent(journal.stageLeaf), retired = parent.appendingPathComponent(journal.recoveringLeaf)
        guard fm.fileExists(atPath: retired.path) else { try fm.removeItem(at: journalURL); return }
        if original.path == preservedGeneration?.standardizedFileURL.path {
            if !fm.fileExists(atPath: original.path) {
                // A complete pinned generation can be restored. A partially
                // removed pinned generation remains visible for a later update.
                try validateGeneration(retired, identity: journal.generation)
                for file in files(retired) where file.lastPathComponent != ADBPortableRuntime.manifestName { try await verify(file) }
                try fm.moveItem(at: retired, to: original); try fm.removeItem(at: journalURL)
            }
            return
        }
        let leases = parent.deletingLastPathComponent().appendingPathComponent("leases")
        try privateDirectory(leases)
        let lease = try AvailabilityRuntimeLease.acquire(url: leases.appendingPathComponent(journal.generation + ".lock"), exclusive: true, wait: 0)
        defer { withExtendedLifetime(lease) {} }
        try validateRetirement(retired, journal: journal)
        var remaining = journal.files(in: retired).filter { fm.fileExists(atPath: $0.path) }
        for file in remaining where file.lastPathComponent != ADBPortableRuntime.manifestName { try await verify(file) }
        if !remaining.isEmpty, try await inUse(remaining) { throw BridgeError.message("Retired availability bytes are still in use.") }
        try validateRetirement(retired, journal: journal)
        remaining = journal.files(in: retired).filter { fm.fileExists(atPath: $0.path) }
        if !remaining.isEmpty, try await inUse(remaining) { throw BridgeError.message("Retired availability bytes remain mapped.") }
        try fm.removeItem(at: retired); try fm.removeItem(at: journalURL)
    }
    private static func validateRetirement(_ retired: URL, journal: StageJournal) throws {
        try validateDirectory(retired)
        guard Set(try boundedEntries(retired, maximum: ADBPortableRuntime.maximumFiles + 2).map(\.lastPathComponent)).isSubset(of: Set(journal.sources.map { $0.0 })) else { throw BridgeError.message("Retired availability directory contains unknown bytes.") }
        for (name, expected) in journal.sources {
            let file = retired.appendingPathComponent(name)
            var metadata = stat()
            if lstat(file.path, &metadata) != 0 { guard errno == ENOENT else { throw BridgeError.message("Retired availability file is unreadable.") }; continue }
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(), metadata.st_nlink == 1,
                  metadata.st_mode & 0o022 == 0, metadata.st_size == expected.size, try digest(file) == expected.sha256 else { throw BridgeError.message("Retired availability file no longer matches its ownership receipt.") }
        }
    }
    private static func recoverStage(_ journal: StageJournal, journalURL: URL, parent: URL, inUse: InUse) async throws {
        let fm = FileManager.default
        let paths = [parent.appendingPathComponent(journal.stageLeaf), parent.appendingPathComponent(journal.recoveringLeaf)]
        let existing = paths.filter { fm.fileExists(atPath: $0.path) }
        guard existing.count <= 1 else { throw BridgeError.message("Availability staging recovery paths conflict.") }
        guard let stage = existing.first else { try fm.removeItem(at: journalURL); return }
        try validateStage(stage, journal: journal)
        let present = journal.files(in: stage).filter { fm.fileExists(atPath: $0.path) }
        if !present.isEmpty, try await inUse(present) { throw BridgeError.message("Availability staging bytes are in use.") }
        let retired = paths[1]
        if stage.path != retired.path { try fm.moveItem(at: stage, to: retired) }
        try validateStage(retired, journal: journal)
        let renamed = journal.files(in: retired).filter { fm.fileExists(atPath: $0.path) }
        if !renamed.isEmpty, try await inUse(renamed) { throw BridgeError.message("Availability staging bytes are still in use.") }
        try fm.removeItem(at: retired)
        try fm.removeItem(at: journalURL)
    }
    private static func validateStage(_ stage: URL, journal: StageJournal) throws {
        try validateDirectory(stage)
        let entries = try boundedEntries(stage, maximum: ADBPortableRuntime.maximumFiles + 2)
        guard Set(entries.map(\.lastPathComponent)).isSubset(of: Set(journal.sources.map { $0.0 })) else { throw BridgeError.message("Availability stage contains unknown bytes.") }
        for (name, expected) in journal.sources {
            let url = stage.appendingPathComponent(name)
            var metadata = stat()
            if lstat(url.path, &metadata) != 0 { guard errno == ENOENT else { throw BridgeError.message("Availability stage is unreadable.") }; continue }
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(), metadata.st_nlink == 1, metadata.st_mode & 0o022 == 0,
                  metadata.st_size >= 0, metadata.st_size <= expected.size else { throw BridgeError.message("Availability stage ownership or size is invalid.") }
            if metadata.st_size == 0 { continue }
            if metadata.st_size == expected.size {
                guard try digest(url) == expected.sha256 else { throw BridgeError.message("Availability staged bytes do not match their receipt.") }
            } else {
                // A partial copy is known only when the unchanged original can
                // prove every retained prefix byte. Missing sources preserve it.
                let source = URL(fileURLWithPath: expected.path)
                guard try digest(source) == expected.sha256 else { throw BridgeError.message("Availability partial-copy source is unavailable or changed.") }
                let actual = try FileHandle(forReadingFrom: url), original = try FileHandle(forReadingFrom: source)
                defer { try? actual.close(); try? original.close() }
                var remaining = Int(metadata.st_size)
                while remaining > 0 {
                    let count = min(262_144, remaining)
                    let left = try actual.read(upToCount: count) ?? Data(), right = try original.read(upToCount: count) ?? Data()
                    guard left.count == count, left == right else { throw BridgeError.message("Availability partial copy does not match its source.") }; remaining -= count
                }
            }
        }
    }
    private static func files(_ directory: URL) -> [URL] {
        // Called only after exact generation validation. Recovery of partial
        // cohorts uses the durable journal's complete list instead.
        let extras = (try? ADBPortableRuntime.inventory(adb: directory.appendingPathComponent("adb"), requireOwned: true).extraFiles) ?? []
        return [directory.appendingPathComponent("DroidBridgeAvailability"), directory.appendingPathComponent("adb")] + extras.map { directory.appendingPathComponent($0.name) }
    }
    static func validIdentity(_ value: String) -> Bool { value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    static func privateDirectory(_ directory: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) { try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try validateDirectory(directory)
    }
    private static func validateDirectory(_ directory: URL) throws {
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o022 == 0 else { throw BridgeError.message("Availability storage ownership or permissions are unsafe.") }
    }
    static func validateGeneration(_ directory: URL, identity: String) throws {
        try validateDirectory(directory)
        let runtime = try ADBPortableRuntime.inventory(adb: directory.appendingPathComponent("adb"), requireOwned: true)
        let names = Set(runtime.files.map(\.name) + ["DroidBridgeAvailability"])
        guard Set(try boundedEntries(directory, maximum: ADBPortableRuntime.maximumFiles + 2).map(\.lastPathComponent)) == names else { throw BridgeError.message("Availability runtime contains unrecognized files.") }
        for file in files(directory) {
            var metadata = stat()
            guard lstat(file.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(), metadata.st_nlink == 1,
                  metadata.st_mode & 0o022 == 0, metadata.st_size > 0, metadata.st_size <= 64 * 1_048_576 else { throw BridgeError.message("Availability runtime file ownership is unsafe.") }
        }
        guard try Self.identity(helper: files(directory)[0], adb: files(directory)[1]) == identity else { throw BridgeError.message("Availability runtime identity mismatch.") }
    }
    private static func verifySignature(_ file: URL) async throws {
        _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--verify", "--strict", file.path], timeout: 10)
    }
    private static func referenced(_ files: [URL]) async throws -> Bool {
        let result = try await ProcessRunner.run("/usr/sbin/lsof", arguments: ["-nP", "-F", "pn", "--"] + files.map(\.path), timeout: 5, allowNonZeroExit: true)
        if result.status == 0 { return true }
        guard result.status == 1, result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BridgeError.message("Availability runtime process references could not be verified.") }
        return false
    }
}

public final class AvailabilityRuntimeLease: @unchecked Sendable {
    private let descriptor: Int32
    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    deinit { Darwin.close(descriptor) }
    static func acquire(url: URL, exclusive: Bool, wait: TimeInterval) throws -> AvailabilityRuntimeLease {
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BridgeError.message("Availability runtime lock is unavailable.") }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0 else { Darwin.close(descriptor); throw BridgeError.message("Availability runtime lock ownership is unsafe.") }
        let deadline = Date().addingTimeInterval(wait)
        repeat {
            if flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) == 0 { return AvailabilityRuntimeLease(descriptor) }
            if wait == 0 || Date() >= deadline { break }
            Thread.sleep(forTimeInterval: 0.025)
        } while true
        Darwin.close(descriptor); throw BridgeError.message("Availability runtime is busy; retry after the active operation finishes.")
    }
}
