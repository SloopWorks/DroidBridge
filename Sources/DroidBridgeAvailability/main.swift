import Foundation
import AppKit
import Darwin
import DroidBridgeCore

@main struct DroidBridgeAvailabilityMain {
    private static let logLock = NSLock()
    static func appendBounded(data: Data, to url: URL) {
        logLock.lock(); defer { logLock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        if let size = try? fm.attributesOfItem(atPath:url.path)[.size] as? NSNumber, size.intValue > 1_048_576 {
            let prior = url.appendingPathExtension("1"); try? fm.removeItem(at:prior); try? fm.moveItem(at:url,to:prior)
        }
        if !fm.fileExists(atPath:url.path) { fm.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) }
        if let file = try? FileHandle(forWritingTo:url) { _ = try? file.seekToEnd(); try? file.write(contentsOf:data+Data([10])); try? file.close() }
    }
    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--help") { print("Usage: DroidBridgeAvailability [--once] [--adb PATH] [--private-root PATH] [--active-root PATH] [--preferences PATH] [--log PATH] [--interval SECONDS]"); return }
        if args.contains("--version") { print("DroidBridgeAvailability 0.1.8"); return }
        if args.contains("--policy-protocol") { print("1"); return }
        let runtimeLease: AvailabilityRuntimeLease?
        do { runtimeLease = try AvailabilityRuntimeStore.holdRunning(executable: URL(fileURLWithPath: args[0]).resolvingSymlinksInPath()) }
        catch { fputs("Availability runtime lease is unavailable.\n", stderr); return }
        defer { withExtendedLifetime(runtimeLease) {} }
        func option(_ name: String) -> String? { guard let i = args.firstIndex(of: name), args.indices.contains(i+1) else { return nil }; return args[i+1] }
        let paths = ManagedAppsPaths(privateRoot: option("--private-root").map { URL(fileURLWithPath:$0) } ?? ManagedAppsPaths.userDefault.privateRoot, activeRoot: option("--active-root").map { URL(fileURLWithPath:$0) } ?? ManagedAppsPaths.userDefault.activeRoot)
        let preferences = option("--preferences").map { URL(fileURLWithPath:$0) } ?? DroidBridgePreferences.defaultURL
        let adb = option("--adb") ?? URL(fileURLWithPath:args[0]).deletingLastPathComponent().appendingPathComponent("adb").path
        let monitor = ManagedAvailabilityMonitor(toolchain: Toolchain(adb:adb), catalog: ManagedAppCatalog(paths:paths), preferencesURL:preferences)
        let once = args.contains("--once")
        let interval = min(60,max(2,Double(option("--interval") ?? "10") ?? 10))
        let quickWorker = Task {
            var connectionTracker = QuickOpenConnectionTracker()
            var previousQuickPreferences: QuickOpenPreferences?
            let quickPreferencesURL = preferences.deletingLastPathComponent().appendingPathComponent("quick-open.json")
            let tools = Toolchain(adb: adb)

            repeat {
                do {
                    let preference = try QuickOpenPreferences.load(url: quickPreferencesURL)
                    if preference != previousQuickPreferences {
                        connectionTracker = QuickOpenConnectionTracker(serial: preference.serial)
                        previousQuickPreferences = preference
                    }
                    if preference.enabled {
                        let output = try await ProcessRunner.run(adb, arguments: ["devices", "-l"], environment: tools.environment, timeout: 3)
                        let discovered = AndroidDiscovery.parseDevices(output.output)
                        let devices = CompanionQAScope.current?.filterDevices(discovered) ?? discovered
                        var ready = Set<String>()
                        for device in devices where device.state == "device" && (preference.serial == nil || preference.serial == device.serial) {
                            if await DeviceReadiness.isReady(device: device, toolchain: tools, timeout: 1) { ready.insert(device.serial) }
                        }
                        if connectionTracker.observe(devices: devices, readySerials: ready) {
                            guard let path = preference.hostBundlePath else { throw BridgeError.message("Save connection settings from the installed DroidBridge app before enabling automatic opening.") }
                            let host = try QuickOpenHost.validate(path: path)
                            let running = await MainActor.run {
                                NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "app.droidbridge.desktop" && $0.bundleURL?.standardizedFileURL.path == host.standardizedFileURL.path && !$0.isTerminated }
                            }
                            if !running {
                                var arguments = ["-n", "-a", host.path, "--args", "--quick-open"]
                                if let scope = CompanionQAScope.current { arguments += ["--companion-qa-root", scope.root.path, "--serial", scope.serial] }
                                try Task.checkCancellation()
                                guard try QuickOpenPreferences.load(url: quickPreferencesURL) == preference else { throw CancellationError() }
                                _ = try await ProcessRunner.run("/usr/bin/open", arguments: arguments, timeout: 5)
                            }
                        }
                    }
                } catch {
                    let message = "Automatic opening unavailable: " + String(error.localizedDescription.prefix(350))
                    fputs(message + "\n", stderr)
                    if let path = option("--log") { appendBounded(data: Data(message.utf8), to: URL(fileURLWithPath: path)) }
                }
                if once || Task.isCancelled { break }
                // Independent from managed catalog publication and registration.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } while !Task.isCancelled
        }
        let worker = Task {
            var failures = 0
            repeat {
                let result = await monitor.cycle()
                if let data = try? JSONEncoder().encode(result) {
                    print(String(decoding:data,as:UTF8.self)); fflush(stdout)
                    if let path = option("--log") { appendBounded(data: data, to: URL(fileURLWithPath:path)) }
                }
                failures = result.messages.isEmpty ? 0 : min(3,failures+1)
                if once || Task.isCancelled { break }
                // Delay is armed from cycle completion, never from its start.
                let delay = result.pendingRegistrations > 0 && (result.registrations > 0 || result.transitions > 0) ? 0.2 : min(60,interval*pow(2,Double(failures)))
                try? await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))
            } while !Task.isCancelled
        }
        signal(SIGTERM,SIG_IGN); signal(SIGINT,SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal:SIGTERM,queue:.global())
        let interrupt = DispatchSource.makeSignalSource(signal:SIGINT,queue:.global())
        term.setEventHandler { worker.cancel(); quickWorker.cancel() }; interrupt.setEventHandler { worker.cancel(); quickWorker.cancel() }
        term.resume(); interrupt.resume()
        await worker.value
        // --once includes exactly one quick-opening observation, too.
        if !once { quickWorker.cancel() }
        await quickWorker.value
        term.cancel(); interrupt.cancel()
    }
}
