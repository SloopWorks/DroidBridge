import Foundation
import CryptoKit
import DroidBridgeCore

/// Installs only DroidBridge's own per-user job, after an explicit onboarding
/// request. Immutable generation paths never overwrite a mapped executable.
enum DeviceOnboardingAgent {
    static var label: String { CoreAvailabilityAuthority.label }
    static var plistURL: URL { CoreAvailabilityAuthority.plistURL }
    static func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom:url); defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount:1_048_576), !data.isEmpty { hash.update(data:data) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    static func ensureInstalled(hostBundleURL: URL, toolchain: Toolchain, paths: ManagedAppsPaths) async throws {
        let runtime = hostBundleURL.appendingPathComponent("Contents/Resources/Runtime")
        let packaged = runtime.appendingPathComponent("bin/DroidBridgeAvailability")
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("DroidBridgeAvailability")
        let developer = URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/.build/debug/DroidBridgeAvailability")
        guard let helper = [packaged,sibling,developer].compactMap({$0}).first(where:{FileManager.default.isExecutableFile(atPath:$0.path)}) else { throw BridgeError.message("Availability helper is missing. Build or reinstall DroidBridge.") }
        let adb = URL(fileURLWithPath:toolchain.adb)
        let parent = paths.privateRoot.appendingPathComponent("availability/generations")
        let installLease = try await AvailabilityRuntimeStore.lock(parent: parent)
        defer { withExtendedLifetime(installLease) {} }
        var pinned: URL?
        if FileManager.default.fileExists(atPath: plistURL.path) {
            var metadata = stat()
            guard lstat(plistURL.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == geteuid(), metadata.st_mode & 0o022 == 0 else { throw BridgeError.message("Availability service configuration ownership is invalid; it was preserved.") }
            let attributes = try FileManager.default.attributesOfItem(atPath: plistURL.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 65_536,
                  let existing = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any],
                  existing["Label"] as? String == label, let arguments = existing["ProgramArguments"] as? [String], let first = arguments.first else { throw BridgeError.message("Availability service configuration is invalid; it was preserved.") }
            let executable = URL(fileURLWithPath: first).standardizedFileURL
            guard executable.lastPathComponent == "DroidBridgeAvailability", executable.deletingLastPathComponent().deletingLastPathComponent().path == parent.standardizedFileURL.path else { throw BridgeError.message("Availability service points outside its owned store; it was preserved.") }
            pinned = executable.deletingLastPathComponent()
        }
        let destination = try await AvailabilityRuntimeStore.prepare(parent: parent, helper: helper, adb: adb, preservedGeneration: pinned)
        let executable = destination.appendingPathComponent("DroidBridgeAvailability")
        var arguments = [executable.path,"--adb",destination.appendingPathComponent("adb").path,"--private-root",paths.privateRoot.path,"--active-root",paths.activeRoot.path,"--preferences",DroidBridgePreferences.defaultURL.path,"--log",paths.privateRoot.appendingPathComponent("availability/availability.jsonl").path]
        if let scope = CompanionQAScope.current { arguments += ["--companion-qa-root", scope.root.path, "--serial", scope.serial] }
        let plist: [String:Any] = ["Label":label,"ProgramArguments":arguments,"RunAtLoad":true,"KeepAlive":true,"ThrottleInterval":30,"ProcessType":"Background","StandardOutPath":"/dev/null","StandardErrorPath":"/dev/null"]
        let domain = "gui/\(getuid())"
        if let data = try? Data(contentsOf:plistURL), let existing = try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any], existing["ProgramArguments"] as? [String] == arguments,
           (try? await ProcessRunner.run("/bin/launchctl",arguments:["print",domain+"/"+label],timeout:3)) != nil {
            try await CoreAvailabilityAuthority.requireCompanionPolicySafe(paths: paths); return
        }
        try FileManager.default.createDirectory(at:plistURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        let data = try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0)
        let previous = try? await ProcessRunner.run("/bin/launchctl", arguments: ["print", domain + "/" + label], timeout: 3)
        var previousPID: Int32?
        if let previous {
            previousPID = previous.output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { $0.hasPrefix("pid = ") }).flatMap { Int32($0.dropFirst(6)) }
            _ = try await ProcessRunner.run("/bin/launchctl", arguments: ["bootout", domain + "/" + label], timeout: 5)
        }
        if let pid = previousPID, pid > 1 {
            let deadline = Date().addingTimeInterval(15)
            while kill(pid, 0) == 0 || errno != ESRCH {
                guard Date() < deadline else { throw BridgeError.message("The previous availability service is still stopping. Retry after it exits.") }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        try Task.checkCancellation()
        try data.write(to:plistURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:plistURL.path)
        _ = try await ProcessRunner.run("/bin/launchctl",arguments:["enable",domain+"/"+label],timeout:5)
        _ = try await ProcessRunner.run("/bin/launchctl",arguments:["bootstrap",domain,plistURL.path],timeout:10)
        let deadline = Date().addingTimeInterval(5)
        while true {
            do { try await CoreAvailabilityAuthority.requireCompanionPolicySafe(paths: paths); break }
            catch { guard Date() < deadline else { throw error }; try await Task.sleep(nanoseconds: 100_000_000) }
        }
    }
}
