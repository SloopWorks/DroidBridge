import AppKit
import DroidBridgeCore

/// Runs shipping AppKit code with --wrapper and an owned QA root. No device,
/// broker, clipboard, catalog migration or process admission is started.
@main struct LazyWrapperVerification {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
        Task { @MainActor in
            do {
                guard CompanionQAScope.current != nil, ProcessInfo.processInfo.arguments.contains("--wrapper") else { throw BridgeError.message("An explicit isolated wrapper scope is required") }
                let controller = LauncherController()
                guard controller.launcherUI == nil else { throw BridgeError.message("A wrapper eagerly built the hidden launcher") }
                guard controller.prepareWrapperLaunch(), controller.launchPreview?.window?.isVisible == true, controller.launcherUI == nil else { throw BridgeError.message("The local wrapper preview did not precede launcher UI construction") }
                guard controller.reconnect.state == .on else { throw BridgeError.message("Deferred UI changed the reconnect default") }
                controller.showWindow(nil)
                guard let originalUI = controller.launcherUI, controller.window?.isVisible == true, controller.devicePicker.accessibilityLabel() == "Android device" else { throw BridgeError.message("Explicit Window → Launcher did not build a functional launcher") }
                controller.reconnect.state = .off
                controller.showWindow(nil)
                guard controller.launcherUI === originalUI, controller.reconnect.state == .off else { throw BridgeError.message("Reopening rebuilt the launcher or reset user controls") }
                controller.launchPreview?.onClose = nil
                controller.launchPreview?.close(); controller.window?.orderOut(nil)
                let result: [String: Any] = ["passed": true, "scope": "Shipping AppKit with explicit wrapper and private QA flags; no ADB or broker started", "launcher_ui_deferred_before_preview": true, "local_preview_visible": true, "explicit_launcher_builds_once": true, "reconnect_default_preserved": true, "reopen_preserves_control_state": true, "cold_launch_target_verified": false]
                let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("verification/companion/macos-ui/lazy-wrapper.json")
                try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url)
                print("PASS: real deferred wrapper preview and explicit launcher lifecycle")
                fflush(stdout); exit(0)
            } catch { fputs("FAIL: lazy wrapper \(error)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }
}
