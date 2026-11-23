import AppKit
import Foundation
@testable import AnonymousUsage
import DroidBridgeCore
import DroidBridgeStreaming

/// Real packaged wrapper/native frames, real shared ledger and HTTP transport.
/// Foreground time is injected explicitly because the desktop can be locked.
@main struct VerifyTelemetryAppKit {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
        Task { @MainActor in
            do { try await run(); print("PASS: packaged wrappers, consent, native frames, anonymous wire, shared limits and withdrawal"); exit(0) }
            catch { fputs("FAIL: telemetry AppKit \(error)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }
    @MainActor static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw BridgeError.message(message) }
    }
    @MainActor static func wait(_ label: String, _ value: () -> Bool) async throws {
        for _ in 0..<600 { if value() { return }; try await Task.sleep(for: .milliseconds(100)) }
        throw BridgeError.message("Timed out: \(label)")
    }
    @MainActor static func run() async throws {
        guard let scope = CompanionQAScope.current, scope.serial == "emulator-5580",
              let evidence = ProcessInfo.processInfo.environment["DROIDBRIDGE_GUI_EVIDENCE"],
              let hostPath = ProcessInfo.processInfo.environment["DROIDBRIDGE_TELEMETRY_HOST"],
              let pidText = ProcessInfo.processInfo.environment["DROIDBRIDGE_TELEMETRY_MAIN_PID"], let mainPID = Int32(pidText),
              let portIndex = ProcessInfo.processInfo.arguments.firstIndex(of: "--usage-loopback-port"),
              let port = UInt16(ProcessInfo.processInfo.arguments[portIndex + 1]) else { throw BridgeError.message("Explicit owned verification arguments required") }
        let out = URL(fileURLWithPath: evidence), directory = scope.root.appendingPathComponent("AnonymousUsage")
        let ledgerURL = directory.appendingPathComponent("aggregate-v1.json")
        let host = URL(fileURLWithPath: hostPath), device = AndroidDevice(serial: scope.serial, model: "QA emulator")
        let app = AndroidApplication(packageName: "dev.droidbridge.testapp20261121", name: "Telemetry Native Fixture")
        DesktopUsage.shared.start(isWrapper: false)
        guard let owner = DesktopUsage.shared.meter else { throw BridgeError.message("QA meter not wired") }
        let launcher = LauncherController()
        launcher.onboardingPending = true; launcher.pending = []
        launcher.devices = [device]; launcher.devicePicker.removeAllItems(); launcher.devicePicker.addItem(withTitle: device.model); launcher.devicePicker.selectItem(at: 0)
        launcher.readySerials = [device.serial]; launcher.appsDeviceSerial = device.serial
        launcher.applications = [app]; launcher.filterApps(); launcher.backendPicker.selectItem(at: 0)
        var observations: [String: Any] = ["scope": scope.root.path, "foreground_is_injected_not_physical_focus": true, "production_endpoint_contacted": false]
        var owned: [NSRunningApplication] = []
        func ledger() -> [String: Any] { ((try? Data(contentsOf: ledgerURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any] ?? [:] }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func consent(_ enabled: Bool) async throws {
            launcher.showLauncherSettings()
            guard let window = launcher.settingsWindowController?.window,
                  let tabs = window.contentViewController as? NSTabViewController else { throw BridgeError.message("No shipping Settings tabs") }
            tabs.selectedTabViewItemIndex = 1
            window.contentView?.layoutSubtreeIfNeeded()
            guard let content = window.contentView,
                  let button = views(content).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Share local usage summary" }) else { throw BridgeError.message("No shipping usage consent checkbox") }
            try await wait("Settings consent readback") { button.isEnabled }
            if (button.state == .on) != enabled { button.performClick(nil) }
            try await wait("Settings consent persistence") { owner.consentEnabled == enabled }
            observations["shipping_settings_consent_action_verified"] = true
        }
        func open() async throws -> LaunchedDesktopApp {
            launcher.openApp(device: device, app: app, backend: .native, host: host)
            try await wait("wrapper native running") {
                launcher.launchedApps.values.contains { !$0.application.isTerminated && $0.device.serial == scope.serial && $0.app.packageName == app.packageName && $0.snapshot?.sessions.contains(where: { $0.state == .running }) == true }
            }
            guard let value = launcher.launchedApps.values.first(where: { !$0.application.isTerminated && $0.device.serial == scope.serial && $0.app.packageName == app.packageName && $0.snapshot?.sessions.contains(where: { $0.state == .running }) == true }) else { throw BridgeError.message("No exact native wrapper") }
            try require(value.process.bundleURL.resolvingSymlinksInPath().path.hasPrefix(scope.root.resolvingSymlinksInPath().path + "/"), "Wrapper escaped isolated scope")
            owned.append(value.application); return value
        }
        func close(_ value: LaunchedDesktopApp) async throws {
            _ = value.application.terminate()
            try await wait("owned wrapper exit") { value.application.isTerminated }
            try await wait("launch preparation complete") { launcher.appLaunchTask == nil }
        }
        do {
            let initial = try await open()
            try require(!FileManager.default.fileExists(atPath: directory.path), "Pre-consent usage was persisted")
            observations["pre_consent"] = "Actual decoded wrapper video produced no telemetry directory"
            try await close(initial)
            try await consent(true)
            try await wait("explicit opt-in persistence") { owner.consentEnabled }
            let second = try await open()
            try await wait("actual first presented native frame counted") { (ledger()["nativeSessions"] as? Int ?? 0) >= 1 }
            observations["native_wrapper_pid"] = second.process.owner.pid
            observations["native_frame_before_control_exit"] = ledger()["nativeSessions"]

            // Quit only the exact previously launched review control process.
            guard let main = NSRunningApplication(processIdentifier: mainPID),
                  main.bundleURL?.standardizedFileURL.path == host.standardizedFileURL.path else { throw BridgeError.message("Review main process identity mismatch") }
            _ = main.terminate(); try await wait("review control app quit") { main.isTerminated }
            try require(!second.application.isTerminated, "Control quit ended independent wrapper")
            observations["wrapper_survived_control_quit"] = true

            var today = Int(floor(Date().timeIntervalSince1970 / 86_400)), uptime = 0.0
            let timing = UsageMeter(directory: directory, transport: LoopbackUsageTransport(port: port), consentScope: "loopback-\(port)", canChangeConsent: false, day: { today }, uptime: { uptime })
            timing.setForeground(true); timing.settle()
            uptime = 60; timing.tick(); timing.settle()
            uptime = 120; timing.tick(); timing.settle()
            try require(ledger()["activeMinutes"] as? Int == 2, "Injected monotonic minutes did not aggregate")
            today += 1; timing.tick(); timing.settle()
            try require(!FileManager.default.fileExists(atPath: out.appendingPathComponent("wire-captures.json").path), "Sampling timer initiated delivery")
            timing.setForeground(false); timing.settle()
            try await wait("real anonymous HTTP request") { FileManager.default.fileExists(atPath: out.appendingPathComponent("wire-captures.json").path) }
            observations["injected_foreground_minutes"] = 2
            observations["daily_rollover_triggered_actual_http"] = true
            timing.sendPending(); timing.settle()
            try await Task.sleep(for: .milliseconds(300))
            let wire = try JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("wire-captures.json"))) as! [[String: Any]]
            try require(wire.count == 1, "Daily budget allowed more than one request")
            try require(Set((wire[0]["body"] as! [String: Any]).keys) == ["foreground_sessions", "active_minutes", "native_sessions"], "Wire contains unapproved data")
            observations["wire_requests_after_repeated_send"] = wire.count

            try await consent(false); try await wait("withdrawal persisted") { !owner.consentEnabled }
            try await close(second)
            let denied = try await open()
            try await Task.sleep(for: .milliseconds(300))
            try require(ledger()["scope"] == nil && (ledger()["nativeSessions"] as? Int ?? -1) == 0 && (ledger()["activeMinutes"] as? Int ?? -1) == 0, "Withdrawn wrapper collected new usage")
            observations["new_decoded_wrapper_after_withdrawal"] = "Shared counters remained empty and unauthorized"
            try await close(denied)
            try await consent(true); try await wait("consent reenabled") { owner.consentEnabled }
            let afterQuit = try await open()
            try await wait("wrapper records while review control is absent") { ledger()["nativeSessions"] as? Int == 1 }
            observations["new_native_frame_with_control_closed"] = true
            try await consent(false); try await wait("final withdrawal") { !owner.consentEnabled }
            try await close(afterQuit)
            DesktopUsage.shared.stop(); await launcher.shutdownAndWait()
            observations["ledger_mode"] = String((try FileManager.default.attributesOfItem(atPath: ledgerURL.path)[.posixPermissions] as! NSNumber).intValue, radix: 8)
            try require(observations["ledger_mode"] as? String == "600", "Aggregate file is not private")
            try JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("appkit-runtime-results.json"))
        } catch {
            for app in owned where !app.isTerminated { _ = app.terminate() }
            for app in owned { try? await wait("failure cleanup") { app.isTerminated } }
            owner.setConsent(false); DesktopUsage.shared.stop(); await launcher.shutdownAndWait()
            try? JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("appkit-partial-results.json"))
            throw error
        }
    }
}
