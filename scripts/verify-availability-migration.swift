import Foundation
import Darwin
import DroidBridgeCore

@main struct AvailabilityMigrationFixture {
    static func main() async {
        do { try await run() }
        catch { fputs("Availability migration fixture failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() async throws {
        guard let scope = CompanionQAScope.current, scope.serial == "emulator-5580" else { throw BridgeError.message("Use the explicitly owned helper QA root and emulator-5580 scope; no Android connection is used.") }
        let arguments = CommandLine.arguments
        func option(_ key: String) throws -> String {
            guard let index = arguments.firstIndex(of: key), arguments.indices.contains(index + 1) else { throw BridgeError.message("Missing fixture argument \(key)") }; return arguments[index + 1]
        }
        let installedApp = URL(fileURLWithPath: try option("--installed-app")), legacy = URL(fileURLWithPath: try option("--legacy-helper")), output = URL(fileURLWithPath: try option("--output"))
        let parent = scope.managedPaths.privateRoot.appendingPathComponent("availability/generations")
        guard !FileManager.default.fileExists(atPath: parent.path) else { throw BridgeError.message("Preserved helper fixture data already exists. Select a fresh owned QA root.") }
        let root = scope.root
        var report: [String: Any] = ["fixture": "isolated actual LaunchAgent upgrade", "android_availability_verified": false, "adb_transport": "signed compiled fake only", "scope_label": CoreAvailabilityAuthority.label]
        var bootstrapped = false
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            _ = try DroidBridgePreferences.update(url: scope.preferencesURL) { $0.bulkWrapperOnboardingEnabled = false }
            let fakeSources = root.appendingPathComponent("fake-adb-sources")
            try FileManager.default.createDirectory(at: fakeSources, withIntermediateDirectories: true)
            let logLiteral = String(data: try JSONEncoder().encode(root.appendingPathComponent("fake-adb-calls.log").path), encoding: .utf8)!
            var adbs: [URL] = []
            for index in 0...8 {
                let source = fakeSources.appendingPathComponent("adb-\(index).c"), binary = fakeSources.appendingPathComponent("adb-\(index)")
                let code = "#include <stdio.h>\n#include <string.h>\nint main(int argc,char **argv){FILE *f=fopen(\(logLiteral),\"a\");if(f){fprintf(f,\"fake-\(index) argc=%d\\n\",argc);fclose(f);}if(argc==500)puts(\"owned-generation-\(index)\");if(argc>1&&!strcmp(argv[1],\"devices\"))puts(\"List of devices attached\");return 0;}\n"
                try Data(code.utf8).write(to: source)
                _ = try await ProcessRunner.run("/usr/bin/clang", arguments: [source.path, "-o", binary.path], timeout: 10)
                _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", binary.path], timeout: 10); adbs.append(binary)
            }
            var old: [URL] = []
            for index in 0..<8 {
                let lease = try await AvailabilityRuntimeStore.lock(parent: parent)
                let generation = try await AvailabilityRuntimeStore.prepare(parent: parent, helper: legacy, adb: adbs[index], preservedGeneration: old.first)
                withExtendedLifetime(lease) {}; old.append(generation)
            }
            report["before_count"] = try FileManager.default.contentsOfDirectory(atPath: parent.path).count
            let oldHelper = old[0].appendingPathComponent("DroidBridgeAvailability")
            let oldArguments = [oldHelper.path, "--adb", old[0].appendingPathComponent("adb").path, "--private-root", scope.managedPaths.privateRoot.path, "--active-root", scope.managedPaths.activeRoot.path, "--preferences", scope.preferencesURL.path]
            let plist: [String: Any] = ["Label": CoreAvailabilityAuthority.label, "ProgramArguments": oldArguments, "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 30, "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null"]
            try FileManager.default.createDirectory(at: CoreAvailabilityAuthority.plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: CoreAvailabilityAuthority.plistURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CoreAvailabilityAuthority.plistURL.path)
            _ = try await ProcessRunner.run("/bin/launchctl", arguments: ["bootstrap", "gui/\(getuid())", CoreAvailabilityAuthority.plistURL.path], timeout: 10); bootstrapped = true
            let deadline = Date().addingTimeInterval(5)
            while true {
                let loaded = try await ProcessRunner.run("/bin/launchctl", arguments: ["print", "gui/\(getuid())/" + CoreAvailabilityAuthority.label], timeout: 3)
                if loaded.output.contains("pid = ") { break }
                guard Date() < deadline else { throw BridgeError.message("The scoped old helper did not start.") }; try await Task.sleep(nanoseconds: 100_000_000)
            }
            var legacyRefused = false
            do { try await CoreAvailabilityAuthority.requireCompanionPolicySafe(paths: scope.managedPaths) }
            catch { legacyRefused = true }
            guard legacyRefused else { throw BridgeError.message("Legacy helper was accepted unexpectedly.") }
            report["legacy_policy_refused"] = true
            let log = root.appendingPathComponent("fake-adb-calls.log")
            report["legacy_probe_did_not_invoke_adb"] = !FileManager.default.fileExists(atPath: log.path)
            try await DeviceOnboardingAgent.ensureInstalled(hostBundleURL: installedApp, toolchain: Toolchain(adb: adbs[8].path), paths: scope.managedPaths)
            try await CoreAvailabilityAuthority.requireCompanionPolicySafe(paths: scope.managedPaths)
            let entries = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
            let helper = installedApp.appendingPathComponent("Contents/Resources/Runtime/bin/DroidBridgeAvailability")
            let desired = try AvailabilityRuntimeStore.identity(helper: helper, adb: adbs[8])
            guard entries.count == 8, FileManager.default.fileExists(atPath: parent.appendingPathComponent(desired).path), FileManager.default.fileExists(atPath: old[0].path) else { throw BridgeError.message("The bounded runtime upgrade did not preserve its current pin.") }
            report["after_count"] = entries.count; report["current_old_generation_preserved"] = true; report["new_policy_pid_verified"] = true
            report["installed_helper_sha256"] = try AvailabilityRuntimeStore.digest(helper)
            report["new_generation"] = desired
            _ = try await ProcessRunner.run("/bin/launchctl", arguments: ["bootout", "gui/\(getuid())/" + CoreAvailabilityAuthority.label], timeout: 10); bootstrapped = false
            try FileManager.default.removeItem(at: CoreAvailabilityAuthority.plistURL)
            report["scoped_job_removed"] = true; report["acceptance"] = true
        } catch {
            if bootstrapped { _ = try? await ProcessRunner.run("/bin/launchctl", arguments: ["bootout", "gui/\(getuid())/" + CoreAvailabilityAuthority.label], timeout: 10) }
            report["acceptance"] = false; report["error"] = error.localizedDescription
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            throw error
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Scoped availability migration passed; Android availability was not part of this fake-ADB fixture.")
    }
}
