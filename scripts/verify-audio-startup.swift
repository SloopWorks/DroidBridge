import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

@MainActor private final class StartupAudioRouter: DeviceAudioRouting {
    var onStatusChange: ((String, DeviceAudioStatus) -> Void)?
    var current = DeviceAudioStatus(route: .mac, phase: .failed, message: "Previous capture failed")
    var active = Set<String>()
    var retries = [String]()
    func reconcile(activeSerials: Set<String>, connectedSerials: Set<String>, routes: [String: DeviceAudioRoute]) { active = activeSerials }
    func retry(serial: String) { retries.append(serial) }
    func status(for serial: String) -> DeviceAudioStatus { current }
    func shutdown() async {}
}

@main struct VerifyAudioStartup {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); print("PASS: new-session audio retry, retained failure latch, live independent windows, Phone preference and ready-owner preservation"); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw BridgeError.message(message) }
    }
    @MainActor static func run() async throws {
        guard CompanionQAScope.current != nil else { throw BridgeError.message("Private QA scope required") }
        let serial = "emulator-5580"
        let router = StartupAudioRouter()
        var routes: [String: DeviceAudioRoute] = [serial: .mac]
        var unreadable = false
        let controls = AudioControls(router: router, loadRoutes: {
            if unreadable { throw BridgeError.message("Preference read failed") }
            return routes
        }, saveRoute: { serial, route in routes[serial] = route })
        controls.reconcile(activeSerials: [serial], connectedSerials: [serial])
        controls.sessionStarted(serial: serial)
        try require(router.retries == [serial], "New app launch failed to retry the saved Mac route")
        controls.reconcile(activeSerials: [serial], connectedSerials: [serial])
        try require(router.retries.count == 1, "Periodic refresh retried a latched failure")
        router.current = .init(route: .mac, phase: .ready, message: "Initialized")
        controls.sessionStarted(serial: serial)
        router.current = .init(route: .mac, phase: .shared, message: "Another host owns audio")
        controls.sessionStarted(serial: serial)
        router.current = .init(route: .mac, phase: .starting, message: "Connecting")
        controls.sessionStarted(serial: serial)
        try require(router.retries.count == 1, "Opening another app interrupted established or starting audio")
        try controls.setRoute(.phone, serial: serial)
        router.current = .init(route: .phone, phase: .phone, message: "Phone")
        controls.sessionStarted(serial: serial)
        try require(router.retries.count == 1 && routes[serial] == .phone, "New session overrode Phone intent")
        try controls.setRoute(.mac, serial: serial)
        controls.reconcile(activeSerials: [], connectedSerials: [])
        controls.sessionStarted(serial: serial)
        unreadable = true
        controls.reconcile(activeSerials: [serial], connectedSerials: [serial])
        controls.sessionStarted(serial: serial)
        try require(router.retries.count == 1, "Disconnected device or unreadable preferences admitted retry")
        unreadable = false

        let launcher = LauncherController(audioControls: controls)
        launcher.onboardingPending = true
        defer { launcher.window?.orderOut(nil) }
        launcher.readySerials = [serial]
        let device = AndroidDevice(serial: serial, model: "QA Audio")
        let app = AndroidApplication(packageName: "dev.droidbridge.testapp", name: "QA tone")
        guard let owner = CompanionBrokerOwner.live(getpid()) else { throw BridgeError.message("Missing own process") }
        let process = DesktopAppProcess(owner: owner, bundleURL: Bundle.main.bundleURL, bundleIdentifier: "app.droidbridge.audio-startup.fixture")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(process))
        func snapshot(age: TimeInterval, state: String) throws -> DesktopAppSessionSnapshot {
            let data = try JSONSerialization.data(withJSONObject: ["process": encoded, "generation": UUID().uuidString,
                "serial": serial, "packageName": app.packageName, "backend": "native",
                "sessions": [["id": UUID().uuidString, "name": app.name, "state": state, "backend": "native"]],
                "updatedAt": Date().addingTimeInterval(-age).timeIntervalSinceReferenceDate])
            return try JSONDecoder().decode(DesktopAppSessionSnapshot.self, from: data)
        }
        launcher.launchedApps[owner.pid] = .init(application: .current, process: process, device: device, app: app, backend: .native,
            snapshot: try snapshot(age: 0, state: "running"))
        launcher.pollAudioControls()
        try require(router.active == [serial], "Unpaired independent app window was absent from audio state")
        launcher.launchedApps[owner.pid]?.snapshot = try snapshot(age: 31, state: "running")
        launcher.pollAudioControls()
        try require(router.active.isEmpty, "Stale independent snapshot kept capture alive")
        launcher.launchedApps[owner.pid]?.snapshot = try snapshot(age: 0, state: "failed")
        launcher.pollAudioControls()
        try require(router.active.isEmpty, "Failed independent app admitted audio")
        await launcher.shutdownAndWait()
    }
}
