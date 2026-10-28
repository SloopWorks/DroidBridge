import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

@MainActor
final class LauncherController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let toolchain = Toolchain()
    lazy var discovery = AndroidDiscovery(toolchain: toolchain)
    var devices: [AndroidDevice] = []
    var applications: [AndroidApplication] = []
    var filtered: [AndroidApplication] = []
    var sessions: [UUID: BridgeSession] = [:]
    var retiring: [UUID: BridgeSession] = [:]
    var hosts: [UUID: NativeWindowController] = [:]
    var sessionStates: [UUID: String] = [:]
    let devicePicker = NSPopUpButton()
    let backendPicker = NSPopUpButton()
    let search = NSSearchField()
    let table = NSTableView()
    let sessionList = NSStackView()
    let status = NSTextField(wrappingLabelWithString: "Looking for Android devices…")
    let reconnect = NSButton(checkboxWithTitle: "Reconnect interrupted sessions automatically", target: nil, action: nil)
    var timer: Timer?
    var refreshing = false
    var quitting = false
    var pending: [SessionDescriptor] = []
    var previousSerials = Set<String>()
    var readySerials = Set<String>()
    var reconnectRetries: [UUID: ReconnectRetry] = [:]
    var appsDeviceSerial: String?
    var isWrapper: Bool { Bundle.main.url(forResource: "launch", withExtension: "json") != nil || ProcessInfo.processInfo.arguments.contains("--wrapper") }
    var preferredSerial: String? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--serial"), arguments.indices.contains(index + 1) { return arguments[index + 1] }
        if let resource = Bundle.main.url(forResource: "launch", withExtension: "json"), let data = try? Data(contentsOf: resource), let options = try? JSONDecoder().decode([String: String].self, from: data) { return options["serial"] }
        return nil
    }
    var selectedDevice: AndroidDevice? { devices.indices.contains(devicePicker.indexOfSelectedItem) ? devices[devicePicker.indexOfSelectedItem] : nil }
    var selectedApp: AndroidApplication? { filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow] : nil }
    var backend: BackendKind { backendPicker.indexOfSelectedItem == 0 ? .native : .scrcpy }
    var persistenceURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DroidBridge")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(isWrapper ? "sessions-\(Bundle.main.bundleIdentifier ?? "wrapper").json" : "sessions.json")
    }
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 680), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DroidBridge"
        window.minSize = NSSize(width: 780, height: 540)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
        window.center()
        if let data = try? Data(contentsOf: persistenceURL), let descriptors = try? JSONDecoder().decode([SessionDescriptor].self, from: data) { pending = descriptors }

    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func button(_ title: String, _ action: Selector) -> NSButton { let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; return button }
    func buildUI() {
        let outer = NSStackView(); outer.orientation = .vertical; outer.alignment = .leading; outer.spacing = 16; outer.translatesAutoresizingMaskIntoConstraints = false
        window?.contentView?.addSubview(outer)
        NSLayoutConstraint.activate([outer.leadingAnchor.constraint(equalTo: window!.contentView!.leadingAnchor, constant: 24), outer.trailingAnchor.constraint(equalTo: window!.contentView!.trailingAnchor, constant: -24), outer.topAnchor.constraint(equalTo: window!.contentView!.topAnchor, constant: 24), outer.bottomAnchor.constraint(equalTo: window!.contentView!.bottomAnchor, constant: -20)])
        let title = NSTextField(labelWithString: "Android apps. Mac windows."); title.font = .systemFont(ofSize: 25, weight: .bold)
        outer.addArrangedSubview(title)
        let subtitle = NSTextField(labelWithString: "Connect a USB device with debugging enabled, or start an Android emulator."); subtitle.textColor = .secondaryLabelColor
        outer.addArrangedSubview(subtitle)
        devicePicker.target = self; devicePicker.action = #selector(deviceChanged)
        devicePicker.setAccessibilityLabel("Android device")
        backendPicker.addItems(withTitles: ["Native AppKit", "scrcpy fallback"]); backendPicker.setAccessibilityLabel("Rendering backend")
        let controls = NSStackView(views: [NSTextField(labelWithString: "Device"), devicePicker, button("Refresh", #selector(refreshAction)), NSTextField(labelWithString: "Backend"), backendPicker]); controls.spacing = 10; controls.alignment = .centerY
        outer.addArrangedSubview(controls)
        search.placeholderString = "Search apps or package names"; search.delegate = self; search.setAccessibilityLabel("Search Android apps")
        outer.addArrangedSubview(search); search.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); name.title = "Application"; name.width = 260
        let package = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("package")); package.title = "Android package"; package.width = 430
        table.addTableColumn(name); table.addTableColumn(package); table.rowHeight = 34; table.usesAlternatingRowBackgroundColors = true; table.delegate = self; table.dataSource = self; table.target = self; table.doubleAction = #selector(launchAction)
        table.setAccessibilityLabel("Installed Android applications")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        outer.addArrangedSubview(scroll); scroll.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true; scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let launch = button("Launch App", #selector(launchAction)); launch.keyEquivalent = "\r"
        let actions = NSStackView(views: [launch, button("Create Mac App…", #selector(createWrapper)), button("Restore Previous Sessions", #selector(restoreAction)), button("Open Diagnostics", #selector(openDiagnostics))]); actions.spacing = 10
        outer.addArrangedSubview(actions)
        reconnect.state = .on; outer.addArrangedSubview(reconnect)
        let heading = NSTextField(labelWithString: "SESSIONS"); heading.font = .systemFont(ofSize: 11, weight: .semibold); heading.textColor = .secondaryLabelColor; outer.addArrangedSubview(heading)
        sessionList.orientation = .vertical; sessionList.alignment = .leading; sessionList.spacing = 8
        let sessionScroll = NSScrollView(); sessionScroll.documentView = sessionList; sessionScroll.hasVerticalScroller = true; sessionScroll.borderType = .noBorder
        outer.addArrangedSubview(sessionScroll); sessionScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true; sessionScroll.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor; outer.addArrangedSubview(status); status.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        updateSessions()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let app = filtered[row]
        let value = tableColumn?.identifier.rawValue == "name" ? app.name : app.packageName
        let label = NSTextField(labelWithString: value); label.lineBreakMode = .byTruncatingMiddle
        if tableColumn?.identifier.rawValue == "package" { label.textColor = .secondaryLabelColor; label.font = .monospacedSystemFont(ofSize: 11, weight: .regular) }
        return label
    }
    func controlTextDidChange(_ obj: Notification) { filterApps() }
    func filterApps() {
        let query = search.stringValue.lowercased()
        filtered = applications.filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.packageName.lowercased().contains(query) }
        table.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    @objc func refreshAction() { refresh() }
    func beginPolling() {
        guard !quitting else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshDevices() } }
        refresh()
    }
    func refresh() { refreshDevices(forceApps: true) }
    func refreshDevices(forceApps: Bool = false) {
        guard !refreshing, !quitting else { return }; refreshing = true
        let selected = selectedDevice?.serial
        Task {
            defer { refreshing = false }
            do {
                let found = try await discovery.devices()
                guard !quitting else { return }
                let connected = Set(found.filter { $0.state == "device" }.map(\.serial))
                for session in Array(sessions.values) where !connected.contains(session.descriptor.device.serial) {
                    let id = session.descriptor.id
                    if sessionStates[id] != "disconnected" || previousSerials.contains(session.descriptor.device.serial) {
                        session.stop(); sessionStates[id] = "disconnected"; reconnectRetries[id] = ReconnectRetry()
                    }
                }
                let changed = found != devices
                devices = found
                if changed || devicePicker.numberOfItems == 0 {
                    devicePicker.removeAllItems()
                    devicePicker.addItems(withTitles: devices.map { "\($0.model) · \($0.serial)\($0.state == "device" ? "" : " (\($0.state))")" })
                    if let index = DeviceSelection.index(in: devices, currentSerial: selected, preferredSerial: preferredSerial) { devicePicker.selectItem(at: index) }
                    else { devicePicker.selectItem(at: -1) }
                }
                var probeSerials = Set(sessions.values.filter { sessionStates[$0.descriptor.id] == "disconnected" }.map { $0.descriptor.device.serial })
                if let serial = selectedDevice?.serial { probeSerials.insert(serial) }
                if let preferredSerial { probeSerials.insert(preferredSerial) }
                var ready = Set<String>()
                for device in found where probeSerials.contains(device.serial) && device.state == "device" {
                    if await DeviceReadiness.isReady(device: device, toolchain: toolchain) { ready.insert(device.serial) }
                }
                readySerials = ready
                if forceApps || changed || appsDeviceSerial != selectedDevice?.serial || selectedDevice.map({ !ready.contains($0.serial) }) == true { await loadApps(readinessChecked: true) }
                if devices.isEmpty { status.stringValue = "No Android device found. Check USB debugging, authorization, or start an emulator." }
                else if selectedDevice == nil, let preferredSerial { status.stringValue = "Waiting for requested Android device \(preferredSerial). Select another device to browse its apps." }
                if reconnect.state == .on {
                    for session in Array(sessions.values) where sessionStates[session.descriptor.id] == "disconnected" {
                        let descriptor = session.descriptor
                        var retry = reconnectRetries[descriptor.id] ?? ReconnectRetry()
                        guard retry.admits(intentPresent: sessions[descriptor.id] != nil, ready: ready.contains(descriptor.device.serial), enabled: reconnect.state == .on, now: Date()) else { continue }
                        close(descriptor.id)
                        if let successor = await launch(device: descriptor.device, app: descriptor.application, configuration: descriptor.configuration, readinessChecked: true), sessions[successor.descriptor.id] != nil, successor.state != .running {
                            retry.failed(at: Date())
                            reconnectRetries[successor.descriptor.id] = retry
                            sessionStates[successor.descriptor.id] = "disconnected"
                            status.stringValue = retry.failures == ReconnectRetry.maximumAttempts ? "Automatic reconnection paused after three failed launches. Close and launch the app to retry." : "Reconnection failed; retrying after at least eight seconds (\(retry.failures)/3)."
                        }
                    }
                }
                previousSerials = connected; updateSessions()
                await launchArgumentsIfNeeded()
            } catch { status.stringValue = error.localizedDescription }
        }
    }
    @objc func deviceChanged() { appsDeviceSerial = nil; Task { await loadApps() } }
    func loadApps(readinessChecked: Bool = false) async {
        guard let device = selectedDevice, device.state == "device" else { applications = []; appsDeviceSerial = nil; filterApps(); return }
        let ready = readinessChecked ? readySerials.contains(device.serial) : await DeviceReadiness.isReady(device: device, toolchain: toolchain)
        guard selectedDevice?.serial == device.serial, !quitting else { return }
        guard ready else { applications = []; appsDeviceSerial = nil; filterApps(); status.stringValue = "Waiting for Android to finish booting on \(device.model)…"; return }
        status.stringValue = "Reading apps from \(device.model)…"
        do { let found = try await discovery.applications(device: device); guard selectedDevice?.serial == device.serial else { return }; applications = found; appsDeviceSerial = device.serial; filterApps(); status.stringValue = "\(applications.count) launchable apps · \(device.serial) · Video remains on this Mac." }
        catch { guard selectedDevice?.serial == device.serial, !quitting else { return }; applications = []; appsDeviceSerial = nil; filterApps(); status.stringValue = error.localizedDescription }
    }
    @objc func launchAction() {
        guard let device = selectedDevice, let app = selectedApp else { status.stringValue = "Select a connected device and an app first."; return }
        Task { await launch(device: device, app: app, configuration: SessionConfiguration(backend: backend)) }
    }
    @discardableResult
    func launch(device: AndroidDevice, app: AndroidApplication, configuration: SessionConfiguration, readinessChecked: Bool = false) async -> BridgeSession? {
        guard !quitting else { return nil }
        if !readinessChecked, !(await DeviceReadiness.isReady(device: device, toolchain: toolchain)) { status.stringValue = "Android is still booting. The app can launch when package services are ready."; return nil }
        guard !quitting else { return nil }
        let descriptor = SessionDescriptor(device: device, application: app, configuration: configuration)
        let session = BridgeSession(descriptor: descriptor, toolchain: toolchain)
        sessions[descriptor.id] = session; sessionStates[descriptor.id] = "starting"
        if configuration.backend == .native {
            let host = NativeWindowController(session: session)
            host.onClose = { [weak self] in self?.close(descriptor.id) }
            hosts[descriptor.id] = host; host.showWindow(nil); host.window?.makeKeyAndOrderFront(nil)
        }
        session.onState = { [weak self] state, message in
            guard let self, self.sessions[descriptor.id] != nil else { return }
            if self.sessionStates[descriptor.id] == "disconnected" { return }
            self.sessionStates[descriptor.id] = state.rawValue
            if state == .failed || state == .stopped { self.hosts[descriptor.id]?.video.statusMessage = message ?? "Session ended. Close this window and launch again." }
            else { self.hosts[descriptor.id]?.video.statusMessage = nil }
            if let message { self.status.stringValue = message }
            if state == .failed && self.isWrapper { self.window?.makeKeyAndOrderFront(nil) }
            self.updateSessions()
            if state == .stopped && self.isWrapper {
                self.scheduleWrapperTermination()
            }
        }
        updateSessions(); save()
        do { try await session.start(); status.stringValue = "\(app.name) is running with \(configuration.backend == .native ? "native AppKit" : "scrcpy")." }
        catch { if sessions[descriptor.id] != nil { sessionStates[descriptor.id] = "failed"; status.stringValue = error.localizedDescription; updateSessions() } }
        return session
    }
    func close(_ id: UUID) {
        reconnectRetries.removeValue(forKey: id)
        let session = sessions.removeValue(forKey: id)
        if let host = hosts.removeValue(forKey: id) { host.onClose = nil; host.close() }
        if let session {
            session.stop(); retiring[id] = session
            Task { [weak self] in await session.stopAndWait(); self?.retiring.removeValue(forKey: id) }
        }
        sessionStates.removeValue(forKey: id); updateSessions(); if !quitting { save() }
        if isWrapper && sessions.isEmpty && !quitting { scheduleWrapperTermination() }
    }
    func scheduleWrapperTermination() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(terminateWrapperIfIdle), object: nil)
        // AppKit's terminateLater loop must run outside a draining main dispatch
        // block so the async shutdown continuation can execute on MainActor.
        perform(#selector(terminateWrapperIfIdle), with: nil, afterDelay: 3)
    }
    @objc func terminateWrapperIfIdle() {
        guard isWrapper, reconnectRetries.isEmpty, !sessionStates.values.contains("disconnected"), sessions.values.allSatisfy({ $0.state == .stopped }) else { return }
        NSApp.terminate(nil)
    }
    func updateSessions() {
        for view in sessionList.arrangedSubviews { sessionList.removeArrangedSubview(view); view.removeFromSuperview() }
        if sessions.isEmpty { sessionList.addArrangedSubview(NSTextField(labelWithString: "No running sessions. Select an app above and choose Launch App.")) }
        for (id, session) in sessions.sorted(by: { $0.value.descriptor.application.name < $1.value.descriptor.application.name }) {
            let descriptor = session.descriptor
            let label = NSTextField(labelWithString: "\(descriptor.application.name) · \(descriptor.configuration.backend.rawValue) · \(sessionStates[id] ?? "starting")")
            let focus = ClosureButton(title: "Focus") { [weak self] in self?.hosts[id]?.window?.makeKeyAndOrderFront(nil) }
            focus.isEnabled = hosts[id] != nil
            let close = ClosureButton(title: "Close") { [weak self] in self?.close(id) }
            let row = NSStackView(views: [label, focus, close]); row.spacing = 12; sessionList.addArrangedSubview(row)
        }
        sessionList.layoutSubtreeIfNeeded(); sessionList.setFrameSize(NSSize(width: 850, height: max(100, sessionList.fittingSize.height)))
    }
    func save() {
        let values = Array(sessions.values).map(\.descriptor)
        if let data = try? JSONEncoder().encode(values) { try? data.write(to: persistenceURL, options: .atomic) }
    }
    @objc func restoreAction() {
        let restore = pending; pending = []
        Task {
            for descriptor in restore {
                if let device = devices.first(where: { $0.serial == descriptor.device.serial && $0.state == "device" }), await DeviceReadiness.isReady(device: device, toolchain: toolchain) { await launch(device: device, app: descriptor.application, configuration: descriptor.configuration, readinessChecked: true) }
                else { pending.append(descriptor); status.stringValue = "Waiting for \(descriptor.device.model) to connect and finish booting before restoring \(descriptor.application.name)." }
            }
        }
    }
    @objc func openDiagnostics() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DroidBridge")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let report = "DroidBridge 0.1.0\nADB: \(toolchain.adb)\nscrcpy: \(toolchain.scrcpy)\nserver: \(toolchain.server)\nDevices: \(devices)\nSessions: \(sessionStates)\n"
        try? report.write(to: dir.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(dir)
    }
    @objc func createWrapper() {
        guard let device = selectedDevice, let app = selectedApp else { return }
        do { let url = try MacAppWrapper.create(application: app, device: device, backend: backend); status.stringValue = "Created \(url.path). Open it from Finder, add it to the Dock, or search in Spotlight."; NSWorkspace.shared.activateFileViewerSelecting([url]) }
        catch { status.stringValue = error.localizedDescription }
    }
    var processedArguments = false
    func launchArgumentsIfNeeded() async {
        guard !processedArguments else { return }
        var args = ProcessInfo.processInfo.arguments
        if let resource = Bundle.main.url(forResource: "launch", withExtension: "json"), let data = try? Data(contentsOf: resource), let options = try? JSONDecoder().decode([String: String].self, from: data) {
            args += ["--wrapper", "--launch", options["package"] ?? "", "--serial", options["serial"] ?? "", "--name", options["name"] ?? "", "--backend", options["backend"] ?? "native"]
        }
        func value(_ flag: String) -> String? { guard let i = args.firstIndex(of: flag), args.indices.contains(i+1) else { return nil }; return args[i+1] }
        guard let package = value("--launch") else { processedArguments = true; return }
        let serial = value("--serial")
        guard let device = devices.first(where: { $0.state == "device" && (serial == nil || $0.serial == serial) }), readySerials.contains(device.serial) else { return }
        processedArguments = true
        let app = applications.first(where: { $0.packageName == package }) ?? AndroidApplication(packageName: package, name: value("--name") ?? package)
        await launch(device: device, app: app, configuration: SessionConfiguration(backend: BackendKind(rawValue: value("--backend") ?? "native") ?? .native), readinessChecked: true)
        if args.contains("--wrapper"), sessions.values.contains(where: { $0.state == .running || $0.state == .starting }) { window?.orderOut(nil) }
    }
    func shutdownAndWait() async {
        quitting = true; save(); timer?.invalidate()
        let owned = Array(sessions.values) + Array(retiring.values)
        for session in owned { session.stop() }
        for session in owned { await session.stopAndWait() }
        retiring.removeAll()
    }
}

@MainActor
final class ClosureButton: NSButton {
    let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) { self.handler = handler; super.init(frame: .zero); self.title = title; bezelStyle = .rounded; target = self; action = #selector(clicked) }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    @objc func clicked() { handler() }
}
