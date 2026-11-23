import AppKit
import AnonymousUsage
import DroidBridgeCore

@MainActor private final class DesktopSettingsTabs: NSTabViewController {
    var selectionChanged: ((Int) -> Void)?
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        selectionChanged?(selectedTabViewItemIndex)
    }
}

/// Application defaults live here; the main device context owns phone policies.
@MainActor final class DesktopSettingsWindowController: NSWindowController {
    private weak var launcher: LauncherController?
    private let tabs = DesktopSettingsTabs()
    private let quickEnabled = NSButton(checkboxWithTitle: "Open automatically when my device connects", target: nil, action: nil)
    private let quickTarget = NSPopUpButton()
    private let quickSummary = NSTextField(wrappingLabelWithString: "")
    private let quickStatus = NSTextField(wrappingLabelWithString: "")
    private var quickNow: ClosureButton!
    private var quickChoose: ClosureButton!
    private let usageStatus = NSTextField(wrappingLabelWithString: "")
    private var retryUsageWithdrawal: NSButton?
    private let deviceNote = NSTextField(wrappingLabelWithString: "")
    static var defaults: UserDefaults {
        if let scope = CompanionQAScope.current,
           let scoped = UserDefaults(suiteName: "dev.droidbridge.desktop.qa.\(scope.serviceSuffix)") { return scoped }
        return .standard
    }
    static func applyDefaults(to launcher: LauncherController) {
        launcher.backendPicker.selectItem(at: defaults.string(forKey: "desktop.defaultBackend") == "scrcpy" ? 1 : 0)
        launcher.reconnect.state = defaults.object(forKey: "desktop.reconnect") == nil || defaults.bool(forKey: "desktop.reconnect") ? .on : .off
    }
    init(launcher: LauncherController) {
        self.launcher = launcher
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 610, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "DroidBridge Settings"; window.isReleasedWhenClosed = false
        super.init(window: window)
        tabs.tabStyle = .toolbar
        quickTarget.addItems(withTitles: QuickAccessController.Target.allCases.map(\.title))
        quickEnabled.target = self; quickEnabled.action = #selector(saveQuickAccess)
        quickTarget.target = self; quickTarget.action = #selector(saveQuickAccess)
        quickChoose = ClosureButton(title: "Use Selected Device and App") { [weak self, weak launcher] in
            launcher?.quickAccess.saveSelection(); self?.refresh()
        }
        quickNow = ClosureButton(title: "Open Now") { [weak launcher] in launcher?.quickAccess.open() }
        tabs.addTabViewItem(page("General", symbol: "gearshape", views: [
            heading("Quick Access"), quickEnabled,
            note("Bring your chosen window to the front once the saved device is connected and ready. This does not unlock your phone."),
            label("Bring to front"), quickTarget, quickSummary, quickChoose, quickStatus,
            quickNow,
            heading("New app windows"), note("These defaults apply to newly opened Android app windows. Running windows keep their current configuration."),
            label("Rendering backend"), launcher.backendPicker, launcher.decorationsPreference,
            heading("Recovery"), launcher.reconnect,
            note("Reconnect restores interrupted sessions when their device is ready. It does not replay an uncertain phone action."),
            heading("Device settings"), deviceNote,
            ClosureButton(title: "Open Device Settings…") { [weak launcher] in launcher?.showWorkspace(.deviceSettings) }
        ]))
        var integrations: [NSView] = [
            heading("Android apps in Spotlight"), launcher.bulkPreference,
            note("This enables managed Android app launchers on this Mac. Per-app availability is chosen in Apps; device-wide creation and results are in Device Settings. Existing running apps remain protected."),
            ClosureButton(title: "Manage Device Apps…") { [weak launcher] in launcher?.showWorkspace(.deviceSettings) },
            heading("Pairing and permissions"),
            note("Android debugging authorization and optional Android-app pairing are separate. Review saved pairings in Devices and notification permissions in Notifications."),
            ClosureButton(title: "Manage Devices…") { [weak launcher] in launcher?.showWorkspace(.devices) }
        ]
        if !launcher.isWrapper, let meter = DesktopUsage.shared.meter {
            let local = DesktopUsage.shared.isLocalVerification
            let consent = NSButton(checkboxWithTitle: local ? "Share local usage summary" : "Share usage totals with SloopWorks", target: self, action: #selector(updateUsageConsent(_:)))
            consent.isEnabled = false
            let retry = ClosureButton(title: "Retry Turning Off Usage Statistics") { [weak self, weak consent] in
                guard let self, let consent else { return }
                self.changeUsageConsent(false, button: consent)
            }
            retry.isHidden = true
            retryUsageWithdrawal = retry
            usageStatus.isHidden = true
            meter.readConsentStatus { [weak self] result in
                self?.showUsageConsent(result, button: consent)
            }
            integrations.append(contentsOf: [
                heading(local ? "Local usage verification" : "Usage statistics"), consent,
                note(local ? "Send foreground session counts, foreground minutes and native video starts to the receiver on this Mac. Turn this off to stop reporting and clear pending counts." : "Send at most one summary per day with foreground session counts, active minutes and native video starts. Reports omit identifiers. The receiving network sees your IP address. Turn this off to stop reporting and clear pending counts.")
            ])
            integrations.append(contentsOf: [usageStatus, retry])
            if local {
                integrations.append(ClosureButton(title: "Send Usage Summary") { DesktopUsage.shared.meter?.sendPending() })
            }
        }
        tabs.addTabViewItem(page("Integration", symbol: "magnifyingglass", views: integrations))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let identity = version.map { "Version \($0) · Build \(build ?? "unknown")" } ?? "Development build"
        tabs.addTabViewItem(page("About", symbol: "info.circle", views: [
            heading("DroidBridge"), label(identity), note("Android apps run on your Android device and appear in Mac windows. Pairing is local device trust; no online account is required."),
            ClosureButton(title: "Privacy Notice…") { Self.openResource("PRIVACY", extension: "md") },
            ClosureButton(title: "Third-Party Notices…") { Self.openNotices() },
            ClosureButton(title: "Support…") { NSWorkspace.shared.open(URL(string: "https://github.com/SloopWorks/DroidBridge/issues")!) },
            ClosureButton(title: "Release Information…") { [weak launcher] in launcher?.showWorkspace(.delivery) },
            note("Updates use a manual download from the official release page. Review the version and installation instructions before updating.")
        ]))
        window.contentViewController = tabs; window.center()
        tabs.selectionChanged = { [weak self] index in
            guard let self, self.tabs.tabViewItems.indices.contains(index) else { return }
            Self.defaults.set(index, forKey: "desktop.settingsPane")
            self.window?.title = "\(self.tabs.tabViewItems[index].label) — DroidBridge Settings"
        }
        tabs.selectedTabViewItemIndex = max(0, min(tabs.tabViewItems.count - 1, Self.defaults.integer(forKey: "desktop.settingsPane")))
        tabs.selectionChanged?(tabs.selectedTabViewItemIndex)
        launcher.backendPicker.target = self; launcher.backendPicker.action = #selector(saveDefaults)
        launcher.reconnect.target = self; launcher.reconnect.action = #selector(saveDefaults)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    @objc private func updateUsageConsent(_ sender: NSButton) {
        changeUsageConsent(sender.state == .on, button: sender)
    }

    private func changeUsageConsent(_ enabled: Bool, button: NSButton) {
        button.isEnabled = false
        retryUsageWithdrawal?.isEnabled = false
        DesktopUsage.shared.setConsent(enabled) { [weak self] result in
            self?.showUsageConsent(result, button: button)
        }
    }

    private func showUsageConsent(_ result: UsageConsentResult, button: NSButton) {
        let unavailable = result.status == .unavailable
        button.allowsMixedState = unavailable
        switch result.status {
        case .enabled: button.state = .on
        case .disabled: button.state = .off
        case .unavailable: button.state = .mixed
        }
        button.isEnabled = !unavailable && !result.purgePending
        retryUsageWithdrawal?.isHidden = button.isEnabled
        retryUsageWithdrawal?.isEnabled = true
        usageStatus.isHidden = button.isEnabled
        usageStatus.stringValue = unavailable
            ? "DroidBridge could not confirm the saved permission. Retry turning off usage statistics."
            : "Reporting is off. Retry to clear the remaining local counters."
    }
    @objc private func saveDefaults() {
        guard let launcher else { return }
        Self.defaults.set(launcher.backend.rawValue, forKey: "desktop.defaultBackend")
        Self.defaults.set(launcher.reconnect.state == .on, forKey: "desktop.reconnect")
        launcher.updateLauncherPresentation()
    }
    @objc private func saveQuickAccess() {
        guard let quick = launcher?.quickAccess else { return }
        quick.enabled = quickEnabled.state == .on
        quick.target = QuickAccessController.Target.allCases[max(0, quickTarget.indexOfSelectedItem)]
        quick.configure(); quick.persist(); refresh()
    }
    func refresh() {
        if let quick = launcher?.quickAccess {
            let supported = launcher?.isWrapper == false
            quickEnabled.isEnabled = supported
            quickEnabled.state = quick.enabled ? .on : .off
            quickTarget.selectItem(at: QuickAccessController.Target.allCases.firstIndex(of: quick.target) ?? 0)
            quickTarget.isEnabled = supported && quick.enabled
            quickNow.isEnabled = supported && quick.enabled && (quick.target == .control || quick.serial != nil)
            quickChoose.isHidden = false
            quickChoose.isEnabled = supported && quick.enabled && (quick.target == .app ? launcher?.canLaunchSelectedApp == true : launcher?.selectedDevice?.state == "device")
            quickChoose.title = quick.target == .app ? "Use Selected Device and App" : "Use Selected Device"
            quickSummary.stringValue = quick.target == .control ? "DroidBridge control app · \(quick.deviceName)" : (quick.target == .app ? "\(quick.appName) · \(quick.deviceName)" : "Current screen · \(quick.deviceName)")
            quickStatus.stringValue = supported ? quick.message : "Configure automatic opening in the DroidBridge control app’s Settings."
        }
        deviceNote.stringValue = launcher?.selectedDevice.map { "Selected device: \($0.model.replacingOccurrences(of: "_", with: " "))\nAudio, phone-screen policy and performance profile belong to this device." } ?? "Select a device in the main window to configure audio, phone-screen policy and performance."
    }
    private func heading(_ text: String) -> NSTextField { LauncherUI.label(text, size: 15, weight: .semibold) }
    private func label(_ text: String) -> NSTextField { LauncherUI.label(text, size: 13) }
    private func note(_ text: String) -> NSTextField { LauncherUI.label(text, size: 12, secondary: true) }
    private func page(_ title: String, symbol: String, views: [NSView]) -> NSTabViewItem {
        let controller = NSViewController(); let scroll = NSScrollView()
        LauncherUI.document(LauncherUI.column(views, spacing: 14), in: scroll, padding: 24)
        controller.view = scroll
        let item = NSTabViewItem(viewController: controller); item.label = title; item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }
    private static var sourceRoot: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    static func openResource(_ name: String, extension ext: String) {
        let url = Bundle.main.url(forResource: name, withExtension: ext) ?? sourceRoot.appendingPathComponent("\(name).\(ext)")
        NSWorkspace.shared.open(url)
    }
    static func openNotices() {
        let url = Bundle.main.resourceURL?.appendingPathComponent("licenses") ?? sourceRoot.appendingPathComponent("Resources/licenses")
        NSWorkspace.shared.open(url)
    }
}
