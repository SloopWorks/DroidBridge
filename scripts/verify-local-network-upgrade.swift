import AppKit
import DroidBridgeCore

/// Drive bounded production maintenance batches without waiting between them.
/// Each batch retains its normal catalog leases, running guards and signatures.
@main struct VerifyLocalNetworkUpgrade {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let host = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/DroidBridge.app")
                let catalog = ManagedAppCatalog(paths: .userDefault)
                let tools = Toolchain(adb: host.appendingPathComponent("Contents/Resources/Runtime/bin/adb").path)
                for index in 0..<240 {
                    let remaining = try await Task.detached {
                        try catalog.records().filter { $0.sourceBuild != "23" && FileManager.default.fileExists(atPath: $0.bundleURL.path) }.count
                    }.value
                    guard remaining > 0 else { print("PASS: every existing catalog wrapper upgraded to build23 through production maintenance"); exit(0) }
                    print("Batch \(index + 1): \(remaining) wrappers remain")
                    let repair = ManagedAppNameRepair(toolchain: tools, catalog: catalog, hostBundleURL: host)
                    repair.onDetail = { print("DETAIL: " + $0) }
                    repair.schedule()
                    while repair.isRunning { try await Task.sleep(for: .milliseconds(100)) }
                    try await Task.sleep(for: .milliseconds(200))
                }
                throw BridgeError.message("Existing wrapper migration did not finish within its batch bound")
            } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
}
