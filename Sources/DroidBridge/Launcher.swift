import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

@MainActor
final class LauncherController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let toolchain = Toolchain()
    lazy var companion = CompanionDesktopAdapter(launcher: self)
    lazy var discovery = AndroidDiscovery(toolchain: toolchain)
    var devices: [AndroidDevice] = []
    var applications: [AndroidApplication] = []
    var filtered: [AndroidApplication] = []
    var sessions: [UUID: BridgeSession] = [:]
    var retiring: [UUID: BridgeSession] = [:]
    var hosts: [UUID: NativeWindowController] = [:]
    var sessionStates: [UUID: String] = [:]
    lazy var devicePicker = NSPopUpButton()
    lazy var backendPicker = NSPopUpButton()
    lazy var search = NSSearchField()
    lazy var table = LauncherAppTable()
    lazy var sessionList = NSStackView()
    lazy var status = LauncherStatusField(wrappingLabelWithString: "Looking for Android devices…")
    var launcherUI: LauncherUI?
    lazy var reconnect: NSButton = {
        let button = NSButton(checkboxWithTitle: "Reconnect interrupted sessions automatically", target: nil, action: nil)
        button.state = .on
        return button
    }()
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
    var loadingAppsSerial: String?
    var appsLoadToken=UUID()
    var appsError:(serial:String,message:String)?
    var deviceSelectionTask:Task<Void,Never>?
    var deviceSelectionTasks:[UUID:Task<Void,Never>]=[:]
    var sessionPresentation:[LauncherSessionPresentation]?
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
    lazy var sharedPreferences = (try? DroidBridgePreferences.load()) ?? DroidBridgePreferences(bulkWrapperOnboardingEnabled:false)
    lazy var bulkPreference = NSButton(checkboxWithTitle:"Enable device apps in Spotlight",target:nil,action:nil)
    lazy var phoneScreenPreference = NSButton(checkboxWithTitle:"Keep phone screen off during Mac sessions",target:nil,action:nil)
    lazy var audioRoutePicker = NSPopUpButton()
    lazy var audioStatus = NSTextField(wrappingLabelWithString:"Mac audio starts when an app is running.")
    lazy var audioRetry = NSButton(title:"Retry Audio",target:nil,action:nil)
    lazy var audioUsePhone = NSButton(title:"Use Phone",target:nil,action:nil)
    lazy var audioControls: AudioControls = {
        let controls = AudioControls(toolchain: toolchain)
        controls.onChange = { [weak self] _ in self?.updateAudioPresentation() }
        return controls
    }()
    lazy var phoneDisplayControls:PhoneDisplayControls = {
        let controls=PhoneDisplayControls(toolchain:toolchain)
        controls.onMessage={ [weak self] message in
            guard let self,!self.quitting else {return}
            self.status.stringValue=message;self.onboarding.recordMaintenanceMessage(message)
        }
        return controls
    }()
    lazy var decorationsPreference = NSButton(checkboxWithTitle:"Show Android system decorations",target:nil,action:nil)
    lazy var onboardingButton = NSButton(title:"Add All Device Apps to Spotlight",target:nil,action:nil)
    lazy var onboardingCancel = NSButton(title:"Cancel",target:nil,action:nil)
    lazy var onboardingProgress = NSProgressIndicator()
    lazy var onboardingStatus = NSTextField(wrappingLabelWithString:"Ready to add all launchable apps from the selected device.")
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
            self.updateLauncherPresentation()
        }
        return controller
    }()
    var isWrapper: Bool { Bundle.main.url(forResource: "launch", withExtension: "json") != nil || ProcessInfo.processInfo.arguments.contains("--wrapper") }
    var launchPreview: NativeWindowController?
    var wrapperLaunchCancelled = false
    func launchOptions() -> [String:String] {
        var options: [String:String] = [:]
        if let resource = Bundle.main.url(forResource:"launch",withExtension:"json"),
           let data = try? Data(contentsOf:resource), data.count <= 16384,
           let saved = try? JSONDecoder().decode([String:String].self,from:data) { options = saved }
        let args = ProcessInfo.processInfo.arguments
        for (flag,key) in [("--launch","package"),("--serial","serial"),("--name","name"),("--backend","backend")] {
            if let i=args.firstIndex(of:flag),args.indices.contains(i+1) { options[key]=args[i+1] }
        }
        return options
    }
    /// Local bundle metadata only: show before recovery, ADB or app enumeration.
    @discardableResult func prepareWrapperLaunch() -> Bool {
        guard isWrapper, let package=launchOptions()["package"] else {return false}
        guard launchPreview == nil, !wrapperLaunchCancelled else {return true}
        CompanionLaunchTrace.record("wrapper_preview_begin")
        let options=launchOptions()
        let app=AndroidApplication(packageName:package,name:options["name"] ?? package)
        let config=SessionConfiguration(backend:BackendKind(rawValue:options["backend"] ?? "native") ?? .native)
        let icon=Bundle.main.url(forResource:"AndroidApp",withExtension:"icns").flatMap {NSImage(contentsOf:$0)}
        let preview=NativeWindowController(deviceSerial:options["serial"] ?? "",application:app,configuration:config,icon:icon)
        preview.video.loadingMessage="Connecting to your Android device…"
        preview.onClose={ [weak self] in
            guard let self else {return}
            self.wrapperLaunchCancelled=true;self.processedArguments=true;self.launchPreview=nil
            self.scheduleWrapperTermination()
        }
        launchPreview=preview
        preview.showWindow(nil);preview.window?.makeKeyAndOrderFront(nil)
        window?.orderOut(nil)
        CompanionLaunchTrace.record("wrapper_preview_visible")
        return true
    }
    func showLaunchProblem(_ message:String) {
        status.stringValue=message
        launchPreview?.video.statusMessage=message + "\nConnect the device, or open Window → Launcher."
    }
    var preferredSerial: String? {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--serial"), arguments.indices.contains(index + 1) { return arguments[index + 1] }
        if let resource = Bundle.main.url(forResource: "launch", withExtension: "json"), let data = try? Data(contentsOf: resource), let options = try? JSONDecoder().decode([String: String].self, from: data) { return options["serial"] }
        return nil
    }
    var selectedDevice: AndroidDevice? {
        if isWrapper, !launcherUIReady {
            if let preferredSerial { return devices.first { $0.serial == preferredSerial } }
            return devices.first
        }
        return devices.indices.contains(devicePicker.indexOfSelectedItem) ? devices[devicePicker.indexOfSelectedItem] : nil
    }
    var selectedApp: AndroidApplication? { filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow] : nil }
    var backend: BackendKind { backendPicker.indexOfSelectedItem == 0 ? .native : .scrcpy }
    var persistenceURL: URL {
        if let scope = CompanionQAScope.current { return scope.sessionsURL }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DroidBridge")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(isWrapper ? "sessions-\(Bundle.main.bundleIdentifier ?? "wrapper").json" : "sessions.json")
    }
    private var launcherUIReady = false
    private static func makeLauncherWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DroidBridge"
        window.contentMinSize = NSSize(width: 920, height: 640)
        window.titlebarSeparatorStyle = .line
        window.isReleasedWhenClosed = false
        return window
    }
    init(audioControls providedAudioControls: AudioControls? = nil) {
        CompanionLaunchTrace.record("launcher_init_begin")
        let wrapper = Bundle.main.url(forResource: "launch", withExtension: "json") != nil || ProcessInfo.processInfo.arguments.contains("--wrapper")
        super.init(window: wrapper ? nil : Self.makeLauncherWindow())
        if let providedAudioControls {
            audioControls = providedAudioControls
            audioControls.onChange = { [weak self] _ in self?.updateAudioPresentation() }
        }
        if !wrapper { prepareLauncherUIIfNeeded() }
        CompanionLaunchTrace.record("launcher_init_ready")
    }
    private func prepareLauncherUIIfNeeded() {
        guard !launcherUIReady else { return }
        launcherUIReady = true
        if window == nil { window = Self.makeLauncherWindow() }
        CompanionLaunchTrace.record("launcher_ui_begin")
        buildUI()
        if !devices.isEmpty {
            devicePicker.removeAllItems()
            devicePicker.addItems(withTitles: devices.map { "\($0.model) · \($0.serial)\($0.state == "device" ? "" : " (\($0.state))")" })
            if let index = DeviceSelection.index(in: devices, currentSerial: nil, preferredSerial: preferredSerial) { devicePicker.selectItem(at: index) }
            else { devicePicker.selectItem(at: -1) }
        }
        window?.center()
        if sessions.isEmpty, let data = try? Data(contentsOf: persistenceURL), let descriptors = try? JSONDecoder().decode([SessionDescriptor].self, from: data) { pending = descriptors }
        updateLauncherPresentation()
        CompanionLaunchTrace.record("launcher_ui_ready")
    }
    override func showWindow(_ sender: Any?) {
        prepareLauncherUIIfNeeded()
        super.showWindow(sender)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func button(_ title: String, _ action: Selector) -> NSButton { let button = NSButton(title: title, target: self, action: action); button.bezelStyle = .rounded; return button }
    func buildUI() {
        launcherUI=LauncherUI(controller:self)
        launcherUI?.build()
        status.onChange={ [weak self] in self?.updateLauncherPresentation() }
        updateSessions()
    }
    func updateLauncherPresentation() {guard let launcherUI else { return };launcherUI.refresh();updateAudioPresentation()}
    func tableViewSelectionDidChange(_ notification:Notification) {updateLauncherPresentation()}
    var canLaunchSelectedApp:Bool {
        guard let device=selectedDevice else {return false}
        return !quitting && device.state == "device" && readySerials.contains(device.serial) && appsDeviceSerial == device.serial && selectedApp != nil
    }
    var canOnboardSelectedDevice:Bool {
        guard let device=selectedDevice else {return false}
        return !quitting && device.state == "device" && readySerials.contains(device.serial) && appsDeviceSerial == device.serial && !applications.isEmpty && sharedPreferences.bulkWrapperOnboardingEnabled && !onboardingPending && !onboarding.isRunning && managedNameRepair?.isRunning != true
    }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
        guard control === search,selector == #selector(NSResponder.insertNewline(_:)) else {return false}
        if canLaunchSelectedApp {launchAction()} else {NSSound.beep()}
        return true
    }
    @objc func focusAppSearch() {showWindow(nil);window?.makeKeyAndOrderFront(nil);window?.makeFirstResponder(search);refreshDevices(forceApps:true)}
    @objc func clearAppSearch() {search.stringValue="";filterApps();window?.makeFirstResponder(search)}
    @objc func showLauncherSettings() {showWindow(nil);window?.makeKeyAndOrderFront(nil);backendPicker.scrollToVisible(backendPicker.bounds);window?.makeFirstResponder(backendPicker);refreshDevices(forceApps:true)}
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filtered.indices.contains(row) else {return nil}
        let app=filtered[row]
        if tableColumn?.identifier.rawValue == "name" {
            let identifier=NSUserInterfaceItemIdentifier("launcher.app-cell")
            let cell=(tableView.makeView(withIdentifier:identifier,owner:nil) as? LauncherAppCell) ?? LauncherAppCell()
            cell.identifier=identifier
            let key=selectedDevice.map {iconKey($0,app)}
            if let key,icons[key] != nil {touchIcon(key)}
            cell.configure(name:app.name,icon:key.flatMap {icons[$0]},hint:key.flatMap {iconFailures[$0]})
            if let device=selectedDevice {requestIcon(device,app)}
            return cell
        }
        let identifier=NSUserInterfaceItemIdentifier("launcher.package-cell")
        let cell=(tableView.makeView(withIdentifier:identifier,owner:nil) as? LauncherPackageCell) ?? LauncherPackageCell()
        cell.identifier=identifier;cell.label.stringValue=app.packageName;cell.toolTip=app.packageName
        return cell
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
                    if !self.quitting, self.selectedDevice?.serial == device.serial, let row = self.filtered.firstIndex(where: { $0.packageName == app.packageName }) { self.table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0));self.updateLauncherPresentation() }
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
        let previousPackage=selectedApp?.packageName
        let query = search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        filtered = applications.filter { query.isEmpty || $0.name.lowercased().contains(query) || $0.packageName.lowercased().contains(query) }
        table.reloadData()
        if !filtered.isEmpty {table.selectRowIndexes(IndexSet(integer:filtered.firstIndex(where:{$0.packageName==previousPackage}) ?? 0),byExtendingSelection:false)}
        else {table.deselectAll(nil)}
        updateLauncherPresentation()
    }
    @objc func refreshAction() { iconFailures.removeAll(); refresh() }
    func beginPolling() {
        guard !quitting else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in Task { @MainActor in self?.pollPhoneDisplayControls();self?.pollAudioControls();self?.refreshDevices() } }
        refresh()
    }
    func refresh() { refreshDevices(forceApps: true) }
    func refreshDevices(forceApps: Bool = false) {
        guard !refreshing, !quitting else { return }; refreshing = true
        if CompanionQAScope.current == nil { scheduleManagedNameRepair() }
        sharedPreferences=(try? DroidBridgePreferences.load()) ?? DroidBridgePreferences(bulkWrapperOnboardingEnabled:false)
        if launcherUIReady {
            bulkPreference.state=sharedPreferences.bulkWrapperOnboardingEnabled ? .on : .off
            decorationsPreference.state=sharedPreferences.showAndroidSystemDecorations ? .on : .off
            onboardingButton.isEnabled=sharedPreferences.bulkWrapperOnboardingEnabled && !onboardingPending && !onboarding.isRunning && managedNameRepair?.isRunning != true
            if !sharedPreferences.bulkWrapperOnboardingEnabled && onboarding.isRunning { onboarding.cancel() }
        }
        let selected = selectedDevice?.serial
        refreshTask = Task {
            defer { refreshing = false; refreshTask = nil;updateLauncherPresentation() }
            do {
                let recovered = isWrapper || CompanionQAScope.current != nil ? [] : await AndroidIconProvider.recoverAbandonedRequests(toolchain: toolchain)
                if !recovered.isEmpty { iconRecoveryMessages = recovered }
                guard !quitting, !Task.isCancelled else { return }
                let discovered = try await discovery.devices()
                let found = CompanionQAScope.current?.filterDevices(discovered) ?? discovered
                guard !quitting else { return }
                let connected = Set(found.filter { $0.state == "device" }.map(\.serial))
                if launcherUIReady, onboarding.isRunning, let captured=onboarding.capturedSerial, !connected.contains(captured) { onboarding.cancel() }
                for session in Array(sessions.values) where !connected.contains(session.descriptor.device.serial) {
                    let id = session.descriptor.id
                    if sessionStates[id] != "disconnected" || previousSerials.contains(session.descriptor.device.serial) {
                        session.stop(reason: "device_unavailable"); sessionStates[id] = "disconnected"; reconnectRetries[id] = ReconnectRetry()
                    }
                }
                let changed = found != devices
                devices = found
                if launcherUIReady && (changed || devicePicker.numberOfItems == 0) {
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
                pollAudioControls()
                // A wrapper already knows its package/name/icon. Never wait for the
                // full catalog (or fetch every app icon) to launch that identity.
                if (!isWrapper || window?.isVisible == true), forceApps || changed || appsDeviceSerial != selectedDevice?.serial || selectedDevice.map({ !ready.contains($0.serial) }) == true { await loadApps(readinessChecked: true) }
                if devices.isEmpty { showLaunchProblem("No Android device found. Check USB debugging, authorization, or start an emulator.") }
                else if selectedDevice == nil, let preferredSerial { showLaunchProblem("Waiting for requested Android device \(preferredSerial).") }
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
                previousSerials = connected; updateSessions();pollPhoneDisplayControls();pollAudioControls()
                await launchArgumentsIfNeeded()
            } catch { showLaunchProblem(error.localizedDescription) }
        }
    }
    @objc func deviceChanged() {
        deviceSelectionTask?.cancel();pollPhoneDisplayControls();pollAudioControls();discardStaleIconRequests()
        appsDeviceSerial=nil;appsLoadToken=UUID();loadingAppsSerial=nil;appsError=nil;applications=[];filterApps()
        let id=UUID()
        let task=Task { [weak self] in
            guard let self else {return}
            defer {self.deviceSelectionTasks.removeValue(forKey:id)}
            guard !Task.isCancelled,!self.quitting else {return}
            await self.loadApps()
        }
        deviceSelectionTask=task;deviceSelectionTasks[id]=task
    }
    func loadApps(readinessChecked: Bool = false) async {
        guard !quitting,!Task.isCancelled else {return}
        guard let device=selectedDevice,device.state == "device" else {applications=[];appsDeviceSerial=nil;filterApps();return}
        guard loadingAppsSerial != device.serial else {return}
        let token=UUID();appsLoadToken=token;loadingAppsSerial=device.serial;appsError=nil;updateLauncherPresentation()
        defer {if appsLoadToken==token {loadingAppsSerial=nil;updateLauncherPresentation()}}
        let ready=readinessChecked ? readySerials.contains(device.serial) : await DeviceReadiness.isReady(device:device,toolchain:toolchain)
        guard selectedDevice?.serial==device.serial,appsLoadToken==token,!quitting,!Task.isCancelled else {return}
        if ready {readySerials.insert(device.serial)} else {readySerials.remove(device.serial)}
        guard ready else {applications=[];appsDeviceSerial=nil;filterApps();status.stringValue="Waiting for Android to finish booting on \(device.model)…";return}
        status.stringValue="Reading apps from \(device.model)…"
        do {
            let found=try await discovery.applications(device:device)
            guard selectedDevice?.serial==device.serial,appsLoadToken==token,!quitting,!Task.isCancelled else {return}
            applications=found;appsDeviceSerial=device.serial;filterApps()
            status.stringValue="\(applications.count) apps ready. Double-click an app to open it."
        } catch {
            guard selectedDevice?.serial==device.serial,appsLoadToken==token,!quitting,!Task.isCancelled else {return}
            appsError=(device.serial,error.localizedDescription);applications=[];appsDeviceSerial=nil;filterApps();status.stringValue=error.localizedDescription
        }
    }
    @objc func launchAction() {
        guard canLaunchSelectedApp,let device=selectedDevice,let app=selectedApp else {status.stringValue="Select an app from a connected, ready device first.";return}
        status.stringValue="Opening \(app.name) on \(device.model)…"
        Task { await launch(device: device, app: app, configuration: SessionConfiguration(backend: backend,showSystemDecorations:(try? DroidBridgePreferences.load().showAndroidSystemDecorations) ?? true)) }
    }
    @discardableResult
    func launch(device: AndroidDevice, app: AndroidApplication, configuration: SessionConfiguration, readinessChecked: Bool = false,replacing:UUID? = nil,restoring:UUID? = nil,replacementReason:String = "session_replacement", admissionCheck: (() throws -> Void)? = nil) async -> BridgeSession? {
        guard !quitting,!Task.isCancelled,!wrapperLaunchCancelled else { return nil }
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
        guard !wrapperLaunchCancelled else {return nil}
        // Admission is complete. Recheck ownership after every suspension before
        // replacing intent. Insert the successor first so persistence and idle
        // termination can never observe a destructive intermediate empty state.
        if let replacing, sessions[replacing] !== predecessor {return nil}
        if let restoring, !pending.contains(where:{$0.id==restoring}) {return nil}
        // A phone command may have expired while readiness/catalog admission
        // awaited. Check at the transition from pending to an owned session.
        // Once admitted, the session keeps its existing lifecycle/cleanup owner.
        do { try admissionCheck?() }
        catch { status.stringValue = error.localizedDescription; return nil }
        var initialConfiguration=configuration
        initialConfiguration=companion.configuration(initialConfiguration,serial:device.serial)
        if let preview=launchPreview {
            let size=preview.video.bounds.size
            let scale=min(1.5,1600 / max(size.width,size.height))
            initialConfiguration.width=max(240,Int(size.width*scale)/8*8)
            initialConfiguration.height=max(240,Int(size.height*scale)/8*8)
        }
        let descriptor = SessionDescriptor(device: device, application: app, configuration: initialConfiguration)
        let session = BridgeSession(descriptor: descriptor, toolchain: toolchain)
        sessions[descriptor.id] = session; sessionStates[descriptor.id] = "starting"
        if let restoring {pending.removeAll {$0.id==restoring}}
        if let replacing {close(replacing,reason:replacementReason)}
        if configuration.backend == .native || isWrapper {
            let host: NativeWindowController
            let reusingPreview=launchPreview != nil
            if let preview=launchPreview { host=preview;launchPreview=nil;host.video.statusMessage=nil;host.attach(session) }
            else { host=NativeWindowController(session: session);host.video.applicationIcon=icons[iconKey(device,app)] }
            host.video.loadingMessage="Opening \(app.name)…"
            if configuration.backend == .scrcpy, let window=host.window {
                // SDL uses desktop top-left coordinates and point-sized windows.
                session.externalWindowFrame=CGRect(x:window.frame.minX,y:(NSScreen.screens.first?.frame.maxY ?? window.frame.maxY)-window.contentRect(forFrameRect:window.frame).maxY,width:host.video.bounds.width,height:host.video.bounds.height)
            }
            session.onExternalWindowFrame = { [weak host] frame in host?.rememberExternalFrame(frame) }
            host.onClose = { [weak self] in self?.close(descriptor.id, reason: "window_close") }
            hosts[descriptor.id] = host
            if !reusingPreview,host.window?.isMiniaturized != true {host.showWindow(nil);host.window?.makeKeyAndOrderFront(nil)}
            session.recordClientEvent("loading_window_presented",details:["window_number":String(host.window?.windowNumber ?? -1),"width":String(Int(host.video.bounds.width)),"height":String(Int(host.video.bounds.height)),"launcher_visible":String(window?.isVisible ?? false)])
        }
        session.onState = { [weak self, weak session] state, message in
            guard let self, let session, self.sessions[descriptor.id] != nil else { return }
            if self.sessionStates[descriptor.id] == "disconnected" { return }
            self.sessionStates[descriptor.id] = state.rawValue
            self.pollAudioControls()
            if state == .failed || state == .stopped { self.presentFailure(session, message: message) }
            else { self.hosts[descriptor.id]?.video.statusMessage = nil }
            if let message, state != .failed && state != .stopped { self.status.stringValue = message }
            if state == .running {self.pollPhoneDisplayControls()}
            if state == .running && self.isWrapper {
                if descriptor.configuration.backend == .scrcpy {
                    self.hosts[descriptor.id]?.prepareExternalHandoff()
                    self.window?.orderOut(nil)
                    NSApp.setActivationPolicy(.accessory)
                }
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
        // A first frame only updates the already-present window. It must not
        // undo a minimize/hide or steal focus after the user switches apps.
        if reason != "first_frame" {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            native.deminiaturize(nil); native.makeKeyAndOrderFront(nil); native.orderFrontRegardless()
        }
        session.recordClientEvent("native_window_presented", details: ["window_number":String(native.windowNumber), "reason": reason, "visible": String(native.isVisible), "key": String(native.isKeyWindow), "minimized": String(native.isMiniaturized), "app_active": String(NSApp.isActive), "pid": String(getpid()), "bundle_id": Bundle.main.bundleIdentifier ?? "unknown"])
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
        if let preview=launchPreview {
            preview.window?.deminiaturize(nil);preview.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            if !argumentLaunchInFlight,!wrapperLaunchCancelled,!quitting {processedArguments=false;refreshDevices()}
            return
        }
        if let session=sessions.values.first(where: {$0.state == .starting}),let host=hosts[session.descriptor.id] {
            host.window?.deminiaturize(nil);host.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            return
        }
        if let session=sessions.values.first(where: {$0.descriptor.configuration.backend == .scrcpy && $0.state == .running}),let pid=session.externalApplicationPID {
            NSRunningApplication(processIdentifier:pid)?.activate(options:.activateAllWindows)
            return
        }
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
        sessionStates.removeValue(forKey: id); updateSessions();pollAudioControls(); if !quitting { save() }
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
    func focusSession(_ id:UUID) {
        guard let session=sessions[id] else {return}
        if session.descriptor.configuration.backend == .scrcpy,let pid=session.externalApplicationPID {NSRunningApplication(processIdentifier:pid)?.activate(options:.activateAllWindows)}
        else if session.descriptor.configuration.backend == .native,let window=hosts[id]?.window {window.deminiaturize(nil);window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)}
    }
    func updateSessions() {
        companion.markSessionsChanged()
        guard launcherUI != nil else { return }
        let presentation=sessions.values.map {LauncherSessionPresentation(controller:self,session:$0)}.sorted {$0.id.uuidString<$1.id.uuidString}
        guard presentation != sessionPresentation else {updateLauncherPresentation();return}
        sessionPresentation=presentation
        for view in sessionList.arrangedSubviews {sessionList.removeArrangedSubview(view);view.removeFromSuperview()}
        if sessions.isEmpty {sessionList.addArrangedSubview(LauncherUI.sessionEmptyLabel())}
        for (id,session) in sessions.sorted(by:{$0.value.descriptor.application.name.localizedStandardCompare($1.value.descriptor.application.name) == .orderedAscending}) {
            let row=LauncherUI.sessionCard(controller:self,id:id,session:session)
            sessionList.addArrangedSubview(row);row.widthAnchor.constraint(equalTo:sessionList.widthAnchor).isActive=true
        }
        updateLauncherPresentation()
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
        creatingWrapper = true;updateLauncherPresentation(); status.stringValue = "Loading Android icon and building \(app.name)'s Mac app…"
        wrapperTask = Task {
            defer { creatingWrapper = false; wrapperTask = nil;updateLauncherPresentation() }
            do {
                let lease=try DeviceOnboardingLease(root:managedCatalog.paths.privateRoot)
                defer {lease.release()}
                let png: Data
                if let cached = iconData[iconKey(device, app)] { png = cached }
                else { png = try await iconProvider.icon(device: device, application: app) }
                guard !quitting, !Task.isCancelled else { return }
                let qaDestination = CompanionQAScope.current?.root.appendingPathComponent("ManualApps", isDirectory: true)
                let url = try await MacAppWrapper.create(application: app, device: device, backend: chosenBackend, iconPNG: png, destinationRoot: qaDestination)
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
        guard !wrapperLaunchCancelled else {return}
        let options=launchOptions()
        func value(_ flag:String)->String? {options[["--launch":"package","--serial":"serial","--name":"name","--backend":"backend"][flag] ?? ""]}
        guard let package = value("--launch") else { processedArguments = true; return }
        if Bundle.main.bundleIdentifier?.hasPrefix("app.droidbridge.managed.") == true {
            let catalog=managedCatalog,bundleURL=Bundle.main.bundleURL,serial=value("--serial") ?? ""
            let permitted = await Task.detached { ((try? DroidBridgePreferences.load().bulkWrapperOnboardingEnabled) == true) && ((try? catalog.isLaunchAllowed(bundleURL:bundleURL,serial:serial,packageName:package)) == true) }.value
            guard !quitting else { return }
            guard permitted else { processedArguments=true; showLaunchProblem("This managed Android app is unavailable or device apps in Spotlight are disabled. Connect its authorized device and enable the feature in DroidBridge."); return }
        }
        let serial = value("--serial")
        guard let device = devices.first(where: { $0.state == "device" && (serial == nil || $0.serial == serial) }), readySerials.contains(device.serial) else {
            showLaunchProblem("Waiting for the authorized Android device to finish starting…")
            return
        }
        guard !wrapperLaunchCancelled else {return}
        processedArguments = true
        let app = applications.first(where: { $0.packageName == package }) ?? AndroidApplication(packageName: package, name: value("--name") ?? package)
        let launched = await launch(device: device, app: app, configuration: SessionConfiguration(backend: BackendKind(rawValue: value("--backend") ?? "native") ?? .native,showSystemDecorations:(try? DroidBridgePreferences.load().showAndroidSystemDecorations) ?? true), readinessChecked: true)
        hideLauncherIfUsable(launched)
    }
    func shutdownAndWait() async {
        quitting = true
        await companion.shutdown()
        for task in deviceSelectionTasks.values {task.cancel()}
        if let preview=launchPreview {preview.onClose=nil;preview.close();launchPreview=nil}
        phoneDisplayControls.cancel(); managedNameRepair?.cancel(); restoreTask?.cancel(); onboardingAdmissionTask?.cancel(); onboarding.cancel()
        for session in Array(sessions.values)+Array(retiring.values) {session.stop(reason:"application_quit")}
        await audioControls.shutdown()
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
        for task in Array(deviceSelectionTasks.values) {await task.value}
        deviceSelectionTasks.removeAll();deviceSelectionTask=nil
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
