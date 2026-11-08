import Foundation
import CryptoKit
import Darwin

/// A generated app is a distinct app, even when its code comes from the same
/// release. macOS networking uses LC_UUID as an identity shortcut (TN3178).
/// Change only private staged copies, then sign them; never patch running code.
public enum AppBinaryIdentity {
    public static let format = 1

    public static func personalize(_ executable: URL, identifier: String) throws {
        var metadata = stat()
        guard lstat(executable.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1,
              metadata.st_size > 0, metadata.st_size <= 256 * 1024 * 1024 else {
            throw BridgeError.message("Unsafe staged app executable")
        }
        let original = try Data(contentsOf: executable)
        let result = try personalized(original, identifier: identifier)
        // Packaged scrcpy is 0555. Only this owned, non-hardlinked staging copy
        // becomes writable, and its original permissions are restored on exit.
        let permissions = metadata.st_mode & 0o7777
        guard chmod(executable.path, permissions | S_IWUSR) == 0 else { throw BridgeError.message("Cannot prepare staged executable permissions") }
        defer { _ = chmod(executable.path, permissions) }
        let handle = try FileHandle(forWritingTo: executable)
        defer { try? handle.close() }
        try handle.write(contentsOf: result)
        try handle.synchronize()
    }

    public static func personalized(_ original: Data, identifier: String) throws -> Data {
        guard !identifier.isEmpty, identifier.utf8.count <= 1024 else { throw invalid() }
        var bytes = original
        let offsets = try uuidOffsets(original)
        for offset in offsets {
            var seed = Data("DroidBridge.app-uuid.v1\u{0}\(identifier)\u{0}".utf8)
            seed.append(original[offset..<(offset + 16)])
            var uuid = Array(SHA256.hash(data: seed).prefix(16))
            uuid[6] = (uuid[6] & 0x0f) | 0x80 // RFC 9562 version 8, application-defined hash.
            uuid[8] = (uuid[8] & 0x3f) | 0x80
            bytes.replaceSubrange(offset..<(offset + 16), with: uuid)
        }
        return bytes
    }

    /// Compare actual code, not a self-reported source hash in Info.plist.
    /// codesign normalizes the signature-dependent LINKEDIT fields on removal.
    public static func matches(_ executable: URL, source: URL, identifier: String) async throws -> Bool {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("droidbridge-code-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let expected = root.appendingPathComponent("expected"), actual = root.appendingPathComponent("actual")
        try ManagedAppCloneCopy.copy(source, to: expected)
        try ManagedAppCloneCopy.copy(executable, to: actual)
        for file in [expected, actual] {
            _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--remove-signature", file.path], timeout: 10)
        }
        try personalize(expected, identifier: identifier)
        return try Data(contentsOf: expected) == Data(contentsOf: actual)
    }

    /// Strict, bounded parser for thin and universal Mach-O, all endian variants.
    static func uuidOffsets(_ bytes: Data) throws -> [Int] {
        func word(_ at: Int, _ little: Bool, _ width: Int = 4) throws -> UInt64 {
            guard at >= 0, at <= bytes.count, width <= bytes.count - at else { throw invalid() }
            var result: UInt64 = 0
            for index in 0..<width { result |= UInt64(bytes[at + index]) << ((little ? index : width - index - 1) * 8) }
            return result
        }
        func thin(_ start: Int, _ length: Int) throws -> [Int] {
            guard start >= 0, length >= 28, start <= bytes.count, length <= bytes.count - start else { throw invalid() }
            let magic = try word(start, false)
            let little = magic == 0xcefaedfe || magic == 0xcffaedfe
            guard little || magic == 0xfeedface || magic == 0xfeedfacf else { throw invalid() }
            let header = (magic == 0xcffaedfe || magic == 0xfeedfacf) ? 32 : 28
            let count = Int(try word(start + 16, little)), size = Int(try word(start + 20, little))
            guard count > 0, count <= 65_536, size <= length - header else { throw invalid() }
            var cursor = start + header, found: [Int] = []
            let end = cursor + size
            for _ in 0..<count {
                guard cursor <= end - 8 else { throw invalid() }
                let command = try word(cursor, little), size = Int(try word(cursor + 4, little))
                guard size >= 8, size % 4 == 0, size <= end - cursor else { throw invalid() }
                if command == 0x1b {
                    guard size == 24 else { throw invalid() }
                    found.append(cursor + 8)
                }
                cursor += size
            }
            guard found.count == 1, cursor == end else { throw invalid() }
            return found
        }
        let magic = try word(0, false)
        guard [0xcafebabe, 0xbebafeca, 0xcafebabf, 0xbfbafeca].contains(magic) else { return try thin(0, bytes.count) }
        let little = magic == 0xbebafeca || magic == 0xbfbafeca
        let wide = magic == 0xcafebabf || magic == 0xbfbafeca
        let count = Int(try word(4, little)), entry = wide ? 32 : 20
        guard count > 0, count <= 64, 8 + count * entry <= bytes.count else { throw invalid() }
        var ranges: [Range<Int>] = [], result: [Int] = []
        for index in 0..<count {
            let base = 8 + index * entry
            let start = try word(base + 8, little, wide ? 8 : 4)
            let length = try word(base + (wide ? 16 : 12), little, wide ? 8 : 4)
            guard start <= UInt64(bytes.count), length <= UInt64(bytes.count) - start, start >= UInt64(8 + count * entry) else { throw invalid() }
            let range = Int(start)..<Int(start + length)
            guard !ranges.contains(where: { $0.overlaps(range) }) else { throw invalid() }
            ranges.append(range); result += try thin(range.lowerBound, range.count)
        }
        return result
    }
    private static func invalid() -> BridgeError { .message("Invalid or unsupported Mach-O app identity") }
}
