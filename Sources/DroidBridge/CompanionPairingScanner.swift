import AppKit
import AVFoundation
import Vision
import ImageIO
import DroidBridgeCore

private final class CompanionCameraDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private var lastScan = 0.0
    var onCode: ((String) -> Void)?
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastScan > 0.3, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastScan = now
        let request = VNDetectBarcodesRequest(); request.symbologies = [.qr]
        do {
            try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
            if let code = request.results?.compactMap(\.payloadStringValue).first { onCode?(code) }
        } catch { /* A damaged frame can be retried; content is never logged. */ }
    }
}

/// Session configuration/start/stop are serialized off the main actor. AppKit
/// only observes the session through the public preview layer.
private final class CompanionCameraCapture: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "DroidBridge.CompanionCamera")
    private var configured = false
    func start(detector: CompanionCameraDetector, completion: @escaping @Sendable (Bool) -> Void) {
        queue.async { [self] in
            if !configured {
                guard let camera = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { completion(false); return }
                session.beginConfiguration(); session.sessionPreset = .medium; session.addInput(input)
                let output = AVCaptureVideoDataOutput(); output.alwaysDiscardsLateVideoFrames = true
                guard session.canAddOutput(output) else { session.removeInput(input); session.commitConfiguration(); completion(false); return }
                output.setSampleBufferDelegate(detector, queue: queue); session.addOutput(output); session.commitConfiguration(); configured = true
            }
            if !session.isRunning { session.startRunning() }
            completion(session.isRunning)
        }
    }
    func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }
}

@MainActor final class CompanionPairingScanner: NSWindowController, NSWindowDelegate {
    private let camera = CompanionCameraCapture()
    private let detector = CompanionCameraDetector()
    private let preview = NSView()
    private let status = NSTextField(wrappingLabelWithString: "Scan with Camera, import a QR image, or paste the complete current pairing link. Its server fingerprint authenticates the phone; pairing still requires phone approval.")
    private let code = NSSecureTextField(string: "")
    private let cameraButton = NSButton(title: "Scan with Camera", target: nil, action: nil)
    private var previewAdded = false
    private var finished = false
    private var imageTask: Task<Void, Never>?
    var onPairCode: ((CompanionPairCode) -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Pair Android Companion"; window.contentMinSize = NSSize(width: 480, height: 380); window.contentView = LauncherBackground(); window.center()
        super.init(window: window); window.delegate = self
        cameraButton.target = self; cameraButton.action = #selector(scanCamera)
        let image = NSButton(title: "Import QR Image…", target: self, action: #selector(importImage))
        let actions = NSStackView(views: [cameraButton, image]); actions.spacing = 8
        code.placeholderString = "Complete current pairing link from Android"; code.setAccessibilityLabel("Companion pairing link")
        let useCode = NSButton(title: "Use Pairing Link", target: self, action: #selector(useManualCode))
        code.target = self; code.action = #selector(useManualCode); code.nextKeyView = useCode
        let manual = NSStackView(views: [code, useCode]); manual.spacing = 8
        preview.wantsLayer = true; preview.layer?.backgroundColor = NSColor.black.cgColor
        preview.heightAnchor.constraint(equalToConstant: 280).isActive = true
        preview.setAccessibilityLabel("QR camera preview")
        status.maximumNumberOfLines = 0; status.lineBreakMode = .byWordWrapping; status.setAccessibilityLabel("Pairing scanner status")
        let heading = NSTextField(wrappingLabelWithString: "On Android, open DroidBridge → Pair a New Mac. Import its QR or paste the complete pairing link, including the server fingerprint. The link expires after two minutes and differs from the six-digit wireless debugging code.")
        let content = NSStackView(views: [heading, actions, preview, manual, status]); content.orientation = .vertical; content.alignment = .leading; content.spacing = 15
        content.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = LauncherDocumentView(); document.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(content); scroll.documentView = document; window.contentView?.addSubview(scroll)
        if let view = window.contentView { NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor)]) }
        NSLayoutConstraint.activate([document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 22), content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -22), content.topAnchor.constraint(equalTo: document.topAnchor, constant: 22), content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -22)])
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        detector.onCode = { [weak self] value in Task { @MainActor in self?.accept(value) } }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func useManualCode() { let value = code.stringValue; code.stringValue = ""; accept(value) }
    private func accept(_ text: String) {
        guard !finished else { return }
        do {
            let value = try CompanionPairCode(text)
            finished = true; imageTask?.cancel(); stopCamera(); code.stringValue = ""
            onPairCode?(value); close()
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func scanCamera() {
        guard !finished else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil else {
            status.stringValue = "Camera scanning is unavailable in this development build. Import an image or enter the code instead."; return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in Task { @MainActor in
                if allowed { self?.startCamera() } else { self?.status.stringValue = "Camera access was denied. Import a QR image or enter the code; you can change camera access in System Settings." }
            } }
        default: status.stringValue = "Camera access is unavailable. Import a QR image or enter the code instead."
        }
    }
    private func startCamera() {
        guard !finished else { return }
        cameraButton.isEnabled = false
        status.stringValue = "Starting camera…"
        camera.start(detector: detector) { [weak self] running in Task { @MainActor in
            guard let self, !self.finished else { return }
            guard running else { self.cameraButton.isEnabled = true; self.status.stringValue = "No usable camera was found. Import a QR image or enter the code."; return }
            if !self.previewAdded {
                let layer = AVCaptureVideoPreviewLayer(session: self.camera.session); layer.videoGravity = .resizeAspectFill; layer.frame = self.preview.bounds; layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]; self.preview.layer?.addSublayer(layer); self.previewAdded = true
            }
            self.status.stringValue = "Point the camera at the current pairing QR code on the phone. No camera image is stored or sent."
        } }
    }
    private func stopCamera() { camera.stop() }
    @objc private func importImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] result in
            guard result == .OK, let url = panel.url, let self else { return }
            self.imageTask?.cancel(); self.status.stringValue = "Reading QR image…"
            self.imageTask = Task { [weak self] in
                do {
                    let text = try await Task.detached(priority: .userInitiated) { try CompanionQRImageReader.read(url) }.value
                    guard !Task.isCancelled else { return }; self?.accept(text)
                } catch { if !Task.isCancelled { self?.status.stringValue = error.localizedDescription } }
            }
        }
    }
    func windowWillClose(_ notification: Notification) { finished = true; imageTask?.cancel(); stopCamera(); code.stringValue = "" }
}
