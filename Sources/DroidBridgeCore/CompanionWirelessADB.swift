import Foundation
import Darwin

/// Bounded, cancellation-aware wireless ADB setup. The pairing code is supplied
/// through stdin, never an argument or persistent preference.
public enum CompanionWirelessADB {
    public static func pair(adb: String, endpoint: CompanionWirelessEndpoint, code: String, timeout: TimeInterval = 25) async throws -> String {
        guard code.count == 6, code.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw BridgeError.message("Enter the current six-digit wireless debugging pairing code.") }
        return try await run(adb: adb, arguments: ["pair", endpoint.argument], input: code + "\n", secret: code, timeout: timeout)
    }
    public static func connect(adb: String, endpoint: CompanionWirelessEndpoint, timeout: TimeInterval = 25) async throws -> String {
        try await run(adb: adb, arguments: ["connect", endpoint.argument], input: nil, secret: nil, timeout: timeout)
    }

    private final class Owner: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        func launch(_ child: Process) throws {
            lock.lock(); defer { lock.unlock() }
            guard !cancelled else { throw CancellationError() }
            try child.run(); process = child
        }
        func cancel() {
            lock.lock(); cancelled = true
            let child = process; lock.unlock()
            if let child, child.isRunning { child.terminate() }
        }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    private static func run(adb: String, arguments: [String], input: String?, secret: String?, timeout: TimeInterval) async throws -> String {
        let owner = Owner()
        return try await withTaskCancellationHandler(operation: {
            try await Task.detached(priority: .userInitiated) {
                let path = FileManager.default.temporaryDirectory.appendingPathComponent("droidbridge-wireless-\(UUID().uuidString).log")
                guard FileManager.default.createFile(atPath: path.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw BridgeError.message("Unable to prepare wireless debugging.") }
                defer { try? FileManager.default.removeItem(at: path) }
                let handle = try FileHandle(forWritingTo: path); defer { try? handle.close() }
                let pipe = Pipe(); defer { try? pipe.fileHandleForWriting.close() }
                let child = Process(); child.executableURL = URL(fileURLWithPath: adb); child.arguments = arguments
                child.standardOutput = handle; child.standardError = handle; child.standardInput = pipe
                try owner.launch(child)
                if let input { try? pipe.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
                try? pipe.fileHandleForWriting.close()
                let deadline = ProcessInfo.processInfo.systemUptime + min(30, max(0.1, timeout))
                var exceeded = false
                while child.isRunning {
                    let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.intValue ?? 0
                    if owner.isCancelled || ProcessInfo.processInfo.systemUptime >= deadline || size > 64 * 1024 {
                        exceeded = true; child.terminate()
                        let grace = ProcessInfo.processInfo.systemUptime + 0.5
                        while child.isRunning && ProcessInfo.processInfo.systemUptime < grace { try? await Task.sleep(nanoseconds: 20_000_000) }
                        if child.isRunning { kill(child.processIdentifier, SIGKILL) }; break
                    }
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                child.waitUntilExit()
                if owner.isCancelled { throw CancellationError() }
                guard !exceeded else { throw BridgeError.message("Wireless debugging timed out. Check the phone's current address and code, then retry.") }
                let reader = try FileHandle(forReadingFrom: path); defer { try? reader.close() }
                var output = String(decoding: try reader.read(upToCount: 16_384) ?? Data(), as: UTF8.self)
                if let secret { output = output.replacingOccurrences(of: secret, with: "[redacted]") }
                guard child.terminationStatus == 0, !output.lowercased().contains("failed"), !output.lowercased().contains("cannot connect") else { throw BridgeError.message("Wireless debugging failed. Check the current address and code shown on Android.") }
                return String(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1000))
            }.value
        }, onCancel: { owner.cancel() })
    }
}
