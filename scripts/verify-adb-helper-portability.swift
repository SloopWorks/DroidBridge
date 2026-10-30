import Foundation
import Darwin
import DroidBridgeCore

@main struct ADBHelperPortabilityFixture {
    static func main() async {
        do { try await run() }
        catch { fputs("Portable ADB helper fixture failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    static func run() async throws {
        guard let scope = CompanionQAScope.current, scope.serial == "emulator-5580" else { throw BridgeError.message("This fixture requires the explicitly owned helper QA root. No Android connection is used.") }
        func option(_ key: String) throws -> String {
            guard let i = CommandLine.arguments.firstIndex(of: key), CommandLine.arguments.indices.contains(i + 1) else { throw BridgeError.message("Missing \(key)") }
            return CommandLine.arguments[i + 1]
        }
        let adb = URL(fileURLWithPath: try option("--adb")), installed = URL(fileURLWithPath: try option("--installed-app"))
        let brokerSource = URL(fileURLWithPath: try option("--broker")), output = URL(fileURLWithPath: try option("--output"))
        let domain = "gui/\(geteuid())", job = domain + "/" + CompanionBrokerIPC.serviceName
        let plistURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/" + CompanionBrokerIPC.serviceName + ".plist")
        guard !FileManager.default.fileExists(atPath: plistURL.path) else { throw BridgeError.message("A broker plist already exists; preserve it.") }
        if FileManager.default.fileExists(atPath: scope.brokerDirectory.path) {
            guard CommandLine.arguments.contains("--resume-empty-fixture"),
                  let state = try JSONSerialization.jsonObject(with: Data(contentsOf: scope.brokerDirectory.appendingPathComponent("state.json"))) as? [String: Any],
                  (state["devices"] as? [Any])?.isEmpty == true,
                  (state["pendingAdmissions"] as? [Any])?.isEmpty == true,
                  (state["inbox"] as? [Any])?.isEmpty == true else { throw BridgeError.message("This broker fixture already exists. Resume only an explicitly inspected, empty owned fixture.") }
        }
        let prior = try await ProcessRunner.run("/bin/launchctl", arguments: ["print", job], timeout: 3, allowNonZeroExit: true)
        guard prior.status != 0 else { throw BridgeError.message("The owned QA broker label is already loaded.") }
        var report: [String: Any] = ["fixture": "actual scoped broker and immutable availability ADB relocation", "android_transport_tested": false, "server_started": false, "job": CompanionBrokerIPC.serviceName]
        var installationAttempted = false
        do {
            let runtime = try ADBPortableRuntime.inventory(adb: adb)
            try await runtime.verifyLoadClosure()
            report["source_portable_files"] = runtime.files.map(\.name)
            let legacyADB = installed.appendingPathComponent("Contents/Resources/Runtime/bin/adb")
            let legacy = try ADBPortableRuntime.inventory(adb: legacyADB)
            try await legacy.verifyLoadClosure()
            report["installed_legacy_sdk_closure_verified"] = !legacy.isPortable
            report["installed_legacy_sdk_sha256"] = try AvailabilityRuntimeStore.digest(legacyADB)
            let parent = scope.root.appendingPathComponent("PortableAvailability/generations")
            let lease = try await AvailabilityRuntimeStore.lock(parent: parent)
            let helper = installed.appendingPathComponent("Contents/Resources/Runtime/bin/DroidBridgeAvailability")
            let availability = try await AvailabilityRuntimeStore.prepare(parent: parent, helper: helper, adb: adb, preservedGeneration: nil)
            withExtendedLifetime(lease) {}
            let environment = ["PATH": "/usr/bin:/bin"]
            let version = try await ProcessRunner.run(availability.appendingPathComponent("adb").path, arguments: ["version"], environment: environment, timeout: 5)
            guard version.output.contains("Version 37.0.0-android-tools") else { throw BridgeError.message("The relocated availability ADB did not execute.") }
            report["availability_adb_version"] = version.output
            report["availability_generation"] = availability.path
            let brokerCopy = scope.root.appendingPathComponent("PortableBrokerSource-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: brokerCopy, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let broker = brokerCopy.appendingPathComponent("DroidBridgeCompanionBroker")
            try FileManager.default.copyItem(at: brokerSource, to: broker)
            _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", broker.path], timeout: 5)
            installationAttempted = true
            try await CompanionBrokerInstaller.ensureInstalled(executable: broker, adb: adb)
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
            guard let arguments = plist?["ProgramArguments"] as? [String], let executable = arguments.first,
                  let env = plist?["EnvironmentVariables"] as? [String: String], let stagedADB = env["DROIDBRIDGE_ADB"] else { throw BridgeError.message("The scoped broker configuration is incomplete.") }
            let generation = URL(fileURLWithPath: executable).deletingLastPathComponent()
            guard generation.deletingLastPathComponent().path == scope.brokerDirectory.appendingPathComponent("generations").path,
                  stagedADB == generation.appendingPathComponent("adb").path else { throw BridgeError.message("The scoped broker escaped its owned generation.") }
            var loaded: ProcessResult?, pid: Int32?
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                loaded = try await ProcessRunner.run("/bin/launchctl", arguments: ["print", job], timeout: 3)
                pid = loaded?.output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { $0.hasPrefix("pid = ") }).flatMap { Int32($0.dropFirst(6)) }
                if pid != nil { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let pid else { throw BridgeError.message("The scoped broker did not start.") }
            var path = [UInt8](repeating: 0, count: 4096)
            let length = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
            guard length > 0, let end = path.firstIndex(of: 0), String(decoding: path[..<end], as: UTF8.self) == executable else { throw BridgeError.message("The running broker path does not match its staged executable.") }
            let client = CompanionBrokerIPCClient()
            var status: CompanionBrokerReply?
            let readyDeadline = Date().addingTimeInterval(8)
            repeat {
                do {
                    status = try await client.request(operation: "status")
                    break
                } catch let error as CompanionBoundaryError where error.code == "broker_starting" {
                    // A PID can exist before the broker's bounded state load is
                    // complete. Retry readiness with a fresh request identity.
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            } while Date() < readyDeadline
            guard status?.status == "ok", status?.data["devices"]?.array?.isEmpty == true else { throw BridgeError.message("The fresh scoped broker did not answer an empty offline status.") }
            let lockURL = scope.brokerDirectory.appendingPathComponent("leases/" + generation.lastPathComponent + ".lock")
            let fd = open(lockURL.path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw BridgeError.message("The broker lifetime lease was not created.") }
            defer { close(fd) }
            guard flock(fd, LOCK_EX | LOCK_NB) != 0, errno == EWOULDBLOCK else { throw BridgeError.message("The running broker does not hold its checked generation lease.") }
            let stagedRuntime = try ADBPortableRuntime.inventory(adb: URL(fileURLWithPath: stagedADB), requireOwned: true)
            try await stagedRuntime.verifyLoadClosure()
            let brokerVersion = try await ProcessRunner.run(stagedADB, arguments: ["version"], environment: environment, timeout: 5)
            guard brokerVersion.output.contains("Version 37.0.0-android-tools") else { throw BridgeError.message("The relocated broker ADB did not execute.") }
            report["broker_pid"] = pid; report["broker_executable"] = executable
            report["broker_adb_version"] = brokerVersion.output; report["broker_xpc_offline_status"] = true
            report["broker_checked_lifetime_lease"] = true
            try loaded?.output.write(to: output.deletingPathExtension().appendingPathExtension("launchctl.txt"), atomically: true, encoding: .utf8)
            var finalPID = pid
            if CommandLine.arguments.contains("--upgrade-cycles") {
                var upgrades: [[String: Any]] = []
                var previousGeneration = generation
                for index in 0..<4 {
                    let previousOwner = CompanionBrokerOwner.live(finalPID)
                    if index == 3 {
                        // A configured job may be throttled or deliberately
                        // stopped. Its plist pin must survive reclamation too.
                        _ = try await ProcessRunner.run("/bin/launchctl", arguments: ["bootout", job], timeout: 10)
                        let deadline = Date().addingTimeInterval(5)
                        while previousOwner?.isAlive == true && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
                        guard previousOwner?.isAlive != true else { throw BridgeError.message("The owned broker did not stop for the pinned-offline upgrade.") }
                    }
                    _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", "--identifier", "dev.droidbridge.qa.portable-upgrade." + UUID().uuidString, broker.path], timeout: 5)
                    try await CompanionBrokerInstaller.ensureInstalled(executable: broker, adb: adb)
                    let next = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any]
                    guard let argv = next?["ProgramArguments"] as? [String], let path = argv.first else { throw BridgeError.message("Upgraded broker plist is incomplete.") }
                    let nextGeneration = URL(fileURLWithPath: path).deletingLastPathComponent()
                    let readyDeadline = Date().addingTimeInterval(8)
                    var newPID: Int32?
                    while Date() < readyDeadline {
                        let live = try await ProcessRunner.run("/bin/launchctl", arguments: ["print", job], timeout: 3)
                        newPID = live.output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.first(where: { $0.hasPrefix("pid = ") }).flatMap { Int32($0.dropFirst(6)) }
                        if newPID != nil { break }
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    guard let newPID, previousOwner?.isAlive != true,
                          FileManager.default.fileExists(atPath: previousGeneration.path) else { throw BridgeError.message("An upgrade overlapped the previous broker or removed its configured pin.") }
                    let count = try FileManager.default.contentsOfDirectory(atPath: nextGeneration.deletingLastPathComponent().path).count
                    guard count <= 4, index != 3 || count == 4 else { throw BridgeError.message("The broker generation bound failed.") }
                    let upgraded = CompanionBrokerIPCClient()
                    var ready = false
                    while Date() < readyDeadline {
                        do {
                            let state = try await upgraded.request(operation: "status")
                            ready = state.data["devices"]?.array?.isEmpty == true; break
                        } catch let error as CompanionBoundaryError where error.code == "broker_starting" {
                            try await Task.sleep(nanoseconds: 100_000_000)
                        }
                    }
                    guard ready else { throw BridgeError.message("The upgraded broker did not become ready.") }
                    upgrades.append(["index": index, "old_owner_stopped": true, "old_configured_generation_preserved": true, "old_job_stopped_before_upgrade": index == 3, "retained_count": count, "pid": newPID, "generation": nextGeneration.path])
                    previousGeneration = nextGeneration; finalPID = newPID
                }
                report["upgrades"] = upgrades
            }
            _ = try await ProcessRunner.run("/bin/launchctl", arguments: ["bootout", job], timeout: 10)
            let stopped = Date().addingTimeInterval(5)
            while kill(finalPID, 0) == 0 && Date() < stopped { try await Task.sleep(nanoseconds: 50_000_000) }
            guard kill(finalPID, 0) != 0, errno == ESRCH else { throw BridgeError.message("The scoped broker did not stop after bootout.") }
            try FileManager.default.removeItem(at: plistURL)
            installationAttempted = false
            report["scoped_job_removed"] = true; report["acceptance"] = true
        } catch {
            if installationAttempted {
                _ = try? await ProcessRunner.run("/bin/launchctl", arguments: ["bootout", job], timeout: 10, allowNonZeroExit: true)
                if let data = try? Data(contentsOf: plistURL), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], plist["Label"] as? String == CompanionBrokerIPC.serviceName { try? FileManager.default.removeItem(at: plistURL) }
            }
            report["acceptance"] = false; report["error"] = error.localizedDescription
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            throw error
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output)
        print("Portable ADB executed from both helper generation layouts; actual scoped broker PID/XPC/lease verified and removed. No device or server command was issued.")
    }
}
