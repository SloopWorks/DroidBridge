import Foundation
import CryptoKit
import DroidBridgeCore

/// Installs only DroidBridge's own per-user job, after an explicit onboarding
/// request. Immutable generation paths never overwrite a mapped executable.
enum DeviceOnboardingAgent {
    static let label = "app.droidbridge.availability"
    static var plistURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/"+label+".plist") }
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
        let generation = try await Task.detached(priority:.utility) {
            let combined = try digest(helper)+digest(adb)
            return SHA256.hash(data:Data(combined.utf8)).map { String(format:"%02x",$0) }.joined()
        }.value
        let parent = paths.privateRoot.appendingPathComponent("availability/generations")
        let destination = parent.appendingPathComponent(String(generation.prefix(32)))
        try await Task.detached(priority:.utility) {
            let fm = FileManager.default
            try fm.createDirectory(at:parent,withIntermediateDirectories:true)
            if !fm.fileExists(atPath:destination.path) {
                let retained = (try? fm.contentsOfDirectory(at:parent,includingPropertiesForKeys:nil))?.filter { !$0.lastPathComponent.hasPrefix(".") }.count ?? 0
                guard retained < 8 else { throw BridgeError.message("Eight availability runtime generations are retained. Uninstall the availability agent before installing another generation.") }
                let stage = parent.appendingPathComponent(".staging-"+UUID().uuidString)
                try fm.createDirectory(at:stage,withIntermediateDirectories:true)
                defer { try? fm.removeItem(at:stage) }
                try fm.copyItem(at:helper,to:stage.appendingPathComponent("DroidBridgeAvailability"))
                try fm.copyItem(at:adb,to:stage.appendingPathComponent("adb"))
                do { try fm.moveItem(at:stage,to:destination) }
                catch { if !fm.fileExists(atPath:destination.path) { throw error } }
            }
            guard try digest(destination.appendingPathComponent("DroidBridgeAvailability")) == digest(helper),
                  try digest(destination.appendingPathComponent("adb")) == digest(adb) else { throw BridgeError.message("Availability runtime identity mismatch") }
        }.value
        for name in ["DroidBridgeAvailability","adb"] {
            _ = try await ProcessRunner.run("/usr/bin/codesign",arguments:["--verify","--strict",destination.appendingPathComponent(name).path],timeout:10)
        }
        let executable = destination.appendingPathComponent("DroidBridgeAvailability")
        let arguments = [executable.path,"--adb",destination.appendingPathComponent("adb").path,"--private-root",paths.privateRoot.path,"--active-root",paths.activeRoot.path,"--preferences",DroidBridgePreferences.defaultURL.path,"--log",paths.privateRoot.appendingPathComponent("availability/availability.jsonl").path]
        let plist: [String:Any] = ["Label":label,"ProgramArguments":arguments,"RunAtLoad":true,"KeepAlive":true,"ThrottleInterval":30,"ProcessType":"Background","StandardOutPath":"/dev/null","StandardErrorPath":"/dev/null"]
        let domain = "gui/\(getuid())"
        if let data = try? Data(contentsOf:plistURL), let existing = try? PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any], existing["ProgramArguments"] as? [String] == arguments,
           (try? await ProcessRunner.run("/bin/launchctl",arguments:["print",domain+"/"+label],timeout:3)) != nil { return }
        try FileManager.default.createDirectory(at:plistURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        let data = try PropertyListSerialization.data(fromPropertyList:plist,format:.xml,options:0)
        _ = try? await ProcessRunner.run("/bin/launchctl",arguments:["bootout",domain+"/"+label],timeout:5)
        try data.write(to:plistURL,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:plistURL.path)
        _ = try await ProcessRunner.run("/bin/launchctl",arguments:["enable",domain+"/"+label],timeout:5)
        _ = try await ProcessRunner.run("/bin/launchctl",arguments:["bootstrap",domain,plistURL.path],timeout:10)
    }
}
