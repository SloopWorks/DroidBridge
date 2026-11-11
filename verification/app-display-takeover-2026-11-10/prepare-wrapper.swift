import AppKit
import DroidBridgeCore

/// Make unique test identities with the shipping factory so computer control
/// cannot confuse these windows with the owner's running DroidBridge apps.
@main struct PrepareDisplayMoveWrappers {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                guard let scope = CompanionQAScope.current, scope.serial == "emulator-5580",
                      scope.root.path.hasPrefix("/private/tmp/droidbridge-display-wrappers-"),
                      CommandLine.arguments.count == 7 else { throw BridgeError.message("Expected external app, icon, and the dedicated QA scope") }
                let host = URL(fileURLWithPath: CommandLine.arguments[1])
                guard !host.path.contains("/.build/") else { throw BridgeError.message("Use an external packaged app") }
                let icon = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
                for backend: BackendKind in [.native, .scrcpy] {
                    let wrapper = try await MacAppWrapper.createOnDemand(
                        application: .init(packageName: "dev.droidbridge.testapp7", name: "Display Move Probe (\(backend.rawValue))"),
                        device: .init(serial: scope.serial, model: "DroidBridge API35"), backend: backend,
                        iconPNG: icon, hostBundleURL: host, destinationRoot: scope.root.appendingPathComponent(backend.rawValue))
                    print(wrapper.path)
                }
                exit(0)
            } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
}
