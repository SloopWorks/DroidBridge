import Foundation
import Darwin

/// Shared across the launcher, independent wrappers and availability agent.
/// Atomic replacement allows readers to observe a complete version without
/// holding a lock; writers merge under a short, per-user file lock.
public struct DroidBridgePreferences: Codable, Equatable {
    public var bulkWrapperOnboardingEnabled: Bool
    public var showAndroidSystemDecorations: Bool
    public init(bulkWrapperOnboardingEnabled: Bool = true, showAndroidSystemDecorations: Bool = true) {
        self.bulkWrapperOnboardingEnabled = bulkWrapperOnboardingEnabled
        self.showAndroidSystemDecorations = showAndroidSystemDecorations
    }
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DroidBridge/preferences.json")
    }
    private enum CodingKeys: String, CodingKey { case bulkWrapperOnboardingEnabled, showAndroidSystemDecorations }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bulkWrapperOnboardingEnabled = try values.decodeIfPresent(Bool.self, forKey: .bulkWrapperOnboardingEnabled) ?? true
        showAndroidSystemDecorations = try values.decodeIfPresent(Bool.self, forKey: .showAndroidSystemDecorations) ?? true
    }
    public static func load(url: URL = defaultURL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        let file = try FileHandle(forReadingFrom:url); defer { try? file.close() }
        let data = try file.read(upToCount:16_385) ?? Data()
        guard data.count <= 16_384 else { throw BridgeError.message("DroidBridge preferences exceed the supported size") }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    @discardableResult public static func update(url: URL = defaultURL, _ change: (inout Self) -> Void) throws -> Self {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lockPath = url.appendingPathExtension("lock").path
        let descriptor = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BridgeError.message("Cannot open DroidBridge preference lock") }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        let deadline = ProcessInfo.processInfo.systemUptime+0.1
        while flock(descriptor,LOCK_EX|LOCK_NB) != 0 {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline, errno == EWOULDBLOCK || errno == EINTR else { throw BridgeError.message("DroidBridge preferences are busy. Try again.") }
            usleep(1_000)
        }
        var preferences = try load(url: url)
        change(&preferences)
        try JSONEncoder().encode(preferences).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return preferences
    }
}
