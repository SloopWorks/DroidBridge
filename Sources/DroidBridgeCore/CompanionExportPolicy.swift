import Foundation
import Darwin

/// Separate from the legacy catalog/preferences envelopes: an older writer
/// cannot erase an accepted phone export restriction by re-encoding its schema.
public enum CompanionExportPolicy {
    public static let maximumBytes = 1_048_576
    public static func url(paths: ManagedAppsPaths = .userDefault) -> URL {
        paths.privateRoot.appendingPathComponent("companion-exports.json")
    }
    struct Device: Codable {
        var aliases: [String]
        var selection: [String: Bool]
        var authorityTrustID: String? = nil
        var revisions: [String: Int64]? = nil
        /// Explicit local Forget permits later approved installation reassignment.
        /// Historical selection/revisions remain retained even after aliases move.
        var forgotten: Bool? = nil
        var captureIdentity: String? = nil
    }
    struct Document: Codable {
        var version = 1
        var devices: [String: Device] = [:]
    }
    public struct Snapshot: Sendable {
        private let bySerial: [String: [String: Bool]]
        private let readable: Bool
        static let unrestricted = Snapshot(bySerial: [:], readable: true)
        static let unavailable = Snapshot(bySerial: [:], readable: false)
        public func allows(serial: String, packageName: String) -> Bool {
            readable && bySerial[serial]?[packageName] != false
        }
        init(_ document: Document) {
            bySerial = Dictionary(uniqueKeysWithValues: document.devices.values.flatMap { device in
                device.aliases.map { ($0, device.selection) }
            })
            readable = true
        }
        private init(bySerial: [String: [String: Bool]], readable: Bool) {
            self.bySerial = bySerial; self.readable = readable
        }
    }
    static func validate(_ document: Document) throws {
        guard document.version == 1, document.devices.count <= 32,
              document.devices.values.reduce(0, { $0 + $1.selection.count }) <= 16_384 else {
            throw ManagedAppCatalogError.invalid("companion export policy capacity/version")
        }
        var aliases = Set<String>()
        for (id, device) in document.devices {
            guard UUID(uuidString: id) != nil, (!device.aliases.isEmpty || device.forgotten == true), device.aliases.count <= 8,
                  device.selection.count <= 4096 else { throw ManagedAppCatalogError.invalid("companion export identity/limits") }
            for serial in device.aliases {
                try AndroidDiscovery.validateSerial(serial)
                guard aliases.insert(serial).inserted else { throw ManagedAppCatalogError.invalid("companion export alias conflict") }
            }
            if let capture = device.captureIdentity, UUID(uuidString: capture) == nil { throw ManagedAppCatalogError.invalid("companion capture identity") }
            if let trust = device.authorityTrustID, UUID(uuidString: trust) == nil { throw ManagedAppCatalogError.invalid("companion export trust identity") }
            let revisions = device.revisions ?? [:]
            guard revisions.count <= 4096, revisions.allSatisfy({ device.selection[$0.key] != nil && $0.value > 0 && $0.value <= 9_007_199_254_740_991 }) else { throw ManagedAppCatalogError.invalid("companion export revision") }
            for package in device.selection.keys { try AndroidDiscovery.validatePackage(package) }
        }
    }
    static func read(_ url: URL) throws -> Document {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return Document() }
        guard fd >= 0 else { throw ManagedAppCatalogError.invalid("companion export policy unreadable") }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0,
              metadata.st_size >= 0, metadata.st_size <= maximumBytes else {
            throw ManagedAppCatalogError.invalid("companion export policy ownership/size")
        }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ManagedAppCatalogError.invalid("companion export policy read") }
            if count == 0 { break }
            guard data.count + count <= maximumBytes else { throw ManagedAppCatalogError.invalid("companion export policy size") }
            data.append(contentsOf: buffer.prefix(count))
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        try validate(document); return document
    }
    /// Caller holds the managed catalog lock, serializing decisions and policy
    /// publication with registration/admission. No network or process work here.
    static func write(_ document: Document, to url: URL) throws {
        try validate(document)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw ManagedAppCatalogError.invalid("companion export policy size") }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".exports-\(UUID().uuidString)")
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ManagedAppCatalogError.invalid("companion export policy staging") }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw ManagedAppCatalogError.invalid("companion export policy write") }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw ManagedAppCatalogError.invalid("companion export policy publication") }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if parent >= 0 { defer { close(parent) }; guard fsync(parent) == 0 else { throw ManagedAppCatalogError.invalid("companion export policy durability") } }
    }
}
