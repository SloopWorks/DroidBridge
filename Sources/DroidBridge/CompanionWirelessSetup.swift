import AppKit
import CoreImage.CIFilterBuiltins
import DroidBridgeCore

@MainActor final class CompanionWirelessSetup: NSWindowController, NSWindowDelegate {
    private let tools: Toolchain
    private let usbDevice: AndroidDevice?
    private let savedPhones = NSPopUpButton()
    private var profiles: [CompanionWirelessProfile] = []
    private let qrImage = NSImageView()
    private let qrButton = NSButton(title: "Show QR Code", target: nil, action: nil)
    private let usbButton = NSButton(title: "Use Connected USB Phone", target: nil, action: nil)
    private let reconnectButton = NSButton(title: "Reconnect Saved Phone", target: nil, action: nil)
    private let forgetButton = NSButton(title: "Forget Saved Phone", target: nil, action: nil)
    private let manualButton = NSButton(title: "Manual Setup…", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let address = NSTextField(string: "")
    private let code = NSSecureTextField(string: "")
    private let connection = NSTextField(string: "")
    private let pairButton = NSButton(title: "Pair", target: nil, action: nil)
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let manual = NSStackView()
    private let saved = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "Both devices must be on the same network.")
    private var operation: Task<Void, Never>?
    private var profileLoad: Task<Void, Never>?
    var onConnected: ((String?) -> Void)?

    init(tools: Toolchain, usbDevice: AndroidDevice?) {
        self.tools = tools
        self.usbDevice = usbDevice
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 630, height: 600), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Connect over Wi-Fi"
        window.contentMinSize = NSSize(width: 490, height: 380)
        window.contentView = LauncherBackground()
        window.center()
        super.init(window: window)
        window.delegate = self

        let heading = NSTextField(wrappingLabelWithString: "On Android, open Developer options → Wireless debugging. Turn it on, then choose Pair device with QR code and scan the code shown here.")
        heading.font = .systemFont(ofSize: 15, weight: .medium)
        qrImage.imageScaling = .scaleProportionallyUpOrDown
        qrImage.setAccessibilityLabel("Android wireless debugging pairing QR code")
        qrImage.heightAnchor.constraint(equalToConstant: 220).isActive = true
        qrImage.isHidden = true

        for (button, action) in [(qrButton, #selector(showQR)), (usbButton, #selector(useUSB)),
                                 (reconnectButton, #selector(reconnect)), (forgetButton, #selector(forget)),
                                 (manualButton, #selector(toggleManual)), (cancelButton, #selector(cancel)),
                                 (pairButton, #selector(pair)), (connectButton, #selector(connect))] {
            button.target = self; button.action = action; button.bezelStyle = .rounded
        }
        qrButton.keyEquivalent = "\r"
        usbButton.isHidden = usbDevice == nil
        usbButton.toolTip = "Enable Wireless debugging on your selected phone and keep USB plugged in until connected."
        cancelButton.isEnabled = false
        let actions = NSStackView(views: [qrButton, usbButton, cancelButton]); actions.spacing = 8
        saved.orientation = .vertical; saved.alignment = .leading; saved.spacing = 6
        savedPhones.setAccessibilityLabel("Saved Wi-Fi phones")
        let savedActions = NSStackView(views: [savedPhones, reconnectButton, forgetButton]); savedActions.spacing = 8
        saved.addArrangedSubview(NSTextField(labelWithString: "Saved Wi-Fi phones"))
        saved.addArrangedSubview(savedActions)
        saved.isHidden = true

        address.placeholderString = "Pairing IP address:port"; address.setAccessibilityLabel("Wireless ADB pairing address")
        code.placeholderString = "Six-digit pairing code"; code.setAccessibilityLabel("Wireless ADB pairing code")
        connection.placeholderString = "Connection IP address:port"; connection.setAccessibilityLabel("Wireless ADB connection address")
        code.target = self; code.action = #selector(pair); connection.target = self; connection.action = #selector(connect)
        let pairRow = NSStackView(views: [address, code, pairButton]); pairRow.spacing = 8
        code.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let connectRow = NSStackView(views: [connection, connectButton]); connectRow.spacing = 8
        manual.orientation = .vertical; manual.alignment = .leading; manual.spacing = 8
        for view in [NSTextField(wrappingLabelWithString: "1. On Android choose Pair device with pairing code. Enter the pairing address and code."), pairRow,
                     NSTextField(wrappingLabelWithString: "2. If the phone cannot be found automatically, use its separate connection address."), connectRow] {
            manual.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: manual.widthAnchor).isActive = true
        }
        manual.isHidden = true
        let note = NSTextField(wrappingLabelWithString: "Wireless debugging authorizes this Mac to control Android apps. DroidBridge remembers paired phones and reconnects while the Mac app is open. Companion pairing is separate.")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 0; status.lineBreakMode = .byWordWrapping
        status.setAccessibilityLabel("Wireless connection result")
        let content = NSStackView(views: [heading, qrImage, actions, status, saved, manualButton, manual, note])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 14
        content.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = LauncherDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(content); scroll.documentView = document; window.contentView?.addSubview(scroll)
        if let view = window.contentView {
            NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        }
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22), content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22), content.topAnchor.constraint(equalTo: document.topAnchor, constant: 22), content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22)])
        for view in content.arrangedSubviews where view !== manualButton { view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func open() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        profileLoad?.cancel()
        profileLoad = Task { [weak self] in
            guard let self else { return }
            await self.reloadProfiles()
            guard !Task.isCancelled, self.window?.isVisible == true, self.operation == nil,
                  self.profiles.isEmpty, self.usbDevice == nil, self.manual.isHidden else { return }
            self.showQR()
        }
    }

    private func reloadProfiles() async {
        let list = (try? await CompanionWirelessReconnect.shared.profiles()) ?? []
        guard !Task.isCancelled else { return }
        let previous = selectedProfile?.serviceInstance
        profiles = list
        savedPhones.removeAllItems()
        for (index, profile) in profiles.enumerated() {
            let title = profiles.filter { $0.label == profile.label }.count > 1 ? "\(profile.label) \(index + 1)" : profile.label
            savedPhones.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        if let previous, let index = profiles.firstIndex(where: { $0.serviceInstance == previous }) { savedPhones.selectItem(at: index) }
        else if !profiles.isEmpty { savedPhones.selectItem(at: 0) }
        saved.isHidden = profiles.isEmpty
        updateControls()
    }

    private var selectedProfile: CompanionWirelessProfile? {
        let index = savedPhones.indexOfSelectedItem
        return profiles.indices.contains(index) ? profiles[index] : nil
    }

    @objc private func showQR() {
        guard operation == nil else { return }
        let invitation = CompanionWirelessQRInvitation()
        guard let image = Self.pairingImage(invitation) else {
            status.stringValue = "Could not create a QR code. Try again or use Manual Setup."
            return
        }
        qrImage.image = NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
        qrImage.isHidden = false
        manual.isHidden = true
        manualButton.title = "Manual Setup…"
        qrButton.title = "New QR Code"
        start("Scan the code with Android Wireless debugging. This code expires after 90 seconds.") {
            let pairing = try await CompanionWirelessADB.pair(adb: self.tools.adb, invitation: invitation, discoveryTimeout: 90)
            self.clearQR()
            try Task.checkCancellation()
            self.status.stringValue = "Android approved this Mac. Finding the phone’s Wi-Fi connection…"
            try Task.checkCancellation()
            do {
                let connected = try await CompanionWirelessReconnect.shared.connectNow(adb: self.tools.adb, pairing: pairing)
                await self.reloadProfiles()
                try Task.checkCancellation()
                self.showConnected(connected.serial)
            } catch is CancellationError { throw CancellationError() }
            catch { self.status.stringValue = "Android approved this Mac, but the Wi-Fi connection could not be verified. Keep Wireless debugging on and retry with a new QR code or USB. \(error.localizedDescription)" }
        }
    }

    static func pairingImage(_ invitation: CompanionWirelessQRInvitation) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(invitation.payload.utf8)
        filter.correctionLevel = "M"
        guard let qr = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)) else { return nil }
        let bounds = qr.extent.insetBy(dx: -24, dy: -24)
        let white = CIImage(color: .white).cropped(to: bounds)
        return CIContext().createCGImage(qr.composited(over: white), from: bounds)
    }

    @objc private func useUSB() {
        guard let usbDevice else { return }
        start("Checking the selected USB phone. Keep USB attached and turn on Wireless debugging on Android.") {
            let result = try await CompanionWirelessReconnect.connectUsingUSB(adb: self.tools.adb, serial: usbDevice.serial)
            try Task.checkCancellation()
            try await CompanionWirelessReconnect.shared.remember(serviceInstance: result.serviceInstance, label: usbDevice.model, connection: result.connection)
            await self.reloadProfiles()
            self.showConnected(result.connection.serial)
        }
    }

    @objc private func reconnect() {
        guard let profile = selectedProfile else { return }
        start("Looking for the saved phone. Keep Wireless debugging on and join the same network.") {
            let connected = try await CompanionWirelessReconnect.shared.connectNow(adb: self.tools.adb, serviceInstance: profile.serviceInstance)
            try Task.checkCancellation()
            self.showConnected(connected.serial)
        }
    }

    @objc private func forget() {
        guard let profile = selectedProfile else { return }
        start("Removing this phone from DroidBridge’s saved list…") {
            try await CompanionWirelessReconnect.shared.forget(serviceInstance: profile.serviceInstance)
            await self.reloadProfiles()
            self.status.stringValue = "Removed from DroidBridge. To revoke debugging access, forget this Mac in Android’s Wireless debugging settings."
        }
    }

    @objc private func toggleManual() {
        manual.isHidden.toggle()
        manualButton.title = manual.isHidden ? "Manual Setup…" : "Hide Manual Setup"
        if !manual.isHidden {
            cancel()
            status.stringValue = "Use the pairing address and code only if the QR or USB shortcut is unavailable."
            window?.makeFirstResponder(address)
        } else { code.stringValue = "" }
    }

    @objc private func pair() {
        do {
            let endpoint = try CompanionWirelessEndpoint(address.stringValue)
            let secret = code.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard secret.count == 6, secret.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw BridgeError.message("Enter the six-digit pairing code currently shown on the phone.") }
            code.stringValue = ""
            start("Waiting for Android to approve pairing…") {
                let pairing = try await CompanionWirelessADB.pairForDiscovery(adb: self.tools.adb, endpoint: endpoint, code: secret)
                try Task.checkCancellation()
                if let pairing {
                    self.status.stringValue = "Paired. Finding the phone’s Wi-Fi connection…"
                    do {
                        let connected = try await CompanionWirelessReconnect.shared.connectNow(adb: self.tools.adb, pairing: pairing, discoveryTimeout: 5)
                        await self.reloadProfiles()
                        try Task.checkCancellation()
                        self.showConnected(connected.serial)
                        return
                    } catch is CancellationError { throw CancellationError() }
                    catch { /* The explicit connection address is the fallback. */ }
                }
                self.status.stringValue = "Paired. Enter the connection address shown on the main Wireless debugging screen."
                self.window?.makeFirstResponder(self.connection)
            }
        } catch { status.stringValue = error.localizedDescription }
    }

    @objc private func connect() {
        do {
            let endpoint = try CompanionWirelessEndpoint(connection.stringValue)
            start("Connecting to Android over Wi-Fi…") {
                _ = try await CompanionWirelessADB.connect(adb: self.tools.adb, endpoint: endpoint)
                try Task.checkCancellation()
                self.showConnected(nil)
            }
        } catch { status.stringValue = error.localizedDescription }
    }

    private func showConnected(_ serial: String?) {
        guard !Task.isCancelled else { return }
        status.stringValue = "Connected over Wi-Fi. You can unplug USB when ready. Close any active USB app windows before reopening them over Wi-Fi."
        onConnected?(serial)
    }

    private func clearQR() {
        qrImage.image = nil
        qrImage.isHidden = true
    }

    private func updateControls() {
        let idle = operation == nil
        for button in [qrButton, usbButton, pairButton, connectButton] { button.isEnabled = idle }
        reconnectButton.isEnabled = idle && selectedProfile != nil
        forgetButton.isEnabled = idle && selectedProfile != nil
        savedPhones.isEnabled = idle
        cancelButton.isEnabled = !idle
    }

    private func start(_ message: String, action: @escaping @MainActor () async throws -> Void) {
        guard operation == nil else { return }
        status.stringValue = message
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.clearQR(); self.operation = nil; self.updateControls() }
            do { try await action() }
            catch is CancellationError {
                if self.window?.isVisible == true, self.manual.isHidden { self.status.stringValue = "Cancelled. Show a new QR code or reconnect a saved phone." }
            }
            catch { self.status.stringValue = error.localizedDescription }
        }
        updateControls()
    }

    @objc func cancel() { operation?.cancel(); clearQR() }
    func shutdown() { profileLoad?.cancel(); cancel(); code.stringValue = "" }
    func shutdownAndWait() async { shutdown(); await profileLoad?.value; await operation?.value }
    func windowWillClose(_ notification: Notification) { shutdown() }
}
