import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    var launcher: LauncherController!
    let audioMenu = NSMenu(title:"Audio")
    func applicationWillFinishLaunching(_ notification: Notification) {
        // A wrapper needs only its local identity and one window. Present it
        // before menu construction and the rest of AppKit launch completion.
        do { _ = try CompanionQAScope.parse(arguments: ProcessInfo.processInfo.arguments) }
        catch { return } // didFinishLaunching presents the existing error path.
        guard Bundle.main.url(forResource: "launch", withExtension: "json") != nil || ProcessInfo.processInfo.arguments.contains("--wrapper") else { return }
        CompanionLaunchTrace.record("will_finish_launching")
        NSApp.setActivationPolicy(.regular)
        launcher = LauncherController()
        _ = launcher.prepareWrapperLaunch()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do { _ = try CompanionQAScope.parse(arguments: ProcessInfo.processInfo.arguments) }
        catch { let alert = NSAlert(); alert.messageText = "Invalid companion verification scope"; alert.informativeText = error.localizedDescription; alert.runModal(); NSApp.terminate(nil); return }
        CompanionLaunchTrace.record("did_finish_launching")
        NSApp.setActivationPolicy(.regular)
        let applicationName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "DroidBridge"
        if let url = Bundle.main.url(forResource: "AndroidApp", withExtension: "icns"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        let appMenu = NSMenu()
        let root = NSMenuItem(); root.submenu = appMenu
        let menu = NSMenu(); menu.addItem(root)
        appMenu.addItem(withTitle: "About \(applicationName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Settings…",action:#selector(showSettings),keyEquivalent:",").target=self
        appMenu.addItem(.separator())
        let services=NSMenu(title:"Services"),servicesItem=NSMenuItem(title:"Services",action:nil,keyEquivalent:"");servicesItem.submenu=services;appMenu.addItem(servicesItem);NSApp.servicesMenu=services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Hide \(applicationName)",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        let hideOthers=appMenu.addItem(withTitle:"Hide Others",action:#selector(NSApplication.hideOtherApplications(_:)),keyEquivalent:"h");hideOthers.keyEquivalentModifierMask=[.command,.option]
        appMenu.addItem(withTitle:"Show All",action:#selector(NSApplication.unhideAllApplications(_:)),keyEquivalent:"")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(applicationName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let fileItem=NSMenuItem(title:"File",action:nil,keyEquivalent:""),fileMenu=NSMenu(title:"File");fileItem.submenu=fileMenu
        fileMenu.addItem(withTitle:"Close Window",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w");menu.addItem(fileItem)
        let edit = NSMenuItem(); edit.title = "Edit"; edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.submenu?.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        menu.addItem(edit)
        let viewItem=NSMenuItem(title:"View",action:nil,keyEquivalent:""),viewMenu=NSMenu(title:"View");viewItem.submenu=viewMenu
        for (index,section) in DesktopWorkspaceSection.primary.enumerated() {let item=viewMenu.addItem(withTitle:section.title,action:#selector(navigateWorkspace(_:)),keyEquivalent:String(index+1));item.target=self;item.representedObject=section.rawValue}
        viewMenu.addItem(.separator());viewMenu.addItem(withTitle:"Toggle Sidebar",action:#selector(NSSplitViewController.toggleSidebar(_:)),keyEquivalent:"s").keyEquivalentModifierMask=[.command,.control];menu.addItem(viewItem)
        let phoneItem=NSMenuItem();phoneItem.title="Devices"
        let phoneMenu=NSMenu(title:"Devices")
        phoneMenu.addItem(withTitle:"Connection and Pairing…",action:#selector(showCompanion),keyEquivalent:"").target=self
        phoneMenu.addItem(withTitle:"Device Settings…",action:#selector(showDeviceSettings),keyEquivalent:"").target=self
        phoneMenu.addItem(.separator())
        phoneMenu.addItem(withTitle:"Turn Phone Screen Off",action:#selector(turnPhoneScreenOff),keyEquivalent:"").target=self
        phoneMenu.addItem(withTitle:"Turn Phone Screen On",action:#selector(turnPhoneScreenOn),keyEquivalent:"").target=self
        phoneMenu.addItem(.separator())
        phoneItem.submenu=phoneMenu;menu.addItem(phoneItem)
        let audioItem=NSMenuItem();audioItem.title="Audio";audioItem.submenu=audioMenu
        audioMenu.delegate=self;audioMenu.autoenablesItems=false;menu.addItem(audioItem)
        let appActions=NSMenuItem();appActions.title="Apps"
        let appsMenu=NSMenu(title:"Apps")
        appsMenu.addItem(withTitle:"Find App…",action:#selector(findApp),keyEquivalent:"f").target=self
        appsMenu.addItem(withTitle:"Launch Selected App",action:#selector(launchSelectedApp),keyEquivalent:"o").target=self
        appsMenu.addItem(withTitle:"Create / Update Mac App…",action:#selector(createSelectedMacApp),keyEquivalent:"").target=self
        appsMenu.addItem(.separator())
        appsMenu.addItem(withTitle:"Add All Device Apps to Spotlight…",action:#selector(addDeviceApps),keyEquivalent:"").target=self
        appsMenu.addItem(withTitle:"Restore Previous Sessions",action:#selector(restoreSessions),keyEquivalent:"").target=self
        appActions.submenu=appsMenu;menu.addItem(appActions)
        let handoffItem=NSMenuItem(title:"Handoff",action:nil,keyEquivalent:""),handoffMenu=NSMenu(title:"Handoff");handoffItem.submenu=handoffMenu
        for command in [CompanionTaskCommand.sendText,.sendWebLink,.sendClipboard,.sendFile,.refreshInbox] {let item=handoffMenu.addItem(withTitle:command.title,action:#selector(performTaskCommand(_:)),keyEquivalent:"");item.target=self;item.representedObject=command.rawValue}
        menu.addItem(handoffItem)
        let windowItem = NSMenuItem(); windowItem.title = "Window"
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "DroidBridge", action: #selector(showLauncher), keyEquivalent: "l").target = self
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu; menu.addItem(windowItem); NSApp.windowsMenu = windowMenu
        let helpItem=NSMenuItem(title:"Help",action:nil,keyEquivalent:""),help=NSMenu(title:"Help");helpItem.submenu=help
        help.addItem(withTitle:"DroidBridge Help",action:#selector(showHelp),keyEquivalent:"?").target=self
        help.addItem(withTitle:"Diagnostics…",action:#selector(showDiagnostics),keyEquivalent:"").target=self
        help.addItem(withTitle:"Open Logs Folder…",action:#selector(openLogs),keyEquivalent:"").target=self
        help.addItem(withTitle:"Release Information…",action:#selector(showReleaseInformation),keyEquivalent:"").target=self
        for command in [CompanionTaskCommand.refreshNotifications,.refreshDiagnostics,.exportDiagnostics,.refreshRelease] {let item=help.addItem(withTitle:command.title,action:#selector(performTaskCommand(_:)),keyEquivalent:"");item.target=self;item.representedObject=command.rawValue}
        help.addItem(.separator())
        help.addItem(withTitle:"Privacy Notice…",action:#selector(showPrivacy),keyEquivalent:"").target=self
        help.addItem(withTitle:"Third-Party Notices…",action:#selector(showNotices),keyEquivalent:"").target=self
        help.addItem(withTitle:"Support…",action:#selector(showSupport),keyEquivalent:"").target=self
        menu.addItem(helpItem);NSApp.helpMenu=help
        NSApp.mainMenu = menu
        if launcher == nil { launcher = LauncherController() }
        if !launcher.prepareWrapperLaunch() { launcher.showWindow(nil) }
        NSApp.activate(ignoringOtherApps: true)
        launcher.companion.start()
        CompanionLaunchTrace.record("companion_start_scheduled")
        Task { @MainActor in
            let recovery = CompanionQAScope.current == nil ? await BridgeSession.recoverAbandonedSessions(toolchain: launcher.toolchain) : []
            if !recovery.isEmpty { launcher.status.stringValue = recovery.joined(separator: " · ") }
            launcher.beginPolling()
        }
    }
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        if item.action == #selector(findApp) {return launcher?.window?.isKeyWindow == true || (launcher?.sessions.isEmpty == true && launcher?.launchPreview == nil && launcher?.isWrapper == false)}
        if item.action == #selector(launchSelectedApp) || item.action == #selector(createSelectedMacApp) {return launcher?.window?.isKeyWindow == true && launcher?.launcherUI?.currentSection == .apps && launcher?.canLaunchSelectedApp == true}
        if item.action == #selector(addDeviceApps) {return launcher?.canOnboardSelectedDevice == true}
        if item.action == #selector(restoreSessions) {item.title=launcher?.selectedDevice == nil ? "Restore Sessions for All Devices" : "Restore Previous Sessions";return launcher?.restorableSessions.isEmpty == false && launcher?.restoreTask == nil}
        if item.action == #selector(turnPhoneScreenOff) || item.action == #selector(turnPhoneScreenOn) {return launcher?.audioMenuDevice() != nil}
        if item.action == #selector(navigateWorkspace(_:)),let raw=item.representedObject as? String {item.state=launcher?.launcherUI?.currentSection.rawValue == raw ? .on : .off;return launcher?.window?.isKeyWindow == true}
        if item.action == #selector(performTaskCommand(_:)),let raw=item.representedObject as? String,let command=CompanionTaskCommand(rawValue:raw) {return launcher?.window?.isKeyWindow == true && launcher?.companion.windowController?.canPerform(command) == true}
        return true
    }
    @objc func findApp() {guard let launcher,launcher.window?.isKeyWindow == true || (launcher.sessions.isEmpty && launcher.launchPreview == nil && !launcher.isWrapper) else {return};launcher.focusAppSearch()}
    @objc func showSettings() {launcher?.showLauncherSettings()}
    @objc func showCompanion() {launcher?.companion.show()}
    @objc func showDeviceSettings() {launcher?.showWorkspace(.deviceSettings)}
    @objc func navigateWorkspace(_ item:NSMenuItem) {guard launcher?.window?.isKeyWindow == true,let raw=item.representedObject as? String,let section=DesktopWorkspaceSection(rawValue:raw) else {return};launcher?.showWorkspace(section)}
    @objc func launchSelectedApp() {guard launcher?.window?.isKeyWindow == true,launcher?.launcherUI?.currentSection == .apps,launcher?.canLaunchSelectedApp == true else {return};launcher?.launchAction()}
    @objc func createSelectedMacApp() {guard launcher?.window?.isKeyWindow == true,launcher?.launcherUI?.currentSection == .apps,launcher?.canLaunchSelectedApp == true else {return};launcher?.createWrapper()}
    @objc func addDeviceApps() {launcher?.showWorkspace(.deviceSettings);launcher?.onboardDeviceApps()}
    @objc func restoreSessions() {launcher?.showWorkspace(.sessions);launcher?.restoreAction()}
    @objc func showDiagnostics() {launcher?.showWorkspace(.diagnostics)}
    @objc func openLogs() {launcher?.openDiagnostics()}
    @objc func showReleaseInformation() {launcher?.showWorkspace(.delivery)}
    @objc func performTaskCommand(_ item:NSMenuItem) {guard launcher?.window?.isKeyWindow == true,let raw=item.representedObject as? String,let command=CompanionTaskCommand(rawValue:raw) else {return};launcher?.companion.windowController?.perform(command)}
    @objc func showHelp() {DesktopSettingsWindowController.openResource("README",extension:"md")}
    @objc func showPrivacy() {DesktopSettingsWindowController.openResource("PRIVACY",extension:"md")}
    @objc func showNotices() {DesktopSettingsWindowController.openNotices()}
    @objc func showSupport() {NSWorkspace.shared.open(URL(string:"https://github.com/SloopWorks/DroidBridge/issues")!)}
    func menuNeedsUpdate(_ menu:NSMenu) {if menu === audioMenu {updateAudioMenu()}}
    func updateAudioMenu() {
        audioMenu.removeAllItems()
        guard let launcher else {return}
        let device=launcher.audioMenuDevice(),state=launcher.audioControls.presentation(for:device?.serial)
        func note(_ text:String) {let item=NSMenuItem(title:String(text.prefix(180)),action:nil,keyEquivalent:"");item.isEnabled=false;item.toolTip=text;audioMenu.addItem(item)}
        note(device.map {"Audio for \($0.model)"} ?? "Select an Android device")
        note("Device-wide · includes other Android apps")
        audioMenu.addItem(.separator())
        for (name,route) in [("Mac",DeviceAudioRoute.mac),("Phone",.phone),("Mac + Phone",.macAndPhone)] {
            let item=NSMenuItem(title:name,action:#selector(selectAudioMenuRoute(_:)),keyEquivalent:"")
            item.target=self;item.representedObject=route.rawValue;item.state=state.route == route ? .on : .off
            item.isEnabled=device != nil && (route == .phone || device.map {launcher.readySerials.contains($0.serial)} == true)
            audioMenu.addItem(item)
        }
        audioMenu.addItem(.separator());note(state.title);note(state.message)
        if state.phase == .ready {note("Output initialized; sound depends on the Android app and Mac volume.")}
        if state.phase == .failed {
            let retry=NSMenuItem(title:"Retry Audio",action:#selector(retryMenuAudio),keyEquivalent:"");retry.target=self;retry.isEnabled=state.canRetry && device != nil;audioMenu.addItem(retry)
            let phone=NSMenuItem(title:"Use Phone",action:#selector(usePhoneMenuAudio),keyEquivalent:"");phone.target=self;phone.isEnabled=state.canUsePhone && device != nil;audioMenu.addItem(phone)
        }
    }
    @objc func selectAudioMenuRoute(_ sender:NSMenuItem) {
        guard let launcher,let device=launcher.audioMenuDevice(),let raw=sender.representedObject as? String,let route=DeviceAudioRoute(rawValue:raw) else {return}
        launcher.setAudioRoute(route,device:device)
    }
    @objc func retryMenuAudio() {if let launcher,let device=launcher.audioMenuDevice() {launcher.audioControls.retry(serial:device.serial)}}
    @objc func usePhoneMenuAudio() {if let launcher,let device=launcher.audioMenuDevice() {launcher.setAudioRoute(.phone,device:device)}}
    @objc func turnPhoneScreenOff() {launcher?.turnPhoneScreenOff()}
    @objc func turnPhoneScreenOn() {launcher?.turnPhoneScreenOn()}
    @objc func showLauncher() { launcher?.showWindow(nil); launcher?.window?.makeKeyAndOrderFront(nil);launcher?.refreshDevices(forceApps:true) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { launcher?.reopen(); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor in
            await launcher?.shutdownAndWait()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
MainActor.assumeIsolated {
    CompanionLaunchTrace.record("app_entry")
    let application = NSApplication.shared
    CompanionLaunchTrace.record("appkit_shared_ready")
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
