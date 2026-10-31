import Foundation
import CryptoKit
import Darwin

public struct ManagedAppsPaths: Sendable {
    public let privateRoot: URL
    public let activeRoot: URL
    public init(privateRoot: URL, activeRoot: URL) {
        self.privateRoot = Self.canonicalAncestors(privateRoot)
        self.activeRoot = Self.canonicalAncestors(activeRoot)
    }
    private static func canonicalAncestors(_ url: URL) -> URL {
        var parent = url.standardizedFileURL.deletingLastPathComponent()
        var missing = [url.lastPathComponent]
        while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
            missing.append(parent.lastPathComponent); parent.deleteLastPathComponent()
        }
        let resolved = realpath(parent.path, nil)
        var result = resolved.map { URL(fileURLWithPath: String(cString: $0)) } ?? parent.resolvingSymlinksInPath()
        if let resolved { free(resolved) }
        for component in missing.reversed() { result.appendPathComponent(component) }
        return result
    }
    public static var userDefault: Self {
        if let scope = CompanionQAScope.current { return scope.managedPaths }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return Self(privateRoot: home.appendingPathComponent("Library/Application Support/DroidBridge/ManagedApps.noindex"), activeRoot: home.appendingPathComponent("Applications/DroidBridge Apps/Devices"))
    }
}
public enum ManagedAppAvailability: String, Codable, Sendable { case active, inactive }
public enum ManagedAppCatalogError: LocalizedError {
    case busy, running, invalid(String)
    public var errorDescription: String? {
        switch self {
        case .busy: return "Another DroidBridge process is preparing this managed app. Try again when it finishes."
        case .running: return "Quit the managed Android Mac app before updating it."
        case .invalid(let reason): return "Managed app catalog refused: \(reason)"
        }
    }
}
public struct ManagedAppReservation: Codable, Sendable, Equatable {
    public var namingVersion: Int? = nil
    public let id: UUID
    public let key: String
    public let deviceHash: String
    public let bundleIdentifier: String
    public let bundleFilename: String
    public let stagingRoot: URL
    public let stagedBundleURL: URL
    public let activeBundleURL: URL
    public let device: AndroidDevice
    public let application: AndroidApplication
    public let backend: BackendKind
    public let manualAdoption: ManagedAppManualAdoption?
    public let previousGeneration: UUID?
    public let ownerPID: Int32
}
public struct ManagedAppManualAdoption: Codable, Sendable, Equatable {
    public let bundleURL: URL
    public let infoSHA256: String
    public let configuration: Data
}
public struct ManagedAppRecord: Codable, Sendable {
    public var namingVersion: Int? = nil
    public let key: String
    public let generation: UUID
    public let deviceHash: String
    public let deviceSerial: String
    public let deviceModel: String
    public let packageName: String
    public let name: String
    public let backend: BackendKind
    public let bundleIdentifier: String
    public let bundleFilename: String
    public let activeBundleURL: URL
    public let inactiveBundleURL: URL
    public var availability: ManagedAppAvailability
    public var location: ManagedAppAvailability
    public let sourceVersion: String
    public let sourceBuild: String
    public var bundleURL: URL { location == .active ? activeBundleURL : inactiveBundleURL }
}
public struct ManagedAppIssue: Codable, Sendable {
    public let key: String
    public let message: String
    public let retryAfter: Date
}
public struct ManagedAppRegistrationAction: Codable, Sendable, Equatable {
    public let id: UUID
    public let bundleURL: URL
    public let register: Bool
    public let key: String
    public let generation: UUID
}

/// A local manifest with cross-process flock fencing. Only bounded metadata reads,
/// atomic JSON writes and same-volume renames occur while locked. Android work,
/// icon rendering, bundle copies, code signing and Launch Services run outside it.
public final class ManagedAppCatalog: @unchecked Sendable {
    public let paths: ManagedAppsPaths
    private let fm = FileManager.default
    private struct ManifestFingerprint: Equatable {
        let inode: UInt64, size: Int64, modified: Int64, modifiedNanos: Int64, changed: Int64, changedNanos: Int64
        init(_ value: stat) {
            inode = value.st_ino; size = value.st_size
            modified = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
            changed = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
        }
    }
    private var cachedManifest: Manifest?
    private var cachedFingerprint: ManifestFingerprint?
    private var exportSnapshot = CompanionExportPolicy.Snapshot.unrestricted
    private var exportFingerprint: ManifestFingerprint?

    private struct Publication: Codable {
        let reservation: ManagedAppReservation
        let candidate: ManagedAppRecord
        let previous: ManagedAppRecord?
    }
    private struct Manifest: Codable {
        var version = 1
        var records: [String: ManagedAppRecord] = [:]
        var reservations: [String: ManagedAppReservation] = [:]
        var publications: [String: Publication] = [:]
        var actions: [ManagedAppRegistrationAction] = []
        var policyEnabled = false
        var availableSerials: Set<String> = []
        var issues: [String:ManagedAppIssue] = [:]
        var missingHistory: [String:ManagedAppRecord] = [:]
        // Exact previous public paths remain authoritative for late LS effects
        // after a filename change; they never authorize replacing foreign bytes.
        var retiredNames: [String:ManagedAppRecord] = [:]
        init() {}
        private enum CodingKeys: String, CodingKey { case version, records, reservations, publications, actions, policyEnabled, availableSerials, issues, missingHistory, retiredNames }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy:CodingKeys.self)
            version = try values.decode(Int.self,forKey:.version)
            records = try values.decode([String:ManagedAppRecord].self,forKey:.records)
            reservations = try values.decode([String:ManagedAppReservation].self,forKey:.reservations)
            publications = try values.decode([String:Publication].self,forKey:.publications)
            actions = try values.decode([ManagedAppRegistrationAction].self,forKey:.actions)
            policyEnabled = try values.decodeIfPresent(Bool.self,forKey:.policyEnabled) ?? false
            availableSerials = try values.decodeIfPresent(Set<String>.self,forKey:.availableSerials) ?? []
            issues = try values.decodeIfPresent([String:ManagedAppIssue].self,forKey:.issues) ?? [:]
            missingHistory = try values.decodeIfPresent([String:ManagedAppRecord].self,forKey:.missingHistory) ?? [:]
            retiredNames = try values.decodeIfPresent([String:ManagedAppRecord].self,forKey:.retiredNames) ?? [:]
        }
    }
    public init(paths: ManagedAppsPaths = .userDefault) { self.paths = paths }
    /// A trusted broker publishes the complete accepted selection for all
    /// verified aliases under the same lock used by wrapper admission.
    public func updateCompanionExports(deviceID: String, aliases: [String], selection: [String: Bool]) throws {
        try locked { manifest in
            let url = CompanionExportPolicy.url(paths: paths)
            var policy = try CompanionExportPolicy.read(url)
            guard let id = UUID(uuidString: deviceID)?.uuidString.lowercased() else { throw ManagedAppCatalogError.invalid("companion phone identity") }
            guard policy.devices[id]?.authorityTrustID == nil else { throw ManagedAppCatalogError.invalid("companion export requires revision authority") }
            try advanceCompanionPolicyFence(&manifest)
            policy.devices[id] = .init(aliases: aliases, selection: selection)
            try CompanionExportPolicy.write(policy, to: url)
            exportSnapshot = CompanionExportPolicy.Snapshot(policy)
            exportFingerprint = nil
        }
    }
    /// Only call after authenticating the exact phone installation and trust.
    /// Re-pairing preserves export choices, but starts a fresh revision authority.
    public func bindCompanionExportAuthority(deviceID: String, trustID: String, aliases: [String], allowingForgottenAliasTransfer: Bool = false) throws {
        try locked { _ in
            guard let id = UUID(uuidString: deviceID)?.uuidString.lowercased(),
                  let trust = UUID(uuidString: trustID)?.uuidString.lowercased() else { throw ManagedAppCatalogError.invalid("companion export identity") }
            return try CanonicalAliasAdmission.withPolicyFence(paths: paths) {
            let url = CompanionExportPolicy.url(paths: paths)
            var policy = try CompanionExportPolicy.read(url)
            let priorAliases = Set(policy.devices.values.flatMap { $0.aliases })
            let newAliases = aliases.filter { !priorAliases.contains($0) }
            try CanonicalAliasAdmission.requireDrained(Set(newAliases.map { CanonicalAliasAdmission.serialIdentity($0) }), paths: paths)
            var device = policy.devices[id] ?? .init(aliases: aliases, selection: [:])
            var inherited: [String: Bool] = [:]
            var inheritedCapture = Set<String>()
            for oldID in policy.devices.keys.sorted() where oldID != id {
                guard var old = policy.devices[oldID], !Set(old.aliases).isDisjoint(with: aliases) else { continue }
                guard allowingForgottenAliasTransfer, old.forgotten == true else { throw ManagedAppCatalogError.invalid("companion alias belongs to another installation; explicitly forget its pairing before re-pairing") }
                inheritedCapture.insert(old.captureIdentity ?? oldID)
                for (package, selected) in old.selection { inherited[package] = (inherited[package] ?? true) && selected }
                old.aliases.removeAll { aliases.contains($0) }; policy.devices[oldID] = old
            }
            // New installation's deliberate choices win; otherwise retain the
            // most restrictive historical choice across explicitly moved aliases.
            let previousCapture = device.captureIdentity ?? id
            if !inheritedCapture.isEmpty {
                try CanonicalAliasAdmission.requireDrained(inheritedCapture.union([previousCapture]), paths: paths)
                device.captureIdentity = policy.devices[id] != nil ? previousCapture : inheritedCapture.sorted().first
            } else { device.captureIdentity = previousCapture }
            device.selection = inherited.merging(device.selection) { _, current in current }
            device.aliases = aliases; device.forgotten = false
            if device.authorityTrustID != trust { device.authorityTrustID = trust; device.revisions = [:] }
            policy.devices[id] = device
            try CompanionExportPolicy.write(policy, to: url)
            exportSnapshot = CompanionExportPolicy.Snapshot(policy); exportFingerprint = nil
            }
        }
    }
    /// Local explicit consent only. Keep historical choices and revision bytes;
    /// no wrapper, app preference, publication or accepted selection is deleted.
    public func forgetCompanionExportAuthority(deviceID: String) throws {
        try locked { _ in
            guard let id = UUID(uuidString: deviceID)?.uuidString.lowercased() else { throw ManagedAppCatalogError.invalid("companion phone identity") }
            let url = CompanionExportPolicy.url(paths: paths)
            var policy = try CompanionExportPolicy.read(url)
            if var device = policy.devices[id] { device.forgotten = true; policy.devices[id] = device; try CompanionExportPolicy.write(policy, to: url) }
            exportSnapshot = CompanionExportPolicy.Snapshot(policy); exportFingerprint = nil
        }
    }
    public func companionExportWasForgotten(deviceID: String) throws -> Bool {
        try locked { _ in
            guard let id = UUID(uuidString: deviceID)?.uuidString.lowercased() else { throw ManagedAppCatalogError.invalid("companion phone identity") }
            return try CompanionExportPolicy.read(CompanionExportPolicy.url(paths: paths)).devices[id]?.forgotten == true
        }
    }
    /// Per-package fences retain independent choices when events arrive out of
    /// order. False means a newer choice already won; equal conflicting bytes fail.
    public enum CompanionExportOutcome: Equatable, Sendable { case committed, replayed, stale }
    @discardableResult
    public func applyCompanionExport(deviceID: String, trustID: String, packageName: String, selected: Bool, revision: Int64) throws -> Bool {
        try applyCompanionExportOutcome(deviceID: deviceID, trustID: trustID, packageName: packageName, selected: selected, revision: revision) != .stale
    }
    @discardableResult
    public func applyCompanionExportOutcome(deviceID: String, trustID: String, packageName: String, selected: Bool, revision: Int64) throws -> CompanionExportOutcome {
        try AndroidDiscovery.validatePackage(packageName)
        return try locked { manifest in
            guard let id = UUID(uuidString: deviceID)?.uuidString.lowercased(),
                  let trust = UUID(uuidString: trustID)?.uuidString.lowercased(), revision > 0,
                  revision <= 9_007_199_254_740_991 else { throw ManagedAppCatalogError.invalid("companion export identity/revision") }
            let url = CompanionExportPolicy.url(paths: paths)
            var policy = try CompanionExportPolicy.read(url)
            guard var device = policy.devices[id], device.authorityTrustID == trust else { throw ManagedAppCatalogError.invalid("companion export authority changed") }
            let previous = device.revisions?[packageName] ?? 0
            if revision < previous { return .stale }
            if revision == previous {
                guard device.selection[packageName] == selected else { throw ManagedAppCatalogError.invalid("companion export revision conflict") }
                return .replayed
            }
            try advanceCompanionPolicyFence(&manifest)
            device.selection[packageName] = selected
            var revisions = device.revisions ?? [:]; revisions[packageName] = revision; device.revisions = revisions
            policy.devices[id] = device
            try CompanionExportPolicy.write(policy, to: url)
            exportSnapshot = CompanionExportPolicy.Snapshot(policy); exportFingerprint = nil
            return .committed
        }
    }
    /// Version 2 is an intentional forward-compatibility fence. Legacy helpers
    /// reject it before moving or registering wrappers, including after restart.
    /// Publish this first; a crash may defer a choice, but cannot accept a choice
    /// while retaining a legacy writer that ignores the separate policy.
    private func advanceCompanionPolicyFence(_ manifest: inout Manifest) throws {
        if manifest.version < 2 { manifest.version = 2; try save(manifest) }
    }
    /// The separate policy is authoritative after a broker crash between policy
    /// publication and its own cached-state write.
    public func companionExportSelection(deviceID: String) throws -> [String: Bool] {
        try locked { _ in
            guard let id = UUID(uuidString: deviceID)?.uuidString.lowercased() else { throw ManagedAppCatalogError.invalid("companion phone identity") }
            return try CompanionExportPolicy.read(CompanionExportPolicy.url(paths: paths)).devices[id]?.selection ?? [:]
        }
    }
    public static func bundleFilename(_ package: String, name: String? = nil) -> String {
        filenameStem(name ?? package) + ".app"
    }
    private static func legacyFilename(_ package: String, name: String) -> String {
        let suffix = SHA256.hash(data:Data(package.utf8)).prefix(8).map { String(format:"%02x",$0) }.joined()
        return filenameStem(name) + "-" + suffix + ".app"
    }
    private static func filenameStem(_ name: String, limit: Int = 160) -> String {
        let label = name.replacingOccurrences(of:"/",with:"-").replacingOccurrences(of:":",with:"-").trimmingCharacters(in:.whitespacesAndNewlines)
        var slug = ""
        for character in label where !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            guard (slug + String(character)).utf8.count <= limit else { break }; slug.append(character)
        }
        if slug.isEmpty || slug.hasPrefix(".") { slug = "Android App" }
        return slug
    }
    private static func filenameKey(_ filename: String) -> String {
        filename.precomposedStringWithCanonicalMapping.folding(options:[.caseInsensitive],locale:Locale(identifier:"en_US_POSIX"))
    }
    public static func needsNameRepair(_ record: ManagedAppRecord) -> Bool {
        record.bundleFilename == legacyFilename(record.packageName,name:record.name)
    }
    private func cleanNamesAllowed(_ manifest: Manifest, running: Set<String> = []) -> Bool {
        // Deleted bundles have no reader to upgrade. Keep their accepted metadata
        // for explicit repair, but don't let one absent icon block healthy apps.
        // A deleted-but-still-running app remains a compatibility barrier.
        manifest.records.values.allSatisfy { record in
            if (record.namingVersion ?? 1) >= 2 { return true }
            for url in [record.activeBundleURL,record.inactiveBundleURL] {
                if running.contains(Self.canonical(url)) { return false }
                var metadata = stat()
                if lstat(url.path,&metadata) == 0 || errno != ENOENT { return false }
            }
            return true
        } &&
        manifest.reservations.values.allSatisfy { ($0.namingVersion ?? 1) >= 2 || (kill($0.ownerPID,0) != 0 && errno != EPERM) } &&
        manifest.publications.values.allSatisfy { ($0.candidate.namingVersion ?? 1) >= 2 }
    }
    private func chooseFilename(package: String, name: String, hash: String, key: String, manifest: Manifest) throws -> String {
        var occupied = Set<String>()
        for record in manifest.records.values where record.deviceHash == hash && record.key != key { occupied.insert(Self.filenameKey(record.bundleFilename)) }
        for claim in manifest.reservations.values where claim.deviceHash == hash && claim.key != key { occupied.insert(Self.filenameKey(claim.bundleFilename)) }
        for publication in manifest.publications.values where publication.candidate.deviceHash == hash && publication.candidate.key != key { occupied.insert(Self.filenameKey(publication.candidate.bundleFilename)) }
        for parent in [paths.activeRoot.appendingPathComponent(hash),paths.privateRoot.appendingPathComponent("inactive/"+hash)] {
            try rejectSymlink(parent,below:root(containing:parent))
            if fm.fileExists(atPath:parent.path) {
                let children = try fm.contentsOfDirectory(at:parent,includingPropertiesForKeys:nil)
                guard children.count <= 20_000 else { throw ManagedAppCatalogError.invalid("application directory capacity") }
                for child in children { occupied.insert(Self.filenameKey(child.lastPathComponent)) }
            }
        }
        let plain = Self.bundleFilename(package,name:name)
        if !occupied.contains(Self.filenameKey(plain)) { return plain }
        let qualifier = Self.filenameStem(package,limit:80)
        for number in 1...10_001 {
            let suffix = " ("+qualifier+(number == 1 ? "" : " \(number)")+").app"
            let candidate = Self.filenameStem(name,limit:210-suffix.utf8.count)+suffix
            if !occupied.contains(Self.filenameKey(candidate)) { return candidate }
        }
        throw ManagedAppCatalogError.invalid("application name capacity")
    }

    public static func deviceHash(_ serial: String) -> String { SHA256.hash(data: Data(serial.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined() }
    public static func bundleIdentifier(serial: String, packageName: String) -> String { "app.droidbridge.managed.d\(deviceHash(serial)).\(packageName)" }

    public func records() throws -> [ManagedAppRecord] { try locked { manifest in manifest.records.values.sorted { $0.key < $1.key } } }
    public func canRepairNames(runningBundlePaths: Set<String> = []) throws -> Bool {
        let running = Set(runningBundlePaths.map { Self.canonical(URL(fileURLWithPath:$0)) })
        return try locked { cleanNamesAllowed($0,running:running) }
    }
    public func savedLaunchConfiguration(for record: ManagedAppRecord) throws -> [String:String] {
        try locked { manifest in
            guard manifest.records[record.key]?.generation == record.generation, manifest.publications[record.key] == nil else { throw ManagedAppCatalogError.busy }
            try validateBundle(record.bundleURL,record:record)
            guard let options = try boundedDictionary(record.bundleURL.appendingPathComponent("Contents/Resources/launch.json"),plist:false) as? [String:String] else { throw ManagedAppCatalogError.invalid("saved launch configuration") }
            return options
        }
    }
    public func savedIcon(for record: ManagedAppRecord) throws -> Data {
        let url = try locked { manifest in
            guard manifest.records[record.key]?.generation == record.generation, manifest.publications[record.key] == nil else { throw ManagedAppCatalogError.busy }
            try validateBundle(record.bundleURL,record:record)
            let url = record.bundleURL.appendingPathComponent("Contents/Resources/AndroidApp.png")
            try rejectSymlink(url,below:root(containing:url))
            return url
        }
        // Byte staging stays outside the catalog lock. A concurrent availability
        // move can refuse this read and be retried without altering accepted state.
        let fd = open(url.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard fd >= 0 else { throw ManagedAppCatalogError.invalid("saved Android icon unavailable") }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(fd,&metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_size <= 4*1024*1024 else { throw ManagedAppCatalogError.invalid("saved Android icon size/type") }
        return try handle.read(upToCount:4*1024*1024+1) ?? Data()
    }
    public func issues() throws -> [ManagedAppIssue] { try locked { manifest in Array(manifest.issues.values.sorted { $0.key < $1.key }.prefix(32)) } }
    public func isCurrent(_ record: ManagedAppRecord, hostVersion: String, hostBuild: String, backend: BackendKind, name: String) throws -> Bool {
        try locked { manifest in
            guard manifest.records[record.key]?.generation == record.generation,
                  manifest.publications[record.key] == nil, record.sourceVersion == hostVersion,
                  record.sourceBuild == hostBuild, record.backend == backend, record.name == name else { return false }
            return (try? validateBundle(record.bundleURL, record: record)) != nil
        }
    }
    public func companionExportAllowed(serial: String, packageName: String) throws -> Bool {
        try AndroidDiscovery.validateSerial(serial); try AndroidDiscovery.validatePackage(packageName)
        return try locked { _ in exportSnapshot.allows(serial: serial, packageName: packageName) }
    }
    public func reserve(device: AndroidDevice, application: AndroidApplication, backend: BackendKind, runningBundlePaths: Set<String> = [], adoptManualWrappers: Bool = false, preserveLegacyFilename: Bool = false) throws -> ManagedAppReservation {
        try AndroidDiscovery.validateSerial(device.serial); try AndroidDiscovery.validatePackage(application.packageName)
        guard !application.name.isEmpty, application.name.utf8.count <= 1024 else { throw ManagedAppCatalogError.invalid("application name") }
        let normalizedRunning = Set(runningBundlePaths.map { Self.canonical(URL(fileURLWithPath:$0)) })
        return try locked { manifest in
            guard exportSnapshot.allows(serial: device.serial, packageName: application.packageName) else { throw ManagedAppCatalogError.invalid("This app is excluded from Mac export") }
            let hash = Self.deviceHash(device.serial), key = hash + ":" + application.packageName
            guard manifest.publications[key] == nil else { throw ManagedAppCatalogError.busy }
            if let reservation = manifest.reservations[key], kill(reservation.ownerPID, 0) == 0 || errno == EPERM { throw ManagedAppCatalogError.busy }
            if let previous = manifest.records[key], normalizedRunning.contains(Self.canonical(previous.bundleURL)) { throw ManagedAppCatalogError.running }
            let adoption = adoptManualWrappers ? try findManual(device: device, application: application, running: normalizedRunning) : nil
            var selectedApplication = application, selectedBackend = backend
            if let existing = manifest.records[key] {
                selectedApplication = AndroidApplication(packageName:application.packageName,name:existing.name); selectedBackend = existing.backend
            }
            if let adoption, let saved = try JSONSerialization.jsonObject(with: adoption.configuration) as? [String:String], let savedName = saved["name"], let savedBackend = saved["backend"].flatMap(BackendKind.init(rawValue:)) {
                selectedApplication = AndroidApplication(packageName: application.packageName, name: savedName); selectedBackend = savedBackend
            }
            let filename: String
            if let existing = manifest.records[key], preserveLegacyFilename || !Self.needsNameRepair(existing) || !cleanNamesAllowed(manifest,running:normalizedRunning) { filename = existing.bundleFilename }
            else if !cleanNamesAllowed(manifest,running:normalizedRunning) || preserveLegacyFilename { filename = Self.legacyFilename(application.packageName,name:selectedApplication.name) }
            else { filename = try chooseFilename(package:application.packageName,name:selectedApplication.name,hash:hash,key:key,manifest:manifest) }
            let id = UUID(), root = paths.privateRoot.appendingPathComponent("staging/\(id.uuidString)")
            var result = ManagedAppReservation(id: id, key: key, deviceHash: hash, bundleIdentifier: Self.bundleIdentifier(serial: device.serial, packageName: application.packageName), bundleFilename: filename, stagingRoot: root, stagedBundleURL: root.appendingPathComponent(filename), activeBundleURL: activeURL(hash, filename), device: device, application: selectedApplication, backend: selectedBackend, manualAdoption: adoption, previousGeneration: manifest.records[key]?.generation, ownerPID: getpid())
            result.namingVersion = 2
            manifest.issues.removeValue(forKey:key); manifest.reservations[key] = result; try save(manifest); return result
        }
    }
    public func abandon(_ reservation: ManagedAppReservation) throws {
        let released = try locked { manifest -> Bool in
            guard manifest.reservations[reservation.key]?.id == reservation.id, manifest.publications[reservation.key] == nil else { return false }
            manifest.reservations.removeValue(forKey: reservation.key); try save(manifest); return true
        }
        guard released else { return }
        // Only an unpublished reservation can be removed. Once commit journals a
        // publication, cleanup must leave it available for crash recovery.
        guard reservation.stagingRoot.path == paths.privateRoot.appendingPathComponent("staging/\(reservation.id.uuidString)").path else { throw ManagedAppCatalogError.invalid("staging path") }
        try rejectSymlink(reservation.stagingRoot, below: paths.privateRoot)
        if fm.fileExists(atPath: reservation.stagingRoot.path) { try fm.removeItem(at: reservation.stagingRoot) }
    }
    public func commit(_ reservation: ManagedAppReservation, runningBundlePaths: Set<String> = []) throws -> ManagedAppRecord {
        let normalizedRunning = Set(runningBundlePaths.map { Self.canonical(URL(fileURLWithPath:$0)) })
        return try locked { manifest in
            guard manifest.reservations[reservation.key] == reservation,
                  manifest.records[reservation.key]?.generation == reservation.previousGeneration else { throw ManagedAppCatalogError.invalid("expired reservation generation") }
            if let previous = manifest.records[reservation.key], normalizedRunning.contains(Self.canonical(previous.bundleURL)) { throw ManagedAppCatalogError.running }
            let info = try boundedDictionary(reservation.stagedBundleURL.appendingPathComponent("Contents/Info.plist"), plist: true)
            var record = ManagedAppRecord(key: reservation.key, generation: reservation.id, deviceHash: reservation.deviceHash, deviceSerial: reservation.device.serial, deviceModel: reservation.device.model, packageName: reservation.application.packageName, name: reservation.application.name, backend: reservation.backend, bundleIdentifier: reservation.bundleIdentifier, bundleFilename: reservation.bundleFilename, activeBundleURL: reservation.activeBundleURL, inactiveBundleURL: inactiveURL(reservation.deviceHash, reservation.bundleFilename), availability: .inactive, location: .inactive, sourceVersion: info["CFBundleShortVersionString"] as? String ?? "", sourceBuild: info["CFBundleVersion"] as? String ?? "")
            record.namingVersion = info["DroidBridgeManagedNamingVersion"] as? Int ?? 1
            try validateBundle(reservation.stagedBundleURL, record: record)
            if let previous = manifest.records[record.key] {
                for oldURL in [previous.activeBundleURL,previous.inactiveBundleURL] {
                    var metadata = stat()
                    if lstat(oldURL.path,&metadata) == 0 { try validateBundle(oldURL,record:previous) }
                    else if errno != ENOENT { throw ManagedAppCatalogError.invalid("previous generation ownership unavailable") }
                }
            }
            manifest.publications[record.key] = Publication(reservation: reservation, candidate: record, previous: manifest.records[record.key])
            if let previous = manifest.records[record.key], previous.activeBundleURL != record.activeBundleURL || Self.needsNameRepair(previous) { manifest.retiredNames[previous.generation.uuidString] = previous }
            if let previous = manifest.records[record.key], previous.location == .active { enqueue(register: false, record: previous, manifest: &manifest) }
            if let adoption = reservation.manualAdoption { enqueueUnregister(url: adoption.bundleURL, key: record.key, generation: record.generation, manifest: &manifest) }
            try save(manifest)
            try finishPublication(record.key, manifest: &manifest)
            return manifest.records[record.key] ?? record
        }
    }
    /// Positive ADB authorization is the only availability admission. Unknown,
    /// absent, unauthorized and feature-disabled cohorts remain private/noindex.
    public func reconcile(availableSerials: Set<String>, enabled: Bool) throws -> [ManagedAppRegistrationAction] {
        try locked { manifest in
            guard availableSerials.count <= 10_000 else { throw ManagedAppCatalogError.invalid("availability cohort limit") }
            for serial in availableSerials { try AndroidDiscovery.validateSerial(serial) }
            let admittedSerials = enabled ? availableSerials : []
            let policyChanged = manifest.policyEnabled != enabled || manifest.availableSerials != admittedSerials
            manifest.policyEnabled = enabled; manifest.availableSerials = admittedSerials
            manifest.actions.removeAll { action in
                guard action.register else { return false }
                guard let record = manifest.records[action.key] else { return true }
                return !enabled || !availableSerials.contains(record.deviceSerial) || !exportSnapshot.allows(serial: record.deviceSerial, packageName: record.packageName) || record.generation != action.generation || record.availability != .active || record.location != .active || manifest.publications[action.key] != nil
            }
            // A malformed/missing owned row may refuse its move, but cannot
            // roll back a newer cohort-wide deny decision for unrelated rows.
            if policyChanged { try save(manifest) }
            let now = Date()
            for key in manifest.publications.keys.sorted().filter({ (manifest.issues[$0]?.retryAfter ?? .distantPast) <= now }).prefix(2) {
                do { try finishPublication(key,manifest:&manifest); manifest.issues.removeValue(forKey:key) }
                catch { noteIssue(key,error:error,manifest:&manifest) }
            }
            var moves: [(ManagedAppRecord,URL,URL)] = []
            var transitions = 0
            for key in manifest.records.keys.sorted() {
                guard transitions < 64 else { break }
                guard manifest.publications[key] == nil, (manifest.issues[key]?.retryAfter ?? .distantPast) <= now else { continue }
                var record = manifest.records[key]!
                do {
                    let desired: ManagedAppAvailability = enabled && availableSerials.contains(record.deviceSerial) && exportSnapshot.allows(serial: record.deviceSerial, packageName: record.packageName) ? .active : .inactive
                    if !fm.fileExists(atPath:record.bundleURL.path) {
                        let other = record.location == .active ? record.inactiveBundleURL : record.activeBundleURL
                        guard fm.fileExists(atPath:other.path) else { throw ManagedAppCatalogError.invalid("Mac app bundle is missing. Use Add All Device Apps to repair it.") }
                        try validateBundle(other,record:record)
                        moves.append((record,other,record.bundleURL)); transitions += 1; continue
                    }
                    if desired == record.availability && desired == record.location { manifest.issues.removeValue(forKey:key); continue }
                    try validateBundle(record.bundleURL,record:record)
                    record.availability = desired; manifest.records[key] = record; transitions += 1
                    if desired == .active && record.location == .inactive {
                        let source = record.bundleURL; record.location = .active; manifest.records[key] = record
                        enqueue(register:true,record:record,manifest:&manifest); moves.append((record,source,record.activeBundleURL))
                    } else if desired == .inactive && record.location == .active { enqueue(register:false,record:record,manifest:&manifest) }
                    else if desired == .active && manifest.actions.contains(where: { $0.key == key && !$0.register }) { enqueue(register:true,record:record,manifest:&manifest) }
                    manifest.issues.removeValue(forKey:key)
                } catch { transitions += 1; noteIssue(key,error:error,manifest:&manifest) }
            }
            try save(manifest)
            var moveFailed = false
            for (record,source,target) in moves {
                do { try relocate(record:record,source:source,target:target) }
                catch { noteIssue(record.key,error:error,manifest:&manifest); moveFailed = true }
            }
            if moveFailed { try save(manifest) }

            return manifest.actions.sorted { !$0.register && $1.register }
        }
    }
    /// Remaining local moves/publications, in addition to returned LS receipts.
    /// Coordinators use this to continue finite batches without waiting a full poll.
    public func pendingTransitionCount() throws -> Int {
        try locked { manifest in
            let now = Date()
            var count = manifest.publications.keys.filter { (manifest.issues[$0]?.retryAfter ?? .distantPast) <= now }.count
            for record in manifest.records.values {
                guard (manifest.issues[record.key]?.retryAfter ?? .distantPast) <= now else { continue }
                let desired: ManagedAppAvailability = manifest.policyEnabled && manifest.availableSerials.contains(record.deviceSerial) && exportSnapshot.allows(serial: record.deviceSerial, packageName: record.packageName) ? .active : .inactive
                if record.availability != desired || record.location != desired || !fm.fileExists(atPath:record.bundleURL.path) { count += 1 }
            }
            return count
        }
    }
    public func registrationIsCurrent(_ action: ManagedAppRegistrationAction) throws -> Bool {
        try locked { manifest in
            guard manifest.actions.contains(action) else { return false }
            if !action.register {
                var metadata = stat()
                if lstat(action.bundleURL.path,&metadata) != 0 {
                    guard errno == ENOENT else { throw ManagedAppCatalogError.invalid("unregister ownership unavailable") }
                    return true // Exact journal-owned old URL is already absent.
                }
                if let publication = manifest.publications[action.key], let adoption = publication.reservation.manualAdoption, adoption.bundleURL.path == action.bundleURL.path {
                    try validateManual(adoption,serial:publication.candidate.deviceSerial,package:publication.candidate.packageName)
                } else if let record = manifest.records[action.key], record.activeBundleURL.path == action.bundleURL.path {
                    try validateBundle(action.bundleURL,record:record)
                } else if let record = manifest.retiredNames[action.generation.uuidString], record.key == action.key, record.activeBundleURL.path == action.bundleURL.path {
                    try validateBundle(action.bundleURL,record:record)
                } else { throw ManagedAppCatalogError.invalid("unregister path has no current owned bundle") }
                return true
            }
            guard let record = manifest.records[action.key] else { return false }
            return (manifest.policyEnabled && manifest.availableSerials.contains(record.deviceSerial) && exportSnapshot.allows(serial: record.deviceSerial, packageName: record.packageName) && record.generation == action.generation && record.availability == .active && record.location == .active && manifest.publications[action.key] == nil && (try? validateBundle(record.activeBundleURL, record: record)) != nil)
        }
    }
    /// Returns false when an effect became stale during dispatch. A durable
    /// compensating unregister/register is retained; no successor receipt is acked.
    @discardableResult
    public func completeRegistration(_ action: ManagedAppRegistrationAction) throws -> Bool {
        try completeRegistrations([action])[action.id] ?? false
    }
    /// A finite coordinator wave acknowledges actual completed external effects
    /// with one durable journal, avoiding a full-manifest write per application.
    public func completeRegistrations(_ actions: [ManagedAppRegistrationAction]) throws -> [UUID:Bool] {
        guard actions.count <= 64 else { throw ManagedAppCatalogError.invalid("registration completion batch limit") }
        return try locked { manifest in
            var results: [UUID:Bool] = [:]
            var moves: [(ManagedAppRecord,URL,URL)] = []
            for action in actions {
                let present = manifest.actions.contains(action)
                manifest.actions.removeAll { $0.id == action.id && $0 == action }
                results[action.id] = present
                if action.register {
                    guard let record = manifest.records[action.key] else { throw ManagedAppCatalogError.invalid("completed registration owner") }
                    if action.bundleURL.path != record.activeBundleURL.path {
                        guard let retired = manifest.retiredNames[action.generation.uuidString], retired.key == action.key, retired.activeBundleURL.path == action.bundleURL.path else { throw ManagedAppCatalogError.invalid("completed registration path") }
                        enqueueUnregister(url:action.bundleURL,key:action.key,generation:action.generation,manifest:&manifest,supersedeRegistrations:false)
                        if manifest.policyEnabled && manifest.availableSerials.contains(record.deviceSerial) && exportSnapshot.allows(serial: record.deviceSerial, packageName: record.packageName) && record.availability == .active && record.location == .active && manifest.publications[action.key] == nil { enqueue(register:true,record:record,manifest:&manifest) }
                        results[action.id] = false
                        continue
                    }
                    if !manifest.policyEnabled || !manifest.availableSerials.contains(record.deviceSerial) || !exportSnapshot.allows(serial: record.deviceSerial, packageName: record.packageName) || record.generation != action.generation || record.availability != .active || record.location != .active || manifest.publications[action.key] != nil {
                        enqueueUnregister(url:action.bundleURL,key:action.key,generation:action.generation,manifest:&manifest,supersedeRegistrations:false)
                        if manifest.policyEnabled && manifest.availableSerials.contains(record.deviceSerial) && exportSnapshot.allows(serial: record.deviceSerial, packageName: record.packageName) && record.availability == .active && record.location == .active && manifest.publications[action.key] == nil { enqueue(register:true,record:record,manifest:&manifest) }
                        results[action.id] = false
                    }
                } else if let record = manifest.records[action.key], action.bundleURL.path == record.activeBundleURL.path, record.availability == .inactive && record.location == .active && manifest.publications[action.key] == nil {
                    var successor = record; successor.location = .inactive; manifest.records[action.key] = successor
                    moves.append((successor,record.activeBundleURL,record.inactiveBundleURL))
                }
                if !action.register, let current = manifest.records[action.key], manifest.policyEnabled, manifest.availableSerials.contains(current.deviceSerial), exportSnapshot.allows(serial: current.deviceSerial, packageName: current.packageName), current.availability == .active, current.location == .active, action.bundleURL.path == current.activeBundleURL.path, manifest.publications[action.key] == nil {
                    enqueue(register:true,record:current,manifest:&manifest)
                }
            }
            try save(manifest)
            for (record,source,target) in moves {
                do { try relocate(record:record,source:source,target:target) }
                catch { noteIssue(record.key,error:error,manifest:&manifest) }
            }
            for key in manifest.publications.keys.sorted().filter({ (manifest.issues[$0]?.retryAfter ?? .distantPast) <= Date() }).prefix(2) {
                do { try finishPublication(key,manifest:&manifest); manifest.issues.removeValue(forKey:key) }
                catch { noteIssue(key,error:error,manifest:&manifest) }
            }
            if !manifest.issues.isEmpty { try save(manifest) }
            return results
        }
    }
    public func isLaunchAllowed(bundleURL: URL, serial: String, packageName: String) throws -> Bool {
        try locked { manifest in
            let key = Self.deviceHash(serial) + ":" + packageName
            guard let record = manifest.records[key], manifest.policyEnabled, manifest.availableSerials.contains(serial), exportSnapshot.allows(serial: serial, packageName: packageName), record.availability == .active, record.location == .active,
                  manifest.publications[key] == nil, Self.canonical(bundleURL) == Self.canonical(record.activeBundleURL) else { return false }
            return (try? validateBundle(record.activeBundleURL, record: record)) != nil
        }
    }
    private func finishPublication(_ key: String, manifest: inout Manifest) throws {
        guard let publication = manifest.publications[key] else { return }
        let record = publication.candidate
        if manifest.actions.contains(where: { $0.key == key && !$0.register }) { return }
        if let adoption = publication.reservation.manualAdoption {
            let backup = paths.privateRoot.appendingPathComponent("manual-backups/\(record.deviceHash)/\(record.packageName)-\(record.generation.uuidString).app")
            if fm.fileExists(atPath: adoption.bundleURL.path) {
                try validateManual(adoption, serial: record.deviceSerial, package: record.packageName)
                try moveManualExclusive(adoption.bundleURL, backup)
            } else { try validateManual(adoption, serial: record.deviceSerial, package: record.packageName, at: backup) }
        }
        if let previous = publication.previous {
            let backup = paths.privateRoot.appendingPathComponent("backups/\(previous.deviceHash)/\(previous.packageName)-\(previous.generation.uuidString).app")
            let other = previous.location == .active ? previous.inactiveBundleURL : previous.activeBundleURL
            let existing = [previous.bundleURL,other].filter { fm.fileExists(atPath:$0.path) }
            guard existing.count <= 1 else { throw ManagedAppCatalogError.invalid("ambiguous previous-generation locations") }
            if let source = existing.first { try validateBundle(source,record:previous); try moveExclusive(source,backup) }
            else if fm.fileExists(atPath:backup.path) { try validateBundle(backup,record:previous) }
            else {
                // User deletion is repairable; metadata history remains even
                // when no previous bundle bytes survive. Foreign bytes never qualify.
                try rejectSymlink(previous.activeBundleURL,below:paths.activeRoot)
                try rejectSymlink(previous.inactiveBundleURL,below:paths.privateRoot)
                manifest.missingHistory[previous.generation.uuidString] = previous
            }
        }
        if fm.fileExists(atPath: publication.reservation.stagedBundleURL.path) {
            try validateBundle(publication.reservation.stagedBundleURL, record: record)
            try moveExclusive(publication.reservation.stagedBundleURL, record.inactiveBundleURL)
        } else { try validateBundle(record.inactiveBundleURL, record: record) }
        manifest.actions.removeAll { $0.key == key && $0.register }
        manifest.issues.removeValue(forKey:key); manifest.records[key] = record; manifest.reservations.removeValue(forKey: key); manifest.publications.removeValue(forKey: key); try save(manifest)
    }
    private func noteIssue(_ key: String, error: Error, manifest: inout Manifest) {
        manifest.issues[key] = ManagedAppIssue(key:key,message:String(error.localizedDescription.prefix(350)),retryAfter:Date().addingTimeInterval(60))
        manifest.actions.removeAll { $0.key == key && $0.register }
    }
    private func enqueueUnregister(url: URL, key: String, generation: UUID, manifest: inout Manifest, supersedeRegistrations: Bool = true) {
        if supersedeRegistrations { manifest.actions.removeAll { $0.key == key && $0.register } }
        if !manifest.actions.contains(where: { !$0.register && $0.key == key && $0.bundleURL == url && $0.generation == generation }) { manifest.actions.append(ManagedAppRegistrationAction(id: UUID(), bundleURL: url, register: false, key: key, generation: generation)) }
    }
    private func enqueue(register: Bool, record: ManagedAppRecord, manifest: inout Manifest) {
        // A newer availability decision supersedes a queued registration. Always
        // unregister by the stable public URL, including after a move/crash.
        manifest.actions.removeAll { $0.key == record.key && $0.register && (!register || $0.generation != record.generation || $0.bundleURL.path != record.activeBundleURL.path) }
        if !manifest.actions.contains(where: { $0.key == record.key && $0.register == register && $0.generation == record.generation }) {
            manifest.actions.append(ManagedAppRegistrationAction(id: UUID(), bundleURL: record.activeBundleURL, register: register, key: record.key, generation: record.generation))
        }
    }
    private func relocate(record: ManagedAppRecord, source: URL, target: URL) throws {
        if fm.fileExists(atPath: source.path) { try validateBundle(source, record: record); try moveExclusive(source, target) }
        else { try validateBundle(target, record: record) }
    }
    private func moveExclusive(_ source: URL, _ destination: URL) throws {
        try rejectSymlink(source, below: root(containing: source)); try rejectSymlink(destination, below: root(containing: destination))
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw ManagedAppCatalogError.invalid("atomic owned move failed errno \(errno); no destination replaced") }
    }
    private func validateBundle(_ url: URL, record: ManagedAppRecord) throws {
        try rejectSymlink(url, below: root(containing: url))
        let info = try boundedDictionary(url.appendingPathComponent("Contents/Info.plist"), plist: true)
        try rejectSymlink(url.appendingPathComponent("Contents/MacOS/DroidBridge"), below: root(containing: url))
        let launch = try boundedDictionary(url.appendingPathComponent("Contents/Resources/launch.json"), plist: false)
        guard info["CFBundleIdentifier"] as? String == record.bundleIdentifier,
              info["DroidBridgeManagedGeneration"] as? String == record.generation.uuidString,
              info["DroidBridgeManagedDevice"] as? String == record.deviceHash,
              launch["managed_key"] as? String == record.key,
              launch["managed_generation"] as? String == record.generation.uuidString,
              launch["serial"] as? String == record.deviceSerial, launch["package"] as? String == record.packageName,
              launch["name"] as? String == record.name, launch["backend"] as? String == record.backend.rawValue,
              (record.namingVersion ?? 1) < 2 || info["DroidBridgeManagedNamingVersion"] as? Int == record.namingVersion,
              fm.isExecutableFile(atPath: url.appendingPathComponent("Contents/MacOS/DroidBridge").path) else { throw ManagedAppCatalogError.invalid("owned bundle metadata mismatch at \(url.lastPathComponent)") }
    }
    private func boundedDictionary(_ url: URL, plist: Bool) throws -> [String: Any] {
        try rejectSymlink(url, below: root(containing: url))
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 65_536 else { throw ManagedAppCatalogError.invalid("oversized metadata") }
        let bytes = try Data(contentsOf: url)
        let value = plist ? try PropertyListSerialization.propertyList(from: bytes, format: nil) : try JSONSerialization.jsonObject(with: bytes)
        guard let dictionary = value as? [String: Any] else { throw ManagedAppCatalogError.invalid("metadata object") }; return dictionary
    }
    private func activeURL(_ hash: String, _ filename: String) -> URL { paths.activeRoot.appendingPathComponent(hash).appendingPathComponent(filename) }
    private func inactiveURL(_ hash: String, _ filename: String) -> URL { paths.privateRoot.appendingPathComponent("inactive/\(hash)/\(filename)") }
    private static func canonical(_ url: URL) -> String {
        guard let resolved = realpath(url.path,nil) else { return url.path }
        defer { free(resolved) }; return String(cString:resolved)
    }
    private func root(containing url: URL) throws -> URL {
        for root in [paths.privateRoot, paths.activeRoot] where url.path.hasPrefix(root.path + "/") { return root }
        throw ManagedAppCatalogError.invalid("path outside managed roots")
    }
    private func rejectSymlink(_ url: URL, below root: URL) throws {
        guard url.path == root.path || url.path.hasPrefix(root.path + "/") else { throw ManagedAppCatalogError.invalid("path traversal") }
        var current = url
        while current.path.count >= root.path.count {
            var attributes = stat()
            if lstat(current.path, &attributes) == 0, (attributes.st_mode & S_IFMT) == S_IFLNK { throw ManagedAppCatalogError.invalid("symbolic link in owned path") }
            if current == root { break }; current.deleteLastPathComponent()
        }
    }
    private func rejectRootAncestry(_ url: URL) throws {
        var current = url
        while current.path != "/" {
            var metadata = stat()
            if lstat(current.path,&metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFLNK { throw ManagedAppCatalogError.invalid("symbolic link above managed root") }
            current.deleteLastPathComponent()
        }
    }
    private func locked<T>(_ operation: (inout Manifest) throws -> T) throws -> T {
        guard paths.privateRoot.isFileURL, paths.activeRoot.isFileURL, paths.privateRoot.path.hasSuffix(".noindex"), !paths.activeRoot.path.hasPrefix(paths.privateRoot.path + "/"), !paths.privateRoot.path.hasPrefix(paths.activeRoot.path + "/") else { throw ManagedAppCatalogError.invalid("root layout") }
        try rejectRootAncestry(paths.privateRoot); try rejectRootAncestry(paths.activeRoot)
        try fm.createDirectory(at: paths.privateRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: paths.activeRoot, withIntermediateDirectories: true)
        let lockURL = paths.privateRoot.appendingPathComponent("catalog.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ManagedAppCatalogError.invalid("lock file") }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        let lockDeadline = ProcessInfo.processInfo.systemUptime + 0.150
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            try Task.checkCancellation()
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else { throw ManagedAppCatalogError.invalid("lock acquisition") }
            guard ProcessInfo.processInfo.systemUptime < lockDeadline else { throw ManagedAppCatalogError.busy }
            Thread.sleep(forTimeInterval:0.005)
        }
        try Task.checkCancellation()
        let policyURL = CompanionExportPolicy.url(paths: paths)
        var policyMetadata = stat()
        if lstat(policyURL.path, &policyMetadata) == 0 {
            let fingerprint = ManifestFingerprint(policyMetadata)
            if exportFingerprint != fingerprint {
                exportSnapshot = (try? CompanionExportPolicy.read(policyURL)).map(CompanionExportPolicy.Snapshot.init) ?? .unavailable
                exportFingerprint = fingerprint
            }
        } else {
            exportSnapshot = errno == ENOENT ? .unrestricted : .unavailable
            exportFingerprint = nil
        }
        var manifest = Manifest()
        let url = paths.privateRoot.appendingPathComponent("catalog.json")
        if fm.fileExists(atPath: url.path) {
            try rejectSymlink(url, below: paths.privateRoot)
            guard let size = try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber, size.intValue <= 8 * 1024 * 1024 else { throw ManagedAppCatalogError.invalid("manifest size") }
            var metadata = stat()
            guard lstat(url.path,&metadata) == 0 else { throw ManagedAppCatalogError.invalid("manifest metadata unavailable") }
            let fingerprint = ManifestFingerprint(metadata)
            if let cachedManifest, cachedFingerprint == fingerprint {
                manifest = cachedManifest
            } else {
            manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
            guard [1, 2].contains(manifest.version), manifest.records.count <= 10_000, manifest.reservations.count <= 10_000, manifest.actions.count <= 30_000, manifest.publications.count <= 10_000, manifest.availableSerials.count <= 10_000, manifest.issues.count <= 10_000, manifest.missingHistory.count <= 10_000, manifest.retiredNames.count <= 10_000 else { throw ManagedAppCatalogError.invalid("manifest limits/version") }
            for serial in manifest.availableSerials { try AndroidDiscovery.validateSerial(serial) }
            for (id,record) in manifest.missingHistory {
                guard id == record.generation.uuidString else { throw ManagedAppCatalogError.invalid("missing history identity") }
                try validateRecord(record,key:record.key)
            }
            for (id,record) in manifest.retiredNames {
                guard id == record.generation.uuidString, manifest.records[record.key] != nil || manifest.publications[record.key] != nil else { throw ManagedAppCatalogError.invalid("retired name owner") }
                try validateRecord(record,key:record.key)
            }
            for (key,issue) in manifest.issues {
                guard issue.key == key, issue.message.utf8.count <= 4096, manifest.records[key] != nil || manifest.publications[key] != nil else { throw ManagedAppCatalogError.invalid("issue owner/size") }
            }
            for (key, record) in manifest.records { try validateRecord(record, key: key) }
            for (key, reservation) in manifest.reservations { try validateReservation(reservation, key: key) }
            for (key, publication) in manifest.publications {
                try validateReservation(publication.reservation, key: key); try validateRecord(publication.candidate, key: key)
                guard publication.candidate.generation == publication.reservation.id else { throw ManagedAppCatalogError.invalid("publication generation") }
                if let previous = publication.previous { try validateRecord(previous, key: key) }
            }
            for action in manifest.actions {
                guard let record = manifest.records[action.key] ?? manifest.publications[action.key]?.candidate else { throw ManagedAppCatalogError.invalid("unknown action owner") }
                let publication = manifest.publications[action.key]
                let manual = publication?.reservation.manualAdoption?.bundleURL
                let retired = manifest.retiredNames[action.generation.uuidString]
                let retiredMatch = retired?.key == action.key && retired?.activeBundleURL.path == action.bundleURL.path
                guard action.bundleURL.isFileURL, action.bundleURL.path == record.activeBundleURL.path || action.bundleURL.path == publication?.candidate.activeBundleURL.path || (!action.register && action.bundleURL.path == manual?.path) || retiredMatch else { throw ManagedAppCatalogError.invalid("action path") }
            }
            cachedManifest = manifest; cachedFingerprint = fingerprint
            }
        } else { cachedManifest = nil; cachedFingerprint = nil }
        return try operation(&manifest)
    }
    private func validateFilename(_ filename: String, package: String, name: String) throws {
        let suffix = "-" + SHA256.hash(data:Data(package.utf8)).prefix(8).map { String(format:"%02x",$0) }.joined() + ".app"
        var clean = filename == Self.bundleFilename(package,name:name)
        if !clean {
            let qualifier = Self.filenameStem(package,limit:80)
            let tail = ").app"
            if filename.hasSuffix(tail), let range = filename.range(of:" ("+qualifier,options:.backwards) {
                let numeric = String(filename[range.upperBound..<filename.index(filename.endIndex,offsetBy:-tail.count)])
                if numeric.isEmpty || (numeric.hasPrefix(" ") && Int(numeric.dropFirst()).map({ (2...10_001).contains($0) }) == true) {
                    let extra = " ("+qualifier+numeric+tail
                    clean = filename == Self.filenameStem(name,limit:210-extra.utf8.count)+extra
                }
            }
        }
        guard (filename.hasSuffix(suffix) || clean), filename.utf8.count <= 220, !filename.hasPrefix("."), !filename.contains("/"), !filename.contains(":"), !filename.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { throw ManagedAppCatalogError.invalid("friendly filename binding") }
    }
    private func validateRecord(_ record: ManagedAppRecord, key: String) throws {
        try AndroidDiscovery.validateSerial(record.deviceSerial); try AndroidDiscovery.validatePackage(record.packageName)
        try validateFilename(record.bundleFilename, package:record.packageName,name:record.name)
        guard key == record.key, record.deviceHash == Self.deviceHash(record.deviceSerial), key == record.deviceHash + ":" + record.packageName,
              record.bundleIdentifier == Self.bundleIdentifier(serial: record.deviceSerial, packageName: record.packageName),
              record.activeBundleURL.path == activeURL(record.deviceHash, record.bundleFilename).path, record.inactiveBundleURL.path == inactiveURL(record.deviceHash, record.bundleFilename).path, record.name.utf8.count <= 1024 else { throw ManagedAppCatalogError.invalid("manifest record identity") }
    }
    private func validateReservation(_ reservation: ManagedAppReservation, key: String) throws {
        try AndroidDiscovery.validateSerial(reservation.device.serial); try AndroidDiscovery.validatePackage(reservation.application.packageName)
        try validateFilename(reservation.bundleFilename, package:reservation.application.packageName,name:reservation.application.name)
        guard reservation.ownerPID > 0, reservation.key == key, reservation.deviceHash == Self.deviceHash(reservation.device.serial),
              key == reservation.deviceHash + ":" + reservation.application.packageName,
              reservation.bundleIdentifier == Self.bundleIdentifier(serial: reservation.device.serial, packageName: reservation.application.packageName),
              reservation.stagingRoot.path == paths.privateRoot.appendingPathComponent("staging/\(reservation.id.uuidString)").path,
              reservation.stagedBundleURL.path == reservation.stagingRoot.appendingPathComponent(reservation.bundleFilename).path,
              reservation.activeBundleURL.path == activeURL(reservation.deviceHash, reservation.bundleFilename).path else { throw ManagedAppCatalogError.invalid("reservation paths") }
        try rejectSymlink(reservation.stagingRoot, below: paths.privateRoot)
        if let adoption = reservation.manualAdoption { try validateManualPath(adoption.bundleURL) }
    }
    private var manualRoot: URL { paths.activeRoot.deletingLastPathComponent() }
    private func validateManualPath(_ url: URL) throws {
        guard url.deletingLastPathComponent().path == manualRoot.path, url.pathExtension == "app", !url.lastPathComponent.hasPrefix(".") else { throw ManagedAppCatalogError.invalid("manual adoption path \(url.path), expected parent \(manualRoot.path)") }
        try rejectSymlink(url, below: manualRoot)
    }
    private func findManual(device: AndroidDevice, application: AndroidApplication, running: Set<String>) throws -> ManagedAppManualAdoption? {
        guard fm.fileExists(atPath: manualRoot.path) else { return nil }
        let children = try fm.contentsOfDirectory(at: manualRoot, includingPropertiesForKeys: nil)
        guard children.count <= 10_000 else { throw ManagedAppCatalogError.invalid("manual application directory size") }
        var matches: [ManagedAppManualAdoption] = []
        for candidate in children where candidate.pathExtension == "app" && !candidate.lastPathComponent.hasPrefix(".") {
            try validateManualPath(candidate)
            let infoURL = candidate.appendingPathComponent("Contents/Info.plist"), configURL = candidate.appendingPathComponent("Contents/Resources/launch.json")
            guard let info = try? manualDictionary(infoURL, plist: true), info["CFBundleIdentifier"] as? String == "app.droidbridge.wrapper.\(application.packageName)",
                  let config = try? manualDictionary(configURL, plist: false), config["serial"] as? String == device.serial, config["package"] as? String == application.packageName else { continue }
            if running.contains(Self.canonical(candidate)) { throw ManagedAppCatalogError.running }
            let adoption = ManagedAppManualAdoption(bundleURL: candidate, infoSHA256: digest(try Data(contentsOf: infoURL)), configuration: try Data(contentsOf: configURL))
            try validateManual(adoption, serial: device.serial, package: application.packageName); matches.append(adoption)
        }
        guard matches.count <= 1 else { throw ManagedAppCatalogError.invalid("ambiguous matching manual wrappers") }
        return matches.first
    }
    private func validateManual(_ adoption: ManagedAppManualAdoption, serial: String, package: String, at override: URL? = nil) throws {
        try validateManualPath(adoption.bundleURL)
        let url = override ?? adoption.bundleURL
        if override != nil { try rejectSymlink(url, below: paths.privateRoot) }
        let infoURL = url.appendingPathComponent("Contents/Info.plist"), configURL = url.appendingPathComponent("Contents/Resources/launch.json")
        let info = try manualDictionary(infoURL, plist: true), config = try manualDictionary(configURL, plist: false)
        guard info["CFBundleIdentifier"] as? String == "app.droidbridge.wrapper.\(package)", info["CFBundleExecutable"] as? String == "DroidBridge", info["CFBundlePackageType"] as? String == "APPL", config["serial"] as? String == serial,
              config["package"] as? String == package, let backend = config["backend"] as? String, BackendKind(rawValue: backend) != nil,
              let name = config["name"] as? String, !name.isEmpty,
              (info["DroidBridgeWrapperFormat"] as? Int == 2 || (info["CFBundleShortVersionString"] as? String == "0.1.0" && info["CFBundleVersion"] as? String == "1")),
              info["DroidBridgeManagedDevice"] == nil, digest(try Data(contentsOf:infoURL)) == adoption.infoSHA256,
              try Data(contentsOf: configURL) == adoption.configuration else { throw ManagedAppCatalogError.invalid("manual wrapper changed or ownership mismatch") }
    }
    private func manualDictionary(_ url: URL, plist: Bool) throws -> [String:Any] {
        let root = url.path.hasPrefix(paths.privateRoot.path + "/") ? paths.privateRoot : manualRoot
        try rejectSymlink(url, below: root)
        guard let size = try fm.attributesOfItem(atPath:url.path)[.size] as? NSNumber, size.intValue <= 65_536 else { throw ManagedAppCatalogError.invalid("manual metadata size") }
        let bytes = try Data(contentsOf:url)
        let value = plist ? try PropertyListSerialization.propertyList(from:bytes,format:nil) : try JSONSerialization.jsonObject(with:bytes)
        guard let dictionary = value as? [String:Any] else { throw ManagedAppCatalogError.invalid("manual metadata object") }; return dictionary
    }
    private func moveManualExclusive(_ source: URL, _ destination: URL) throws {
        try validateManualPath(source); try rejectSymlink(destination, below: paths.privateRoot)
        try fm.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
        guard renamex_np(source.path,destination.path,UInt32(RENAME_EXCL)) == 0 else { throw ManagedAppCatalogError.invalid("manual backup move errno \(errno)") }
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    private func save(_ manifest: Manifest) throws {
        let bytes = try JSONEncoder().encode(manifest)
        guard bytes.count <= 8 * 1024 * 1024 else { throw ManagedAppCatalogError.invalid("manifest capacity") }
        let url = paths.privateRoot.appendingPathComponent("catalog.json")
        try bytes.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if file >= 0 { defer { close(file) }; guard fsync(file) == 0 else { throw ManagedAppCatalogError.invalid("manifest sync") } }
        else { throw ManagedAppCatalogError.invalid("manifest sync open") }
        var metadata = stat()
        guard lstat(url.path,&metadata) == 0 else { throw ManagedAppCatalogError.invalid("manifest cache metadata") }
        cachedManifest = manifest; cachedFingerprint = ManifestFingerprint(metadata)
    }
}
