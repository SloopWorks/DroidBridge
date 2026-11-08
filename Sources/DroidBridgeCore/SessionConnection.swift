import Foundation

/// Only connection failures opt into automatic recovery. Invalid configuration,
/// protocol and decoder errors remain terminal and keep their diagnostic.
public enum SessionRecoveryReason: String, Sendable {
    case transportInterrupted = "transport_interrupted"
    case deviceSleeping = "device_sleeping"
    case processExited = "process_exited"
}

public enum SessionConnectionError: LocalizedError {
    case interrupted(String)
    case sleeping

    public var recoveryReason: SessionRecoveryReason {
        switch self {
        case .interrupted: return .transportInterrupted
        case .sleeping: return .deviceSleeping
        }
    }
    public var errorDescription: String? {
        switch self {
        case .interrupted(let detail): return detail
        case .sleeping: return "The phone is asleep. Wake and unlock it to resume this app."
        }
    }
}

public enum DeviceVideoReadiness: Equatable, Sendable {
    case awake, sleeping, unknown

    /// Use system wakefulness, not physical panel state: an explicit screen-off
    /// preference may turn display 0 off while virtual displays remain usable.
    public static func parse(powerDump: String) -> Self {
        let values = powerDump.split(separator: "\n").compactMap { line -> String? in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("mWakefulness=") else { return nil }
            return String(text.dropFirst("mWakefulness=".count))
        }
        // Some OEMs append a numeric summary. Only accept one authoritative
        // symbolic value; unreadable/ambiguous output never fabricates sleep.
        let symbolic = values.filter { ["Awake", "Asleep", "Dozing", "Dreaming"].contains($0) }
        guard symbolic.count == 1, let value = symbolic.first else { return .unknown }
        return value == "Asleep" || value == "Dozing" ? .sleeping : .awake
    }

    public static func probe(device: AndroidDevice, toolchain: Toolchain, timeout: TimeInterval = 2) async -> Self {
        guard device.state == "device", (try? AndroidDiscovery.validateSerial(device.serial)) != nil else { return .unknown }
        do {
            let result = try await ProcessRunner.run(toolchain.adb, arguments: ["-s", device.serial, "shell", "dumpsys", "power"], environment: toolchain.environment, timeout: timeout)
            return parse(powerDump: result.output)
        } catch { return .unknown }
    }
}
