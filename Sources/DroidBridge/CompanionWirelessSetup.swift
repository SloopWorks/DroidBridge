import AppKit
import Darwin
import DroidBridgeCore

@MainActor final class CompanionWirelessSetup: NSWindowController, NSWindowDelegate {
    private let tools: Toolchain
    private let address = NSTextField(string: "")
    private let code = NSSecureTextField(string: "")
    private let connection = NSTextField(string: "")
    private let status = NSTextField(wrappingLabelWithString: "Pair first, then connect using the separate IP address and port on the Wireless debugging screen.")
    private let pairButton = NSButton(title: "Pair", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel Operation", target: nil, action: nil)
    private var operation: Task<Void, Never>?
    var onConnected: (() -> Void)?

    init(tools: Toolchain) {
        self.tools = tools
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Connect over Wi-Fi"; window.contentMinSize = NSSize(width: 500, height: 380); window.contentView = LauncherBackground(); window.center()
        super.init(window: window); window.delegate = self
        let heading = NSTextField(wrappingLabelWithString: "On Android, open Developer options → Wireless debugging. Enable it, then choose Pair device with pairing code. Both devices must be on a network that allows their connection.")
        address.placeholderString = "Pairing IP address:port"; address.setAccessibilityLabel("Wireless ADB pairing address")
        code.placeholderString = "Six-digit pairing code"; code.setAccessibilityLabel("Wireless ADB pairing code")
        connection.placeholderString = "Connection IP address:port"; connection.setAccessibilityLabel("Wireless ADB connection address")
        pairButton.target = self; pairButton.action = #selector(pair)
        connectButton.target = self; connectButton.action = #selector(connect)
        cancelButton.target = self; cancelButton.action = #selector(cancel); cancelButton.isEnabled = false
        code.target = self; code.action = #selector(pair); connection.target = self; connection.action = #selector(connect)
        address.nextKeyView = code; code.nextKeyView = pairButton; pairButton.nextKeyView = connection; connection.nextKeyView = connectButton
        let pairRow = NSStackView(views: [address, code, pairButton]); pairRow.spacing = 8
        code.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let connectRow = NSStackView(views: [connection, connectButton]); connectRow.spacing = 8
        let note = NSTextField(wrappingLabelWithString: "ADB pairing authorizes broad Android debugging access. Pair only a trusted Mac. Companion pairing is a separate confirmation inside the DroidBridge Android app. This does not expose the companion API to the network.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 0; status.lineBreakMode = .byWordWrapping; status.setAccessibilityLabel("Wireless connection result")
        let content = NSStackView(views: [heading, NSTextField(wrappingLabelWithString: "1. Pair Android debugging · pairing address and six-digit code"), pairRow, NSTextField(wrappingLabelWithString: "2. Connect · address and port on the main Wireless debugging screen"), connectRow, status, cancelButton, note])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 15
        content.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = LauncherDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(content); scroll.documentView = document; window.contentView?.addSubview(scroll)
        if let view = window.contentView { NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)]) }
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22), content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22), content.topAnchor.constraint(equalTo: document.topAnchor, constant: 22), content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22)])
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func pair() {
        do {
            let endpoint = try CompanionWirelessEndpoint(address.stringValue)
            let secret = code.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard secret.count == 6, secret.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw BridgeError.message("Enter the six-digit pairing code currently shown on the phone.") }
            code.stringValue = ""
            start { [tools] in try await CompanionWirelessADB.pair(adb: tools.adb, endpoint: endpoint, code: secret) }
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func connect() {
        do {
            let endpoint = try CompanionWirelessEndpoint(connection.stringValue)
            start(connected: true) { [tools] in try await CompanionWirelessADB.connect(adb: tools.adb, endpoint: endpoint) }
        } catch { status.stringValue = error.localizedDescription }
    }

    private func start(connected: Bool = false, action: @escaping @Sendable () async throws -> String) {
        guard operation == nil else { return }
        pairButton.isEnabled = false; connectButton.isEnabled = false; cancelButton.isEnabled = true
        status.stringValue = "Waiting for Android wireless debugging…"
        operation = Task { [weak self] in
            do {
                let result = try await action(); try Task.checkCancellation()
                self?.status.stringValue = result
                if connected { self?.onConnected?() }
            } catch {
                self?.status.stringValue = error is CancellationError ? "Operation cancelled. Retry using the current address and code shown on Android." : error.localizedDescription
            }
            self?.operation = nil; self?.pairButton.isEnabled = true; self?.connectButton.isEnabled = true; self?.cancelButton.isEnabled = false
        }
    }
    @objc func cancel() { operation?.cancel() }
    func shutdown() { cancel(); code.stringValue = "" }
    func shutdownAndWait() async { shutdown(); await operation?.value }
    func windowWillClose(_ notification: Notification) { shutdown() }
}
