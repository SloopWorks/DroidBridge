import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

/// This executes shipping AppKit composition against an anonymous NSXPC peer.
/// It deliberately makes no claim about physical input, live Android video,
/// real notifications, Finder/Spotlight indexing, signing or distribution.
private final class UnifiedFixtureBroker: NSObject, NSXPCListenerDelegate, CompanionBrokerXPCProtocol {
    static let phones = ["ac147b36-e0b4-48fa-965c-c694a98ed5d0", "bc147b36-e0b4-48fa-965c-c694a98ed5d0"]
    static let trusts = ["9bf0e385-15bd-4d61-9650-26221a8af695", "8bf0e385-15bd-4d61-9650-26221a8af695"]
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []
    private var requests: [CompanionBrokerRequest] = []
    private var profiles = ["balanced", "battery"]
    func count(_ operation: String) -> Int { lock.lock(); defer { lock.unlock() }; return requests.filter { $0.operation == operation }.count }
    func last(_ operation: String) -> CompanionBrokerRequest? { lock.lock(); defer { lock.unlock() }; return requests.last { $0.operation == operation } }
    func operations() -> [String] { lock.lock(); defer { lock.unlock() }; return requests.map(\.operation) }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: CompanionBrokerXPCProtocol.self)
        connection.exportedObject = self; connection.resume()
        lock.lock(); connections.append(connection); lock.unlock(); return true
    }
    func exchange(_ bytes: Data, reply: @escaping (Data) -> Void) {
        lock.lock(); defer { lock.unlock() }
        do {
            let request = try JSONDecoder().decode(CompanionBrokerRequest.self, from: bytes)
            guard request.nonce == "unified-fixture" else { throw CompanionBoundaryError("unauthorized", "Fixture nonce mismatch") }
            requests.append(request)
            let payload = request.payload
            let index = Self.phones.firstIndex(of: payload["device_id"]?.string ?? "") ?? 0
            var data: [String: CompanionJSON] = [:]
            switch request.operation {
            case "status":
                data = ["devices": .array((0..<2).map { i in .object([
                    "device_id": .string(Self.phones[i]), "device_name": .string(i == 0 ? "QA Primary Phone With A Long Readable Name" : "QA Other Phone"),
                    "serial": .string(i == 0 ? "emulator-5580" : "emulator-5582"), "aliases": .array([.string(i == 0 ? "emulator-5580" : "emulator-5582")]),
                    "connected": .bool(true), "paired": .bool(true), "profile": .string(profiles[i]), "trust_id": .string(Self.trusts[i]),
                    "catalog_change_token": .string(i == 0 ? "ca147b36-e0b4-48fa-965c-c694a98ed5d0" : "da147b36-e0b4-48fa-965c-c694a98ed5d0"),
                    "capabilities": .array(["catalog", "share", "clipboard", "notifications", "notification_scope_v2", "profiles"].map(CompanionJSON.string))
                ]) }), "sessions": .array((0..<2).map { i in .object([
                    "session_id": .string(i == 0 ? "6803ee5e-496c-413e-ac22-e740b23043eb" : "7803ee5e-496c-413e-ac22-e740b23043eb"),
                    "device_id": .string(Self.phones[i]), "label": .string(i == 0 ? "Primary wrapper fixture" : "Other wrapper fixture"), "backend": .string("native"), "phase": .string("running")
                ]) })]
            case "catalog":
                let start = Int(payload["cursor"]?.string ?? "0") ?? 0, end = min(start + 64, 1000)
                data = ["generation": .string("fixture-generation-\(index)"), "items": .array((start..<end).map { n in .object([
                    "package_name": .string("dev.droidbridge.fixture.phone\(index).app\(n)"),
                    "label": .string(n == 17 ? "Distinct Unified Search \(index)" : "Phone \(index) Android App \(n)"), "launchable": .bool(true), "export_to_mac": .bool(false)
                ]) }), "next_cursor": end < 1000 ? .string(String(end)) : .null]
            case "export_selection_get": data = ["selection": .object([:])]
            case "inbox_list":
                data = ["items": .array([.object(["id": .string("d39a1ccc-7d17-4839-a17e-671b18e6ea93"), "device_id": .string(Self.phones[index]), "kind": .string("share_text"), "payload": .object(["text": .string("Received fixture phone \(index)")])]), .object(["id": .string("9444cc0e-bd58-44bc-aa6c-7c23a05b7c85"), "device_id": .string(Self.phones[index]), "trust_id": .string(Self.trusts[index]), "kind": .string("notification_posted"), "payload": .object(["title": .string("Fixture notification \(index)"), "text": .string("In-app fixture only"), "can_reply": .bool(false), "notification_key": .string("fixture-key"), "action_id": .string("fixture-action")])])])]
            case "profile_set": profiles[index] = payload["profile"]?.string ?? "balanced"; data = ["status": .string("accepted")]
            case "notification_preferences", "notification_dismiss":
                guard payload["expected_trust_id"]?.string == Self.trusts[index] else { throw CompanionBoundaryError("trust_superseded", "Exact fixture trust required") }
                data = ["status": .string("applied")]
            case "host_command", "share_send": data = ["status": .string("accepted")]
            case "command_status": data = ["status": .string("applied"), "result": .object(["phase": .string("fixture_effect")])]
            case "trust_list": data = ["items": .array([.object(["trust_id": .string(Self.trusts[index]), "mac_name": .string("Fixture Mac")])])]
            case "diagnostics": data = ["connected": .bool(true), "battery_percent": .number(75)]
            case "delivery": data = ["version": .string("fixture"), "architecture": .string("arm64"), "minimum_macos": .string("14"), "size_bytes": .number(1024), "sha256": .string(String(repeating: "a", count: 64)), "download_url": .string("https://github.com/SloopWorks/DroidBridge/releases/download/fixture/DroidBridge.dmg"), "signing": .string("Fixture metadata; no signing claim")]
            default: break
            }
            reply(try JSONEncoder().encode(CompanionBrokerReply(requestID: request.requestID, data: data)))
        } catch {
            let id = (try? JSONDecoder().decode(CompanionBrokerRequest.self, from: bytes).requestID) ?? UUID()
            reply((try? JSONEncoder().encode(CompanionBrokerReply(requestID: id, error: error as? CompanionBoundaryError ?? .init("fixture_error", "Fixture failed")))) ?? Data())
        }
    }
}

@main struct VerifyUnifiedDesktop {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular); NSApplication.shared.finishLaunching()
        Task { @MainActor in
            do { try await run(); print("PASS: unified desktop isolated AppKit fixture (not live-device acceptance)"); fflush(stdout); exit(0) }
            catch { fputs("FAIL: unified desktop \(error)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw BridgeError.message(message) } }
    static func unwrap<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw BridgeError.message(message) }; return value }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func visible(_ view: NSView) -> [NSView] { descendants(view).filter { !$0.isHiddenOrHasHiddenAncestor } }
    @MainActor static func button(_ title: String, in view: NSView) throws -> NSButton {
        try unwrap(visible(view).compactMap { $0 as? NSButton }.first { $0.title == title }, "Missing visible action: \(title)")
    }
    @MainActor static func actionResult(in root: NSView) -> String {
        visible(root).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Companion action result" }?.stringValue ?? ""
    }
    @MainActor static func wait(_ message: String, _ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(for: .milliseconds(20)) }
        throw BridgeError.message("Timed out: \(message)")
    }
    @MainActor static func capture(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded(); descendants(view).forEach { $0.needsDisplay = true }; view.displayIfNeeded()
        let bitmap = try unwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds), "No AppKit bitmap")
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try unwrap(bitmap.representation(using: .png, properties: [:]), "Cannot encode capture").write(to: url)
    }
    @MainActor static func assertReachable(_ view: NSView, in root: NSView, context: String) throws -> [String: Any] {
        view.scrollToVisible(view.bounds); root.layoutSubtreeIfNeeded()
        let frame = view.convert(view.bounds, to: root), exposed = view.visibleRect
        try require(!view.isHiddenOrHasHiddenAncestor && frame.width > 0 && frame.height > 0 && exposed.width > 0 && exposed.height > 0, "Unreachable control \(context): \(view.accessibilityLabel() ?? view.identifier?.rawValue ?? String(describing: type(of: view)))")
        try require(frame.minX >= -1 && frame.maxX <= root.bounds.maxX + 1, "Horizontal clipping \(context): \(frame)")
        return ["label": view.accessibilityLabel() ?? (view as? NSButton)?.title ?? String(describing: type(of: view)), "frame": [frame.minX, frame.minY, frame.width, frame.height]]
    }
    @MainActor static func run() async throws {
        let scope = try unwrap(CompanionQAScope.current, "Refusing fixture without explicit private CompanionQAScope")
        try require(scope.serial == "emulator-5580" && DroidBridgePreferences.defaultURL == scope.preferencesURL, "Fixture storage not isolated")
        let defaults = UserDefaults(suiteName: "dev.droidbridge.companion.qa.\(scope.serviceSuffix)")!
        defer {
            defaults.removePersistentDomain(forName: "dev.droidbridge.companion.qa.\(scope.serviceSuffix)")
            UserDefaults(suiteName: "dev.droidbridge.desktop.qa.\(scope.serviceSuffix)")?.removePersistentDomain(forName: "dev.droidbridge.desktop.qa.\(scope.serviceSuffix)")
        }
        try DroidBridgePreferences.update { $0.bulkWrapperOnboardingEnabled = false; $0.screenOffDeviceSerials = ["emulator-5582"]; $0.deviceAudioRoutes = ["emulator-5580": .phone, "emulator-5582": .macAndPhone] }
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DROIDBRIDGE_GUI_EVIDENCE"] ?? "verification/unified-desktop/fixture")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let peer = UnifiedFixtureBroker(), listener = NSXPCListener.anonymous(); listener.delegate = peer; listener.resume(); defer { listener.invalidate() }
        let launcher = LauncherController(); launcher.onboardingPending = true; launcher.timer?.invalidate(); launcher.pending = []
        let adapter = CompanionDesktopAdapter(launcher: launcher, broker: CompanionBrokerIPCClient(endpoint: listener.endpoint, nonce: "unified-fixture")); launcher.companion = adapter
        let window = try unwrap(launcher.window, "Main window missing"), content = try unwrap(launcher.window?.contentView, "Main content missing")
        try require(launcher.persistenceURL == scope.sessionsURL, "Session persistence escaped private fixture root")
        let primary = AndroidDevice(serial: "emulator-5580", model: "QA Primary Phone With A Long Readable Name")
        let other = AndroidDevice(serial: "emulator-5582", model: "QA Other Phone")
        launcher.devices = [primary, other]; launcher.readySerials = [primary.serial, other.serial]
        launcher.devicePicker.removeAllItems(); launcher.devicePicker.addItems(withTitles: [primary.model, other.model]); launcher.devicePicker.selectItem(at: 0)
        launcher.showWorkspace(.apps); window.orderFrontRegardless(); try await adapter.refreshStatus()
        try await wait("primary catalog") { launcher.applications.count == 1000 && launcher.appsDeviceSerial == primary.serial }
        let primaryIntent = SessionDescriptor(device: primary, application: AndroidApplication(packageName: "dev.droidbridge.fixture.restore0", name: "Restore primary"), configuration: SessionConfiguration(backend: .native))
        let otherIntent = SessionDescriptor(device: other, application: AndroidApplication(packageName: "dev.droidbridge.fixture.restore1", name: "Restore other"), configuration: SessionConfiguration(backend: .native))
        launcher.pending = [primaryIntent, otherIntent]
        try require(launcher.restorableSessions.map(\.id) == [primaryIntent.id], "Restore includes another phone's saved intent")
        launcher.devicePicker.selectItem(at: -1)
        try require(Set(launcher.restorableSessions.map(\.id)) == [primaryIntent.id, otherIntent.id], "No-selection Restore lost saved intents")
        launcher.devicePicker.selectItem(at: 0)
        let search = launcher.search, table = launcher.table
        search.stringValue = "dIsTiNcT uNiFiEd"; launcher.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try require(launcher.filtered.count == 1 && launcher.filtered[0].packageName == "dev.droidbridge.fixture.phone0.app17", "Unified label search failed")
        search.stringValue = "dev.droidbridge.fixture.phone0.app42"; launcher.filterApps()
        try require(!launcher.filtered.isEmpty && launcher.filtered.allSatisfy { $0.packageName.contains(search.stringValue) } && launcher.filtered.contains { $0.packageName == "dev.droidbridge.fixture.phone0.app42" }, "Unified package substring search failed")
        search.stringValue = "Distinct Unified"; launcher.filterApps(); table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let selection = launcher.selectedApp?.packageName
        let sections: [DesktopWorkspaceSection] = [.apps, .sessions, .handoff, .notifications, .devices, .deviceSettings, .diagnostics, .delivery]
        let sectionNames = ["apps", "sessions", "handoff", "notifications", "devices", "deviceSettings", "diagnostics", "delivery"]
        let expectedActions: [[String]] = [[], ["Refresh Sessions", "Stop"], ["Send Text", "Send Web Link", "Send Clipboard", "Send File…", "Cancel Transfer", "Refresh Inbox", "Clear Inbox…", "Retry File Confirmation", "Reveal Saved File"], ["Mirror permitted phone notifications", "Check Mac Notification Permission", "Apply Notification Filters"], ["Connect Companion", "Pair Phone…", "Set Up Wi-Fi ADB…", "Install / Update Android Companion", "Open Android Companion", "Disconnect Companion", "Forget Pairing on This Mac…", "Refresh Trusted Macs"], ["Apply to New App Windows", "Refresh Battery, Thermal and Network Status"], ["Refresh Diagnostics", "Export Report…"], ["Official Releases…", "Refresh Release Details", "Download Installer…", "Copy Download Link"]]
        var cases: [[String: Any]] = []
        let minimum = window.contentMinSize
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for size in [NSSize(width: 1160, height: 780), minimum] {
                window.setContentSize(size)
                for (index, section) in sections.enumerated() {
                    launcher.showWorkspace(section); content.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(60))
                    try require(launcher.window === window && launcher.launcherUI?.currentSection == section, "Route changed host or destination: \(sectionNames[index])")
                    try require(!NSApp.windows.contains { $0.title == "DroidBridge Companion" }, "Production route allocated standalone Companion window")
                    try require(launcher.search === search && launcher.table === table && search.stringValue == "Distinct Unified" && launcher.selectedApp?.packageName == selection, "Route lost unified catalog/search/selection")
                    for title in expectedActions[index] {
                        let action = try button(title, in: content)
                        try require(action.target != nil && action.action != nil, "Disconnected action: \(title)")
                    }
                    if section == .apps {
                        try require(visible(content).compactMap { $0 as? NSSearchField }.count == 1, "Apps route has competing catalog searches")
                        try require(visible(content).contains { $0 === table }, "Apps route lost shipping app table")
                    } else { try require(!visible(content).contains { $0 === search }, "App search remains active outside Apps") }
                    var controls: [[String: Any]] = []
                    for control in visible(content).filter({ $0 is NSButton || $0 is NSPopUpButton || $0 is NSSearchField || $0 is NSTableView || $0 is NSTextView || ($0 as? NSTextField)?.isEditable == true }) {
                        controls.append(try assertReachable(control, in: content, context: "\(sectionNames[index]) \(appearance.rawValue) \(size)"))
                    }
                    let chrome = try unwrap(content.superview, "Native window chrome missing")
                    controls.append(try assertReachable(launcher.devicePicker, in: chrome, context: "Toolbar selected device"))
                    let tag = "\(appearance.rawValue)-\(Int(size.width))x\(Int(size.height))-\(sectionNames[index])"
                    for scroll in visible(content).compactMap({ $0 as? NSScrollView }) { scroll.documentView?.scrollToVisible(NSRect(x: 0, y: 0, width: 1, height: 1)) }
                    try capture(content, to: output.appendingPathComponent(tag + ".png"))
                    cases.append(["section": sectionNames[index], "appearance": appearance.rawValue, "size": [size.width, size.height], "controls": controls])
                }
            }
        }
        // Use the real sidebar table selection path as well as the route API.
        let navigation = try unwrap(visible(content).compactMap { $0 as? NSTableView }.first { $0.accessibilityLabel() == "Workspace sections" }, "Workspace navigation table missing")
        try require(navigation.numberOfRows >= 5, "Primary workspace destinations missing")
        for row in 0..<navigation.numberOfRows {
            navigation.scrollRowToVisible(row)
            try require(navigation.rect(ofRow: row).intersects(navigation.visibleRect), "Sidebar destination unreachable: \(row)")
        }
        navigation.selectRowIndexes(IndexSet(integer: 4), byExtendingSelection: false)
        try require(launcher.launcherUI?.currentSection == .devices && launcher.window === window, "Sidebar selection did not route inside the existing host")
        // Action receipts prove the retained controls still dispatch to the exact selected phone.
        launcher.showWorkspace(.handoff)
        let outgoing = try unwrap(visible(content).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "Text or web link to share with phone" }, "Handoff editor missing")
        outgoing.string = "Isolated unified desktop fixture text"
        try button("Send Text", in: content).performClick(nil)
        try await wait("handoff receipt") { peer.count("share_send") == 1 && actionResult(in: content).contains("Phone receipt:") }
        try require(peer.last("share_send")?.payload["device_id"]?.string == UnifiedFixtureBroker.phones[0], "Handoff targeted wrong phone")
        launcher.showWorkspace(.sessions); try button("Stop", in: content).performClick(nil)
        try await wait("stop receipt") { peer.count("host_command") == 1 && peer.count("command_status") > 0 && actionResult(in: content).contains("Applied") }
        try require(peer.last("host_command")?.payload["device_id"]?.string == UnifiedFixtureBroker.phones[0] && peer.last("host_command")?.payload["payload"]?.object?["session_id"]?.string == "6803ee5e-496c-413e-ac22-e740b23043eb", "Stop lost exact owner scope")
        launcher.showWorkspace(.deviceSettings)
        let profile = try unwrap(visible(content).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Companion performance profile" }, "Device profile missing")
        profile.selectItem(at: 1); try button("Apply to New App Windows", in: content).performClick(nil)
        try await wait("profile receipt") { peer.count("profile_set") == 1 && actionResult(in: content).contains("New app windows only") }
        try require(peer.last("profile_set")?.payload["device_id"]?.string == UnifiedFixtureBroker.phones[0], "Profile targeted wrong phone")
        launcher.showWorkspace(.notifications)
        let filters = try unwrap(visible(content).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Advanced notification package allowlist" }, "Notification filters missing")
        filters.stringValue = "dev.droidbridge.fixture.phone0.app17"
        // Mirroring stays off: no system authorization prompt or OS notification is allowed.
        let mirror = try button("Mirror permitted phone notifications", in: content); mirror.state = .off
        try button("Apply Notification Filters", in: content).performClick(nil)
        try await wait("notification policy receipt") { peer.count("notification_preferences") == 1 && actionResult(in: content).contains("Notification preference receipt:") }
        try require(peer.last("notification_preferences")?.payload["device_id"]?.string == UnifiedFixtureBroker.phones[0] && peer.last("notification_preferences")?.payload["expected_trust_id"]?.string == UnifiedFixtureBroker.trusts[0], "Notifications lost selected phone/trust scope")
        let responder = window.firstResponder
        let catalogReads = peer.count("catalog")
        for _ in 0..<3 { try await adapter.refreshStatus(); launcher.updateLauncherPresentation() }
        try require(filters.stringValue == "dev.droidbridge.fixture.phone0.app17" && window.firstResponder === responder, "Unchanged polling replaced notification filter/focus")
        launcher.showWorkspace(.handoff)
        try require(outgoing.string == "Isolated unified desktop fixture text", "Hidden handoff page lost draft")
        window.makeFirstResponder(outgoing)
        for _ in 0..<3 { try await adapter.refreshStatus(); launcher.updateLauncherPresentation() }
        try require(window.firstResponder === outgoing && outgoing.string == "Isolated unified desktop fixture text", "Hidden-page/poll refresh stole active editor focus")
        launcher.showWorkspace(.apps)
        try require(peer.count("catalog") == catalogReads && launcher.search === search, "Route switching duplicated app catalog reads/control")
        // Change selected context without admitting ADB discovery; fixture broker owns all catalog data.
        launcher.devicePicker.selectItem(at: 1); launcher.applications = []; launcher.appsDeviceSerial = nil; launcher.filterApps()
        launcher.showWorkspace(.apps); adapter.catalogVisibilityChanged()
        try await wait("other catalog") { launcher.appsDeviceSerial == other.serial && launcher.applications.count == 1000 }
        launcher.showWorkspace(.deviceSettings); launcher.pollPhoneDisplayControls()
        try require(launcher.restorableSessions.map(\.id) == [otherIntent.id], "Restore did not follow the changed selected phone")
        try require(launcher.phoneScreenPreference.state == .on, "Per-device screen policy did not follow selected device")
        try require(profile.indexOfSelectedItem == 2, "Performance profile stayed attached to previous phone")
        profile.selectItem(at: 0); try button("Apply to New App Windows", in: content).performClick(nil)
        try await wait("other profile receipt") { peer.count("profile_set") == 2 && actionResult(in: content).contains("New app windows only") }
        try require(peer.last("profile_set")?.payload["device_id"]?.string == UnifiedFixtureBroker.phones[1], "Changed selected device did not scope profile action")
        launcher.showWorkspace(.notifications); filters.stringValue = "dev.droidbridge.fixture.phone1.app17"; mirror.state = .off
        try button("Apply Notification Filters", in: content).performClick(nil)
        try await wait("other notification receipt") { peer.count("notification_preferences") == 2 && actionResult(in: content).contains("Notification preference receipt:") }
        try require(peer.last("notification_preferences")?.payload["device_id"]?.string == UnifiedFixtureBroker.phones[1] && peer.last("notification_preferences")?.payload["expected_trust_id"]?.string == UnifiedFixtureBroker.trusts[1], "Changed selected device did not scope notifications")
        launcher.showWorkspace(.diagnostics); try button("Refresh Diagnostics", in: content).performClick(nil)
        try await wait("diagnostics action") { peer.count("diagnostics") > 0 && actionResult(in: content).contains("Redacted diagnostic snapshot updated") }
        launcher.showWorkspace(.delivery); try button("Refresh Release Details", in: content).performClick(nil)
        try await wait("delivery action") { peer.count("delivery") > 0 }
        try await wait("delivery validation") { (try? button("Download Installer…", in: content).isEnabled) == true }
        let deviceSettingsItem = try unwrap(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "device-settings" }, "Device Settings toolbar item missing")
        let deviceSettingsAction = try unwrap(deviceSettingsItem.action, "Device Settings toolbar action missing")
        try require(NSApp.sendAction(deviceSettingsAction, to: deviceSettingsItem.target, from: deviceSettingsItem), "Device Settings toolbar action did not dispatch")
        try require(launcher.launcherUI?.currentSection == .deviceSettings && launcher.window === window, "Toolbar did not route to Device Settings in existing host")
        let destinationBeforeSettings = launcher.launcherUI?.currentSection
        launcher.showLauncherSettings()
        let settings = try unwrap(NSApp.windows.first { $0 !== window && $0.isVisible && $0.title.localizedCaseInsensitiveContains("Settings") }, "Settings did not open a real separate NSWindow")
        let settingsContent = try unwrap(settings.contentView, "Settings content missing")
        try button("Settings…", in: content).performClick(nil)
        try require(NSApp.windows.filter { $0 !== window && $0.isVisible && $0.title.localizedCaseInsensitiveContains("Settings") }.count == 1 && launcher.launcherUI?.currentSection == destinationBeforeSettings, "Settings duplicated host or navigated workspace")
        let settingsTabs = try unwrap(settings.contentViewController as? NSTabViewController, "Native Settings tabs missing")
        try require(settingsTabs.tabViewItems.map(\.label) == ["General", "Integration", "About"], "Settings scopes missing")
        settingsTabs.selectedTabViewItemIndex = 0; settingsContent.layoutSubtreeIfNeeded()
        try require(launcher.decorationsPreference.window === settings && launcher.backendPicker.window === settings && launcher.reconnect.window === settings, "General defaults do not live in Settings")
        settingsTabs.selectedTabViewItemIndex = 1; settingsContent.layoutSubtreeIfNeeded()
        try require(launcher.bulkPreference.window === settings, "Spotlight default does not live in Integration Settings")
        settingsTabs.selectedTabViewItemIndex = 0; settingsContent.layoutSubtreeIfNeeded()
        try require(launcher.phoneScreenPreference.window === window && launcher.audioRoutePicker.window === window, "Per-device policies moved into global Settings")
        let previous = try DroidBridgePreferences.load()
        launcher.decorationsPreference.performClick(nil)
        try await wait("private preference write") { (try? DroidBridgePreferences.load().showAndroidSystemDecorations) != previous.showAndroidSystemDecorations }
        let persisted = try DroidBridgePreferences.load()
        try require(persisted.screenOffDeviceSerials == previous.screenOffDeviceSerials && persisted.deviceAudioRoutes == previous.deviceAudioRoutes, "Global preference action overwrote per-device policy")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            settings.appearance = NSAppearance(named: appearance)
            // Settings is a fixed-size native window; its unspecified minimum is zero.
            for (index, item) in settingsTabs.tabViewItems.enumerated() {
                settingsTabs.selectedTabViewItemIndex = index; settingsContent.layoutSubtreeIfNeeded()
                for control in visible(settingsContent).filter({ $0 is NSButton || $0 is NSPopUpButton }) { _ = try assertReachable(control, in: settingsContent, context: "Settings \(item.label) \(appearance.rawValue)") }
                try capture(settingsContent, to: output.appendingPathComponent("\(appearance.rawValue)-settings-\(item.label.lowercased()).png"))
            }
        }
        let prohibited = Set(["host_register", "connect", "pair", "recover_pairing", "export_selection_set", "clipboard_send", "inbox_clear"])
        try require(prohibited.isDisjoint(with: Set(peer.operations())), "Read/layout fixtures triggered unauthorized effect")
        settings.orderOut(nil); window.orderOut(nil)
        await launcher.shutdownAndWait()
        let result: [String: Any] = ["passed": true, "scope": "Shipping AppKit controls + anonymous NSXPC fixture only; no physical-input, Android-video, OS-notification, Spotlight, signing or installer acceptance", "private_storage": true, "workspace_host_windows": 1, "settings_windows": 1, "routes": sectionNames, "layout_cases": cases, "broker_operations": peer.operations(), "action_receipts": ["handoff_selected_phone": true, "stop_exact_session": true, "profiles_follow_selected_phone": true, "notifications_follow_exact_trust": true, "diagnostics": true, "delivery_metadata": true], "focus_and_drafts_retained": true]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
    }
}
