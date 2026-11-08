import AppKit
import ImageIO
import DroidBridgeCore

/// Production launcher/factory, Launch Services and decoded emulator video.
/// Only a private QA scope and emulator-5580 are permitted.
@main struct VerifyAppLaunchIcons {
    static let device = AndroidDevice(serial: "emulator-5580", model: "DroidBridge API35")
    static let probe = AndroidApplication(packageName: "dev.droidbridge.testapp7", name: "Android Launch Probe")
    static let alias = AndroidApplication(packageName: "dev.droidbridge.iconfixture", name: "Android Icon Alias")
    static let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DROIDBRIDGE_LAUNCH_EVIDENCE"]!)
    static let host = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DROIDBRIDGE_LAUNCH_REVIEW_APP"]!)
    @MainActor static var reports: [[String: Any]] = []
    @MainActor static var owned: [NSRunningApplication] = []
    @MainActor static var controllers: [LauncherController] = []
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
        Task { @MainActor in
            do {
                try await run()
                await cleanup()
                try require(owned.allSatisfy(\.isTerminated), "An owned app failed to quit")
                try save()
                print("PASS: independent launcher apps, real Android video, full Android icons, progress, cancellation, reuse, rediscovery, stale status, exact cleanup")
                fflush(stdout); exit(0)
            } catch {
                reports.append(["passed": false, "error": String(describing: error)])
                await cleanup(); try? save()
                fputs("FAIL: app launch icons: \(error)\n", stderr); exit(1)
            }
        }
        NSApplication.shared.run()
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw BridgeError.message(message) } }
    @MainActor static func wait(_ label: String, seconds: Double = 35, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return }; try await Task.sleep(for: .milliseconds(35)) }
        throw BridgeError.message("Timed out: " + label)
    }
    @MainActor static func save() throws {
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
    }
    @MainActor static func cleanup() async {
        for c in controllers { await c.shutdownAndWait(); c.window?.close() }
        for application in owned where !application.isTerminated { _ = application.terminate() }
        for _ in 0..<600 {
            if owned.allSatisfy(\.isTerminated) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
    @MainActor static func capture(_ launcher: LauncherController, _ name: String) throws {
        guard let view = launcher.window?.contentView else { throw BridgeError.message("No launcher view") }
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw BridgeError.message("No launcher bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
    }
    @MainActor static func pixels(_ image: NSImage) -> [UInt8] {
        let size = 64
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return Array(UnsafeBufferPointer(start: bitmap.bitmapData!, count: size * size * 4))
    }
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        zip(a,b).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(a.count)
    }
    @MainActor static func open(_ launcher: LauncherController, app: AndroidApplication, backend: BackendKind = .native) async throws -> LaunchedDesktopApp {
        let start = Date()
        launcher.openApp(device: device, app: app, backend: backend, host: host)
        try require(launcher.appLaunchProgress?.busy == true && launcher.launcherUI?.appLaunchBanner.isHidden == false, "No synchronous visible progress")
        try require(launcher.launcherUI?.appLaunchLabel.stringValue.contains(app.name) == true, "Progress omitted app identity")
        launcher.status.stringValue = "Unrelated periodic device status"
        try require(launcher.launcherUI?.appLaunchLabel.stringValue.contains("Checking") == true, "Periodic status erased launch progress")
        var stages = Set<String>()
        while launcher.appLaunchTask != nil {
            if let progress = launcher.appLaunchProgress {
                let firstObservation = stages.insert(progress.message).inserted
                if progress.message.contains("Preparing"), firstObservation {
                    try capture(launcher, "preparing-" + backend.rawValue + "-" + app.packageName)
                    launcher.showWorkspace(.sessions)
                    try require(launcher.launcherUI?.appLaunchBanner.isHidden == false && launcher.appLaunchProgress?.busy == true, "Navigation hid in-progress launch")
                    try capture(launcher, "progress-across-workspaces")
                    launcher.showWorkspace(.apps)
                }
            }
            try require(Date().timeIntervalSince(start) < 55, "App preparation did not finish within its bound")
            try await Task.sleep(for: .milliseconds(40))
        }
        guard let tracked = launcher.launchedApps.values.first(where: { $0.app.packageName == app.packageName && $0.backend == backend }) else {
            throw BridgeError.message(launcher.appLaunchProgress?.message ?? "No independent app process")
        }
        if !owned.contains(where: { $0.processIdentifier == tracked.process.owner.pid }) { owned.append(tracked.application) }
        try await wait("actual running video snapshot") {
            launcher.pollLaunchedApps()
            return launcher.launchedApps[tracked.process.owner.pid]?.snapshot?.sessions.contains(where: { $0.state == .running }) == true
        }
        let current = launcher.launchedApps[tracked.process.owner.pid]!
        guard let session = current.snapshot?.sessions.first(where: { $0.state == .running }), let scope = CompanionQAScope.current else { throw BridgeError.message("Missing live session") }
        let log = scope.logDirectory.appendingPathComponent("session-\(session.id.uuidString).log.jsonl")
        if backend == .native {
            // Session running admits its first decoded frame; the local splash
            // may persist through initial black frames. Await visible content too.
            try await wait("visible decoded Android content", seconds: 15) {
                guard let text = try? String(contentsOf: log, encoding: .utf8) else { return false }
                return text.contains("native_content_presented")
            }
        }
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        if backend == .native { try require(lines.contains { $0["event"] as? String == "native_content_presented" }, "Running snapshot had no presented decoded Android content") }
        if backend == .scrcpy {
            let raw = try String(contentsOf: log.deletingPathExtension(), encoding: .utf8)
            try require(raw.contains("Texture") && raw.contains("Starting app"), "Fallback had no actual Android video texture")
            try await wait("fallback independent Player identity") { NSRunningApplication.runningApplications(withBundleIdentifier: current.process.bundleIdentifier + ".player").contains { $0.activationPolicy == .regular && $0.bundleURL?.standardizedFileURL.path.hasPrefix(current.process.bundleURL.path) == true } }
            let player = NSRunningApplication.runningApplications(withBundleIdentifier: current.process.bundleIdentifier + ".player").first { $0.bundleURL?.standardizedFileURL.path.hasPrefix(current.process.bundleURL.path) == true }!
            try require(difference(pixels(player.icon!), pixels(NSWorkspace.shared.icon(forFile: player.bundleURL!.path))) < 4, "Fallback Player retained the host icon")
        }
        let bundle = tracked.process.bundleURL
        func uuids(_ executable: URL) async throws -> [String] {
            let result = try await ProcessRunner.run("/usr/bin/dwarfdump", arguments: ["--uuid", executable.path])
            return result.output.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: " ")
                return fields.count > 1 && fields[0] == "UUID:" ? String(fields[1]) : nil
            }
        }
        let sourceUUIDs = try await uuids(host.appendingPathComponent("Contents/MacOS/DroidBridge"))
        let appUUIDs = try await uuids(bundle.appendingPathComponent("Contents/MacOS/DroidBridge"))
        let playerUUIDs = try await uuids(bundle.appendingPathComponent("Contents/Resources/Runtime/Player.app/Contents/MacOS/scrcpy"))
        let sourcePlayerUUIDs = try await uuids(host.appendingPathComponent("Contents/Resources/Runtime/Player.app/Contents/MacOS/scrcpy"))
        try require(!appUUIDs.isEmpty && Set(appUUIDs).isDisjoint(with: sourceUUIDs), "Generated app shares the host executable UUID")
        try require(!playerUUIDs.isEmpty && Set(playerUUIDs).isDisjoint(with: sourcePlayerUUIDs + appUUIDs), "Generated Player shares another app executable UUID")
        for other in launcher.launchedApps.values where other.process != current.process {
            let otherUUIDs = try await uuids(other.process.bundleURL.appendingPathComponent("Contents/MacOS/DroidBridge"))
            try require(Set(appUUIDs).isDisjoint(with: otherUUIDs), "Two Android apps share an executable UUID")
        }
        _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", bundle.path])
        let android = NSImage(contentsOf: bundle.appendingPathComponent("Contents/Resources/AndroidApp.png"))!
        let icns = NSImage(contentsOf: bundle.appendingPathComponent("Contents/Resources/AndroidApp.icns"))!
        let actual = tracked.application.icon!
        let expected = NSWorkspace.shared.icon(forFile: bundle.path)
        let rawError = difference(pixels(android), pixels(icns))
        let platformError = difference(pixels(actual), pixels(expected))
        let genericDifference = difference(pixels(actual), pixels(NSWorkspace.shared.icon(forFile: host.path)))
        try require(rawError < 4 && platformError < 4 && genericDifference > 10, "Android app icon did not reach the running Mac identity")
        try require(current.application.activationPolicy == .regular || backend == .scrcpy, "Native app lacked its own regular Dock identity")
        try Data(contentsOf: bundle.appendingPathComponent("Contents/Resources/AndroidApp.png")).write(to: output.appendingPathComponent("android-icon-\(app.packageName).png"))
        reports.append(["case": "open", "package": app.packageName, "backend": backend.rawValue, "passed": true, "pid": current.process.owner.pid,
                        "bundle": bundle.path, "identifier": current.process.bundleIdentifier, "seconds": Date().timeIntervalSince(start), "stages": stages.sorted(),
                        "android_icns_pixel_error": rawError, "running_icon_pixel_error": platformError, "difference_from_droidbridge_icon": genericDifference,
                        "session": session.id.uuidString, "presented_decoded_video": backend == .native])
        reports.append(["case":"isolated_executable_identities", "passed":true, "identifier":current.process.bundleIdentifier,
                        "source_uuids":sourceUUIDs, "app_uuids":appUUIDs, "source_player_uuids":sourcePlayerUUIDs, "player_uuids":playerUUIDs])
        try save()
        return current
    }
    @MainActor static func run() async throws {
        guard let scope = CompanionQAScope.current, scope.serial == device.serial, !host.path.contains("/.build/") else { throw BridgeError.message("External app and dedicated QA scope required") }
        let launcher = LauncherController(); controllers.append(launcher); launcher.showWindow(nil)
        launcher.devices = [device]; launcher.devicePicker.addItem(withTitle: device.model); launcher.devicePicker.selectItem(at: 0)
        launcher.readySerials = [device.serial]; launcher.appsDeviceSerial = device.serial
        launcher.applications = [probe,alias]; launcher.filtered = launcher.applications; launcher.table.reloadData()
        launcher.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        // Immediate cancellation must not launch a process or leave a generic app.
        launcher.openApp(device: device, app: probe, backend: .native, host: host)
        let pending = launcher.appLaunchTask
        launcher.cancelAppLaunch(); await pending?.value
        try require(launcher.launchedApps.isEmpty && launcher.appLaunchProgress?.message == "Opening cancelled.", "Cancelled request admitted an app")
        reports.append(["case": "cancel_before_admission", "passed": true]); try capture(launcher, "cancelled")
        let first = try await open(launcher, app: probe)
        let originalSession = first.snapshot!.sessions.first!.id
        _ = first.application.hide()
        let again = try await open(launcher, app: probe)
        try require(again.process == first.process && again.snapshot!.sessions.first!.id == originalSession && !again.application.isHidden, "Reopen duplicated the process/session or left it hidden")
        reports.append(["case": "reuse_same_process_session_and_unhide", "passed": true]); try save()
        let second = try await open(launcher, app: alias)
        try require(first.process.bundleIdentifier != second.process.bundleIdentifier && first.process.owner != second.process.owner, "Two Android apps shared a Mac identity")
        try require(launcher.sessions.isEmpty && launcher.visibleLaunchedApps.count == 2, "Main retained Android windows or omitted independent sessions")
        launcher.showWorkspace(.sessions); try capture(launcher, "two-independent-apps")
        reports.append(["case": "two_distinct_android_app_identities", "passed": true]); try save()
        if ProcessInfo.processInfo.environment["DROIDBRIDGE_QA_HOLD"] == "1" {
            try Data("ready".utf8).write(to: output.appendingPathComponent("ready-for-visual-review"))
            try await Task.sleep(for: .seconds(45))
        }
        await launcher.shutdownAndWait(); launcher.window?.close()
        try require(!first.application.isTerminated && !second.application.isTerminated, "Quitting management closed independent apps")
        let reopened = LauncherController(); controllers.append(reopened); reopened.showWindow(nil); reopened.devices = [device]
        reopened.startAppSessionMonitoring()
        try await wait("management restart rediscovery") { reopened.launchedApps.count == 2 }
        try require(reopened.launchedApps[first.process.owner.pid]?.phase == "Running", "Rediscovery lost actual running state")
        reports.append(["case": "management_restart_rediscovers_unpaired_apps", "passed": true]); try save()
        // Clear a snapshot briefly: process liveness cannot preserve stale Running.
        let registry = scope.root.appendingPathComponent("DesktopAppSessions")
        let files = try FileManager.default.contentsOfDirectory(at: registry, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard let file = files.first(where: { url in
            guard let value = try? JSONDecoder().decode(DesktopAppSessionSnapshot.self, from: Data(contentsOf: url)) else { return false }
            return value.process == first.process
        }) else { throw BridgeError.message("Missing exact registry file") }
        let saved = try Data(contentsOf: file); try FileManager.default.removeItem(at: file)
        reopened.pollLaunchedApps()
        try await wait("missing snapshot clears stale running", seconds: 3) { reopened.launchedApps[first.process.owner.pid]?.statusUnavailable == true }
        try saved.write(to: file, options: .atomic); try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:file.path)
        try await wait("snapshot recovery") { reopened.pollLaunchedApps(); return reopened.launchedApps[first.process.owner.pid]?.phase == "Running" }
        reports.append(["case": "missing_snapshot_never_claims_running", "passed": true]); try save()
        reopened.closeLaunchedApp(first.process.owner.pid); reopened.closeLaunchedApp(second.process.owner.pid)
        try await wait("exact app close and cleanup") { first.application.isTerminated && second.application.isTerminated }
        reports.append(["case": "close_exact_independent_apps", "passed": true])
        let resolved = try await Task.detached {
            try await AppLaunchResolver.find(device: device, app: probe, backend: .native, host: host, catalog: ManagedAppCatalog(paths: scope.managedPaths), running: [])
        }.value
        try require(resolved.map { WrapperBackup.canonicalPath($0.url) } == WrapperBackup.canonicalPath(first.process.bundleURL), "Personalized stopped app failed provenance/reuse validation")
        reports.append(["case":"personalized_stopped_app_reuse", "passed":true])
        // Cancellation after asynchronous icon work begins must drain cleanup.
        reopened.showWorkspace(.apps)
        reopened.openApp(device: device, app: alias, backend: .scrcpy, host: host)
        try await wait("asynchronous icon extraction", seconds: 8) { reopened.appLaunchProgress?.message.contains("Loading Android") == true }
        reopened.cancelAppLaunch(); await reopened.appLaunchTask?.value
        try require(reopened.appLaunchProgress?.message == "Opening cancelled.", "Icon-stage cancellation was not surfaced")
        reports.append(["case": "cancel_during_icon_extraction", "passed": true])
        _ = try await open(reopened, app: probe, backend: .scrcpy)
        reports.append(["case": "fallback_wrapper_and_video", "passed": true])
    }
}
