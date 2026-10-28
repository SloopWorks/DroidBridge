import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var launcher: LauncherController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let applicationName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "DroidBridge"
        if let url = Bundle.main.url(forResource: "AndroidApp", withExtension: "icns"), let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
        let appMenu = NSMenu()
        let root = NSMenuItem(); root.submenu = appMenu
        let menu = NSMenu(); menu.addItem(root)
        appMenu.addItem(withTitle: "About \(applicationName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(applicationName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); edit.title = "Edit"; edit.submenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.submenu?.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        menu.addItem(edit)
        let windowItem = NSMenuItem(); windowItem.title = "Window"
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Launcher", action: #selector(showLauncher), keyEquivalent: "l").target = self
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu; menu.addItem(windowItem); NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = menu
        launcher = LauncherController()
        launcher.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in
            let recovery = await BridgeSession.recoverAbandonedSessions(toolchain: launcher.toolchain)
            if !recovery.isEmpty { launcher.status.stringValue = recovery.joined(separator: " · ") }
            launcher.beginPolling()
        }
    }
    @objc func showLauncher() { launcher?.showWindow(nil); launcher?.window?.makeKeyAndOrderFront(nil) }
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
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) { application.run() }
}
