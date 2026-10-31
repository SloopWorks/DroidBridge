import Foundation
import Darwin

/// Bounded, private state publication. Rename atomicity alone does not establish
/// the journal's ordering before Keychain or catalog publication.
enum CompanionBrokerJournal {
    struct Fingerprint: Equatable {
        let inode: UInt64, size: Int64
        let seconds: Int, nanoseconds: Int
    }
    static func fingerprint(_ url: URL) -> Fingerprint? {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == geteuid(), value.st_nlink == 1, value.st_mode & 0o777 == 0o600 else { return nil }
        return Fingerprint(inode: value.st_ino, size: value.st_size, seconds: value.st_mtimespec.tv_sec, nanoseconds: value.st_mtimespec.tv_nsec)
    }
    static func write(_ bytes: Data, to url: URL, checkpoint: (String) throws -> Void) throws -> Fingerprint {
        guard bytes.count <= 4_194_304 else { throw failure("Companion state exceeds its byte limit.") }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw failure("Companion state directory is unavailable.") }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw failure("Companion state directory is not private.") }
        let target = url.lastPathComponent
        guard target == "state.json" else { throw failure("Invalid companion journal path.") }
        if fstatat(parent, target, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_nlink == 1,
                  info.st_mode & 0o077 == 0 else { throw failure("Companion state ownership is unsafe.") }
        } else if errno != ENOENT { throw failure("Companion state cannot be inspected.") }
        try checkpoint("persist_before_write")
        let name = ".state-\(UUID().uuidString)"
        let fd = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("Companion state staging failed.") }
        defer { close(fd); unlinkat(parent, name, 0) }
        guard fchmod(fd, 0o600) == 0 else { throw failure("Companion state permissions could not be set.") }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw failure("Companion state write failed.") }
                offset += written
            }
        }
        guard fsync(fd) == 0 else { throw failure("Companion state file could not be synchronized.") }
        try checkpoint("persist_after_file_sync")
        guard renameat(parent, name, parent, target) == 0 else { throw failure("Companion state publication failed.") }
        try checkpoint("persist_after_rename")
        guard fsync(parent) == 0 else { throw failure("Companion state directory could not be synchronized.") }
        guard let result = fingerprint(url), result.size == bytes.count else { throw failure("Published companion state could not be verified.") }
        return result
    }
    private static func failure(_ message: String) -> CompanionBoundaryError {
        CompanionBoundaryError("broker_storage_unavailable", message)
    }
}
