import AppKit
import DroidBridgeCore

@MainActor struct LaunchedDesktopApp {
    let application: NSRunningApplication
    let process: DesktopAppProcess
    let device: AndroidDevice
    let app: AndroidApplication
    let backend: BackendKind
    var snapshot: DesktopAppSessionSnapshot?
    var statusUnavailable = false
    let observedAt = Date()

    var phase: String {
        if statusUnavailable { return "Status unavailable — open app" }
        guard let sessions = snapshot?.sessions, !sessions.isEmpty else { return "Connecting in app window" }
        if sessions.contains(where: { $0.state == .recovering }) { return "Waiting to reconnect" }
        if sessions.contains(where: { $0.state == .failed }) { return "Needs attention — open app" }
        if sessions.contains(where: { $0.state == .running }) { return "Running" }
        if sessions.contains(where: { $0.state == .starting }) { return "Starting" }
        if sessions.contains(where: { $0.state == .stopped }) { return "Session ended — open app" }
        return "Connecting in app window"
    }
    var presentation: String {
        "\(process.owner.pid):\(process.owner.start):\(phase):" + (snapshot?.sessions.map { "\($0.id):\($0.state):\($0.backend?.rawValue ?? "")" }.joined(separator: ",") ?? "")
    }
    var actualBackend: BackendKind { snapshot?.sessions.first(where: { $0.state == .running })?.backend ?? snapshot?.sessions.first?.backend ?? backend }
}

extension LauncherController {
    var visibleLaunchedApps: [LaunchedDesktopApp] {
        let aliases = selectedDevice.map { Set(companion.device(for: $0.serial)?.aliases ?? [$0.serial]) }
        return launchedApps.values.filter { !$0.application.isTerminated && (aliases?.contains($0.device.serial) ?? true) }
            .sorted { $0.app.name.localizedStandardCompare($1.app.name) == .orderedAscending }
    }
    var launchedSessionIDs: Set<String> {
        Set(launchedApps.values.flatMap { $0.snapshot?.sessions.map { $0.id.uuidString.lowercased() } ?? [] })
    }

    func trackAppLaunch(_ application: NSRunningApplication, owner: CompanionBrokerOwner, device: AndroidDevice, app: AndroidApplication, backend: BackendKind) {
        guard let url = application.bundleURL, let identifier = application.bundleIdentifier else { return }
        let process = DesktopAppProcess(owner: owner, bundleURL: url.standardizedFileURL, bundleIdentifier: identifier)
        if launchedApps[owner.pid]?.process != process {
            launchedApps[owner.pid] = LaunchedDesktopApp(application: application, process: process, device: device, app: app, backend: backend)
        }
        startAppSessionMonitoring()
        pollLaunchedApps(); updateSessions()
    }

    func startAppSessionMonitoring() {
        guard !isWrapper else { return }
        if appSessionTimer == nil {
            appSessionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.pollLaunchedApps() }
            }
        }
        pollLaunchedApps()
    }

    func pollLaunchedApps() {
        guard !quitting, appSessionPollTask == nil else { return }
        let oldCount = launchedApps.count
        launchedApps = launchedApps.filter { !$0.value.application.isTerminated && $0.value.process.owner.isAlive }
        if oldCount != launchedApps.count { updateSessions() }
        // After management-app restart, only live AppKit identities supply PIDs.
        // Registry files are presentation, never launch or process authority.
        let live = NSWorkspace.shared.runningApplications.filter { application in
            guard application.processIdentifier != getpid(), let identifier = application.bundleIdentifier else { return false }
            return ["app.droidbridge.launcher.", "app.droidbridge.managed.", "app.droidbridge.wrapper."].contains(where: identifier.hasPrefix)
        }.prefix(256)
        var observed: [Int32: NSRunningApplication] = [:]
        var expected = launchedApps.values.map(\.process)
        for application in live {
            guard let url = application.bundleURL, let identifier = application.bundleIdentifier,
                  let owner = CompanionBrokerOwner.live(application.processIdentifier) else { continue }
            observed[owner.pid] = application
            let process = DesktopAppProcess(owner: owner, bundleURL: url.standardizedFileURL, bundleIdentifier: identifier)
            if !expected.contains(process) { expected.append(process) }
        }
        let store = desktopAppSessionStore
        guard !expected.isEmpty else { return }
        appSessionPollTask = Task { [weak self] in
            guard let self else { return }
            defer { self.appSessionPollTask = nil }
            let read = Task.detached {
                var snapshots: [DesktopAppSessionSnapshot] = []
                for process in expected {
                    try Task.checkCancellation()
                    if let snapshot = try? store.read(expected: process) { snapshots.append(snapshot) }
                }
                return snapshots
            }
            let snapshots = (try? await withTaskCancellationHandler(operation: { try await read.value }, onCancel: { read.cancel() })) ?? []
            guard !self.quitting, !Task.isCancelled else { return }
            var changed = false
            let fresh = snapshots.filter { Date().timeIntervalSince($0.updatedAt) < 30 }
            for (pid, var tracked) in self.launchedApps {
                if !fresh.contains(where: { $0.process == tracked.process }),
                   tracked.snapshot != nil || (!tracked.statusUnavailable && Date().timeIntervalSince(tracked.observedAt) >= 30) {
                    tracked.snapshot = nil; tracked.statusUnavailable = true
                    self.launchedApps[pid] = tracked; changed = true
                }
            }
            for snapshot in fresh {
                let pid = snapshot.process.owner.pid
                if self.launchedApps[pid] == nil, let application = observed[pid], self.isOwnedAppSnapshot(snapshot) {
                    let name = snapshot.sessions.first?.name ?? snapshot.packageName
                    self.launchedApps[pid] = LaunchedDesktopApp(application: application, process: snapshot.process,
                        device: AndroidDevice(serial: snapshot.serial, model: self.devices.first(where: { $0.serial == snapshot.serial })?.model ?? snapshot.serial),
                        app: AndroidApplication(packageName: snapshot.packageName, name: name), backend: snapshot.backend)
                    changed = true
                }
                guard var tracked = self.launchedApps[pid], tracked.process == snapshot.process,
                      snapshot.serial == tracked.device.serial, snapshot.packageName == tracked.app.packageName,
                      snapshot.backend == tracked.backend else { continue }
                let previous = tracked.presentation
                tracked.snapshot = snapshot; tracked.statusUnavailable = false; self.launchedApps[pid] = tracked
                changed = changed || tracked.presentation != previous
            }
            if changed {
                self.updateSessions()
                self.companion.windowController?.refreshLocalSessions()
            }
        }
    }

    private func isOwnedAppSnapshot(_ snapshot: DesktopAppSessionSnapshot) -> Bool {
        let url = snapshot.process.bundleURL, identifier = snapshot.process.bundleIdentifier
        let app = AndroidApplication(packageName: snapshot.packageName, name: snapshot.packageName)
        let device = AndroidDevice(serial: snapshot.serial, model: snapshot.serial)
        if identifier == MacAppWrapper.onDemandIdentifier(device: device, application: app, backend: snapshot.backend) {
            return url.deletingLastPathComponent().standardizedFileURL.path == AppLaunchResolver.directory(device: device, app: app, backend: snapshot.backend).standardizedFileURL.path
        }
        let manual = CompanionQAScope.current?.root.appendingPathComponent("ManualApps") ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/DroidBridge Apps")
        if identifier == "app.droidbridge.wrapper." + snapshot.packageName { return url.deletingLastPathComponent().standardizedFileURL.path == manual.standardizedFileURL.path }
        if identifier == ManagedAppCatalog.bundleIdentifier(serial: snapshot.serial, packageName: snapshot.packageName) {
            return [managedCatalog.paths.activeRoot, managedCatalog.paths.privateRoot].contains { url.path.hasPrefix($0.standardizedFileURL.path + "/") }
        }
        return false
    }

    func focusLaunchedApp(_ pid: Int32) {
        guard let tracked = launchedApps[pid], tracked.process.owner.isAlive, !tracked.application.isTerminated,
              tracked.application.bundleURL?.standardizedFileURL.path == tracked.process.bundleURL.path,
              tracked.application.bundleIdentifier == tracked.process.bundleIdentifier else { return }
        guard !runningAppLaunches().contains(where: { $0.identifier == tracked.process.bundleIdentifier && $0.url.standardizedFileURL.path != tracked.process.bundleURL.path }) else {
            status.stringValue = "Another copy of \(tracked.app.name) is running. Quit that copy before reopening this app."
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        if let scope = CompanionQAScope.current { configuration.arguments = ["--companion-qa-root", scope.root.path, "--serial", tracked.device.serial] }
        Task {
            do {
                let opened = try await NSWorkspace.shared.openApplication(at: tracked.process.bundleURL, configuration: configuration)
                guard opened.bundleURL?.standardizedFileURL.path == tracked.process.bundleURL.path, opened.bundleIdentifier == tracked.process.bundleIdentifier else {
                    status.stringValue = "macOS opened a different copy of \(tracked.app.name)."
                    return
                }
            }
            catch { status.stringValue = "Couldn’t focus \(tracked.app.name): \(error.localizedDescription)" }
        }
    }
    func closeLaunchedApp(_ pid: Int32) {
        guard let tracked = launchedApps[pid], tracked.process.owner.isAlive, !tracked.application.isTerminated,
              tracked.application.bundleURL?.standardizedFileURL.path == tracked.process.bundleURL.path,
              tracked.application.bundleIdentifier == tracked.process.bundleIdentifier else { return }
        _ = tracked.application.terminate()
    }

    /// The local snapshot is presentation only, independent of companion pairing.
    /// Serialize/coalesce writes so late state callbacks cannot reorder them.
    func publishWrapperSessions() {
        guard isWrapper, !quitting, Bundle.main.bundleURL.pathExtension == "app" else { return }
        wrapperSessionDirty = true
        guard wrapperSessionTask == nil else { return }
        wrapperSessionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.wrapperSessionTask = nil }
            while self.wrapperSessionDirty, !self.quitting {
                self.wrapperSessionDirty = false
                let options = self.launchOptions()
                guard let serial = options["serial"], let package = options["package"],
                      let identifier = Bundle.main.bundleIdentifier, let owner = CompanionBrokerOwner.live(getpid()) else { return }
                let process = DesktopAppProcess(owner: owner, bundleURL: Bundle.main.bundleURL.standardizedFileURL, bundleIdentifier: identifier)
                let backend = BackendKind(rawValue: options["backend"] ?? "native") ?? .native
                let rows = self.sessions.values.filter { $0.descriptor.device.serial == serial && $0.descriptor.application.packageName == package }.prefix(32).map { session in
                    let state = self.sessionStates[session.descriptor.id] == "disconnected" ? DesktopAppSession.State.recovering : (DesktopAppSession.State(rawValue: session.state.rawValue) ?? .failed)
                    let name = String(session.descriptor.application.name.filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(128))
                    return DesktopAppSession(id: session.descriptor.id, name: name.isEmpty ? String(package.prefix(128)) : name, state: state, backend: session.descriptor.configuration.backend)
                }
                let producer = self.wrapperSessionProducer, store = self.desktopAppSessionStore
                do {
                    let published = try await Task.detached {
                        let current = try producer ?? store.begin(process: process, serial: serial, packageName: package, backend: backend)
                        _ = try store.publish(current, sessions: rows)
                        return current
                    }.value
                    self.wrapperSessionProducer = published
                } catch { return } // Optional presentation must never gate video.
            }
        }
    }
}
