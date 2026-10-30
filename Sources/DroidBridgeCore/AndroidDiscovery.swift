import Foundation

public struct AndroidCapabilities: Codable {
    public let apiLevel: Int
    public let androidVersion: String
    public let scrcpyVersion: String
    public let virtualDisplays: Bool
    public let adaptiveResize: Bool
    public let limitations: [String]
}

public struct AndroidDiscovery {
    private let toolchain: Toolchain
    public init(toolchain: Toolchain = Toolchain()) { self.toolchain = toolchain }

    public func devices() async throws -> [AndroidDevice] {
        let result = try await ProcessRunner.run(toolchain.adb, arguments: ["devices", "-l"])
        return Self.parseDevices(result.output)
    }

    public func applications(device: AndroidDevice) async throws -> [AndroidApplication] {
        try Self.validateSerial(device.serial)
        let result = try await ProcessRunner.run(toolchain.scrcpy, arguments: ["--serial", device.serial, "--list-apps"], environment: toolchain.environment, timeout: 45)
        let apps = Self.parseApplications(result.output)
        guard !apps.isEmpty else { throw BridgeError.message("No launchable applications were returned. Check Android authorization and scrcpy 5.0.1 compatibility.") }
        return apps
    }

    public func capabilities(device: AndroidDevice) async throws -> AndroidCapabilities {
        try Self.validateSerial(device.serial)
        let api = try await ProcessRunner.run(toolchain.adb, arguments: ["-s", device.serial, "shell", "getprop", "ro.build.version.sdk"])
        let release = try await ProcessRunner.run(toolchain.adb, arguments: ["-s", device.serial, "shell", "getprop", "ro.build.version.release"])
        let version = try await ProcessRunner.run(toolchain.scrcpy, arguments: ["--version"], environment: toolchain.environment)
        let help = try await ProcessRunner.run(toolchain.scrcpy, arguments: ["--help"], environment: toolchain.environment)
        let level = Int(api.output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return AndroidCapabilities(apiLevel: level, androidVersion: release.output.trimmingCharacters(in: .whitespacesAndNewlines), scrcpyVersion: version.output.components(separatedBy: .newlines).first ?? "unknown", virtualDisplays: level >= 33 && help.output.contains("--new-display"), adaptiveResize: help.output.contains("--flex-display"), limitations: ["DroidBridge requires Android 13 (API 33) or later for display-scoped hidden software keyboard policy.", "Capability support must be confirmed by a launch; apps may prohibit secondary displays or secure video.", "SDK keyboard text injection supports Android's character map; complex text and IME behavior depend on the app.", "Android task affinity or singleTask activities may move an existing task between displays."])
    }

    public static func validatePackage(_ value: String) throws {
        guard value.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil, value.utf8.count <= 255 else { throw BridgeError.message("Invalid Android package name: \(value)") }
    }

    public static func validateSerial(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 256, value.range(of: #"^[A-Za-z0-9_.:\[\]%-]+$"#, options: .regularExpression) != nil else { throw BridgeError.message("Invalid ADB device serial") }
    }

    public static func parseDevices(_ output: String) -> [AndroidDevice] {
        output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, ["device", "unauthorized", "offline", "recovery", "sideload", "bootloader"].contains(fields[1]), (try? validateSerial(fields[0])) != nil else { return nil }
            let model = fields.first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") } ?? fields[0]
            return AndroidDevice(serial: fields[0], model: model, state: fields[1])
        }
    }

    public static func parseApplications(_ output: String) -> [AndroidApplication] {
        let lines = output.components(separatedBy: .newlines)
        var result: [AndroidApplication] = []
        var pendingName: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") {
                let body = String(trimmed.dropFirst(2))
                let parts = body.split(whereSeparator: \.isWhitespace)
                if let last = parts.last, (try? validatePackage(String(last))) != nil {
                    let package = String(last)
                    let label = String(body.dropLast(package.count)).trimmingCharacters(in: .whitespaces)
                    result.append(AndroidApplication(packageName: package, name: label.isEmpty ? package : label)); pendingName = nil
                } else { pendingName = body.trimmingCharacters(in: .whitespaces) }
            } else if let name = pendingName, (try? validatePackage(trimmed)) != nil {
                result.append(AndroidApplication(packageName: trimmed, name: name)); pendingName = nil
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.packageName).inserted }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
