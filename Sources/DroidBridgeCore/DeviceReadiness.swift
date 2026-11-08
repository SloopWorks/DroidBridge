import Foundation

public enum DeviceReadiness {
    /// ADB transport may return before Android services are ready after a reboot.
    public static func isReady(device: AndroidDevice, toolchain: Toolchain, timeout: TimeInterval = 2) async -> Bool {
        guard device.state == "device", (try? AndroidDiscovery.validateSerial(device.serial)) != nil else { return false }
        do {
            let boot = try await ProcessRunner.run(toolchain.adb, arguments: ["-s", device.serial, "shell", "getprop", "sys.boot_completed"], environment: toolchain.environment, timeout: min(2, max(0.1, timeout)))
            guard boot.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else { return false }
            let packages = try await ProcessRunner.run(toolchain.adb, arguments: ["-s", device.serial, "shell", "cmd", "package", "path", "android"], environment: toolchain.environment, timeout: min(2, max(0.1, timeout)))
            return packages.output.components(separatedBy: .newlines).contains { $0.hasPrefix("package:") }
        } catch { return false }
    }
}

/// A finite retry budget attached to one interrupted session intent. Polling,
/// boot and sleep waits do not consume attempts. A briefly successful launch
/// does not reset a flapping connection's budget; a stable minute does.
public struct ReconnectRetry {
    public static let maximumAttempts = 3
    public static let retryDelay: TimeInterval = 8
    public private(set) var failures: Int = 0
    public private(set) var nextAttempt: Date = .distantPast
    public static let stableInterval: TimeInterval = 60
    public private(set) var runningSince: Date?
    public init() {}
    public func admits(intentPresent: Bool, ready: Bool, enabled: Bool, now: Date) -> Bool {
        intentPresent && ready && enabled && failures < Self.maximumAttempts && now >= nextAttempt
    }
    public mutating func failed(at now: Date) {
        attempted(at: now)
    }
    /// `failures` is retained for existing clients; it counts admitted recovery
    /// launches, including ones that start but immediately lose their transport.
    public mutating func attempted(at now: Date) {
        failures += 1
        nextAttempt = now.addingTimeInterval(Self.retryDelay)
        runningSince = nil
    }
    public mutating func running(at now: Date) { runningSince = now }
    public mutating func interrupted(at now: Date) {
        if let runningSince, now.timeIntervalSince(runningSince) >= Self.stableInterval {
            failures = 0; nextAttempt = .distantPast
        }
        runningSince = nil
    }
}
