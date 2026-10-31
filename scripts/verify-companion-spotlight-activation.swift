/// Disposable public CoreSpotlight/NSUserActivity diagnostic. Never links
/// production DroidBridge, launches Android, or changes global index settings.
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

@MainActor final class SpotlightProbeDelegate: NSObject, NSApplicationDelegate {
    let root: URL, identifier: String, itemTitle: String, index: CSSearchableIndex
    var window: NSWindow!, status = NSTextField(wrappingLabelWithString: "No synthetic item indexed yet.")
    init(root: URL, identifier: String, title: String) {
        self.root = root; self.identifier = identifier; self.itemTitle = title
        self.index = CSSearchableIndex(name: "DroidBridgeActivationQA-" + identifier)
        super.init()
    }
    func record(_ kind: String, _ fields: [String: Any] = [:]) {
        var value = fields; value["event"] = kind; value["uptime"] = ProcessInfo.processInfo.systemUptime
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        let url = root.appendingPathComponent("events.jsonl")
        let old = (try? Data(contentsOf: url)) ?? Data()
        guard old.count + data.count < 65_536 else { return }
        try? (old + data + Data([10])).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), top = NSMenuItem(); top.submenu = NSMenu(); top.submenu?.addItem(withTitle: "Quit Spotlight QA", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); menu.addItem(top); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 280), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "DroidBridge Spotlight Activation QA"
        let title = NSTextField(wrappingLabelWithString: itemTitle)
        title.setAccessibilityLabel("Synthetic Spotlight query")
        let indexButton = NSButton(title: "Index Synthetic Item", target: self, action: #selector(indexItem))
        let deleteButton = NSButton(title: "Delete Synthetic Item", target: self, action: #selector(deleteItem))
        let content = NSStackView(views: [title, indexButton, deleteButton, status]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 18; content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content); NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24), content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24), content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)])
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        record("app_started", ["bundle_id": Bundle.main.bundleIdentifier!, "item_id": identifier, "query": itemTitle])
    }
    @objc func indexItem() {
        let attrs = CSSearchableItemAttributeSet(contentType: .text); attrs.title = itemTitle; attrs.contentDescription = "Synthetic DroidBridge QA activation item. No personal content."
        let item = CSSearchableItem(uniqueIdentifier: identifier, domainIdentifier: "droidbridge-activation-qa", attributeSet: attrs); item.expirationDate = Date().addingTimeInterval(900)
        Task { do { try await index.indexSearchableItems([item]); status.stringValue = "Synthetic index request accepted. Search its exact title in Spotlight."; record("indexed", ["item_id": identifier]) }
            catch { status.stringValue = error.localizedDescription; record("index_failed", ["error": error.localizedDescription]) } }
    }
    @objc func deleteItem() {
        Task { do { try await index.deleteSearchableItems(withIdentifiers: [identifier]); status.stringValue = "Exact synthetic item deleted. Check Spotlight again."; record("deleted", ["item_id": identifier]) }
            catch { status.stringValue = error.localizedDescription; record("delete_failed", ["error": error.localizedDescription]) } }
    }
    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        let matched = userActivity.activityType == CSSearchableItemActionType && userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String == identifier
        record("spotlight_activation", ["matched": matched, "activity_type": userActivity.activityType])
        guard matched else { return false }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); status.stringValue = "Activated from Spotlight with the exact synthetic item identifier."; return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { do { try await index.deleteSearchableItems(withIdentifiers: [identifier]); record("cleanup_confirmed", ["item_id": identifier]) }
            catch { record("cleanup_failed", ["error": error.localizedDescription]) }; NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
@main struct SpotlightActivationQA {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 2, Bundle.main.bundleIdentifier?.hasPrefix("dev.droidbridge.qa.spotlight.activation.") == true else { throw NSError(domain: "Explicit isolated QA bundle required", code: 1) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        let attrs = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attrs[.posixPermissions] as? Int == 0o700, attrs[.ownerAccountID] as? UInt32 == getuid() else { throw NSError(domain: "Owned private probe root required", code: 2) }
        let config = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("config.json"))) as! [String: String]
        guard let id = config["item_id"], UUID(uuidString: id) != nil, let title = config["title"], title.hasPrefix("DroidBridgeZebraQA"), title.utf8.count < 64 else { throw NSError(domain: "Synthetic probe identity required", code: 3) }
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let delegate = SpotlightProbeDelegate(root: root, identifier: id, title: title); app.delegate = delegate; withExtendedLifetime(delegate) { app.run() }
    }
}
