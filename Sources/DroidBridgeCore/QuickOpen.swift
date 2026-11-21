import Foundation
import Darwin

/// Separate storage prevents older shared-preference writers erasing this intent.
public struct QuickOpenPreferences: Codable, Equatable, Sendable {
    public var enabled: Bool = false
    public var target: String = "control"
    public var serial: String?
    public var package: String?
    public var appName: String?
    public var deviceName: String?
    public var hostBundlePath: String?
    public init() {}
    public static var defaultURL: URL { (CompanionQAScope.current?.root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DroidBridge")).appendingPathComponent("quick-open.json") }
    public func validate() throws {
        guard ["control", "app", "screen"].contains(target) else { throw BridgeError.message("Choose DroidBridge, an Android app, or the current device screen.") }
        guard !enabled || serial != nil else { throw BridgeError.message("Choose a device before enabling automatic opening.") }
        if let serial { try AndroidDiscovery.validateSerial(serial) }
        if let package { try AndroidDiscovery.validatePackage(package) }
        for value in [appName, deviceName, hostBundlePath].compactMap({ $0 }) {
            guard value.utf8.count <= 4096, !value.contains("\0") else { throw BridgeError.message("Connection opening preferences are invalid.") }
        }
    }
    public static func load(url: URL = defaultURL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        let data = try file.read(upToCount: 16385) ?? Data()
        guard data.count <= 16384 else { throw BridgeError.message("Connection opening preferences exceed the supported size.") }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
    @discardableResult public static func update(url: URL = defaultURL, recoveringInvalidFile: Bool = false, _ change: (inout Self) -> Void) throws -> Self {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.appendingPathExtension("lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw BridgeError.message("Cannot open connection preference lock.") }
        defer { flock(fd, LOCK_UN); close(fd) }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.1
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline, errno == EWOULDBLOCK || errno == EINTR else { throw BridgeError.message("Connection preferences are busy. Try again.") }
            usleep(1000)
        }
        var recovered = false
        var value: Self
        do { value = try load(url: url) }
        catch {
            guard recoveringInvalidFile else { throw error }
            value = Self(); recovered = true
        }
        change(&value); try value.validate()
        let data = try JSONEncoder().encode(value)
        let backup = url.deletingLastPathComponent().appendingPathComponent("quick-open.recovered-\(UUID().uuidString).json")
        if recovered { try FileManager.default.moveItem(at: url, to: backup) }
        do { try data.write(to: url, options: .atomic) }
        catch {
            if recovered, !FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.moveItem(at: backup, to: url) }
            throw error
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return value
    }
}

/// Readiness flaps do not reopen; absence or loss of ADB authorization rearms.
public struct QuickOpenConnectionTracker: Sendable {
    public var serial: String?
    private var admitted = Set<String>()
    public init(serial: String? = nil) { self.serial = serial }
    public mutating func observe(devices: [AndroidDevice], readySerials: Set<String>) -> Bool {
        let authorized = Set(devices.filter { $0.state == "device" && (serial == nil || $0.serial == serial) }.map(\.serial))
        admitted.formIntersection(authorized)
        let new = authorized.intersection(readySerials).subtracting(admitted)
        admitted.formUnion(new)
        return !new.isEmpty
    }
}

/// Read-only ownership checks before crossing Launch Services. No shell expansion.
public enum QuickOpenHost {
    public static func validate(path: String) throws -> URL {
        let url = URL(fileURLWithPath: path)
        guard path.hasPrefix("/"), url.pathExtension == "app" else { throw BridgeError.message("DroidBridge installation is unavailable. Open DroidBridge and save connection settings again.") }
        let executable = url.appendingPathComponent("Contents/MacOS/DroidBridge")
        for candidate in [url, url.appendingPathComponent("Contents/Info.plist"), executable] {
            var info = stat()
            guard lstat(candidate.path, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o022 == 0, info.st_mode & S_IFMT != S_IFLNK else { throw BridgeError.message("DroidBridge installation ownership could not be verified. Save connection settings from your installed app.") }
        }
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "app.droidbridge.desktop", bundle.executableURL?.standardizedFileURL.path == executable.standardizedFileURL.path,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw BridgeError.message("The saved application is not the DroidBridge control app. Save connection settings again.") }
        return url
    }
}
