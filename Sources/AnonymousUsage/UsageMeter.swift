import Darwin
import Foundation

public enum UsageConsentStatus: Equatable { case enabled, disabled, unavailable }

public struct UsageConsentResult {
    public let status: UsageConsentStatus
    public let purgePending: Bool
    init(_ status: UsageConsentStatus, purgePending: Bool = false) {
        self.status = status
        self.purgePending = purgePending
    }
}

/// A single aggregate replaces event history. The host calls tick about once a
/// minute and reports only foreground transitions and first presented frames.
public final class UsageMeter {
    private let queue = DispatchQueue(label: "works.sloop.anonymous-usage.meter")
    private let scope: String
    private let canChangeConsent: Bool
    private let transport: UsageTransport?
    private let directory: URL
    private let day: () -> Int
    private let uptime: () -> TimeInterval
    private let gate = NSLock()
    private var optedIn = false
    private var revision: UInt64?
    private var foreground = false
    private var lastSample: TimeInterval?
    private var lastExit: TimeInterval?
    private var remainder: TimeInterval = 0

    public var consentEnabled: Bool { gate.withLock { optedIn } }

    public convenience init(directory: URL, transport: UsageTransport?, consentScope: String, canChangeConsent: Bool = false) {
        self.init(directory: directory, transport: transport, consentScope: consentScope, canChangeConsent: canChangeConsent,
                  day: { Int(floor(Date().timeIntervalSince1970 / 86_400)) },
                  uptime: { ProcessInfo.processInfo.systemUptime })
    }

    init(directory: URL, transport: UsageTransport?, consentScope: String, canChangeConsent: Bool,
         day: @escaping () -> Int, uptime: @escaping () -> TimeInterval) {
        self.transport = transport
        self.scope = consentScope
        self.canChangeConsent = canChangeConsent
        self.directory = directory
        self.day = day
        self.uptime = uptime
    }

    public func refreshConsent(_ callback: @escaping (Bool) -> Void) {
        readConsentStatus { callback($0.status == .enabled) }
    }

    public func readConsentStatus(_ completion: @escaping (UsageConsentResult) -> Void) {
        queue.async { [self] in
            let result: UsageConsentResult
            do {
                result = try withDirectory(create: false) { fd in
                    let permit = try readPermit(fd)
                    if permit == nil {
                        do {
                            return try withAccountingLock(create: false) {
                                UsageConsentResult(.disabled, purgePending: try read().scope != nil)
                            }
                        } catch { return UsageConsentResult(.disabled, purgePending: true) }
                    }
                    let ledger = try withAccountingLock(create: false) { try read() }
                    return UsageConsentResult(authorized(ledger, permit: permit) ? .enabled : .disabled)
                }
            } catch let error as POSIXError where error.code == .ENOENT {
                result = UsageConsentResult(.disabled)
            } catch { result = UsageConsentResult(.unavailable) }
            publish(result, completion)
        }
    }

    private func authorized(_ ledger: Ledger, permit: UInt64?) -> Bool {
        transport != nil && !scope.isEmpty && ledger.scope == scope && permit == ledger.revision
    }

    public func setConsent(_ enabled: Bool, completion: ((UsageConsentResult) -> Void)? = nil) {
        if !enabled && canChangeConsent { transport?.cancel() }
        queue.async { [self] in
            guard canChangeConsent else { publish(UsageConsentResult(.unavailable), completion); return }
            let result: UsageConsentResult
            do {
                result = try withDirectory(create: enabled) { fd in
                    if enabled {
                        guard transport != nil, !scope.isEmpty, scope.utf8.count <= 256 else { throw POSIXError(.EINVAL) }
                        return try withAccountingLock(create: true) {
                            var ledger = try read()
                            if !authorized(ledger, permit: try readPermit(fd)) {
                                ledger.clearCounters()
                                ledger.scope = scope
                                ledger.revision = max(ledger.revision, try readPermit(fd, name: Self.withdrawnName) ?? 0)
                                guard ledger.revision < UInt64.max else { throw POSIXError(.EOVERFLOW) }
                                ledger.revision += 1
                                try write(ledger)
                                try publishBytes(Data(String(ledger.revision).utf8), target: Self.permitName)
                            }
                            observe(ledger)
                            return UsageConsentResult(.enabled)
                        }
                    }

                    // Revoke and synchronize before touching the independently
                    // locked counters. A busy or corrupt ledger cannot restore consent.
                    try retirePermit(fd)
                    do {
                        try withAccountingLock(create: true) {
                            var ledger: Ledger
                            do { ledger = try read() }
                            catch is DecodingError { ledger = Ledger(lastAttemptDay: day()) }
                            catch let error as CocoaError where error.code == .fileReadCorruptFile {
                                ledger = Ledger(lastAttemptDay: day())
                            }
                            ledger.clearCounters()
                            ledger.scope = nil
                            try write(ledger)
                        }
                        return UsageConsentResult(.disabled)
                    } catch { return UsageConsentResult(.disabled, purgePending: true) }
                }
            } catch let error as POSIXError where error.code == .ENOENT && !enabled {
                result = UsageConsentResult(.disabled)
            } catch { result = UsageConsentResult(.unavailable) }
            if result.status != .enabled { resetIntervals(); transport?.cancel() }
            publish(result, completion)
        }
    }

    private func publish(_ result: UsageConsentResult, _ completion: ((UsageConsentResult) -> Void)?) {
        gate.withLock { optedIn = result.status == .enabled }
        if let completion { DispatchQueue.main.async { completion(result) } }
    }

    private static let permitName = "permission-v1"

    private static let withdrawnName = "withdrawn-revision-v1"

    private func retirePermit(_ parent: Int32) throws {
        // Retain only the last grant revision, so repairing damaged counters
        // cannot reauthorize a delayed socket from an earlier grant.
        if (try? readPermit(parent)) != nil {
            guard renameat(parent, Self.permitName, parent, Self.withdrawnName) == 0 else { throw POSIXError(.EIO) }
        } else {
            guard unlinkat(parent, Self.permitName, 0) == 0 || errno == ENOENT else { throw POSIXError(.EIO) }
        }
        guard fsync(parent) == 0 else { throw POSIXError(.EIO) }
    }

    private func readPermit(_ parent: Int32, name: String = UsageMeter.permitName) throws -> UInt64? {
        let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o600 else { throw POSIXError(.EACCES) }
        let bytes = try handle.read(upToCount: 21) ?? Data()
        guard let text = String(data: bytes, encoding: .utf8), let value = UInt64(text),
              value > 0, String(value) == text else { throw POSIXError(.EINVAL) }
        return value
    }

    private func observe(_ ledger: Ledger) {
        if revision != ledger.revision {
            resetIntervals()
            revision = ledger.revision
        }
    }

    public func setForeground(_ active: Bool) {
        update(canDeliver: { [self] in foreground != active }) { [self] ledger, now in
            guard active != foreground else { return }
            if active {
                if lastExit.map({ now - $0 >= 1_800 }) ?? true {
                    ledger.foregroundSessions = min(8, ledger.foregroundSessions + 1)
                }
                lastSample = now
            } else {
                sample(&ledger, now)
                lastSample = nil
                lastExit = now
            }
            foreground = active
        }
    }

    public func recordNativeSession() {
        update { ledger, _ in ledger.nativeSessions = min(8, ledger.nativeSessions + 1) }
    }

    public func tick() { update(canDeliver: { false }) { [self] ledger, now in sample(&ledger, now) } }

    /// Explicit loopback QA action. It shares the ordinary attempt budget.
    public func sendPending() { update(manual: true) { [self] ledger, now in sample(&ledger, now) } }

    private func sample(_ ledger: inout Ledger, _ now: TimeInterval) {
        guard foreground, let previous = lastSample else { return }
        lastSample = now
        remainder += min(60, max(0, now - previous))
        let minutes = Int(remainder / 60)
        remainder -= Double(minutes * 60)
        ledger.activeMinutes = min(120, ledger.activeMinutes + minutes)
    }

    private func resetIntervals() {
        foreground = false
        lastSample = nil
        lastExit = nil
        remainder = 0
    }

    private func update(manual: Bool = false, canDeliver: @escaping () -> Bool = { true }, _ measure: @escaping (inout Ledger, TimeInterval) -> Void) {
        guard transport != nil else { return }
        queue.async { [self] in
            var pending: (report: UsageReport, revision: UInt64)?
            withMeasurementLock { permit in
                do {
                    let previous = try read()
                    observe(previous)
                    let allowed = authorized(previous, permit: permit)
                    gate.withLock { optedIn = allowed }
                    guard allowed else { return }
                    var ledger = previous
                    let today = day()
                    if let start = ledger.startDay, today > start + 7 {
                        ledger.clearCounters()
                        remainder = 0
                    }
                    var attempt: UsageReport?
                    func drain() {
                        guard ledger.hasUsage, today > (ledger.lastAttemptDay ?? -1) else { return }
                        attempt = ledger.report
                        ledger.lastAttemptDay = today
                        ledger.clearCounters()
                    }
                    // A regular send includes only the previously accumulated days.
                    if let start = ledger.startDay, today > start, canDeliver() { drain() }
                    measure(&ledger, uptime())
                    if ledger.hasUsage && ledger.startDay == nil { ledger.startDay = today }
                    if manual && attempt == nil { drain() }
                    if ledger != previous { try write(ledger) }
                    if let attempt { pending = (attempt, ledger.revision) }
                } catch {
                    // A failed destructive drain never reaches the transport.
                    return
                }
            }
            if let pending {
                transport?.send(pending.report) { [weak self] handoff in
                    guard let self else { return false }
                    var accepted = false
                    self.withMeasurementLock { permit in
                        guard let current = try? self.read(), current.revision == pending.revision,
                              self.authorized(current, permit: permit) else { return }
                        handoff()
                        accepted = true
                    }
                    return accepted
                }
            }
        }
    }

    private struct Ledger: Codable, Equatable {
        var scope: String?
        var revision: UInt64 = 0
        var startDay: Int?
        var lastAttemptDay: Int?
        var foregroundSessions = 0
        var activeMinutes = 0
        var nativeSessions = 0

        var report: UsageReport { UsageReport(foregroundSessions: foregroundSessions, activeMinutes: activeMinutes, nativeSessions: nativeSessions) }
        var hasUsage: Bool { foregroundSessions + activeMinutes + nativeSessions > 0 }
        mutating func clearCounters() {
            self = Ledger(scope: scope, revision: revision, lastAttemptDay: lastAttemptDay)
        }
    }

    private var file: URL { directory.appendingPathComponent("aggregate-v1.json") }

    private func read() throws -> Ledger {
        let fd = open(file.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 && errno == ENOENT { return Ledger() }
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer { try? handle.close() }
        try ensurePrivateFile(fd)
        let data = try handle.read(upToCount: 1025) ?? Data()
        guard data.count <= 1024 else { throw CocoaError(.fileReadCorruptFile) }
        let ledger = try JSONDecoder().decode(Ledger.self, from: data)
        guard (0...8).contains(ledger.foregroundSessions), (0...120).contains(ledger.activeMinutes),
              (0...8).contains(ledger.nativeSessions), validDay(ledger.startDay), validDay(ledger.lastAttemptDay),
              ledger.hasUsage == (ledger.startDay != nil) else { throw CocoaError(.fileReadCorruptFile) }
        return ledger
    }

    private func validDay(_ value: Int?) -> Bool { value.map { (0...3_000_000).contains($0) } ?? true }

    private func write(_ ledger: Ledger) throws {
        try publishBytes(JSONEncoder().encode(ledger), target: file.lastPathComponent)
    }

    private func publishBytes(_ bytes: Data, target: String) throws {
        guard bytes.count <= 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard parent >= 0 else { throw POSIXError(.EIO) }
        defer { close(parent) }

        // The exclusive ledger lock makes the single staging name recoverable
        // after a crash. The file is private before its first byte is written.
        let staging = target == Self.permitName ? ".permission-v1.pending" : ".aggregate-v1.pending"
        guard unlinkat(parent, staging, 0) == 0 || errno == ENOENT else { throw POSIXError(.EIO) }
        let fd = openat(parent, staging, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        defer {
            try? handle.close()
            unlinkat(parent, staging, 0)
        }
        try ensurePrivateFile(fd)
        try handle.write(contentsOf: bytes)
        guard fsync(fd) == 0, renameat(parent, staging, parent, target) == 0,
              fsync(parent) == 0 else { throw POSIXError(.EIO) }
    }

    private func ensurePrivateFile(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1 else { throw POSIXError(.EACCES) }
        if info.st_mode & 0o7777 != 0o600 {
            guard fchmod(fd, 0o600) == 0, fsync(fd) == 0 else { throw POSIXError(.EACCES) }
        }
    }

    private func withMeasurementLock(_ body: (UInt64) -> Void) {
        do {
            try withDirectory(create: false) { fd in
                guard let permit = try readPermit(fd) else { return }
                try withAccountingLock(create: false) { body(permit) }
            }
        } catch { return }
    }

    // The directory itself serializes permission changes and handoffs, even
    // when the independently opened accounting lock has become unavailable.
    private func withDirectory<T>(create: Bool, _ body: (Int32) throws -> T) throws -> T {
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else {
            throw POSIXError(.EACCES)
        }
        try lockBriefly(fd)
        defer { flock(fd, LOCK_UN) }
        return try body(fd)
    }

    private func withAccountingLock<T>(create: Bool, _ body: () throws -> T) throws -> T {
        let lock = directory.appendingPathComponent("usage.lock")
        let fd = open(lock.path, (create ? O_CREAT : 0) | O_RDWR | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd) }
        try ensurePrivateFile(fd)
        try lockBriefly(fd)
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func lockBriefly(_ fd: Int32) throws {
        for _ in 0..<12 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return }
            guard errno == EWOULDBLOCK || errno == EINTR else { throw POSIXError(.EIO) }
            usleep(1_000)
        }
        throw POSIXError(.EWOULDBLOCK)
    }

    // A test barrier for queued persistence and transport admission.
    func settle() { queue.sync {} }
}
