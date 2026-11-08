import AppKit
import DroidBridgeCore

/// Prepare a real production wrapper without starting it from a terminal.
/// Open the printed path using computer control, then inspect decoded video.
@main struct PrepareLocalNetworkGUI {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let args = CommandLine.arguments
                guard args.count == 4 else { throw BridgeError.message("Expected host.app, private output directory and Android icon PNG") }
                let host = URL(fileURLWithPath: args[1]), root = URL(fileURLWithPath: args[2])
                guard !host.path.contains("/.build/"), root.path.hasPrefix("/private/tmp/droidbridge-network-gui-") else { throw BridgeError.message("External artifact and dedicated GUI scope required") }
                let result = try await MacAppWrapper.create(application: .init(packageName: "dev.droidbridge.testapp7", name: "DroidBridge Test"),
                    device: .init(serial: "emulator-5580", model: "Dedicated QA AVD"), backend: .native,
                    iconPNG: Data(contentsOf: URL(fileURLWithPath: args[3])), hostBundleURL: host, destinationRoot: root)
                print(result.path); exit(0)
            } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
}
