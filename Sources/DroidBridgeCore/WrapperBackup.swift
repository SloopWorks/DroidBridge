import Foundation
import Darwin
import CoreServices

/// Backups are recoverable data, never runnable applications. Keeping an APPL
/// Info.plist in a .noindex directory still lets Launch Services discover it.
/// Renaming metadata preserves every signed byte for explicit restoration.
public enum WrapperBackup {
    public struct Migration: Sendable {
        public var retired: [URL] = []
        public var issues: [String] = []
        public var attempts: Int = 0
        public init() {}
        public mutating func note(_ url: URL, _ error: Error) {
            if issues.count < 16 { issues.append(String((url.lastPathComponent + ": " + error.localizedDescription).prefix(500))) }
        }
    }
    public static func canonicalPath(_ url: URL) -> String {
        guard let path = realpath(url.path, nil) else { return url.path }
        defer { free(path) }; return String(cString: path)
    }
    public static let registrationTool = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
    public static let retiredInfoName = "DroidBridgeRetiredInfo.plist"
    public static func unregister(_ app: URL) async throws {
        let player = app.appendingPathComponent("Contents/Resources/Runtime/Player.app")
        for target in [player, app] where FileManager.default.fileExists(atPath: target.path) {
            try Task.checkCancellation()
            let result = try await ProcessRunner.run(registrationTool, arguments: ["-u", target.path], timeout: 10, allowNonZeroExit: true)
            // A retained copy may never have been registered. That absence is
            // success only when Launch Services independently confirms the URL
            // is absent; don't treat arbitrary unregister errors as success.
            guard result.status == 0 || result.output.contains(": -10814\n") else { throw BridgeError.message("Backup unregistration failed: " + String(result.output.suffix(500))) }
            let info = try dictionary(infoURL(target), plist: true)
            guard let identifier = info["CFBundleIdentifier"] as? String else { throw invalid() }
            var lookupError: Unmanaged<CFError>?
            let found = LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, &lookupError)?.takeRetainedValue()
            if let error = lookupError?.takeRetainedValue(), CFErrorGetCode(error) != Int(kLSApplicationNotFoundErr) { throw invalid() }
            if let found {
                guard let urls = found as? [URL], !urls.contains(where: { canonicalPath($0) == canonicalPath(target) }) else {
                    throw BridgeError.message("Backup remains registered; unregistration will retry")
                }
            } else if lookupError == nil { throw invalid() }
        }
    }

    public static func infoURL(_ app: URL) -> URL {
        let normal = app.appendingPathComponent("Contents/Info.plist")
        return FileManager.default.fileExists(atPath: normal.path) ? normal : app.appendingPathComponent("Contents/" + retiredInfoName)
    }

    public static func retire(_ app: URL) throws {
        try validatePath(app)
        let info = try dictionary(infoURL(app), plist: true)
        let config = try dictionary(app.appendingPathComponent("Contents/Resources/launch.json"), plist: false)
        guard let package = config["package"] as? String, let serial = config["serial"] as? String,
              let identifier = info["CFBundleIdentifier"] as? String,
              info["CFBundleExecutable"] as? String == "DroidBridge", info["CFBundlePackageType"] as? String == "APPL",
              identifier == "app.droidbridge.wrapper." + package ||
                identifier == ManagedAppCatalog.bundleIdentifier(serial: serial, packageName: package) ||
                identifier.hasPrefix("app.droidbridge.launcher.") else { throw invalid() }
        try AndroidDiscovery.validatePackage(package); try AndroidDiscovery.validateSerial(serial)
        let player = app.appendingPathComponent("Contents/Resources/Runtime/Player.app")
        if FileManager.default.fileExists(atPath: player.path) {
            try validatePath(player)
            let child = try dictionary(infoURL(player), plist: true)
            guard let childID = child["CFBundleIdentifier"] as? String,
                  childID == identifier + ".player" || childID == "app.droidbridge.player" else { throw invalid() }
            try parkInfo(player)
        }
        try parkInfo(app)
    }

    /// Bounded migration for legacy manual/cache backups, outside the catalog.
    /// The caller supplies only the known backup directory, never an app root.
    public static func retireDirectory(_ directory: URL, runningBundlePaths: Set<String>, limit: Int = 16) async throws -> Migration {
        guard directory.lastPathComponent == ".DroidBridge Backups" else { throw invalid() }
        try validatePath(directory)
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return Migration() }
        let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard entries.count <= 20_000 else { throw invalid() }
        var result = Migration()
        let running = Set(runningBundlePaths.map { canonicalPath(URL(fileURLWithPath: $0)) })
        for app in entries where app.pathExtension == "app" && !app.lastPathComponent.hasPrefix(".") {
            try Task.checkCancellation()
            guard result.attempts < max(0, min(limit, 16)) else { break }
            let path = canonicalPath(app)
            let receipt = app.appendingPathComponent(".launch-services-unregistered")
            guard !fm.fileExists(atPath: receipt.path), !running.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) else { continue }
            do {
            try Task.checkCancellation()
            // Validate/retire before invoking an external tool with any path.
            try retire(app)
            result.attempts += 1
            try await unregister(app)
            try Task.checkCancellation()
            try validatePath(receipt)
            try Data("unregistered by exact URL\n".utf8).write(to: receipt, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receipt.path)
                result.retired.append(app)
            } catch is CancellationError { throw CancellationError() }
              catch { result.note(app, error) }
        }
        return result
    }

    public static func legacyDirectories(manualRoot: URL, cacheRoot: URL) -> (directories: [URL], issues: [String]) {
        let fm = FileManager.default
        var result = [manualRoot.appendingPathComponent(".DroidBridge Backups")]
        var issues: [String] = []
        func children(_ parent: URL) -> [URL] {
            do {
                try validatePath(parent)
                guard fm.fileExists(atPath: parent.path) else { return [] }
                let entries = try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
                guard entries.count <= 20_000 else { throw invalid() }
                return entries
            } catch {
                if issues.count < 16 { issues.append(String((parent.lastPathComponent + ": " + error.localizedDescription).prefix(500))) }
                return []
            }
        }
        var visited = 0
        for device in children(cacheRoot) where device.lastPathComponent.range(of: "^[a-f0-9]{24}$", options: .regularExpression) != nil {
            for backend in children(device) where BackendKind(rawValue: backend.lastPathComponent) != nil {
                for package in children(backend) where (try? AndroidDiscovery.validatePackage(package.lastPathComponent)) != nil {
                    visited += 1; guard visited <= 20_000 else { return (result, issues + ["Cache directory limit reached"]) }
                    result.append(package.appendingPathComponent(".DroidBridge Backups"))
                }
            }
        }
        return (result, issues)
    }

    private static func parkInfo(_ app: URL) throws {
        let normal = app.appendingPathComponent("Contents/Info.plist"), retired = app.appendingPathComponent("Contents/" + retiredInfoName)
        if FileManager.default.fileExists(atPath: normal.path) {
            if renamex_np(normal.path, retired.path, UInt32(RENAME_EXCL)) != 0 {
                guard errno == ENOENT else { throw invalid() }
                _ = try dictionary(retired, plist: true) // Another admitted maintainer won the rename.
            }
        } else { _ = try dictionary(retired, plist: true) }
    }
    private static func dictionary(_ url: URL, plist: Bool) throws -> [String: Any] {
        try validatePath(url)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_nlink == 1, metadata.st_size > 0, metadata.st_size <= 65_536 else { throw invalid() }
        let data = try Data(contentsOf: url)
        let value = try plist ? PropertyListSerialization.propertyList(from: data, format: nil) : JSONSerialization.jsonObject(with: data)
        guard let result = value as? [String: Any] else { throw invalid() }; return result
    }
    public static func validatePath(_ url: URL) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else { throw invalid() }
        var path = url
        while path.path != "/" {
            var metadata = stat()
            if lstat(path.path, &metadata) == 0 {
                guard metadata.st_mode & S_IFMT != S_IFLNK else { throw invalid() }
            }
            path.deleteLastPathComponent()
        }
    }
    private static func invalid() -> BridgeError { .message("Backup identity or metadata is invalid; it was preserved") }
}
