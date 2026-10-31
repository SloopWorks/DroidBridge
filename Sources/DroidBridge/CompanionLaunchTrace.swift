import Foundation
import Darwin
import DroidBridgeCore

/// Explicit isolated-QA instrumentation. Normal launches perform no trace I/O.
enum CompanionLaunchTrace {
    static func record(_ phase: String) {
        guard ProcessInfo.processInfo.arguments.contains("--companion-launch-trace"), let scope = CompanionQAScope.current else { return }
        let path = scope.root.appendingPathComponent("launch-trace-\(getpid()).jsonl").path
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o077 == 0, metadata.st_size < 65_536,
              var bytes = try? JSONSerialization.data(withJSONObject: ["phase": phase, "uptime": ProcessInfo.processInfo.systemUptime]) else { return }
        bytes.append(10)
        _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    }
}
