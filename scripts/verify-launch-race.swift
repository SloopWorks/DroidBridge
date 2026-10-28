import AppKit
import Foundation
import DroidBridgeCore
import DroidBridgeStreaming

/// No-device regression: exact shipping launcher and view/controller sources,
/// delayed fake ADB, and a retained interrupted intent before start completes.
@main struct LaunchRaceVerification {
    @MainActor static func main() {
        let app=NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); print("PASS: late cancelled launch preserved disconnected intent"); exit(0) }
            catch { fputs("FAIL: \(error)\n",stderr); exit(1) }
        }
        app.run()
    }
    @MainActor static func run() async throws {
        let marker=URL(fileURLWithPath:ProcessInfo.processInfo.environment["DROIDBRIDGE_QA_MARKER"]!)
        let launcher=LauncherController()
        let device=AndroidDevice(serial:"qa-no-device",model:"Synthetic delayed ADB")
        let app=AndroidApplication(packageName:"dev.droidbridge.testapp",name:"Lifecycle regression")
        let startup=Task { @MainActor in await launcher.launch(device:device,app:app,configuration:SessionConfiguration(backend:.native)) }
        for _ in 0..<200 { if FileManager.default.fileExists(atPath:marker.path) { break }; try await Task.sleep(nanoseconds:10_000_000) }
        guard FileManager.default.fileExists(atPath:marker.path), let (id,session)=launcher.sessions.first, session.state == .starting else { throw BridgeError.message("Did not reach delayed startup boundary") }
        // Exact ordering used by the disconnected-device polling branch.
        session.stop(); launcher.sessionStates[id]="disconnected"
        _ = await startup.value
        guard launcher.sessions[id] === session, launcher.sessionStates[id] == "disconnected" else { throw BridgeError.message("Late launch catch overwrote retained interrupted intent with \(launcher.sessionStates[id] ?? "missing")") }
        guard session.state == .stopped else { throw BridgeError.message("Cancelled startup did not settle stopped") }
        launcher.close(id)
        await launcher.shutdownAndWait()
        launcher.window?.close()
    }
}
