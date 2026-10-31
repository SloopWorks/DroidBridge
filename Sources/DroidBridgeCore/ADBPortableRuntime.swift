import Foundation
import CryptoKit
import Darwin

/// A relocatable ADB cohort has a bounded, flat inventory. Keeping every dylib
/// beside adb makes its @loader_path references valid in an app or a helper's
/// immutable generation without rewriting signed bytes during installation.
public struct ADBPortableRuntime: Sendable {
    public static let manifestName = "adb-runtime.json"
    public static let maximumFiles = 16
    public static let maximumFileBytes: Int64 = 64 * 1_048_576
    public static let maximumTotalBytes: Int64 = 128 * 1_048_576
    public struct File: Codable, Equatable, Sendable {
        public let name: String
        public let sha256: String
        public let size: Int64
        public init(name: String, sha256: String, size: Int64) {
            self.name = name; self.sha256 = sha256; self.size = size
        }
    }
    private struct Manifest: Codable { let version: Int; let files: [File] }
    public let directory: URL
    private let adbURL: URL
    /// Includes adb and, for a portable cohort, the manifest itself.
    public let files: [File]
    public let isPortable: Bool
    public var extraFiles: [File] { files.filter { $0.name != "adb" } }
    /// Empty for historical, standalone ADB. This preserves existing identities.
    public var identitySuffix: String {
        guard isPortable else { return "" }
        return extraFiles.sorted { $0.name < $1.name }.map { "\n\($0.name):\($0.sha256):\($0.size)" }.joined()
    }
    public static func inventory(adb: URL, requireOwned: Bool = false) throws -> ADBPortableRuntime {
        let directory = adb.deletingLastPathComponent()
        let manifestURL = directory.appendingPathComponent(manifestName)
        var metadata = stat()
        if lstat(manifestURL.path, &metadata) != 0 {
            guard errno == ENOENT else { throw invalid("ADB runtime manifest is unreadable.") }
            let file = try inspect(adb, name: "adb", requireOwned: requireOwned)
            return ADBPortableRuntime(directory: directory, adbURL: adb, files: [file], isPortable: false)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
              metadata.st_uid == geteuid() || (!requireOwned && metadata.st_uid == 0),
              metadata.st_mode & 0o022 == 0, metadata.st_size > 0, metadata.st_size <= 16_384 else { throw invalid("ADB runtime manifest ownership or size is unsafe.") }
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= 16_384 else { throw invalid("ADB runtime manifest exceeds its byte budget.") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.version == 1, (2..<maximumFiles).contains(manifest.files.count),
              Set(manifest.files.map(\.name)).count == manifest.files.count,
              manifest.files.filter({ $0.name == "adb" }).count == 1 else { throw invalid("ADB runtime inventory has an unsupported version or file count.") }
        var total: Int64 = Int64(data.count)
        for expected in manifest.files {
            guard validName(expected.name), validHash(expected.sha256), expected.size > 0,
                  expected.size <= maximumFileBytes else { throw invalid("ADB runtime inventory contains an invalid file.") }
            total += expected.size
            guard total <= maximumTotalBytes else { throw invalid("ADB runtime inventory exceeds its byte budget.") }
            let url = expected.name == "adb" ? adb : directory.appendingPathComponent(expected.name)
            guard try inspect(url, name: expected.name, requireOwned: requireOwned) == expected else { throw invalid("ADB runtime bytes differ from the signed cohort inventory.") }
        }
        let manifestFile = File(name: manifestName, sha256: hash(data), size: Int64(data.count))
        return ADBPortableRuntime(directory: directory, adbURL: adb, files: manifest.files + [manifestFile], isPortable: true)
    }
    public func copy(to destination: URL) throws {
        for file in files {
            try FileManager.default.copyItem(at: file.name == "adb" ? adbURL : directory.appendingPathComponent(file.name), to: destination.appendingPathComponent(file.name))
        }
    }
    /// The cohort must have no absolute Homebrew paths, ambient @rpath lookup,
    /// or unlisted dylib. This also rejects a dynamic binary with no manifest.
    public func verifyLoadClosure() async throws {
        let names = Set(files.filter { $0.name != Self.manifestName }.map(\.name))
        for file in files where file.name != Self.manifestName {
            let url = file.name == "adb" ? adbURL : directory.appendingPathComponent(file.name)
            _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--verify", "--strict", url.path], timeout: 10)
            let result = try await ProcessRunner.run("/usr/bin/otool", arguments: ["-arch", "arm64", "-L", url.path], timeout: 5)
            let lines = result.output.split(separator: "\n").dropFirst()
            guard lines.count <= 64 else { throw Self.invalid("ADB dependency count exceeds its bound.") }
            for line in lines {
                let dependency = line.trimmingCharacters(in: .whitespaces).components(separatedBy: " (")[0]
                if dependency.hasPrefix("/usr/lib/") || dependency.hasPrefix("/System/Library/") { continue }
                guard dependency.hasPrefix("@loader_path/"),
                      names.contains(String(dependency.dropFirst("@loader_path/".count))),
                      Self.validName(String(dependency.dropFirst("@loader_path/".count))) else { throw Self.invalid("ADB has a dependency outside its portable runtime inventory.") }
            }
        }
    }
    static func validName(_ name: String) -> Bool {
        if name == "adb" { return true }
        return name.utf8.count <= 120 && name.hasPrefix("adb-lib") && name.hasSuffix(".dylib") &&
            name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }
    }
    static func validHash(_ hash: String) -> Bool { hash.utf8.count == 64 && hash.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func inspect(_ url: URL, name: String, requireOwned: Bool) throws -> File {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_nlink == 1,
              metadata.st_uid == geteuid() || (!requireOwned && metadata.st_uid == 0),
              metadata.st_mode & 0o022 == 0, metadata.st_size > 0, metadata.st_size <= maximumFileBytes else { throw invalid("ADB runtime file ownership or size is unsafe.") }
        return File(name: name, sha256: try AvailabilityRuntimeStore.digest(url), size: Int64(metadata.st_size))
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func invalid(_ message: String) -> BridgeError { .message(message) }
}
