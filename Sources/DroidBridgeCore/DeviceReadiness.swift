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

/// A finite retry budget attached to one interrupted session intent. Polling and
/// boot readiness do not consume launch attempts. Closing the intent cancels it.
public struct ReconnectRetry {
    public static let maximumAttempts = 3
    public static let retryDelay: TimeInterval = 8
    public private(set) var failures: Int = 0
    public private(set) var nextAttempt: Date = .distantPast
    public init() {}
    public func admits(intentPresent: Bool, ready: Bool, enabled: Bool, now: Date) -> Bool {
        intentPresent && ready && enabled && failures < Self.maximumAttempts && now >= nextAttempt
    }
    public mutating func failed(at now: Date) {
        failures += 1
        nextAttempt = now.addingTimeInterval(Self.retryDelay)
    }
}
