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
    var refreshTask: Task<Void, Never>?
    var refreshing = false
    var quitting = false
    var pending: [SessionDescriptor] = []
    var restoreTask: Task<Void,Never>?
    var previousSerials = Set<String>()
    var readySerials = Set<String>()
    var reconnectRetries: [UUID: ReconnectRetry] = [:]
    var appsDeviceSerial: String?
    var sessionErrors: [UUID: String] = [:]
    var iconData: [String: Data] = [:]
    var icons: [String: NSImage] = [:]
    var iconFailures: [String: String] = [:]
    var iconQueue: [(AndroidDevice, AndroidApplication)] = []
    var iconTasks: [String: Task<Void, Never>] = [:]
    var creatingWrapper = false
    var wrapperTask: Task<Void, Never>?
    var iconRecency: [String] = []
    var iconRecoveryMessages: [String] = []
    lazy var iconProvider = AndroidIconProvider(toolchain: toolchain)
    var sharedPreferences = (try? DroidBridgePreferences.load()) ?? DroidBridgePreferences(bulkWrapperOnboardingEnabled:false)
    let bulkPreference = NSButton(checkboxWithTitle:"Enable device apps in Spotlight",target:nil,action:nil)
    let phoneScreenPreference = NSButton(checkboxWithTitle:"Keep phone screen off during Mac sessions",target:nil,action:nil)
    lazy var phoneDisplayControls:PhoneDisplayControls = {
        let controls=PhoneDisplayControls(toolchain:toolchain)
        controls.onMessage={ [weak self] message in
            guard let self,!self.quitting else {return}
            self.status.stringValue=message;self.onboarding.recordMaintenanceMessage(message)
        }
        return controls
    }()
    let decorationsPreference = NSButton(checkboxWithTitle:"Show Android system decorations",target:nil,action:nil)
    let onboardingButton = NSButton(title:"Add All Device Apps to Spotlight",target:nil,action:nil)
    let onboardingCancel = NSButton(title:"Cancel",target:nil,action:nil)
    let onboardingProgress = NSProgressIndicator()
    let onboardingStatus = NSTextField(wrappingLabelWithString:"Ready to add all launchable apps from the selected device.")
    var onboardingAdmissionTask: Task<Void,Never>?
    var onboardingPending = false
    var managedNameRepair: ManagedAppNameRepair?
    lazy var managedCatalog = ManagedAppCatalog()
    lazy var availabilityMonitor = ManagedAvailabilityMonitor(toolchain:toolchain,catalog:managedCatalog)
    lazy var onboarding: DeviceOnboardingController = {
        let controller=DeviceOnboardingController(toolchain:toolchain,catalog:managedCatalog)
        controller.onProgress = { [weak self,weak controller] progress in
            guard let self else { return }
            self.onboardingProgress.maxValue=Double(max(1,progress.total)); self.onboardingProgress.doubleValue=Double(progress.completed)
            self.onboardingStatus.stringValue=String((progress.summary + (progress.active.isEmpty ? "" : " Working: " + progress.active.joined(separator:", "))).prefix(2000))
            self.onboardingStatus.toolTip=self.onboardingStatus.stringValue
            self.onboardingCancel.isEnabled=controller?.isRunning == true
            self.onboardingButton.isEnabled=self.bulkPreference.state == .on && controller?.isRunning != true
            if controller?.isRunning != true { self.pumpIcons() }
        }
        return controller
    }()
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
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DroidBridge"
        window.minSize = NSSize(width: 900, height: 720)
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
        let actions = NSStackView(views: [launch, button("Create / Update Mac App…", #selector(createWrapper)), button("Restore Previous Sessions", #selector(restoreAction)), button("Open Diagnostics", #selector(openDiagnostics))]); actions.spacing = 10
        outer.addArrangedSubview(actions)
        bulkPreference.state=sharedPreferences.bulkWrapperOnboardingEnabled ? .on : .off
        decorationsPreference.state=sharedPreferences.showAndroidSystemDecorations ? .on : .off
        for control in [bulkPreference,decorationsPreference] { control.target=self; control.action=#selector(sharedPreferenceChanged(_:)) }
        bulkPreference.setAccessibilityLabel("Enable device apps in Spotlight")
        decorationsPreference.toolTip="Controls Android virtual-display launcher and system navigation. App-drawn controls are unaffected."
        phoneScreenPreference.target=self;phoneScreenPreference.action=#selector(phoneScreenPreferenceChanged(_:));phoneScreenPreference.isEnabled=false
        phoneScreenPreference.toolTip="Opt in for this device. Applies only to its physical phone screen while Android apps run on this Mac. Use the Phone menu to turn the screen back on."
        outer.addArrangedSubview(phoneScreenPreference)
        let preferences=NSStackView(views:[bulkPreference,decorationsPreference]); preferences.spacing=14; outer.addArrangedSubview(preferences)
        onboardingButton.target=self; onboardingButton.action=#selector(onboardDeviceApps); onboardingButton.isEnabled=sharedPreferences.bulkWrapperOnboardingEnabled
        onboardingCancel.target=self; onboardingCancel.action=#selector(cancelOnboarding); onboardingCancel.isEnabled=false
        onboardingProgress.isIndeterminate=false; onboardingProgress.minValue=0; onboardingProgress.maxValue=1; onboardingProgress.widthAnchor.constraint(equalToConstant:150).isActive=true
        let onboardingControls=NSStackView(views:[onboardingButton,onboardingCancel,button("Onboarding Details",#selector(showOnboardingDetails)),onboardingProgress]); onboardingControls.spacing=10; outer.addArrangedSubview(onboardingControls)
        onboardingStatus.font = .systemFont(ofSize:11); onboardingStatus.textColor = .secondaryLabelColor; onboardingStatus.maximumNumberOfLines=3; onboardingStatus.lineBreakMode = .byTruncatingTail; outer.addArrangedSubview(onboardingStatus); onboardingStatus.widthAnchor.constraint(equalTo:outer.widthAnchor).isActive=true
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
        if tableColumn?.identifier.rawValue == "name" {
            let imageView = NSImageView(); imageView.imageScaling = .scaleProportionallyUpOrDown
            let label = NSTextField(labelWithString: app.name); label.lineBreakMode = .byTruncatingTail
            let key = selectedDevice.map { iconKey($0, app) }
            if let key, icons[key] != nil { touchIcon(key) }
            imageView.image = key.flatMap { icons[$0] } ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "Android icon loading or unavailable")
            if let device = selectedDevice { requestIcon(device, app) }
            let row = NSStackView(views: [imageView, label]); row.spacing = 8; row.alignment = .centerY
            imageView.widthAnchor.constraint(equalToConstant: 28).isActive = true; imageView.heightAnchor.constraint(equalToConstant: 28).isActive = true
            row.toolTip = key.flatMap { iconFailures[$0] }.map { "Android icon unavailable: " + $0 } ?? app.name
            return row
        }
        let label = NSTextField(labelWithString: app.packageName); label.lineBreakMode = .byTruncatingMiddle; label.textColor = .secondaryLabelColor; label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        return label
    }
    func iconKey(_ device: AndroidDevice, _ app: AndroidApplication) -> String { device.serial + ":" + app.packageName }
    func requestIcon(_ device: AndroidDevice, _ app: AndroidApplication) {
        let key = iconKey(device, app)
        guard icons[key] == nil, iconTasks[key] == nil, iconFailures[key] == nil, !iconQueue.contains(where: { iconKey($0.0, $0.1) == key }), iconQueue.count < 64, !quitting, !onboardingPending, !onboarding.isRunning else { return }
        iconQueue.append((device, app)); pumpIcons()
    }
    func pumpIcons() {
        while iconTasks.count < 2, !iconQueue.isEmpty, !quitting, !onboardingPending, !onboarding.isRunning {
            let (device, app) = iconQueue.removeFirst(), key = iconKey(device, app)
            iconTasks[key] = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.iconTasks.removeValue(forKey: key); self.pumpIcons()
                    if !self.quitting, self.selectedDevice?.serial == device.serial, let row = self.filtered.firstIndex(where: { $0.packageName == app.packageName }) { self.table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0)) }
                }
                do {
                    let data = try await self.iconProvider.icon(device: device, application: app)
                    guard !self.quitting, !Task.isCancelled, let image = NSImage(data: data) else { return }
                    self.iconData[key] = data; self.icons[key] = image; self.touchIcon(key)
                } catch { if !Task.isCancelled { self.iconFailures[key] = error.localizedDescription; self.touchIcon(key) } }

            }
        }
    }
    func touchIcon(_ key: String) {
        iconRecency.removeAll { $0 == key }; iconRecency.append(key)
        while iconRecency.count > 128 { let old = iconRecency.removeFirst(); icons.removeValue(forKey: old); iconData.removeValue(forKey: old); iconFailures.removeValue(forKey: old) }
    }
    func discardStaleIconRequests() {
        let prefix = (selectedDevice?.serial ?? "") + ":"
        iconQueue.removeAll { iconKey($0.0, $0.1).hasPrefix(prefix) == false }
        for (key, task) in iconTasks where !key.hasPrefix(prefix) { task.cancel() }
    }
    func controlTextDidChange(_ obj: Notification) { filterApps() }
    func filterApps() {
        let query = search.stringValue.lowercased()
        filtered = applications.filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.packageName.lowercased().contains(query) }
        table.reloadData()
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }
    @objc func refreshAction() { iconFailures.removeAll(); refresh() }
    func beginPolling() {
        guard !quitting else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollPhoneDisplayControls();self?.refreshDevices() } }
        refresh()
    }
    func refresh() { refreshDevices(forceApps: true) }
    func refreshDevices(forceApps: Bool = false) {
        guard !refreshing, !quitting else { return }; refreshing = true
        scheduleManagedNameRepair()
        sharedPreferences=(try? DroidBridgePreferences.load()) ?? DroidBridgePreferences(bulkWrapperOnboardingEnabled:false)
        bulkPreference.state=sharedPreferences.bulkWrapperOnboardingEnabled ? .on : .off
        decorationsPreference.state=sharedPreferences.showAndroidSystemDecorations ? .on : .off
        onboardingButton.isEnabled=sharedPreferences.bulkWrapperOnboardingEnabled && !onboardingPending && !onboarding.isRunning && managedNameRepair?.isRunning != true
        if !sharedPreferences.bulkWrapperOnboardingEnabled && onboarding.isRunning { onboarding.cancel() }
        let selected = selectedDevice?.serial
        refreshTask = Task {
            defer { refreshing = false; refreshTask = nil }
            do {
                let recovered = await AndroidIconProvider.recoverAbandonedRequests(toolchain: toolchain)
                if !recovered.isEmpty { iconRecoveryMessages = recovered }
                guard !quitting, !Task.isCancelled else { return }
                let found = try await discovery.devices()
                guard !quitting else { return }
                let connected = Set(found.filter { $0.state == "device" }.map(\.serial))
                if onboarding.isRunning, let captured=onboarding.capturedSerial, !connected.contains(captured) { onboarding.cancel() }
                for session in Array(sessions.values) where !connected.contains(session.descriptor.device.serial) {
                    let id = session.descriptor.id
                    if sessionStates[id] != "disconnected" || previousSerials.contains(session.descriptor.device.serial) {
                        session.stop(reason: "device_unavailable"); sessionStates[id] = "disconnected"; reconnectRetries[id] = ReconnectRetry()
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
                discardStaleIconRequests()
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
                        if let successor = await launch(device: descriptor.device, app: descriptor.application, configuration: descriptor.configuration, readinessChecked: true,replacing:descriptor.id,replacementReason:"reconnect_replacement"), !quitting, sessions[successor.descriptor.id] != nil, successor.state != .running {
                            retry.failed(at: Date())
                            reconnectRetries[successor.descriptor.id] = retry
                            sessionStates[successor.descriptor.id] = "disconnected"
                            status.stringValue = retry.failures == ReconnectRetry.maximumAttempts ? "Automatic reconnection paused after three failed launches. Close and launch the app to retry." : "Reconnection failed; retrying after at least eight seconds (\(retry.failures)/3)."
                        }
                    }
                }
                previousSerials = connected; updateSessions();pollPhoneDisplayControls()
                await launchArgumentsIfNeeded()
            } catch { status.stringValue = error.localizedDescription }
        }
    }
    @objc func deviceChanged() { pollPhoneDisplayControls();discardStaleIconRequests(); appsDeviceSerial = nil; Task { await loadApps() } }
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
        Task { await launch(device: device, app: app, configuration: SessionConfiguration(backend: backend,showSystemDecorations:(try? DroidBridgePreferences.load().showAndroidSystemDecorations) ?? true)) }
    }
    @discardableResult
    func launch(device: AndroidDevice, app: AndroidApplication, configuration: SessionConfiguration, readinessChecked: Bool = false,replacing:UUID? = nil,restoring:UUID? = nil,replacementReason:String = "session_replacement") async -> BridgeSession? {
        guard !quitting,!Task.isCancelled else { return nil }
        let predecessor=replacing.flatMap {sessions[$0]}
        if replacing != nil && predecessor == nil {return nil}
        if let restoring, !pending.contains(where:{$0.id==restoring}) {return nil}
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(terminateWrapperIfIdle), object: nil)
        if !readinessChecked, !(await DeviceReadiness.isReady(device: device, toolchain: toolchain)) { status.stringValue = "Android is still booting. The app can launch when package services are ready."; return nil }
        guard !quitting,!Task.isCancelled else { return nil }
        if Bundle.main.bundleIdentifier?.hasPrefix("app.droidbridge.managed.") == true {
            let bundleURL=Bundle.main.bundleURL, catalog=managedCatalog
            let allowed = await Task.detached { ((try? DroidBridgePreferences.load().bulkWrapperOnboardingEnabled) == true) && ((try? catalog.isLaunchAllowed(bundleURL:bundleURL,serial:device.serial,packageName:app.packageName)) == true) }.value
            guard allowed, !quitting,!Task.isCancelled else { status.stringValue="This managed app is disabled or its owning device is unavailable. Enable device apps in Spotlight and reconnect that device."; return nil }
        }
        // Admission is complete. Recheck ownership after every suspension before
        // replacing intent. Insert the successor first so persistence and idle
        // termination can never observe a destructive intermediate empty state.
        if let replacing, sessions[replacing] !== predecessor {return nil}
        if let restoring, !pending.contains(where:{$0.id==restoring}) {return nil}
        let descriptor = SessionDescriptor(device: device, application: app, configuration: configuration)
        let session = BridgeSession(descriptor: descriptor, toolchain: toolchain)
        sessions[descriptor.id] = session; sessionStates[descriptor.id] = "starting"
        if let restoring {pending.removeAll {$0.id==restoring}}
        if let replacing {close(replacing,reason:replacementReason)}
        if configuration.backend == .native {
            let host = NativeWindowController(session: session)
            host.onClose = { [weak self] in self?.close(descriptor.id, reason: "window_close") }
            hosts[descriptor.id] = host; host.showWindow(nil); host.window?.makeKeyAndOrderFront(nil)
        }
        session.onState = { [weak self, weak session] state, message in
            guard let self, let session, self.sessions[descriptor.id] != nil else { return }
            if self.sessionStates[descriptor.id] == "disconnected" { return }
            self.sessionStates[descriptor.id] = state.rawValue
            if state == .failed || state == .stopped { self.presentFailure(session, message: message) }
            else { self.hosts[descriptor.id]?.video.statusMessage = nil }
            if let message, state != .failed && state != .stopped { self.status.stringValue = message }
            if state == .running {self.pollPhoneDisplayControls()}
            if state == .running && self.isWrapper {
                if descriptor.configuration.backend == .scrcpy { NSApp.setActivationPolicy(.accessory) }
                else { self.presentNativeWrapper(session, reason: "first_frame") }
            }
            self.updateSessions()
        }
        updateSessions(); save()
        do { try await session.start(); status.stringValue = "\(app.name) is running with \(configuration.backend == .native ? "native AppKit" : "scrcpy")." }
        catch { if sessions[descriptor.id] != nil, sessionStates[descriptor.id] != "disconnected" { sessionStates[descriptor.id] = "failed"; if session.state != .failed || sessionErrors[descriptor.id] == nil { presentFailure(session, message: error.localizedDescription) }; updateSessions() } }
        return session
    }
    func presentNativeWrapper(_ session: BridgeSession, reason: String) {
        guard isWrapper, session.descriptor.configuration.backend == .native, let native = hosts[session.descriptor.id]?.window else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        native.deminiaturize(nil); native.makeKeyAndOrderFront(nil); native.orderFrontRegardless()
        session.recordClientEvent("native_window_presented", details: ["reason": reason, "visible": String(native.isVisible), "key": String(native.isKeyWindow), "minimized": String(native.isMiniaturized), "app_active": String(NSApp.isActive), "pid": String(getpid()), "bundle_id": Bundle.main.bundleIdentifier ?? "unknown"])
    }
    func hideLauncherIfUsable(_ session: BridgeSession?) {
        guard isWrapper, let session, session.state == .running else { return }
        if session.descriptor.configuration.backend == .native {
            guard hosts[session.descriptor.id]?.window?.isVisible == true else { return }
        }
        window?.orderOut(nil)
        session.recordClientEvent("launcher_hidden", details: ["native_window_visible": String(hosts[session.descriptor.id]?.window?.isVisible ?? false)])
    }
    func reopen() {
        if let session = sessions.values.first(where: { $0.descriptor.configuration.backend == .native && ($0.state == .running || $0.state == .starting) }), hosts[session.descriptor.id]?.window != nil {
            presentNativeWrapper(session, reason: "application_reopen")
            if !isWrapper { hosts[session.descriptor.id]?.window?.deminiaturize(nil); hosts[session.descriptor.id]?.window?.makeKeyAndOrderFront(nil) }
        } else {
            NSApp.setActivationPolicy(.regular); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            if Bundle.main.bundleIdentifier?.hasPrefix("app.droidbridge.managed.") == true, sessions.isEmpty, !argumentLaunchInFlight, !quitting {
                // A denied Spotlight click retains diagnostics. A later explicit
                // reopen retries the original immutable launch identity only.
                processedArguments=false
                refreshDevices(forceApps:true)
            }
        }
    }
    func presentFailure(_ session: BridgeSession, message: String?) {
        let id = session.descriptor.id
        let reason = message ?? "The Android stream ended without an error message. Its process and Android server output are in the session log."
        sessionErrors[id] = reason
        hosts[id]?.video.statusMessage = "Session ended.\nRetry or switch backend in the DroidBridge launcher."
        status.stringValue = "\(session.descriptor.application.name): \(reason.prefix(350)) Retry this session or try the other backend. Open its Log for details."
        if isWrapper { NSApp.setActivationPolicy(.regular); showWindow(nil); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    }
    func retry(_ id: UUID, backend: BackendKind? = nil) {
        guard let previous = sessions[id] else { return }
        Task {
            let descriptor = previous.descriptor
            guard await DeviceReadiness.isReady(device: descriptor.device, toolchain: toolchain) else { status.stringValue = "Android is unavailable or still booting. Connect the device, then Retry."; return }
            guard sessions[id] === previous, !quitting else { return }
            var configuration = descriptor.configuration
            if let backend { configuration.backend = backend }
            let successor = await launch(device: descriptor.device, app: descriptor.application, configuration: configuration, readinessChecked: true,replacing:id,replacementReason:"retry_replacement")
            hideLauncherIfUsable(successor)
        }
    }
    func close(_ id: UUID, reason: String = "close_control") {
        sessionErrors.removeValue(forKey: id)
        reconnectRetries.removeValue(forKey: id)
        let session = sessions.removeValue(forKey: id)
        session?.recordClientEvent("session_close", details: ["reason": reason])
        if let host = hosts.removeValue(forKey: id) { host.onClose = nil; host.close() }
        if let session {
            session.stop(reason: reason); retiring[id] = session
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
        guard isWrapper, sessions.isEmpty, !quitting else { return }
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
            var controls: [NSView] = [label, focus]
            if session.state == .failed || session.state == .stopped {
                controls += [ClosureButton(title: "Retry") { [weak self] in self?.retry(id) }, ClosureButton(title: descriptor.configuration.backend == .native ? "Try scrcpy" : "Try Native") { [weak self] in self?.retry(id, backend: descriptor.configuration.backend == .native ? .scrcpy : .native) }]
            }
            controls += [ClosureButton(title: "Log") { NSWorkspace.shared.open(session.logURL) }, close]
            let row = NSStackView(views: controls); row.spacing = 10; row.toolTip = sessionErrors[id]; sessionList.addArrangedSubview(row)
        }
        sessionList.layoutSubtreeIfNeeded(); sessionList.setFrameSize(NSSize(width: 850, height: max(100, sessionList.fittingSize.height)))
    }
    func save() {
        var intents=Dictionary(pending.map {($0.id,$0)},uniquingKeysWith:{first,_ in first})
        for session in sessions.values {intents[session.descriptor.id]=session.descriptor}
        let values=intents.values.sorted {$0.id.uuidString<$1.id.uuidString}
        if let data = try? JSONEncoder().encode(values) { try? data.write(to: persistenceURL, options: .atomic) }
    }
    @objc func restoreAction() {
        guard restoreTask == nil,!quitting else {return}
        let restore=pending
        restoreTask=Task {
            defer {restoreTask=nil}
            for descriptor in restore {
                guard !quitting,!Task.isCancelled else {break}
                if let device = devices.first(where: { $0.serial == descriptor.device.serial && $0.state == "device" }), await DeviceReadiness.isReady(device: device, toolchain: toolchain) {
                    guard !quitting,!Task.isCancelled else {break}
                    _ = await launch(device:device,app:descriptor.application,configuration:descriptor.configuration,readinessChecked:true,restoring:descriptor.id)
                } else if !quitting,!Task.isCancelled {status.stringValue = "Waiting for \(descriptor.device.model) to connect and finish booting before restoring \(descriptor.application.name)."}
            }
        }
    }
    @objc func openDiagnostics() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DroidBridge")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let report = "DroidBridge \(version)\nBundle: \(Bundle.main.bundleIdentifier ?? "unbundled")\nPID: \(getpid())\nADB: \(toolchain.adb)\nscrcpy: \(toolchain.scrcpy)\nserver: \(toolchain.server)\nDevices: \(devices)\nSessions: \(sessionStates)\nIcon recovery: \(iconRecoveryMessages)\n"
        try? report.write(to: dir.appendingPathComponent("diagnostics.txt"), atomically: true, encoding: .utf8)
        NSWorkspace.shared.open(dir)
    }
    @objc func createWrapper() {
        guard let device = selectedDevice, let app = selectedApp, !creatingWrapper else { return }
        guard managedNameRepair?.isRunning != true,!onboardingPending,!onboarding.isRunning else {status.stringValue="Wait for the current Mac app update to finish.";return}
        let chosenBackend = backend
        creatingWrapper = true; status.stringValue = "Loading Android icon and building \(app.name)'s Mac app…"
        wrapperTask = Task {
            defer { creatingWrapper = false; wrapperTask = nil }
            do {
                let lease=try DeviceOnboardingLease(root:managedCatalog.paths.privateRoot)
                defer {lease.release()}
                let png: Data
                if let cached = iconData[iconKey(device, app)] { png = cached }
                else { png = try await iconProvider.icon(device: device, application: app) }
                guard !quitting, !Task.isCancelled else { return }
                let url = try await MacAppWrapper.create(application: app, device: device, backend: chosenBackend, iconPNG: png)
                status.stringValue = "Created or updated \(url.path). Existing launch settings are preserved; the previous generation is retained under .DroidBridge Backups."
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch { status.stringValue = "Mac app was not changed: " + error.localizedDescription }
        }
    }
    var processedArguments = false
    var argumentLaunchInFlight = false
    func launchArgumentsIfNeeded() async {
        guard !processedArguments, !argumentLaunchInFlight, !quitting else { return }
        argumentLaunchInFlight=true; defer { argumentLaunchInFlight=false }
        var args = ProcessInfo.processInfo.arguments
        if let resource = Bundle.main.url(forResource: "launch", withExtension: "json"), let data = try? Data(contentsOf: resource), let options = try? JSONDecoder().decode([String: String].self, from: data) {
            args += ["--wrapper", "--launch", options["package"] ?? "", "--serial", options["serial"] ?? "", "--name", options["name"] ?? "", "--backend", options["backend"] ?? "native"]
        }
        func value(_ flag: String) -> String? { guard let i = args.firstIndex(of: flag), args.indices.contains(i+1) else { return nil }; return args[i+1] }
        guard let package = value("--launch") else { processedArguments = true; return }
        if Bundle.main.bundleIdentifier?.hasPrefix("app.droidbridge.managed.") == true {
            let catalog=managedCatalog,bundleURL=Bundle.main.bundleURL,serial=value("--serial") ?? ""
            let permitted = await Task.detached { ((try? DroidBridgePreferences.load().bulkWrapperOnboardingEnabled) == true) && ((try? catalog.isLaunchAllowed(bundleURL:bundleURL,serial:serial,packageName:package)) == true) }.value
            guard !quitting else { return }
            guard permitted else { processedArguments=true; status.stringValue="This managed Android app is unavailable or device apps in Spotlight are disabled. Connect its authorized device and enable the feature in DroidBridge."; return }
        }
        let serial = value("--serial")
        guard let device = devices.first(where: { $0.state == "device" && (serial == nil || $0.serial == serial) }), readySerials.contains(device.serial) else { return }
        processedArguments = true
        let app = applications.first(where: { $0.packageName == package }) ?? AndroidApplication(packageName: package, name: value("--name") ?? package)
        let launched = await launch(device: device, app: app, configuration: SessionConfiguration(backend: BackendKind(rawValue: value("--backend") ?? "native") ?? .native,showSystemDecorations:(try? DroidBridgePreferences.load().showAndroidSystemDecorations) ?? true), readinessChecked: true)
        hideLauncherIfUsable(launched)
    }
    func shutdownAndWait() async {
        quitting = true; phoneDisplayControls.cancel(); managedNameRepair?.cancel(); restoreTask?.cancel(); onboardingAdmissionTask?.cancel(); onboarding.cancel()
        for session in Array(sessions.values)+Array(retiring.values) {session.stop(reason:"application_quit")}
        if let task=onboardingAdmissionTask { await task.value }
        await onboarding.cancelAndWait()
        await managedNameRepair?.cancelAndWait()
        await phoneDisplayControls.cancelAndWait()
        save(); timer?.invalidate(); iconQueue.removeAll(); for task in iconTasks.values { task.cancel() }
        refreshTask?.cancel()
        wrapperTask?.cancel()
        for session in Array(sessions.values) + Array(retiring.values) { session.stop(reason: "application_quit") }
        let pendingIcons = Array(iconTasks.values)
        for task in pendingIcons { await task.value }
        if let task = wrapperTask { await task.value }
        if let task = refreshTask { await task.value }
        if let task = restoreTask {await task.value}
        let owned = Array(sessions.values) + Array(retiring.values)
        for session in owned { session.stop(reason: "application_quit") }
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
