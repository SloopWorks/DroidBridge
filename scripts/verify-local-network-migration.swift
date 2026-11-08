import AppKit
import DroidBridgeCore

/// Run the shipping retirement APIs against the user's already-owned backups.
/// This does not reserve/update current apps or change ADB or privacy settings.
@main struct VerifyLocalNetworkMigration {
    static func catalogOperation<T>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        for _ in 0..<50 {
            do { return try await Task.detached { try operation() }.value }
            catch ManagedAppCatalogError.busy { try await Task.sleep(for: .milliseconds(100)) }
        }
        throw ManagedAppCatalogError.busy
    }
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let catalog = ManagedAppCatalog(paths: .userDefault)
                var completed = 0
                for _ in 0..<200 {
                    let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL.map(WrapperBackup.canonicalPath) })
                    let batch = try await catalogOperation { try catalog.retireBackups(runningBundlePaths: running) }
                    for issue in batch.issues { print("PRESERVED: " + issue) }
                    guard !batch.retired.isEmpty else { break }
                    for backup in batch.retired {
                        try await WrapperBackup.unregister(backup)
                        try await catalogOperation { try catalog.completeBackupUnregistration(backup) }
                        completed += 1
                    }
                    print("Retired and unregistered \(completed) managed backups")
                }
                let home = FileManager.default.homeDirectoryForCurrentUser
                let discovery = WrapperBackup.legacyDirectories(manualRoot: home.appendingPathComponent("Applications/DroidBridge Apps"), cacheRoot: home.appendingPathComponent("Library/Application Support/DroidBridge/Launchers.noindex"))
                for issue in discovery.issues { print("PRESERVED: " + issue) }
                for directory in discovery.directories {
                    for _ in 0..<200 {
                        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL.map(WrapperBackup.canonicalPath) })
                        let batch = try await WrapperBackup.retireDirectory(directory, runningBundlePaths: running)
                        for issue in batch.issues { print("PRESERVED: " + issue) }
                        completed += batch.retired.count
                        if batch.retired.isEmpty { break }
                    }
                }
                print("PASS: \(completed) retained app backups migrated through production APIs; running apps preserved")
                exit(0)
            } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
}
