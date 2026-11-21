import AppKit
import Foundation
import CryptoKit
import DroidBridgeCore
import DroidBridgeStreaming

/// Executes shipping Quick Access/AppKit code against the dedicated emulator.
/// App launches use the packaged shipping host, never this QA executable.
@main struct VerifyQuickAccess {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
        Task { @MainActor in
            do { try await run(); print("PASS: automatic quick open, native mirror, app reuse, failures and cleanup"); fflush(stdout); exit(0) }
            catch { fputs("FAIL: quick access: \(error)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }
    @MainActor static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw BridgeError.message(message) }
    }
    @MainActor static func wait(_ label: String, seconds: Double = 30, _ value: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            if value() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BridgeError.message("Timed out: \(label)")
    }
    @MainActor static func capture(_ view: NSView, to path: URL) throws -> String {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw BridgeError.message("No AppKit bitmap") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw BridgeError.message("No PNG") }
        try data.write(to: path)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    @MainActor static func run() async throws {
        guard let scope = CompanionQAScope.current, scope.serial == "emulator-5580",
              let hostPath = ProcessInfo.processInfo.environment["DROIDBRIDGE_QUICK_HOST"],
              let evidencePath = ProcessInfo.processInfo.environment["DROIDBRIDGE_GUI_EVIDENCE"] else { throw BridgeError.message("Explicit owned scope, packaged host and evidence required") }
        let output = URL(fileURLWithPath: evidencePath), host = URL(fileURLWithPath: hostPath)
        let launcher = LauncherController(), quick = launcher.quickAccess
        let device = AndroidDevice(serial: scope.serial, model: "Dedicated Android 15 emulator")
        let fixture = AndroidApplication(packageName: "dev.droidbridge.testapp20261121", name: "Quick Open Test")
        var observations: [String: Any] = [:], commands: [[String: Any]] = []
        var ownedApps: [NSRunningApplication] = []
        func adb(_ arguments: [String]) async throws -> String {
            let args = ["-s", scope.serial] + arguments
            let result = try await ProcessRunner.run(launcher.toolchain.adb, arguments: args, environment: launcher.toolchain.environment, timeout: 15)
            commands.append(["executable": launcher.toolchain.adb, "arguments": args, "output": result.output])
            return result.output
        }
        func selection(_ d: AndroidDevice, _ app: AndroidApplication) {
            launcher.devices = [d]; launcher.devicePicker.removeAllItems(); launcher.devicePicker.addItem(withTitle: d.model)
            launcher.devicePicker.selectItem(at: 0); launcher.readySerials = [d.serial]
            launcher.applications = [app]; launcher.appsDeviceSerial = d.serial; launcher.filterApps()
            launcher.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        do {
            launcher.timer?.invalidate(); launcher.pending = []; launcher.onboardingPending = true
            launcher.backendPicker.selectItem(at: 0)
            // Never change audio routes or device-panel preferences during video QA.
            launcher.sharedPreferences.deviceAudioRoutes[device.serial] = .phone
            _ = try await Task.detached { try DroidBridgePreferences.update { $0.deviceAudioRoutes["emulator-5580"] = .phone } }.value
            try await Task.sleep(for: .milliseconds(150)) // Drain initial settings read.
            selection(device, fixture)
            let initialForwards = try await adb(["forward", "--list"])
            let initialDisplays = try await adb(["shell", "dumpsys", "display"])
            _ = try await adb(["shell", "input", "keyevent", "KEYCODE_WAKEUP"])
            _ = try await adb(["shell", "wm", "dismiss-keyguard"])
            _ = try await adb(["shell", "am", "start", "-n", fixture.packageName + "/.MainActivity"])
            quick.enabled = false; quick.target = .control; quick.saveSelection(); quick.configure()
            launcher.window?.orderOut(nil); quick.observe(devices: [device], ready: [device.serial]); quick.open()
            try require(launcher.window?.isVisible == false, "Disabled feature brought controls forward")
            quick.enabled = true; quick.configure()
            quick.observe(devices: [AndroidDevice(serial: "qa-other", model: "Other")], ready: ["qa-other"])
            try require(launcher.window?.isVisible == false, "Other device triggered quick-open")
            quick.observe(devices: [device], ready: [])
            try require(launcher.window?.isVisible == false, "Booting device triggered quick-open")
            quick.observe(devices: [device], ready: [device.serial])
            try require(launcher.window?.isVisible == true, "Ready connection did not open controls")
            try await Task.sleep(for: .milliseconds(250))
            observations["control_focus"] = ["active": NSApp.isActive, "key_window": launcher.window?.isKeyWindow ?? false, "frontmost_pid": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, "qa_pid": getpid()]
            launcher.window?.orderOut(nil)
            for _ in 0..<5 { quick.observe(devices: [device], ready: [device.serial]) }
            quick.observe(devices: [device], ready: []); quick.observe(devices: [device], ready: [device.serial])
            try require(launcher.window?.isVisible == false, "Polling/readiness flap repeatedly stole focus")
            quick.observe(devices: [], ready: []); quick.observe(devices: [device], ready: [device.serial])
            try require(launcher.window?.isVisible == true, "Reconnect did not rearm automatic open")
            observations["connection_edges"] = "Disabled/other-device/booting ignored; ready edge opens once; readiness flaps do not refocus; disconnect/reconnect rearms"

            // Actual display-0 decoding through the shipping automatic trigger.
            quick.target = .screen; quick.configure(); quick.saveSelection()
            let screenBegan = ProcessInfo.processInfo.systemUptime
            quick.observe(devices: [device], ready: [device.serial])
            try await wait("decoded current-screen video") { launcher.sessions.values.contains { $0.descriptor.configuration.mirrorDeviceScreen && $0.state == .running && $0.metrics.frames > 6 } }
            let decodedSeconds = ProcessInfo.processInfo.systemUptime - screenBegan
            guard let mirror = launcher.sessions.values.first(where: { $0.descriptor.configuration.mirrorDeviceScreen }), let view = launcher.hosts[mirror.descriptor.id] else { throw BridgeError.message("No mirror view") }
            let before = try capture(view.video, to: output.appendingPathComponent("mirror-before.png"))
            try await Task.sleep(for: .milliseconds(600))
            let after = try capture(view.video, to: output.appendingPathComponent("mirror-after.png"))
            try require(before != after, "Current-screen decoded pixels did not change")
            try require(mirror.metrics.width == 1080 && mirror.metrics.height == 1920, "Mirror changed display-0 dimensions")
            let mirrorID = mirror.descriptor.id, mirrorWindow = view.window
            view.window?.miniaturize(nil); quick.open()
            try await wait("mirror reopen request settled") { !quick.isOpening }
            try await wait("reuse minimized mirror") { view.window?.isMiniaturized == false }
            try require(launcher.sessions.count == 1 && launcher.hosts[mirrorID]?.window === mirrorWindow, "Quick-open duplicated mirror")
            view.window?.setContentSize(NSSize(width: 500, height: 400))
            try await Task.sleep(for: .milliseconds(500))
            try require(mirror.metrics.width == 1080 && mirror.metrics.height == 1920, "Resizing mirror resized phone display")
            let placement = try await adb(["shell", "dumpsys", "activity", "activities"])
            try require(placement.contains(fixture.packageName) && placement.contains("displayId=0"), "Mirror moved/relaunched foreground task")
            observations["mirror"] = ["decoded_several_frames_seconds": decodedSeconds, "width": mirror.metrics.width, "height": mirror.metrics.height, "frames": mirror.metrics.frames, "changing_pixel_hashes": [before, after], "same_window_on_reopen": true, "log": mirror.logURL.path]
            quick.open(); launcher.close(mirrorID, reason: "qa_mirror_complete"); await mirror.stopAndWait()
            try await wait("closed mirror pending reuse drains") { !quick.isOpening }
            try require(launcher.sessions.isEmpty, "Closing a mirror admitted a late replacement")
            // A canceled pending request must never admit a late session.
            quick.open(); quick.enabled = false; quick.configure()
            try await Task.sleep(for: .milliseconds(500))
            try require(launcher.sessions.isEmpty, "Disabled pending request admitted a session")
            quick.enabled = true; quick.target = .app; quick.configure()
            selection(device, AndroidApplication(packageName: "dev.droidbridge.missing20261121", name: "Missing QA App")); quick.saveSelection(); quick.open(host: host)
            try await wait("missing app guidance") { quick.message.contains("no longer available") }
            try require(launcher.appLaunchTask == nil && launcher.sessions.isEmpty, "Missing app launched a task")
            observations["missing_app"] = quick.message
            selection(AndroidDevice(serial: "qa-disconnected", model: "Disconnected QA"), fixture); quick.saveSelection(); quick.open(host: host)
            try await wait("disconnected guidance") { quick.message.contains("disconnected") }
            observations["disconnected"] = quick.message

            selection(device, fixture); quick.saveSelection(); quick.open(host: host)
            try await wait("specific app preparation begins", seconds: 30) { launcher.appLaunchTask != nil }
            quick.enabled = false; quick.configure()
            try await wait("disabled app launch drains", seconds: 60) { launcher.appLaunchTask == nil }
            try require(!launcher.launchedApps.values.contains { $0.device.serial == device.serial && $0.app.packageName == fixture.packageName }, "Disabled request opened a late independent app")
            observations["disabled_during_app_preparation"] = "No late Launch Services handoff"
            quick.enabled = true; quick.configure(); quick.open(host: host)
            try await wait("packaged specific-app handoff", seconds: 60) { launcher.launchedApps.values.contains { $0.device.serial == device.serial && $0.app.packageName == fixture.packageName } || launcher.appLaunchProgress?.message.contains("Couldn’t") == true }
            guard let launched = launcher.launchedApps.values.first(where: { $0.device.serial == device.serial && $0.app.packageName == fixture.packageName }) else { throw BridgeError.message(launcher.appLaunchProgress?.message ?? "No app handoff") }
            ownedApps.append(launched.application)
            try require(launched.process.bundleURL.resolvingSymlinksInPath().path.hasPrefix(scope.root.resolvingSymlinksInPath().path + "/"), "Specific app escaped isolated QA root")
            try await wait("specific app actual running video", seconds: 45) { launcher.launchedApps[launched.process.owner.pid]?.snapshot?.sessions.contains { $0.state == .running } == true }
            let pid = launched.process.owner.pid
            quick.open(host: host)
            try await Task.sleep(for: .seconds(2))
            try require(launcher.launchedApps.values.filter { $0.device.serial == device.serial && $0.app.packageName == fixture.packageName }.map { $0.process.owner.pid } == [pid], "Quick-open duplicated specific app")
            observations["specific_app"] = ["pid": pid, "bundle": launched.process.bundleURL.path, "actual_running_video": true, "same_pid_on_reopen": true]
            _ = launched.application.terminate()
            try await wait("owned wrapper quit", seconds: 20) { launched.application.isTerminated }

            // Both appearances at the real Settings minimum width; scroll layout.
            quick.target = .screen; quick.configure(); quick.saveSelection()
            launcher.showLauncherSettings()
            if let settings = launcher.settingsWindowController, let window = settings.window, let content = window.contentView {
                for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                    window.appearance = NSAppearance(named: appearance); window.setContentSize(NSSize(width: 610, height: 470))
                    _ = try capture(content, to: output.appendingPathComponent("settings-" + appearance.rawValue + ".png"))
                }
            }
            await launcher.shutdownAndWait()
            try await Task.sleep(for: .seconds(2))
            try require(try await adb(["forward", "--list"]) == initialForwards, "Leaked owned ADB forward")
            let finalDisplays = try await adb(["shell", "dumpsys", "display"])
            observations["display_counts"] = ["before_device_info_lines": initialDisplays.components(separatedBy: "DisplayDeviceInfo{").count - 1, "after_device_info_lines": finalDisplays.components(separatedBy: "DisplayDeviceInfo{").count - 1]
            try require(initialDisplays.components(separatedBy: "DisplayDeviceInfo{").count == finalDisplays.components(separatedBy: "DisplayDeviceInfo{").count, "Leaked virtual display")
            observations["cleanup"] = "No extra ADB forwards or displays; owned wrapper terminated"
            try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("runtime-results.json"))
            try JSONSerialization.data(withJSONObject: commands, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("android-commands.json"))
        } catch {
            for app in ownedApps where !app.isTerminated { _ = app.terminate() }
            for app in ownedApps { try? await wait("owned app failure cleanup", seconds: 20) { app.isTerminated } }
            await launcher.shutdownAndWait()
            try? JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("partial-results.json"))
            try? JSONSerialization.data(withJSONObject: commands, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("android-commands.json"))
            throw error
        }
    }
}
