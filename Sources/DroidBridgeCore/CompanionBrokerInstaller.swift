import Foundation
import CryptoKit
import Darwin

public enum CompanionBrokerInstaller {
    /// Independent from Spotlight onboarding and its historical generation cap.
    /// Stage only the broker and a hash-bound portable ADB cohort, never app content.
    public static func ensureInstalled(executable: URL, adb: URL? = nil) async throws {
        try await Task.detached(priority: .utility) {
            try CompanionBrokerIPC.prepareDirectory()
            _ = try CompanionBrokerIPC.nonce(create: true)
            let root = CompanionBrokerIPC.directory
            let lock = open(root.appendingPathComponent("install.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard lock >= 0 else { throw CompanionBoundaryError("install_unavailable", "Companion service installation lock is unavailable.") }
            defer { close(lock) }
            var lockInfo = stat()
            guard fstat(lock, &lockInfo) == 0, lockInfo.st_uid == geteuid(), lockInfo.st_mode & S_IFMT == S_IFREG, lockInfo.st_mode & 0o077 == 0 else { throw CompanionBoundaryError("unsafe_install_lock", "Companion installation lock has unsafe ownership.") }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw CompanionBoundaryError("install_busy", "Another DroidBridge process is updating the companion service.", retryable: true) }
            defer { flock(lock, LOCK_UN) }
            let adbSource = adb ?? executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Runtime/bin/adb")
            for file in [executable, adbSource] {
                var info = stat()
                guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0, info.st_size < 128 * 1024 * 1024,
                      FileManager.default.isExecutableFile(atPath: file.path) else { throw CompanionBoundaryError("invalid_broker_runtime", "The packaged companion service or ADB helper is unavailable.") }
            }
            let runtime = try ADBPortableRuntime.inventory(adb: adbSource)
            try await runtime.verifyLoadClosure()
            let generation = try identity(executable: executable, adb: adbSource, suffix: runtime.identitySuffix)
            let generations = root.appendingPathComponent("generations", isDirectory: true)
            try CompanionBrokerIPC.prepareDirectory(generations)
            let agents = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            let plistURL = agents.appendingPathComponent("\(CompanionBrokerIPC.serviceName).plist")
            let pinned = try configuredGeneration(plistURL: plistURL, parent: generations)
            let target = generations.appendingPathComponent(generation, isDirectory: true)
            if !FileManager.default.fileExists(atPath: target.path) {
                // Admission happens before copying. Never remove a generation holding a live lease.
                let entries = try FileManager.default.contentsOfDirectory(at: generations, includingPropertiesForKeys: nil)
                guard entries.count <= 64 else { throw CompanionBoundaryError("broker_generation_capacity", "The companion runtime store exceeds its bounded recovery capacity.") }
                var count = entries.count
                let leases = root.appendingPathComponent("leases", isDirectory: true)
                try CompanionBrokerIPC.prepareDirectory(leases)
                for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where count >= 4 {
                    guard validGeneration(entry.lastPathComponent), entry.standardizedFileURL.path != pinned?.standardizedFileURL.path else { continue }
                    do {
                        try await validateGeneration(entry, identity: entry.lastPathComponent)
                        let lease = try AvailabilityRuntimeLease.acquire(url: leases.appendingPathComponent(entry.lastPathComponent + ".lock"), exclusive: true, wait: 0)
                        defer { withExtendedLifetime(lease) {} }
                        let files = try mappedFiles(entry)
                        guard try await !referenced(files) else { continue }
                        let retired = generations.appendingPathComponent("retiring-" + entry.lastPathComponent + "-" + UUID().uuidString)
                        try FileManager.default.moveItem(at: entry, to: retired)
                        do {
                            try await validateGeneration(retired, identity: entry.lastPathComponent)
                            guard try await !referenced(mappedFiles(retired)) else {
                                try FileManager.default.moveItem(at: retired, to: entry); continue
                            }
                            try FileManager.default.removeItem(at: retired); count -= 1
                        } catch {
                            if !FileManager.default.fileExists(atPath: entry.path) { try? FileManager.default.moveItem(at: retired, to: entry) }
                            throw error
                        }
                    } catch { continue }
                }
                guard count < 4 else { throw CompanionBoundaryError("broker_generation_capacity", "Four companion service generations are current, running or unverified. Quit older DroidBridge processes and retry.", retryable: true) }
                let stage = generations.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: stage) }
                try FileManager.default.copyItem(at: executable, to: stage.appendingPathComponent("DroidBridgeCompanionBroker"))
                try runtime.copy(to: stage)
                try await validateGeneration(stage, identity: generation)
                try FileManager.default.moveItem(at: stage, to: target)
            }
            try CompanionBrokerIPC.prepareDirectory(target)
            try await validateGeneration(target, identity: generation)
            try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
            var st = stat()
            guard lstat(agents.path, &st) == 0, st.st_uid == geteuid(), st.st_mode & S_IFMT == S_IFDIR else { throw CompanionBoundaryError("unsafe_launchagents", "The user LaunchAgents folder has unsafe ownership.") }
            var arguments = [target.appendingPathComponent("DroidBridgeCompanionBroker").path]
            if let scope = CompanionQAScope.current { arguments += ["--companion-qa-root", scope.root.path, "--serial", scope.serial] }
            let plist: [String: Any] = ["Label": CompanionBrokerIPC.serviceName,
                "ProgramArguments": arguments,
                "MachServices": [CompanionBrokerIPC.serviceName: true], "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false], "ThrottleInterval": 10,
                "EnvironmentVariables": ["DROIDBRIDGE_ADB": target.appendingPathComponent("adb").path]]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let old = try? Data(contentsOf: plistURL)
            if old != data {
                if FileManager.default.fileExists(atPath: plistURL.path) {
                    guard lstat(plistURL.path, &st) == 0, st.st_uid == geteuid(), st.st_mode & S_IFMT == S_IFREG else { throw CompanionBoundaryError("unsafe_launchagent", "The companion LaunchAgent has unsafe ownership.") }
                }
                // Do not publish the replacement plist while an old owner is
                // still stopping. A timeout must remain retryable against the
                // original pin rather than making unchanged-byte retry skip it.
                try await stopPrevious()
                try data.write(to: plistURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
            }
            try await install(plistURL)
        }.value
    }
    /// A generation lease is outside the immutable cohort. Startup refuses an
    /// unsafe/missing lease instead of silently allowing live-runtime pruning.
    public static func holdRunning(executable: URL) throws -> AvailabilityRuntimeLease? {
        let generation = executable.deletingLastPathComponent()
        guard validGeneration(generation.lastPathComponent), generation.deletingLastPathComponent().lastPathComponent == "generations" else { return nil }
        let leases = generation.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("leases")
        try CompanionBrokerIPC.prepareDirectory(leases)
        return try AvailabilityRuntimeLease.acquire(url: leases.appendingPathComponent(generation.lastPathComponent + ".lock"), exclusive: false, wait: 0)
    }
    private static func validGeneration(_ name: String) -> Bool { ADBPortableRuntime.validHash(name) }
    private static func configuredGeneration(plistURL: URL, parent: URL) throws -> URL? {
        var metadata = stat()
        if lstat(plistURL.path, &metadata) != 0 {
            guard errno == ENOENT else { throw CompanionBoundaryError("unsafe_launchagent", "The companion service configuration is unreadable.") }
            return nil
        }
        guard metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1, metadata.st_mode & 0o022 == 0, metadata.st_size > 0, metadata.st_size <= 65_536,
              let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any],
              plist["Label"] as? String == CompanionBrokerIPC.serviceName,
              let arguments = plist["ProgramArguments"] as? [String], let first = arguments.first else {
            throw CompanionBoundaryError("unsafe_launchagent", "The companion service configuration cannot be verified; it was preserved.")
        }
        let executable = URL(fileURLWithPath: first).standardizedFileURL
        let generation = executable.deletingLastPathComponent()
        guard executable.lastPathComponent == "DroidBridgeCompanionBroker", validGeneration(generation.lastPathComponent),
              generation.deletingLastPathComponent().path == parent.standardizedFileURL.path else {
            throw CompanionBoundaryError("unsafe_launchagent", "The companion service points outside its owned runtime store; it was preserved.")
        }
        return generation
    }
    private static func identity(executable: URL, adb: URL, suffix: String) throws -> String {
        var hash = SHA256()
        hash.update(data: try Data(contentsOf: executable, options: .mappedIfSafe))
        hash.update(data: try Data(contentsOf: adb, options: .mappedIfSafe))
        hash.update(data: Data(suffix.utf8))
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func mappedFiles(_ directory: URL) throws -> [URL] {
        let runtime = try ADBPortableRuntime.inventory(adb: directory.appendingPathComponent("adb"), requireOwned: true)
        return [directory.appendingPathComponent("DroidBridgeCompanionBroker")] + runtime.files.filter { $0.name != ADBPortableRuntime.manifestName }.map { directory.appendingPathComponent($0.name) }
    }
    private static func validateGeneration(_ directory: URL, identity expected: String) async throws {
        try CompanionBrokerIPC.prepareDirectory(directory)
        let runtime = try ADBPortableRuntime.inventory(adb: directory.appendingPathComponent("adb"), requireOwned: true)
        let names = Set(runtime.files.map(\.name) + ["DroidBridgeCompanionBroker"])
        let actual = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        guard actual == names || actual == names.union(["running.lock"]) else { throw CompanionBoundaryError("invalid_broker_runtime", "A staged companion runtime contains unknown bytes.") }
        let broker = directory.appendingPathComponent("DroidBridgeCompanionBroker")
        var info = stat()
        guard lstat(broker.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o022 == 0, info.st_size > 0, info.st_size < 128 * 1024 * 1024 else { throw CompanionBoundaryError("invalid_broker_runtime", "A staged companion runtime has unsafe ownership or size.") }
        guard try identity(executable: broker, adb: directory.appendingPathComponent("adb"), suffix: runtime.identitySuffix) == expected else { throw CompanionBoundaryError("broker_integrity_failed", "The staged companion runtime failed its integrity check.") }
        _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--verify", "--strict", broker.path], timeout: 10)
        try await runtime.verifyLoadClosure()
        if actual.contains("running.lock") {
            let lock = directory.appendingPathComponent("running.lock")
            guard lstat(lock.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & S_IFMT == S_IFREG,
                  info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size == 0 else { throw CompanionBoundaryError("invalid_broker_runtime", "A legacy companion runtime lease is unsafe.") }
        }
    }
    private static func referenced(_ files: [URL]) async throws -> Bool {
        let result = try await ProcessRunner.run("/usr/sbin/lsof", arguments: ["-nP", "-F", "pn", "--"] + files.map(\.path), timeout: 5, allowNonZeroExit: true)
        if result.status == 0 { return true }
        guard result.status == 1, result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CompanionBoundaryError("broker_runtime_unknown", "Companion runtime process references could not be verified.") }
        return false
    }
    private static func stopPrevious() async throws {
        let domain = "gui/\(geteuid())"
        let job = "\(domain)/\(CompanionBrokerIPC.serviceName)"
        let previous = try await ProcessRunner.run("/bin/launchctl", arguments: ["print", job], timeout: 5, allowNonZeroExit: true)
        if previous.status == 0 {
            let pid = previous.output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { $0.hasPrefix("pid = ") }).flatMap { Int32($0.dropFirst(6)) }
            let owner = pid.flatMap(CompanionBrokerOwner.live)
            _ = try await ProcessRunner.run("/bin/launchctl", arguments: ["bootout", job], timeout: 5)
            if let owner {
                let deadline = Date().addingTimeInterval(15)
                while owner.isAlive {
                    guard Date() < deadline else { throw CompanionBoundaryError("broker_still_stopping", "The previous companion service is still stopping. Retry after it exits.", retryable: true) }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            try Task.checkCancellation()
        }
    }
    private static func install(_ plist: URL) async throws {
        let domain = "gui/\(geteuid())"
        let present = try await ProcessRunner.run("/bin/launchctl", arguments: ["print", "\(domain)/\(CompanionBrokerIPC.serviceName)"], timeout: 5, allowNonZeroExit: true)
        if present.status != 0 {
            _ = try await ProcessRunner.run("/bin/launchctl", arguments: ["bootstrap", domain, plist.path], timeout: 10)
        }
    }
}
