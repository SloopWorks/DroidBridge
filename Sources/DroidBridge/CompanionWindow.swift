import AppKit
import UserNotifications
import UniformTypeIdentifiers
import DroidBridgeCore

@MainActor final class CompanionWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let adapter: CompanionDesktopAdapter
    private let phones = NSPopUpButton(), adbDevices = NSPopUpButton()
    private let status = NSTextField(wrappingLabelWithString: "Choose an authorized Android device, start its companion service, then connect and pair.")
    private let detail = NSTextField(wrappingLabelWithString: "")
    private let tabs = NSTabView()
    private let navigation = NSStackView()
    private var navigationButtons: [NSButton] = []
    private let appSearch = NSSearchField(), appTable = NSTableView()
    private let appStatus = NSTextField(wrappingLabelWithString: "Load the paired phone's app catalog. Cached icons appear as they arrive.")
    private let appContent = NSStackView(), trusts = NSStackView(), sessions = NSStackView(), inbox = NSStackView()
    private let pendingPairings = NSStackView()
    private var presentedPendingPairings: [CompanionDesktopPendingPairing] = []
    private let transferStatus = NSTextField(wrappingLabelWithString: "Files are limited to 50 MiB and verified by SHA-256. Received content is never opened automatically.")
    private let outgoing = NSTextView()
    private let profile = NSPopUpButton()
    private let diagnostics = NSTextView()
    private let health = NSTextField(wrappingLabelWithString: "Battery, charging, thermal and network status: unknown. Refresh to request a current observation.")
    private let notificationOptIn = NSButton(checkboxWithTitle: "Mirror permitted phone notifications", target: nil, action: nil)
    private let notificationFilters = NSTextField(string: "")
    private let notificationSearch = NSSearchField(), notificationTable = NSTableView()
    private var notificationSelection = Set<String>(), notificationApps: [CompanionApp] = []
    private let notificationStatus = NSTextField(wrappingLabelWithString: "Off until you explicitly enable mirroring and grant Android notification access. Phone permissions remain separate from pairing.")
    private let notificationItems = NSStackView()
    private let delivery = NSTextField(wrappingLabelWithString: "Get the versioned Mac installer from the official DroidBridge releases page. Install on the Mac, then pair; the phone cannot install macOS software.")
    private var downloadURL: URL?
    private var downloadButton: NSButton?, copyDownloadButton: NSButton?
    private let progress = NSProgressIndicator()
    private var selectedID: String?
    private var apps: [CompanionApp] = [], filtered: [CompanionApp] = []
    private var selection: [String: Bool] = [:]
    private var icons: [String: NSImage] = [:], iconTasks: [String: Task<Void, Never>] = [:]
    private var iconQueue: [(String, String)] = []
    private var action: Task<Void, Never>?, refresh: Task<Void, Never>?, catalogTask: Task<Void, Never>?, pairingTask: Task<Void, Never>?
    private var scanner: CompanionPairingScanner?, wireless: CompanionWirelessSetup?
    private var catalogToken = UUID(), changingPhone = false, stopped = false
    private var items: [[String: CompanionJSON]] = []
    private var mirrorShown = Set<String>()
    private var lastInbox = Date.distantPast
    private var presentedDevices: [CompanionDesktopDevice] = []
    private var presentedADBDevices: [AndroidDevice] = []
    private var presentedSessions: [[String: CompanionJSON]] = []
    private var presentedSessionPhone: String?
    private var presentedProfile: CompanionPerformanceProfile?
    private var favoritePackages = Set<String>()
    private lazy var transfers = CompanionTransfers(broker: adapter.broker)

    init(adapter: CompanionDesktopAdapter) {
        self.adapter = adapter
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DroidBridge Companion"; window.contentMinSize = NSSize(width: 700, height: 570); window.isReleasedWhenClosed = false; window.center()
        window.contentView = LauncherBackground()
        super.init(window: window)
        build()
        transfers.onChange = { [weak self] in guard let self else { return }; self.transferStatus.stringValue = self.transfers.message }
        adapter.onChange = { [weak self] in self?.refreshState() }
        refresh = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                if self.window?.isVisible == true { self.refreshState(); if Date().timeIntervalSince(self.lastInbox) >= 3 { await self.loadInbox() } }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        refreshState()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    private var phone: CompanionDesktopDevice? { adapter.devices.first { $0.id == selectedID } }
    private var localDefaults: UserDefaults { CompanionQAScope.current.flatMap { UserDefaults(suiteName: "dev.droidbridge.companion.qa.\($0.serviceSuffix)") } ?? .standard }
    private var serial: String? { adbDevices.selectedItem?.representedObject as? String ?? adapter.launcher?.selectedDevice?.serial }
    private func label(_ text: String, heading: Bool = false) -> NSTextField { let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: heading ? 16 : 12, weight: heading ? .semibold : .regular); return field }
    private func column(_ views: [NSView]) -> NSStackView { let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14; return stack }
    private func row(_ views: [NSView]) -> NSStackView { let stack = NSStackView(views: views); stack.spacing = 8; stack.alignment = .centerY; return stack }
    private func button(_ title: String, _ handler: @escaping () -> Void) -> NSButton { ClosureButton(title: title, handler: handler) }
    private func page(_ title: String, _ content: NSStackView) {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let document = LauncherDocumentView(); content.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 18), content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -18), content.topAnchor.constraint(equalTo: document.topAnchor, constant: 18), content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -18)])
        scroll.documentView = document; document.translatesAutoresizingMaskIntoConstraints = false
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        let item = NSTabViewItem(identifier: title); item.label = title; item.view = scroll; tabs.addTabViewItem(item)
        let short = ["Connection": "Connect", "Notifications": "Alerts", "Performance": "Power", "Diagnostics": "Reports", "Get Mac App": "Install"][title] ?? title
        let index = navigationButtons.count
        let nav = button(short) { [weak self] in self?.selectPage(index) }; nav.setButtonType(.pushOnPushOff); nav.state = index == 0 ? .on : .off; nav.setAccessibilityLabel("Companion section \(title)"); nav.toolTip = title
        navigationButtons.append(nav); navigation.addArrangedSubview(nav)
    }
    private func selectPage(_ index: Int) { tabs.selectTabViewItem(at: index); for (i, button) in navigationButtons.enumerated() { button.state = i == index ? .on : .off } }
    private func build() {
        tabs.tabViewType = .noTabsNoBorder
        navigation.spacing = 5; navigation.distribution = .fillEqually
        phones.target = self; phones.action = #selector(phoneChanged); phones.setAccessibilityLabel("Paired companion phone")
        adbDevices.setAccessibilityLabel("ADB device for companion setup")
        status.maximumNumberOfLines = 4; status.lineBreakMode = .byWordWrapping; status.isSelectable = true; status.setAccessibilityLabel("Companion action result")
        detail.maximumNumberOfLines = 3; detail.textColor = .secondaryLabelColor
        progress.isIndeterminate = true; progress.style = .spinning; progress.isDisplayedWhenStopped = false; progress.controlSize = .small
        let header = row([label("Phone", heading: true), phones, progress, button("Refresh") { [weak self] in self?.run("Refreshing connection…") { [weak self] in try await self?.adapter.refreshStatus(); return "Connection status refreshed." } }])
        let content = column([header, detail, status, navigation, tabs]); content.translatesAutoresizingMaskIntoConstraints = false; window?.contentView?.addSubview(content)
        if let view = window?.contentView { NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18), content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18), content.topAnchor.constraint(equalTo: view.topAnchor, constant: 18), content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -18), header.widthAnchor.constraint(equalTo: content.widthAnchor), detail.widthAnchor.constraint(equalTo: content.widthAnchor), status.widthAnchor.constraint(equalTo: content.widthAnchor), navigation.widthAnchor.constraint(equalTo: content.widthAnchor), tabs.widthAnchor.constraint(equalTo: content.widthAnchor)]) }
        buildConnection(); buildApps(); buildSessions(); buildHandoff(); buildNotifications(); buildPerformance(); buildDiagnostics(); buildDelivery()
    }
    private func buildConnection() {
        let connect = button("Connect Companion") { [weak self] in self?.connect() }
        let pair = button("Pair Phone…") { [weak self] in self?.showPairing() }
        let wifi = button("Set Up Wi-Fi ADB…") { [weak self] in self?.showWireless() }
        let install = button("Install / Update Android Companion") { [weak self] in self?.installCompanion() }
        let open = button("Open Android Companion") { [weak self] in self?.openAndroidCompanion() }
        let retry = button("Retry") { [weak self] in self?.connect() }
        let disconnect = button("Disconnect Companion") { [weak self] in self?.deviceAction("disconnect", message: "Companion disconnected. Android app windows continue independently.") }
        let forget = button("Forget Pairing on This Mac…") { [weak self] in self?.forgetPairing() }
        pendingPairings.orientation = .vertical; pendingPairings.alignment = .leading; pendingPairings.spacing = 10
        let content = column([label("Two permissions, one local connection", heading: true), label("USB or Android's paired wireless debugging authorizes ADB. Companion pairing separately authorizes this Mac's app catalog, handoff and phone dashboard. Select its authorized ADB device, install/open the companion if needed, then start its connection service on the phone."), adbDevices, row([install, open]), row([connect, pair, wifi]), row([retry, disconnect]), forget, pendingPairings, label("Trusted Macs", heading: true), button("Refresh Trusted Macs") { [weak self] in self?.loadTrusts() }, trusts, label("If no ADB device appears: enable Developer options and USB debugging on Android, connect USB, unlock the phone and accept its debugging prompt. A QR code does not grant ADB access. Revoke an untrusted Mac from either companion UI. If a local credential becomes unreadable after an unsigned update, use Forget Pairing on This Mac, remove the old trust on the phone, and pair with a fresh link.")])
        page("Connection", content)
    }
    private func buildApps() {
        appSearch.placeholderString = "Search Android apps"; appSearch.delegate = self; appSearch.setAccessibilityLabel("Companion app search")
        let name = NSTableColumn(identifier: .init("app")); name.title = "Android app and Spotlight export"; name.width = 600
        appTable.addTableColumn(name); appTable.headerView = nil; appTable.rowHeight = 48; appTable.delegate = self; appTable.dataSource = self; appTable.setAccessibilityLabel("Companion Android apps")
        let scroll = NSScrollView(); scroll.documentView = appTable; scroll.hasVerticalScroller = true; scroll.heightAnchor.constraint(equalToConstant: 320).isActive = true
        page("Apps", column([label("Choose apps for Spotlight", heading: true), label("Checked apps are eligible for managed Mac wrappers while this phone is authorized and available. Updating a choice is queued first; DroidBridge reports the actual wrapper result separately. Existing running app windows are preserved."), row([appSearch, button("Refresh Catalog") { [weak self] in self?.loadCatalog() }]), appStatus, scroll]))
    }
    private func buildSessions() {
        page("Sessions", column([label("Mac app sessions", heading: true), label("This dashboard includes independently running Mac wrappers registered with the local broker. Phone commands target the exact owning process. App opening requires the main DroidBridge launcher."), button("Refresh Sessions") { [weak self] in self?.run("Refreshing sessions…") { [weak self] in try await self?.adapter.refreshStatus(); return "Sessions refreshed." } }, sessions]))
    }
    private func buildHandoff() {
        outgoing.isRichText = false; outgoing.font = .systemFont(ofSize: 13); outgoing.setAccessibilityLabel("Text or web link to share with phone")
        let editor = NSScrollView(); editor.documentView = outgoing; editor.hasVerticalScroller = true; editor.heightAnchor.constraint(equalToConstant: 100).isActive = true
        page("Handoff", column([label("Send deliberately, receive privately", heading: true), label("Send selected text, a web link, a file, or the current Mac clipboard. Clipboard contents are read only when you click Send Clipboard. Received items stay here until you choose Copy, Save or Open Link."), editor, row([button("Send Text") { [weak self] in self?.sendText(url: false) }, button("Send Web Link") { [weak self] in self?.sendText(url: true) }, button("Send Clipboard") { [weak self] in self?.sendClipboard() }]), row([button("Send File…") { [weak self] in self?.sendFile() }, button("Cancel Transfer") { [weak self] in self?.transfers.cancel() }, button("Refresh Inbox") { [weak self] in Task { await self?.loadInbox(force: true) } }, button("Clear Inbox…") { [weak self] in self?.clearInbox() }]), transferStatus, button("Retry File Confirmation") { [weak self] in self?.transfers.retryConfirmation() }, label("Received from phone", heading: true), inbox]))
    }
    private func buildNotifications() {
        notificationOptIn.target = self; notificationOptIn.action = #selector(setNotifications)
        notificationFilters.placeholderString = "Advanced: comma-separated package names (optional)"; notificationFilters.setAccessibilityLabel("Advanced notification package allowlist")
        notificationSearch.placeholderString = "Search app names for notification filters"; notificationSearch.delegate = self; notificationSearch.setAccessibilityLabel("Notification app filter search")
        let column = NSTableColumn(identifier: .init("notification-app")); column.width = 600; notificationTable.addTableColumn(column); notificationTable.headerView = nil; notificationTable.rowHeight = 34; notificationTable.delegate = self; notificationTable.dataSource = self; notificationTable.setAccessibilityLabel("Apps permitted to mirror notifications")
        let scroll = NSScrollView(); scroll.documentView = notificationTable; scroll.hasVerticalScroller = true; scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        page("Notifications", self.column([label("Optional phone notifications", heading: true), label("Enable Android notification access on the phone and allow DroidBridge notifications on this Mac. Sensitive, hidden and ongoing notifications are excluded by default. Denied Mac permission keeps the in-app list available. Replies work only while Android still advertises that reply action."), notificationOptIn, label("Choose allowed apps below. An empty app selection permits all notifications allowed by Android and the phone's privacy rules. Refresh Apps first if this list is empty."), notificationSearch, scroll, notificationFilters, button("Apply Notification Filters") { [weak self] in self?.setNotifications() }, notificationStatus, notificationItems]))
    }
    private func buildPerformance() {
        profile.addItems(withTitles: ["Balanced · 30 fps", "Responsive · up to 60 fps", "Battery · 15 fps"]); profile.setAccessibilityLabel("Companion performance profile")
        page("Performance", column([label("Quality and power", heading: true), profile, button("Apply to New App Windows") { [weak self] in self?.setProfile() }, label("Profiles apply to newly opened Android app windows. Existing windows keep their current frame-rate ceiling. Responsive uses more encoder/network/power capacity; Battery reduces frame rate and background asset work. Actual frame rate depends on Android, network conditions and visible content."), button("Refresh Battery, Thermal and Network Status") { [weak self] in self?.loadDiagnostics() }, health, label("Sensor readings and permission availability appear in Diagnostics with their observation time. Unknown readings remain unknown. Use the main launcher's per-device phone-screen and device-wide audio controls; those policies apply across wrappers.")]))
    }
    private func buildDiagnostics() {
        diagnostics.isEditable = false; diagnostics.isRichText = false; diagnostics.font = .monospacedSystemFont(ofSize: 11, weight: .regular); diagnostics.setAccessibilityLabel("Redacted companion diagnostics")
        let scroll = NSScrollView(); scroll.documentView = diagnostics; scroll.hasVerticalScroller = true; scroll.heightAnchor.constraint(equalToConstant: 320).isActive = true
        page("Diagnostics", column([label("Local diagnostics", heading: true), label("Exports include bounded capability, permission and connection counters. Clipboard, shared content, notification bodies, credentials and hardware identifiers are excluded. Nothing is uploaded."), row([button("Refresh Diagnostics") { [weak self] in self?.loadDiagnostics() }, button("Export Report…") { [weak self] in self?.exportDiagnostics() }]), scroll]))
    }
    private func buildDelivery() {
        let open = button("Download Installer…") { [weak self] in if let url = self?.downloadURL { NSWorkspace.shared.open(url) } }; open.isEnabled = false; downloadButton = open
        let copy = button("Copy Download Link") { [weak self] in if let url = self?.downloadURL { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) } }; copy.isEnabled = false; copyDownloadButton = copy
        page("Get Mac App", column([label("Deliver DroidBridge for Mac", heading: true), delivery, row([button("Official Releases…") { if let url = URL(string: "https://github.com/SloopWorks/DroidBridge/releases") { NSWorkspace.shared.open(url) } }, button("Refresh Delivery Details") { [weak self] in self?.loadDelivery() }]), row([open, copy]), label("Use the release's version, architecture, checksum and signing information. Current local builds may be ad-hoc signed; downloading or transferring a DMG does not install it, bypass Gatekeeper or establish trust. The phone's Get Mac App screen provides the same official download and setup guidance. No received installer is run automatically.")]))
    }

    func refreshState() {
        renderPendingPairings()
        guard !stopped else { return }
        let previous = selectedID
        if presentedDevices != adapter.devices {
            phones.removeAllItems()
            for device in adapter.devices { phones.addItem(withTitle: "\(device.name) · \(device.connected ? "Connected" : "Offline")"); phones.lastItem?.representedObject = device.id }
            presentedDevices = adapter.devices
        }
        if let previous, let index = phones.itemArray.firstIndex(where: { ($0.representedObject as? String) == previous }) { phones.selectItem(at: index) }
        else if let serial = adapter.launcher?.selectedDevice?.serial, let device = adapter.device(for: serial), let index = adapter.devices.firstIndex(where: { $0.id == device.id }) { phones.selectItem(at: index) }
        selectedID = phones.selectedItem?.representedObject as? String
        let selectedSerial = serial
        if presentedADBDevices != adapter.launcher?.devices ?? [] {
            adbDevices.removeAllItems()
            for device in adapter.launcher?.devices ?? [] { adbDevices.addItem(withTitle: "\(device.model) · \(device.state)"); adbDevices.lastItem?.representedObject = device.serial }
            presentedADBDevices = adapter.launcher?.devices ?? []
        }
        if let selectedSerial, let index = adbDevices.itemArray.firstIndex(where: { ($0.representedObject as? String) == selectedSerial }) { adbDevices.selectItem(at: index) }
        detail.stringValue = phone.map { "\($0.name) · \($0.connected ? "Authenticated companion connected" : "Companion offline")\($0.error.map { " · \($0)" } ?? "")" } ?? adapter.statusMessage
        if previous != selectedID, !changingPhone { clearPhoneContent() }
        if presentedProfile != phone?.profile || previous != selectedID { profile.selectItem(at: phone?.profile == .responsive ? 1 : phone?.profile == .battery ? 2 : 0); presentedProfile = phone?.profile }
        renderSessions()
    }
    @objc private func phoneChanged() { selectedID = phones.selectedItem?.representedObject as? String; clearPhoneContent(); refreshState(); loadCatalog(); loadTrusts(); Task { await loadInbox(force: true) } }
    private func clearPhoneContent() {
        catalogTask?.cancel(); catalogToken = UUID(); apps = []; filtered = []; selection = [:]; appTable.reloadData(); items = []; renderInbox(); trusts.setViews([]); diagnostics.string = ""; appStatus.stringValue = "Choose Refresh Catalog to read this paired phone's apps."
        for task in iconTasks.values { task.cancel() }; iconTasks.removeAll(); iconQueue.removeAll(); icons.removeAll()
        favoritePackages = Set(localDefaults.stringArray(forKey: "companion-favorites-\(selectedID ?? "none")") ?? [])
        notificationSelection = []; notificationFilters.stringValue = ""; notificationOptIn.state = .off; notificationApps = []; notificationTable.reloadData()
        health.stringValue = "Battery, charging, thermal and network status: unknown. Refresh to request a current observation."
        presentedSessions = []; presentedSessionPhone = nil
    }
    private func run(_ message: String, action work: @escaping () async throws -> String) {
        guard action == nil else { status.stringValue = "Wait for the current action or cancel it first."; return }
        status.stringValue = message; progress.startAnimation(nil)
        action = Task { [weak self] in
            do { let result = try await work(); if !Task.isCancelled { self?.status.stringValue = result } }
            catch { if !Task.isCancelled { self?.status.stringValue = error.localizedDescription } }
            self?.progress.stopAnimation(nil); self?.action = nil
        }
    }
    private func connect() {
        guard let serial else { status.stringValue = "Connect and authorize an Android device first, then click Refresh Devices in DroidBridge."; return }
        run("Connecting to the companion on the selected Android device…") { [weak self] in
            guard let self else { throw CancellationError() }
            let reply = try await self.adapter.broker.request(operation: "connect", payload: ["serial": .string(serial)])
            try await self.adapter.refreshStatus()
            return reply.data["paired"]?.bool == true ? "Authenticated companion connected." : "Pairing is required. Open the phone's pairing window, then choose Pair Phone and use its complete QR or pairing link."
        }
    }
    private func installCompanion() {
        guard let serial, let launcher = adapter.launcher else { status.stringValue = "Select an authorized ADB device first."; return }
        let apk = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Companion/DroidBridgeCompanion.apk")
        run("Installing the bundled Android companion on the selected device…") { [weak self] in
            try AndroidDiscovery.validateSerial(serial)
            guard FileManager.default.fileExists(atPath: apk.path) else { throw CompanionBoundaryError("companion_apk_missing", "This build has no bundled companion APK. Install the complete DroidBridge application release, then retry.") }
            let result = try await ProcessRunner.run(launcher.toolchain.adb, arguments: ["-s", serial, "install", "-r", apk.path], timeout: 90)
            guard result.output.contains("Success") else { throw CompanionBoundaryError("companion_install_failed", "Android did not confirm companion installation. Check its authorization prompt and available storage.") }
            self?.adapter.launcher?.refreshDevices()
            return "Android companion installed. Choose Open Android Companion, then start its connection service and pair this Mac."
        }
    }
    private func openAndroidCompanion() {
        guard let serial, let launcher = adapter.launcher else { status.stringValue = "Select an authorized ADB device first."; return }
        run("Opening the companion on the selected phone…") {
            try AndroidDiscovery.validateSerial(serial)
            let result = try await ProcessRunner.run(launcher.toolchain.adb, arguments: ["-s", serial, "shell", "am", "start", "-n", "dev.droidbridge.companion/.MainActivity"], timeout: 10)
            guard !result.output.contains("Error"), !result.output.contains("Exception") else { throw CompanionBoundaryError("companion_open_failed", "Android could not open the companion. Install or update the bundled companion first.") }
            return "Companion opened on the phone. Start its connection service, then choose Connect Companion here."
        }
    }
    private func showPairing() {
        guard serial != nil else { status.stringValue = "Select an authorized ADB device first."; return }
        scanner = CompanionPairingScanner(); scanner?.onPairCode = { [weak self] code in self?.pair(code) }; scanner?.showWindow(nil)
    }
    private func pair(_ code: CompanionPairCode) {
        guard let serial else { return }; pairingTask?.cancel()
        let name = adapter.launcher?.devices.first(where: { $0.serial == serial })?.model ?? "selected Android phone"
        status.stringValue = "Requesting pairing with \(name). Approve this Mac on the phone; no trust is established yet."; progress.startAnimation(nil)
        pairingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.progress.stopAnimation(nil); self.pairingTask = nil }
            do {
                var payload: [String: CompanionJSON] = ["serial": .string(serial), "secret": .string(code.secret), "server_pin": .string(code.serverPin)]
                if let id = code.deviceID { payload["expected_device_id"] = .string(id) }
                var reply = try await self.adapter.broker.request(operation: "begin_pair", payload: payload)
                guard let id = reply.data["pairing_id"]?.string else { throw CompanionBoundaryError("invalid_pairing", "The phone did not return a pairing request.") }
                let basic = ISO8601DateFormatter(), precise = ISO8601DateFormatter(); precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let remoteExpiry = reply.data["expires_at"]?.string.flatMap { precise.date(from: $0) ?? basic.date(from: $0) }
                let deadline = min(code.expires ?? remoteExpiry ?? Date().addingTimeInterval(120), remoteExpiry ?? Date().addingTimeInterval(120))
                let macName = String((reply.data["mac_name"]?.string ?? Host.current().localizedName ?? "this Mac").prefix(128))
                let comparison = reply.data["comparison_code"]?.string.flatMap { $0.range(of: "^[A-F0-9]{8}$", options: .regularExpression) != nil ? $0 : nil }
                while reply.data["status"]?.string == "pending", Date() < deadline {
                    self.status.stringValue = "On \(name), approve \(macName)\(comparison.map { " · compare \($0)" } ?? ""). Pairing expires in \(max(0, Int(deadline.timeIntervalSinceNow))) seconds. Trust is pending phone approval."
                    try await Task.sleep(nanoseconds: 500_000_000)
                    reply = try await self.adapter.broker.request(operation: "poll_pair", payload: ["pairing_id": .string(id)])
                }
                try Task.checkCancellation()
                guard reply.data["status"]?.string == "approved" else { throw CompanionBoundaryError("pairing_not_approved", "Pairing was not approved or expired. Open a new phone pairing window to retry.") }
                self.selectedID = reply.data["device_id"]?.string; self.changingPhone = true; try await self.adapter.refreshStatus(); self.changingPhone = false
                self.status.stringValue = "Phone approved this Mac. Authenticated companion connected."; self.loadCatalog(); self.loadTrusts()
            } catch { self.changingPhone = false; if !Task.isCancelled { self.status.stringValue = error.localizedDescription } }
        }
    }
    private func showWireless() { wireless = CompanionWirelessSetup(tools: adapter.launcher?.toolchain ?? Toolchain()); wireless?.onConnected = { [weak self] in self?.adapter.launcher?.refreshDevices() }; wireless?.showWindow(nil) }
    private func deviceAction(_ operation: String, message: String) {
        guard let phone else { status.stringValue = "Select a paired phone first."; return }
        run("Updating companion connection…") { [weak self] in guard let self else { throw CancellationError() }; _ = try await self.adapter.broker.request(operation: operation, payload: ["device_id": .string(phone.id)]); try await self.adapter.refreshStatus(); return message }
    }
    private func loadTrusts() {
        guard let phone else { return }
        run("Reading trusted Macs…") { [weak self] in
            guard let self else { throw CancellationError() }
            let reply = try await self.adapter.broker.request(operation: "trust_list", payload: ["device_id": .string(phone.id)])
            guard self.selectedID == phone.id else { throw CancellationError() }
            let rows: [NSView] = (reply.data["items"]?.array ?? []).compactMap { value in
                guard let o = value.object, let id = o["trust_id"]?.string else { return nil }
                return self.row([self.label(o["mac_name"]?.string ?? "Trusted Mac"), self.button("Revoke…") { [weak self] in self?.revoke(id, phone: phone) }])
            }
            self.trusts.setViews(rows.isEmpty ? [self.label("No trusted Macs were returned.")] : rows)
            return "Trusted Macs refreshed. Revoke takes effect on the phone immediately."
        }
    }
    private func forgetPairing() {
        guard let phone else { status.stringValue = "Select a previously paired phone first."; return }
        forgetPairing(deviceID: phone.id, name: phone.name)
    }
    private func forgetPairing(deviceID: String, name: String) {
        let alert = NSAlert()
        alert.messageText = "Forget this Mac's pairing with \(name)?"
        alert.informativeText = "This removes only this Mac's saved companion credential and disconnects its companion connection. App wrappers, app selections, settings and running Android windows are retained. Then remove this Mac's old trust in the phone companion's Trusted Macs settings and pair again with a fresh pairing link. Android debugging authorization is separate."
        alert.addButton(withTitle: "Forget Local Pairing"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        pairingTask?.cancel()
        run("Removing this Mac's saved companion pairing…") { [weak self] in
            guard let self else { throw CancellationError() }
            let reply = try await self.adapter.broker.request(operation: "forget", payload: ["device_id": .string(deviceID)])
            guard reply.data["status"]?.string == "forgotten" else { throw CompanionBoundaryError("pairing_not_forgotten", "The local service did not confirm removal. Refresh and retry.") }
            try await self.adapter.refreshStatus()
            self.trusts.setViews([])
            return "Local pairing removed. On the phone, remove this Mac from Trusted Macs, then use Pair Phone with a fresh pairing link. Your app wrappers and settings are retained." + (reply.data["cleanup_pending"]?.bool == true ? " Old connection cleanup is pending; the local service will retry it." : "")
        }
    }
    private func renderPendingPairings() {
        guard presentedPendingPairings != adapter.pendingPairings else { return }
        presentedPendingPairings = adapter.pendingPairings
        pendingPairings.setViews(adapter.pendingPairings.map { pending in
            let name = adapter.launcher?.devices.first(where: { $0.serial == pending.serial })?.model ?? pending.serial
            let block = self.column([
                self.label("Phone approval needs local completion · \(name)", heading: true),
                self.label("Local recovery expires \(pending.expires.formatted(date: .abbreviated, time: .shortened))."),
                self.label("The phone approved this Mac, but local credential storage or policy setup did not finish. Finish Approved Pairing retries authenticated setup without silently replacing an existing trust. If it expired or cannot be read, forget this pending pairing, remove the old Mac trust on the phone, and use a fresh link."),
                self.row([
                    self.button("Finish Approved Pairing") { [weak self] in self?.finishPairing(pending) },
                    self.button("Forget Pending Pairing…") { [weak self] in self?.forgetPairing(deviceID: pending.id, name: name) }
                ])
            ])
            for child in block.arrangedSubviews { child.widthAnchor.constraint(equalTo: block.widthAnchor).isActive = true }
            return block
        })
    }
    private func finishPairing(_ pending: CompanionDesktopPendingPairing) {
        run("Finishing the phone-approved local pairing…") { [weak self] in
            guard let self else { throw CancellationError() }
            let reply = try await self.adapter.broker.request(operation: "recover_pairing", payload: ["device_id": .string(pending.id)])
            guard reply.data["status"]?.string == "approved" else { throw CompanionBoundaryError("pairing_not_complete", "The approved pairing could not be completed. Forget the pending pairing and use a fresh phone link.") }
            self.selectedID = pending.id
            try await self.adapter.refreshStatus()
            self.loadCatalog()
            self.trusts.setViews([self.label("Pairing completed. Choose Refresh Trusted Macs to review access.")])
            return "Phone-approved pairing completed. Authenticated companion connected."
        }
    }
    private func revoke(_ id: String, phone: CompanionDesktopDevice) {
        let alert = NSAlert(); alert.messageText = "Revoke this Mac's companion access?"; alert.informativeText = "Its credential will stop working immediately. Existing Android debugging authorization is separate."; alert.addButton(withTitle: "Revoke"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run("Revoking trusted Mac…") { [weak self] in guard let self else { throw CancellationError() }; _ = try await self.adapter.broker.request(operation: "revoke", payload: ["device_id": .string(phone.id), "trust_id": .string(id)]); try await self.adapter.refreshStatus(); return "Companion access revoked." }
    }
    func loadCatalog() {
        guard let phone, phone.connected else { appStatus.stringValue = "Connect and pair the companion before reading its catalog. The main launcher can still discover apps through ADB."; return }
        catalogTask?.cancel(); let token = UUID(); catalogToken = token; appStatus.stringValue = "Reading first app page…"
        catalogTask = Task { [weak self] in
            guard let self else { return }
            do {
                let policy = try await self.adapter.broker.request(operation: "export_selection_get", payload: ["device_id": .string(phone.id)])
                self.selection = policy.data["selection"]?.object?.compactMapValues(\.bool) ?? [:]
                var cursor: String?, generation: String?, result: [CompanionApp] = [], pages = 0
                repeat {
                    var payload: [String: CompanionJSON] = ["device_id": .string(phone.id)]
                    if let cursor { payload["cursor"] = .string(cursor) }
                    let response = try await self.adapter.broker.request(operation: "catalog", payload: payload)
                    let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
                    let page = try decoder.decode(CompanionCatalogPage.self, from: JSONEncoder().encode(response.data))
                    guard generation == nil || generation == page.generation else { throw CompanionBoundaryError("stale_catalog", "Apps changed during discovery. Refresh the catalog.") }
                    generation = page.generation; result += page.items; pages += 1
                    guard result.count <= 4096, pages <= 64 else { throw CompanionBoundaryError("catalog_too_large", "The app catalog exceeds its supported bound.") }
                    guard !Task.isCancelled, self.catalogToken == token, self.selectedID == phone.id else { return }
                    self.apps = result; self.filterApps(); self.appStatus.stringValue = "\(result.count) apps loaded\(page.nextCursor == nil ? "." : " · reading more…")"
                    cursor = page.nextCursor
                } while cursor != nil
                self.adapter.launcher?.acceptCompanionCatalog(serial: phone.serial, apps: result)
            } catch { if !Task.isCancelled, self.catalogToken == token { self.appStatus.stringValue = error.localizedDescription + " Existing Android app launching remains available." } }
        }
    }
    func controlTextDidChange(_ obj: Notification) { if obj.object as? NSSearchField === notificationSearch { filterNotificationApps() } else { filterApps() } }
    private func filterApps() { let query = appSearch.stringValue; filtered = apps.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || $0.packageName.localizedCaseInsensitiveContains(query) }.sorted { a, b in let af = favoritePackages.contains(a.packageName), bf = favoritePackages.contains(b.packageName); return af != bf ? af : a.label.localizedStandardCompare(b.label) == .orderedAscending }; appTable.reloadData(); filterNotificationApps() }
    private func filterNotificationApps() { let query = notificationSearch.stringValue; notificationApps = apps.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) || $0.packageName.localizedCaseInsensitiveContains(query) }; notificationTable.reloadData() }
    func numberOfRows(in tableView: NSTableView) -> Int { tableView === notificationTable ? notificationApps.count : filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int) -> NSView? {
        if tableView === notificationTable {
            guard notificationApps.indices.contains(index) else { return nil }; let app = notificationApps[index]
            let check = NSButton(checkboxWithTitle: app.label, target: nil, action: nil); check.state = notificationSelection.contains(app.packageName) ? .on : .off; check.toolTip = app.packageName; check.setAccessibilityLabel("Allow notifications from \(app.label)")
            return CompanionCheckCell(button: check) { [weak self] selected in
                guard let self else { return }; if selected { self.notificationSelection.insert(app.packageName) } else { self.notificationSelection.remove(app.packageName) }
                self.notificationFilters.stringValue = self.notificationSelection.sorted().joined(separator: ", ")
            }
        }
        guard filtered.indices.contains(index) else { return nil }; let app = filtered[index]
        let check = NSButton(checkboxWithTitle: app.label, target: nil, action: nil); check.toolTip = app.packageName; check.state = (selection[app.packageName] ?? app.exportToMac ?? true) ? .on : .off; check.setAccessibilityLabel("Export \(app.label) to Spotlight")
        let cell = CompanionCheckCell(button: check) { [weak self] value in self?.setExport(app, selected: value) }
        let icon = NSImageView(image: app.iconSha256.flatMap { icons[$0] } ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()); icon.imageScaling = .scaleProportionallyUpOrDown; icon.widthAnchor.constraint(equalToConstant: 30).isActive = true; icon.heightAnchor.constraint(equalToConstant: 30).isActive = true
        if let hash = app.iconSha256, icons[hash] == nil { queueIcon(hash) }
        let favorite = button(favoritePackages.contains(app.packageName) ? "★" : "☆") { [weak self] in self?.toggleFavorite(app.packageName) }; favorite.setAccessibilityLabel("Favorite \(app.label)")
        let open = button("Open on Mac") { [weak self] in self?.sendRemoteCommand("open_app", payload: ["package_name": .string(app.packageName)]) }
        cell.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row([icon, cell, favorite, open])
    }
    private func toggleFavorite(_ package: String) { guard let selectedID else { return }; if favoritePackages.contains(package) { favoritePackages.remove(package) } else if favoritePackages.count < 4096 { favoritePackages.insert(package) }; localDefaults.set(Array(favoritePackages).sorted(), forKey: "companion-favorites-\(selectedID)"); filterApps() }
    private func queueIcon(_ hash: String) {
        guard let phone, icons[hash] == nil, iconTasks[hash] == nil, !iconQueue.contains(where: { $0.0 == hash }), iconQueue.count < 64 else { return }
        iconQueue.append((hash, phone.id)); pumpIcons()
    }
    private func pumpIcons() {
        while iconTasks.count < (phone?.profile.assetConcurrency ?? 2), !iconQueue.isEmpty {
            let (hash, device) = iconQueue.removeFirst()
            iconTasks[hash] = Task { [weak self] in
                guard let self else { return }; defer { self.iconTasks.removeValue(forKey: hash); self.pumpIcons() }
                if let bytes = try? await self.adapter.broker.icon(deviceID: device, hash: hash), !Task.isCancelled, self.selectedID == device, let image = NSImage(data: bytes) {
                    image.size = NSSize(width: 30, height: 30); if self.icons.count >= 128 { self.icons.removeAll() }; self.icons[hash] = image
                    let rows = IndexSet(self.filtered.indices.filter { self.filtered[$0].iconSha256 == hash }); self.appTable.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integer: 0))
                }
            }
        }
    }
    private func setExport(_ app: CompanionApp, selected: Bool) {
        guard let phone else { return }
        run("Queuing Spotlight choice for \(app.label)…") { [weak self] in
            guard let self else { throw CancellationError() }
            guard let launcher = self.adapter.launcher else { throw CancellationError() }
            try await DeviceOnboardingAgent.ensureInstalled(hostBundleURL: Bundle.main.bundleURL, toolchain: launcher.toolchain, paths: launcher.managedCatalog.paths)
            let id = UUID()
            _ = try await self.adapter.broker.request(operation: "export_selection_set", payload: ["device_id": .string(phone.id), "package_name": .string(app.packageName), "selected": .bool(selected)], requestID: id)
            self.selection[app.packageName] = selected; self.appTable.reloadData()
            return try await self.waitForHostReceipt(id, device: phone.id, pending: "Choice saved; waiting for the Mac wrapper update…")
        }
    }
    private func renderSessions() {
        let values = adapter.sessionSnapshot.filter { $0["device_id"]?.string == selectedID }
        guard values != presentedSessions || selectedID != presentedSessionPhone else { return }; presentedSessions = values; presentedSessionPhone = selectedID
        let rows: [NSView] = values.map { value in
            let id = value["session_id"]?.string ?? "", title = value["label"]?.string ?? value["package"]?.string ?? "Android app", phase = value["phase"]?.string ?? "unknown"
            return row([label("\(title) · \(phase) · \(value["backend"]?.string ?? "unknown")"), button("Stop") { [weak self] in self?.sendRemoteCommand("stop_session", payload: ["session_id": .string(id)]) }])
        }
        sessions.setViews(rows.isEmpty ? [label("No Mac sessions are registered for this phone.")] : rows)
    }
    private func sendRemoteCommand(_ kind: String, payload: [String: CompanionJSON]) {
        guard let phone else { return }
        run("Requesting \(kind.replacingOccurrences(of: "_", with: " ")) on this Mac…") { [weak self] in guard let self else { throw CancellationError() }; let id = UUID(); _ = try await self.adapter.broker.request(operation: "host_command", payload: ["device_id": .string(phone.id), "kind": .string(kind), "payload": .object(payload)], requestID: id); return try await self.waitForHostReceipt(id, device: phone.id, pending: "Waiting for the exact Mac session owner…") }
    }
    private func waitForHostReceipt(_ id: UUID, device: String, pending: String) async throws -> String {
        let deadline = Date().addingTimeInterval(30)
        repeat {
            try Task.checkCancellation(); status.stringValue = pending
            let reply = try await adapter.broker.request(operation: "command_status", payload: ["device_id": .string(device), "request_id": .string(id.uuidString)])
            let phase = reply.data["status"]?.string ?? "unknown", result = reply.data["result"]?.object ?? [:]
            if phase == "applied" { return "Applied · \(result["phase"]?.string ?? result["state"]?.string ?? result["profile"]?.string ?? "completed")\(result["message"]?.string.map { ": \($0)" } ?? "")" }
            if phase == "rejected" { throw CompanionBoundaryError(result["code"]?.string ?? "action_rejected", result["message"]?.string ?? "The owning Mac process rejected this action. Refresh its state before retrying.") }
            try await Task.sleep(nanoseconds: 350_000_000)
        } while Date() < deadline
        return "Outcome not confirmed for this request. Refresh state before retrying; the request was not sent again."
    }
    private func sendText(url: Bool) {
        let text = outgoing.string
        guard !text.isEmpty, text.utf8.count <= (url ? 8192 : 65536) else { status.stringValue = "Enter nonempty text within the 64 KiB text or 8 KiB link limit."; return }
        if url { guard let value = URL(string: text), ["http", "https"].contains(value.scheme?.lowercased() ?? ""), value.host != nil else { status.stringValue = "Use an http or https web link."; return } }
        sendHandoff("share_send", kind: url ? "share_url" : "share_text", text: text)
    }
    private func sendClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty, text.utf8.count <= 65536 else { status.stringValue = "The Mac clipboard must contain text no larger than 64 KiB."; return }
        sendHandoff("clipboard_send", kind: nil, text: text)
    }
    private func sendHandoff(_ operation: String, kind: String?, text: String) {
        guard let phone else { return }
        run("Sending selected content to phone…") { [weak self] in guard let self else { throw CancellationError() }; var payload: [String: CompanionJSON] = ["device_id": .string(phone.id), "payload": .object(["text": .string(text)])]; if let kind { payload["kind"] = .string(kind) }; let receipt = try await self.adapter.broker.request(operation: operation, payload: payload); return "Phone receipt: \(receipt.data["status"]?.string ?? "accepted"). Open the companion's received items to use the content." }
    }
    private func sendFile() {
        guard let phone else { return }; let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { transfers.send(url, device: phone.id) }
    }
    private func loadInbox(force: Bool = false) async {
        guard let phone, phone.connected, force || Date().timeIntervalSince(lastInbox) >= 3 else { return }; lastInbox = Date()
        do {
            var result: [[String: CompanionJSON]] = [], cursor: String?
            repeat {
                var payload: [String: CompanionJSON] = ["device_id": .string(phone.id)]; if let cursor { payload["after_id"] = .string(cursor) }
                let reply = try await adapter.broker.request(operation: "inbox_list", payload: payload)
                result += (reply.data["items"]?.array ?? []).compactMap(\.object); cursor = reply.data["next_cursor"]?.string
                guard result.count <= 64 else { throw CompanionBoundaryError("inbox_too_large", "The inbox exceeded its bound.") }
            } while cursor != nil
            guard !Task.isCancelled, selectedID == phone.id else { return }
            if items != result { items = result; renderInbox(); await showNotifications() }
        } catch { if force { status.stringValue = error.localizedDescription } }
    }
    private func renderInbox() {
        var shareRows: [NSView] = [], noteRows: [NSView] = []
        for item in items.reversed() {
            guard let kind = item["kind"]?.string, let payload = item["payload"]?.object else { continue }
            if kind == "notification_posted" {
                var controls: [NSView] = [label(String((payload["title"]?.string ?? "Notification").prefix(256))), label(String((payload["text"]?.string ?? "").prefix(2048)))]
                if payload["can_reply"]?.bool == true { controls.append(button("Reply…") { [weak self] in self?.replyNotification(payload) }) }
                controls.append(button("Dismiss on Phone") { [weak self] in self?.notificationAction("notification_dismiss", payload: payload) }); noteRows.append(column(controls)); continue
            }
            if kind == "file_shared" { let size = payload["size"]?.number.flatMap { $0.isFinite && $0 >= 0 && $0 <= 52_428_800 && $0.rounded() == $0 ? "\(Int($0)) bytes" : nil } ?? "size unknown"; shareRows.append(row([label("File · \(payload["display_name"]?.string ?? "Shared file") · \(size)"), button("Save File…") { [weak self] in self?.saveReceivedFile(payload) }])); continue }
            guard ["share_text", "share_url", "clipboard", "clipboard_text", "share"].contains(kind), let text = payload["text"]?.string else { continue }
            var controls: [NSView] = [label("\(kind.replacingOccurrences(of: "_", with: " ")) · \(String(text.prefix(1000)))"), button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }]
            if kind == "share_url", let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil { controls.append(button("Open Link…") { [weak self] in self?.openReceivedLink(url) }) }
            shareRows.append(column(controls))
        }
        inbox.setViews(shareRows.isEmpty ? [label("No received items. Use Android's Share → DroidBridge or its explicit clipboard action.")] : shareRows)
        notificationItems.setViews(noteRows.isEmpty ? [label("No mirrored notifications. Enable permissions and mirroring on the phone.")] : noteRows)
    }
    private func openReceivedLink(_ url: URL) { let alert = NSAlert(); alert.messageText = "Open this phone-shared web link?"; alert.informativeText = String(url.absoluteString.prefix(8192)); alert.addButton(withTitle: "Open"); alert.addButton(withTitle: "Cancel"); if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) } }
    private func saveReceivedFile(_ payload: [String: CompanionJSON]) { guard let phone else { return }; let panel = NSSavePanel(); panel.nameFieldStringValue = String((payload["display_name"]?.string ?? "Shared file").split(whereSeparator: { $0 == "/" || $0 == ":" || $0 == "\\" }).last ?? "Shared file"); if panel.runModal() == .OK, let url = panel.url { transfers.receive(payload, destination: url, device: phone.id) } }
    private func clearInbox() {
        guard let phone else { return }; let alert = NSAlert(); alert.messageText = "Clear received companion items?"; alert.informativeText = "This clears the Mac's inbox metadata. Files you explicitly saved elsewhere are preserved."; alert.addButton(withTitle: "Clear Inbox"); alert.addButton(withTitle: "Cancel"); guard alert.runModal() == .alertFirstButtonReturn else { return }
        run("Clearing companion inbox…") { [weak self] in guard let self else { throw CancellationError() }; _ = try await self.adapter.broker.request(operation: "inbox_clear", payload: ["device_id": .string(phone.id)]); self.items = []; self.renderInbox(); return "Inbox cleared." }
    }
    @objc private func setNotifications() {
        guard let phone else { return }
        let packages = notificationFilters.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard packages.count <= 64, packages.allSatisfy({ (try? AndroidDiscovery.validatePackage($0)) != nil }) else { notificationStatus.stringValue = "Use at most 64 valid Android package names separated by commas."; return }
        let enabled = notificationOptIn.state == .on
        run("Updating notification permissions and filters…") { [weak self] in
            guard let self else { throw CancellationError() }
            if enabled {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                self.notificationStatus.stringValue = allowed ? "Mac notification permission granted. Android notification access and app filters still apply." : "Mac notification permission denied. Mirrored items remain available inside DroidBridge; change permission in System Settings if desired."
            }
            let result = try await self.adapter.broker.request(operation: "notification_preferences", payload: ["device_id": .string(phone.id), "payload": .object(["enabled": .bool(enabled), "packages": .array(packages.map(CompanionJSON.string))])])
            return "Notification preference receipt: \(result.data["status"]?.string ?? "accepted"). The phone's permission state is available in Diagnostics."
        }
    }
    private func showNotifications() async {
        guard notificationOptIn.state == .on else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings(); guard settings.authorizationStatus == .authorized else { return }
        for item in items where item["kind"]?.string == "notification_posted" {
            guard let id = item["id"]?.string, !mirrorShown.contains(id), let p = item["payload"]?.object else { continue }
            let content = UNMutableNotificationContent(); content.title = String((p["package_name"]?.string ?? "Android phone").prefix(128)); content.body = "New phone notification. Open DroidBridge to view it."; content.userInfo = ["companion_item": id]; content.threadIdentifier = "droidbridge-companion"
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "companion-\(id)", content: content, trigger: nil)); mirrorShown.insert(id)
            if mirrorShown.count > 512 { mirrorShown.removeAll(keepingCapacity: true) }
        }
    }
    private func replyNotification(_ p: [String: CompanionJSON]) {
        let alert = NSAlert(); alert.messageText = "Reply to phone notification"; alert.informativeText = "Android revalidates the current reply action before sending."; let text = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 26)); text.setAccessibilityLabel("Phone notification reply"); alert.accessoryView = text; alert.addButton(withTitle: "Send Reply"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !text.stringValue.isEmpty, text.stringValue.utf8.count <= 4096 else { return }
        var payload = p; payload["text"] = .string(text.stringValue); notificationAction("notification_reply", payload: payload)
    }
    private func notificationAction(_ operation: String, payload: [String: CompanionJSON]) {
        guard let phone, let key = payload["notification_key"]?.string, let id = payload["action_id"]?.string else { status.stringValue = "This notification no longer has a usable action. Refresh the inbox."; return }
        var p: [String: CompanionJSON] = ["notification_key": .string(key), "action_id": .string(id)]; if operation == "notification_reply" { p["text"] = payload["text"] }
        run("Sending notification action…") { [weak self] in guard let self else { throw CancellationError() }; let reply = try await self.adapter.broker.request(operation: operation, payload: ["device_id": .string(phone.id), "payload": .object(p)]); return "Notification action: \(reply.data["status"]?.string ?? "accepted")." }
    }
    private func setProfile() { guard let phone else { return }; let value = ["balanced", "responsive", "battery"][max(0, min(2, profile.indexOfSelectedItem))]; run("Saving performance profile…") { [weak self] in guard let self else { throw CancellationError() }; let id = UUID(); _ = try await self.adapter.broker.request(operation: "profile_set", payload: ["device_id": .string(phone.id), "profile": .string(value)], requestID: id); let result = try await self.waitForHostReceipt(id, device: phone.id, pending: "Profile accepted; waiting for the Mac owner…"); try await self.adapter.refreshStatus(); return result + " · New app windows only; existing frame rates are preserved." } }
    private func loadDiagnostics() {
        guard let phone else { return }
        run("Reading redacted diagnostics…") { [weak self] in guard let self else { throw CancellationError() }; let reply = try await self.adapter.broker.request(operation: "diagnostics", payload: ["device_id": .string(phone.id)]); let redacted = CompanionDiagnostics.sanitized(reply.data); let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; let bytes = try encoder.encode(redacted); guard bytes.count <= 262144 else { throw CompanionBoundaryError("diagnostics_too_large", "The diagnostic report exceeded its bound.") }; self.health.stringValue = CompanionDiagnostics.healthSummary(redacted); self.diagnostics.string = "Mac received \(ISO8601DateFormatter().string(from: Date()))\n" + String(decoding: bytes, as: UTF8.self); return "Redacted diagnostic snapshot updated." }
    }
    private func exportDiagnostics() { guard !diagnostics.string.isEmpty else { status.stringValue = "Refresh diagnostics before exporting."; return }; let panel = NSSavePanel(); panel.nameFieldStringValue = "DroidBridge-Companion-Diagnostics.txt"; if panel.runModal() == .OK, let url = panel.url { let text = diagnostics.string; run("Saving redacted diagnostics…") { try await Task.detached { try text.write(to: url, atomically: true, encoding: .utf8) }.value; return "Redacted diagnostics saved locally." } } }
    private func loadDelivery() {
        let phoneID = phone?.id
        run("Fetching current release details from the official HTTPS source…") { [weak self] in
            guard let self else { throw CancellationError() }
            var payload: [String: CompanionJSON] = [:]; if let phoneID { payload["device_id"] = .string(phoneID) }
            let reply = try await self.adapter.broker.request(operation: "delivery", payload: payload), data = reply.data
            self.downloadURL = nil; self.downloadButton?.isEnabled = false; self.copyDownloadButton?.isEnabled = false
            guard let version = data["version"]?.string, version.utf8.count <= 40, let architecture = data["architecture"]?.string, architecture.utf8.count <= 40,
                  let minimum = data["minimum_macos"]?.string, minimum.utf8.count <= 40,
                  let size = data["size_bytes"]?.number, size.isFinite, size > 0, size <= 2_147_483_648, size.rounded() == size,
                  let hash = data["sha256"]?.string, hash.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
                  let url = data["download_url"]?.string.flatMap(URL.init(string:)), url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil, url.path.hasPrefix("/SloopWorks/DroidBridge/releases/download/") else {
                self.delivery.stringValue = "Release metadata is unavailable or incomplete. Open Official Releases to check available installers. No download or installation has been confirmed."
                return "Release details unavailable. No installer was downloaded or run."
            }
            self.downloadURL = url; self.downloadButton?.isEnabled = true; self.copyDownloadButton?.isEnabled = true
            let signing = String((data["signing"]?.string ?? "Not verified").prefix(120)), instructions = String((data["installation"]?.string ?? "Download on the Mac, verify its checksum, install, then pair.").prefix(2000))
            self.delivery.stringValue = "DroidBridge \(version) · \(architecture) · macOS \(minimum)+\n\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))\nSigning: \(signing)\nSHA-256: \(hash)\n\(instructions)\nSource: \(url.absoluteString)"
            return "Versioned release details loaded. Download or copy the link explicitly; no installer was run."
        }
    }
    func shutdown() {
        stopped = true; action?.cancel(); refresh?.cancel(); catalogTask?.cancel(); pairingTask?.cancel(); scanner?.close(); wireless?.shutdown(); transfers.shutdown(); for task in iconTasks.values { task.cancel() }; iconQueue.removeAll(); adapter.onChange = nil
    }
}

@MainActor private final class CompanionCheckCell: NSView {
    private let change: (Bool) -> Void
    init(button: NSButton, change: @escaping (Bool) -> Void) {
        self.change = change; super.init(frame: .zero); button.target = self; button.action = #selector(changed(_:)); button.translatesAutoresizingMaskIntoConstraints = false; addSubview(button)
        NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8), button.centerYAnchor.constraint(equalTo: centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    @objc private func changed(_ sender: NSButton) { change(sender.state == .on) }
}

@MainActor private extension NSStackView {
    func setViews(_ views: [NSView]) {
        for old in arrangedSubviews { removeArrangedSubview(old); old.removeFromSuperview() }
        orientation = .vertical; alignment = .leading; spacing = 12
        for view in views { addArrangedSubview(view); view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
    }
}
