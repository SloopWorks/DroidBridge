import Foundation
import Darwin

/// Companion export restrictions cannot be published while a legacy helper can
/// independently restore the same wrappers using an older policy schema.
public enum CoreAvailabilityAuthority {
    public static var label: String { "app.droidbridge.availability" + (CompanionQAScope.current.map { ".qa." + $0.serviceSuffix } ?? "") }
    public static var plistURL: URL {
        if let scope = CompanionQAScope.current { return scope.root.appendingPathComponent("LaunchAgents/" + label + ".plist") }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/" + label + ".plist")
    }
    public static func requireCompanionPolicySafe(paths: ManagedAppsPaths = .userDefault) async throws {
        var metadata = stat()
        if lstat(plistURL.path, &metadata) != 0 {
            guard errno == ENOENT, try ManagedAppCatalog(paths: paths).records().isEmpty else {
                throw BridgeError.message("Open DroidBridge and finish Spotlight setup to update the availability service before changing phone app visibility.")
            }
            return
        }
        guard metadata.st_uid == geteuid(), metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o022 == 0, metadata.st_size <= 65_536,
              let data = try? Data(contentsOf: plistURL), let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == label, let arguments = plist["ProgramArguments"] as? [String], let first = arguments.first else {
            throw BridgeError.message("Availability service configuration could not be verified.")
        }
        let executable = URL(fileURLWithPath: first).standardizedFileURL
        let parent = paths.privateRoot.appendingPathComponent("availability/generations").standardizedFileURL
        guard executable.lastPathComponent == "DroidBridgeAvailability", executable.deletingLastPathComponent().deletingLastPathComponent().path == parent.path,
              AvailabilityRuntimeStore.validIdentity(executable.deletingLastPathComponent().lastPathComponent) else { throw BridgeError.message("Availability service executable is outside its owned runtime store.") }
        try AvailabilityRuntimeStore.validateGeneration(executable.deletingLastPathComponent(), identity: executable.deletingLastPathComponent().lastPathComponent)
        _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--verify", "--strict", executable.path], timeout: 10)
        guard try containsPolicyOption(executable) else { throw BridgeError.message("Availability service needs an update before changing phone app visibility.") }
        func configured(_ key: String) -> String? {
            guard arguments.filter({ $0 == key }).count == 1,
                  let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { return nil }; return arguments[index + 1]
        }
        guard configured("--private-root") == paths.privateRoot.path, configured("--active-root") == paths.activeRoot.path,
              let adb = configured("--adb"), adb == executable.deletingLastPathComponent().appendingPathComponent("adb").path,
              let preferences = configured("--preferences"), preferences == DroidBridgePreferences.defaultURL.path else { throw BridgeError.message("Availability service scope could not be verified.") }
        try await ADBPortableRuntime.inventory(adb: URL(fileURLWithPath: adb), requireOwned: true).verifyLoadClosure()
        // Old helpers ignore unknown options. Even a marker false positive must
        // run once in the exact configured scope, never default user storage.
        let protocolResult = try await ProcessRunner.run(executable.path, arguments: ["--policy-protocol", "--once", "--adb", adb, "--private-root", paths.privateRoot.path, "--active-root", paths.activeRoot.path, "--preferences", preferences], timeout: 3)
        guard protocolResult.output.trimmingCharacters(in: .whitespacesAndNewlines) == "1" else { throw BridgeError.message("Availability service needs an update before changing phone app visibility.") }
        let loaded = try await ProcessRunner.run("/bin/launchctl", arguments: ["print", "gui/\(getuid())/" + label], timeout: 3)
        let lines = loaded.output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let pidLine = lines.first(where: { $0.hasPrefix("pid = ") }), let pid = Int32(pidLine.dropFirst(6)), pid > 1 else { throw BridgeError.message("Availability service is not running. Finish Spotlight setup and retry.") }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let size = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard size > 0, let end = buffer.firstIndex(of: 0), String(decoding: buffer[..<end], as: UTF8.self) == executable.path else {
            throw BridgeError.message("The running availability service does not match its updated executable.")
        }
    }
    private static func containsPolicyOption(_ executable: URL) throws -> Bool {
        let file = try FileHandle(forReadingFrom: executable); defer { try? file.close() }
        let marker = Data("--policy-protocol".utf8)
        var overlap = Data(), consumed = 0
        while let block = try file.read(upToCount: 1_048_576), !block.isEmpty {
            consumed += block.count
            guard consumed <= 64 * 1_048_576 else { return false }
            var bytes = overlap; bytes.append(block)
            if bytes.range(of: marker) != nil { return true }
            overlap = Data(bytes.suffix(marker.count - 1))
        }
        return false
    }
}
