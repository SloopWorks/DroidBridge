import Foundation
import Darwin

public struct ManagedAppCopyStatistics: Sendable {
    public var clonedFiles = 0
    public var copiedFiles = 0
    public var logicalBytes: Int64 = 0
    public init() {}
}
/// Explicit per-file APFS copy-on-write clones, never hardlinks. Safe internal
/// relative symlinks are preserved; links escaping the copied subtree are refused.
public enum ManagedAppCloneCopy {
    @discardableResult
    public static func copy(_ source: URL, to destination: URL, reserveBytes: Int64 = 256 * 1024 * 1024, preferCloning: Bool = true) throws -> ManagedAppCopyStatistics {
        let fm = FileManager.default
        let root = source.standardizedFileURL.resolvingSymlinksInPath()
        var existing = stat()
        guard lstat(destination.path, &existing) != 0 && errno == ENOENT else { throw BridgeError.message("Copy destination already exists; it was preserved.") }
        var stats = ManagedAppCopyStatistics()
        func available() throws -> Int64 {
            let attributes = try fm.attributesOfFileSystem(forPath: destination.deletingLastPathComponent().path)
            guard let bytes = attributes[.systemFreeSize] as? NSNumber else { throw BridgeError.message("Cannot determine capacity for app creation.") }
            return bytes.int64Value
        }
        guard try available() >= reserveBytes else { throw BridgeError.message("Not enough free space to stage a Mac app safely (256 MiB reserve required).") }
        func visit(_ src: URL, _ dst: URL) throws {
            try Task.checkCancellation()
            let attributes = try fm.attributesOfItem(atPath: src.path)
            let type = attributes[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                let target = try fm.destinationOfSymbolicLink(atPath: src.path)
                let resolved = src.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.resolvingSymlinksInPath()
                guard !target.hasPrefix("/"), resolved.path == root.path || resolved.path.hasPrefix(root.path + "/") else { throw BridgeError.message("Runtime contains an external symbolic link; app creation refused.") }
                try fm.createSymbolicLink(atPath: dst.path, withDestinationPath: target)
            } else if type == .typeDirectory {
                try fm.createDirectory(at: dst, withIntermediateDirectories: false, attributes: [.posixPermissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o755])
                for child in try fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) { try visit(child, dst.appendingPathComponent(child.lastPathComponent)) }
            } else if type == .typeRegular {
                let count = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let cloneFlags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_CLONE_FORCE | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
                if preferCloning && copyfile(src.path, dst.path, nil, cloneFlags) == 0 { stats.clonedFiles += 1 }
                else {
                    let failure = preferCloning ? errno : ENOTSUP
                    // Clone unsupported/cross-volume may fall back to a full copy;
                    // permission and unexpected failures never bypass the refusal.
                    guard [ENOTSUP, EXDEV, EINVAL, ENOSYS].contains(failure) else { throw BridgeError.message("Could not clone app runtime (errno \(failure)).") }
                    if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
                    guard try available() >= reserveBytes + count else { throw BridgeError.message("Not enough capacity for a non-cloning filesystem; app was not published.") }
                    guard copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW | COPYFILE_EXCL)) == 0 else { throw BridgeError.message("Could not copy app runtime (errno \(errno)).") }
                    stats.copiedFiles += 1
                }
                stats.logicalBytes += count
            } else { throw BridgeError.message("Unsupported runtime file type; app creation refused.") }
        }
        do { try visit(source, destination); return stats }
        catch { try? fm.removeItem(at: destination); throw error }
    }
}
