import AppKit
import DroidBridgeCore

@MainActor final class QuickAccessController {
    enum Target: String, CaseIterable { case control, app, screen
        var title: String { switch self { case .control: return "DroidBridge control app"; case .app: return "Specific Android app"; case .screen: return "Current device screen" } }
    }
    private weak var launcher: LauncherController?
    private let hotKey = QuickAccessHotKey()
    private var editGeneration = UUID()
    private var pollTimer: Timer?
    private var connectedAdmission = false
    private var task: Task<Void, Never>?
    var message = ""
    var isOpening: Bool { task != nil }
    private(set) var preferences = QuickOpenPreferences()
    private var saveTask: Task<Void, Never>?
    var enabled: Bool { get { preferences.enabled } set { preferences.enabled = newValue; editGeneration = UUID() } }
    var target: Target { get { Target(rawValue: preferences.target) ?? .control } set { preferences.target = newValue.rawValue; editGeneration = UUID() } }
    var serial: String? { preferences.serial }
    var package: String? { preferences.package }
    var appName: String { preferences.appName ?? package ?? "No app chosen" }
    var deviceName: String { preferences.deviceName ?? serial ?? "No device chosen" }
    init(launcher: LauncherController) { self.launcher = launcher }
    func load() {
        let generation = editGeneration
        saveTask = Task { [weak self] in
            let loaded = await Task.detached { Result { try QuickOpenPreferences.load() } }.value
            guard let self, !Task.isCancelled, self.editGeneration == generation else { return }
            switch loaded {
            case .success(let value): self.preferences = value; self.configure(); self.launcher?.settingsWindowController?.refresh()
            case .failure: self.message = "Automatic opening settings couldn’t be read. Open Settings and save your choice again."
            }
        }
    }
    func persist() {
        guard launcher?.isWrapper == false else { return }
        preferences.hostBundlePath = Bundle.main.bundleURL.path
        let value = preferences
        let predecessor = saveTask
        saveTask = Task { [weak self] in
            await predecessor?.value
            guard !Task.isCancelled else { return }
            do {
                _ = try await Task.detached { try QuickOpenPreferences.update(recoveringInvalidFile: true) { $0 = value } }.value
                guard let self, !Task.isCancelled, self.launcher?.quitting == false else { return }
                if self.enabled, CompanionQAScope.current == nil, let launcher = self.launcher {
                    try await DeviceOnboardingAgent.ensureInstalled(hostBundleURL: Bundle.main.bundleURL, toolchain: launcher.toolchain, paths: launcher.managedCatalog.paths)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.message = "Couldn’t save automatic opening: \(String(error.localizedDescription.prefix(300))). Open Settings and retry."
                self.launcher?.settingsWindowController?.refresh()
            }
        }
    }
    func configure() {
        task?.cancel()
        pollTimer?.invalidate(); pollTimer = nil
        hotKey.disable()
        connectedAdmission = false
        guard enabled, launcher?.isWrapper == false else { message = "Automatic opening is off. Your saved choice is kept."; return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled, self.launcher?.timer != nil else { return }
                self.launcher?.refreshDevices()
            }
        }
        if let error = hotKey.enable(handler: { [weak self] in self?.open() }) { message = error }
        else if serial == nil { message = "Select a connected device in DroidBridge, then choose Use Selected Device." }
        else { message = "Opens once when the saved device connects and is ready. ⇧⌘D also opens it while DroidBridge is running." }
    }
    func saveSelection() {
        guard let launcher, !launcher.isWrapper, let device = launcher.selectedDevice else { message = "Select a connected device in DroidBridge first."; return }
        if target == .app {
            guard launcher.canLaunchSelectedApp, let app = launcher.selectedApp else { message = "Select an app in Apps, then choose it here."; return }
            preferences.package = app.packageName; preferences.appName = app.name
        }
        editGeneration = UUID()
        preferences.serial = device.serial; preferences.deviceName = device.model.replacingOccurrences(of: "_", with: " ")
        connectedAdmission = false
        persist()
        message = "Saved \(target == .app ? appName : target == .control ? "DroidBridge control app" : "current screen") on \(deviceName)."
    }
    /// A readiness interruption does not steal focus again; a missing/offline
    /// transport re-arms the next explicit connection interval.
    func observe(devices: [AndroidDevice], ready: Set<String>) {
        guard enabled, launcher?.isWrapper == false, let serial else { connectedAdmission = false; return }
        if let host = preferences.hostBundlePath, URL(fileURLWithPath: host).standardizedFileURL.path != Bundle.main.bundleURL.standardizedFileURL.path {
            message = "Automatic opening belongs to another copy of DroidBridge. Save your choice in this copy’s Settings to use it instead."
            launcher?.settingsWindowController?.refresh(); return
        }
        guard let device = devices.first(where: { $0.serial == serial }) else {
            connectedAdmission = false
            message = "Waiting for \(deviceName). Reconnect it to open your saved target."
            launcher?.settingsWindowController?.refresh(); return
        }
        guard device.state == "device" else {
            connectedAdmission = false
            message = device.state == "unauthorized" ? "Allow USB debugging on \(deviceName) to open your saved target." : "Waiting for \(deviceName) (\(device.state)). Reconnect it if needed."
            launcher?.settingsWindowController?.refresh(); return
        }
        guard !connectedAdmission else { return }
        guard ready.contains(serial) else {
            message = "Waiting for Android to finish starting on \(deviceName)."
            launcher?.settingsWindowController?.refresh(); return
        }
        guard task == nil else { return }
        connectedAdmission = true
        open()
    }
    private func showControl() {
        guard let launcher else { return }
        launcher.showWindow(nil); launcher.window?.deminiaturize(nil); launcher.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func fail(_ text: String) {
        message = text; showControl(); launcher?.status.stringValue = text
        launcher?.settingsWindowController?.refresh()
    }
    func open(host: URL = Bundle.main.bundleURL) {
        guard enabled, let launcher, !launcher.quitting, !launcher.isWrapper else { return }
        if target == .control { message = "DroidBridge control app brought to front."; showControl(); return }
        guard task == nil else { return }
        guard let serial else { fail("Choose a device for Quick Access in Settings → General."); return }
        let requestedTarget = target, requestedPackage = package, requestedName = appName
        let requestGeneration = editGeneration
        let expectedMirrorID = requestedTarget == .screen ? launcher.sessions.values.first(where: {
            $0.descriptor.device.serial == serial && $0.descriptor.configuration.mirrorDeviceScreen && ($0.state == .running || $0.state == .starting)
        })?.descriptor.id : nil
        task = Task { [weak self, weak launcher] in
            guard let self, let launcher else { return }
            defer { self.task = nil }
            do {
                try AndroidDiscovery.validateSerial(serial)
                let result = try await ProcessRunner.run(launcher.toolchain.adb, arguments: ["devices", "-l"], environment: launcher.toolchain.environment, timeout: 4)
                try Task.checkCancellation()
                guard self.editGeneration == requestGeneration, self.enabled, self.target == requestedTarget, self.serial == serial, !launcher.quitting else { return }
                guard let device = AndroidDiscovery.parseDevices(result.output).first(where: { $0.serial == serial }) else { self.fail("\(self.deviceName) is disconnected. Reconnect it, then choose Window → Quick Access to retry."); return }
                guard device.state == "device" else { self.fail(device.state == "unauthorized" ? "Allow USB debugging on \(self.deviceName), then choose Window → Quick Access to retry." : "\(self.deviceName) is \(device.state). Reconnect it, then choose Window → Quick Access to retry."); return }
                guard await DeviceReadiness.isReady(device: device, toolchain: launcher.toolchain) else { self.fail("\(self.deviceName) is still starting. Wait for Android, then choose Window → Quick Access to retry."); return }
                try Task.checkCancellation()
                guard self.editGeneration == requestGeneration, self.enabled, self.target == requestedTarget, self.serial == serial, !launcher.quitting else { return }
                if requestedTarget == .app {
                    guard let requestedPackage else { self.fail("Choose an Android app in Settings → General."); return }
                    try AndroidDiscovery.validatePackage(requestedPackage)
                    let apps = try await launcher.discovery.applications(device: device)
                    try Task.checkCancellation()
                    guard self.editGeneration == requestGeneration, self.enabled, self.target == requestedTarget, self.package == requestedPackage, self.serial == serial, !launcher.quitting else { return }
                    guard apps.contains(where: { $0.packageName == requestedPackage }) else { self.fail("\(requestedName) is no longer available on \(self.deviceName). Choose another app in Settings → General."); return }
                    guard launcher.appLaunchTask == nil else { self.fail("Another app is opening. Wait for it to finish, then choose Window → Quick Access to retry."); return }
                    launcher.openApp(device: device, app: AndroidApplication(packageName: requestedPackage, name: requestedName), backend: launcher.backend, host: host, admissionCheck: { [weak self] in
                        guard let self, self.editGeneration == requestGeneration, self.enabled, self.target == .app,
                              self.serial == serial, self.package == requestedPackage else { throw CancellationError() }
                    })
                } else {
                    if let expectedMirrorID, launcher.sessions[expectedMirrorID] == nil { return }
                    if let session = launcher.sessions.values.first(where: { $0.descriptor.device.serial == serial && $0.descriptor.configuration.mirrorDeviceScreen && ($0.state == .running || $0.state == .starting) }), let host = launcher.hosts[session.descriptor.id] {
                        host.showWindow(nil); host.window?.deminiaturize(nil); host.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
                    }
                    let config = SessionConfiguration(backend: .native, mirrorDeviceScreen: true)
                    NSApp.activate(ignoringOtherApps: true)
                    let session = await launcher.launch(device: device, app: AndroidApplication(packageName: "dev.droidbridge.screen", name: "\(self.deviceName) — Current Screen"), configuration: config, readinessChecked: true, admissionCheck: { [weak self] in
                        guard let self, self.editGeneration == requestGeneration, self.enabled, self.target == .screen, self.serial == serial else { throw CancellationError() }
                    })
                    guard !Task.isCancelled, self.editGeneration == requestGeneration, self.enabled, !launcher.quitting else { return }
                    if session?.state == .stopped || session?.state == .stopping { return }
                    if session == nil || session?.state == .failed { self.fail("Couldn’t open the device screen. Open Sessions for details, then choose Window → Quick Access to retry.") }

                }
            } catch is CancellationError { }
            catch { guard !Task.isCancelled, !launcher.quitting else { return }; self.fail("Quick Access couldn’t open: \(String(error.localizedDescription.prefix(300))). Choose Window → Quick Access to retry.") }
        }
    }
    func stop() { task?.cancel(); saveTask?.cancel(); pollTimer?.invalidate(); pollTimer = nil; hotKey.disable() }
    func stopAndWait() async {
        stop()
        await task?.value
        await saveTask?.value
    }
}
