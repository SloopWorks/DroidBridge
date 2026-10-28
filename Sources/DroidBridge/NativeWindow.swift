import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

/// A video view with one aspect-fit transform shared by drawing and all pointer events.
@MainActor
final class AndroidVideoView: NSView {
    var frameImage: CGImage? { didSet { needsDisplay = true } }
    var input: ((AndroidInputEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }
    var statusMessage: String? { didSet { needsDisplay = true } }
    var dragging = false
    var videoRect: NSRect {
        guard let image = frameImage else { return bounds }
        return InputGeometry.aspectFitRect(videoWidth: image.width, videoHeight: image.height, bounds: bounds)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard let frameImage, statusMessage == nil else {
            let text = (statusMessage ?? "Connecting to Android…") as NSString
            text.draw(at: NSPoint(x: 24, y: 24), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 15)])
            return
        }
        NSImage(cgImage: frameImage, size: NSSize(width: frameImage.width, height: frameImage.height)).draw(in: videoRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
    func point(_ event: NSEvent, clamp: Bool = false) -> (Int, Int, Int, Int)? {
        guard let image = frameImage else { return nil }
        let p = convert(event.locationInWindow, from: nil), rect = videoRect
        guard let mapped = InputGeometry.coordinates(point: p, rect: rect, videoWidth: image.width, videoHeight: image.height, clamp: clamp) else { return nil }
        return (mapped.x, mapped.y, image.width, image.height)
    }
    func touch(_ event: NSEvent, action: UInt8) {
        guard let (x,y,w,h) = point(event, clamp: action != 0) else { return }
        input?(.touch(action: action, x: x, y: y, width: w, height: h))
    }
    override func mouseDown(with event: NSEvent) { guard point(event) != nil else { return }; dragging = true; window?.makeFirstResponder(self); touch(event, action: 0) }
    override func mouseDragged(with event: NSEvent) { if dragging { touch(event, action: 2) } }
    override func mouseUp(with event: NSEvent) { if dragging { touch(event, action: 1); dragging = false } }
    override func rightMouseDown(with event: NSEvent) { input?(.back) }
    override func scrollWheel(with event: NSEvent) {
        guard let (x,y,w,h) = point(event) else { return }
        input?(.scroll(x: x, y: y, width: w, height: h, horizontal: Double(event.scrollingDeltaX) / 30, vertical: Double(event.scrollingDeltaY) / 30))
    }
    func androidKey(_ event: NSEvent) -> UInt32? {
        switch event.keyCode {
        case 36, 76: return 66
        case 48: return 61
        case 51: return 67
        case 117: return 112
        case 53: return 4
        case 123: return 21
        case 124: return 22
        case 125: return 20
        case 126: return 19
        case 115: return 122
        case 119: return 123
        case 116: return 92
        case 121: return 93
        default: return nil
        }
    }
    func key(_ code: UInt32, action: UInt8 = 0, meta: UInt32 = 0) { input?(.key(action: action, keycode: code, metastate: meta)) }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": if let text = NSPasteboard.general.string(forType: .string) { input?(.clipboard(text, paste: true)) }
            case "a": key(29, meta: 0x1000); key(29, action: 1, meta: 0x1000)
            case "c": key(31, meta: 0x1000); key(31, action: 1, meta: 0x1000)
            case "x": key(52, meta: 0x1000); key(52, action: 1, meta: 0x1000)
            default: super.keyDown(with: event)
            }
        } else if let code = androidKey(event) { key(code, meta: event.modifierFlags.contains(.shift) ? 1 : 0) }
        else if let chars = event.characters, !chars.isEmpty { input?(.text(chars)) }
    }
    override func keyUp(with event: NSEvent) { if let code = androidKey(event) { key(code, action: 1) } }
    @objc func copy(_ sender: Any?) { key(31, meta: 0x1000); key(31, action: 1, meta: 0x1000) }
    @objc func cut(_ sender: Any?) { key(52, meta: 0x1000); key(52, action: 1, meta: 0x1000) }
    @objc func paste(_ sender: Any?) { if let text = NSPasteboard.general.string(forType: .string) { input?(.clipboard(text, paste: true)) } }
    @objc override func selectAll(_ sender: Any?) { key(29, meta: 0x1000); key(29, action: 1, meta: 0x1000) }
}

@MainActor
final class NativeWindowController: NSWindowController, NSWindowDelegate {
    static var nextCascade: NSPoint = .zero
    let video = AndroidVideoView()
    let session: BridgeSession
    var onClose: (() -> Void)?
    var resizing: DispatchWorkItem?
    init(session: BridgeSession) {
        self.session = session
        let config = session.descriptor.configuration
        let size = NSSize(width: CGFloat(config.width) * 0.65, height: CGFloat(config.height) * 0.65)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = session.descriptor.application.name + " — DroidBridge"
        window.minSize = NSSize(width: 240, height: 240)
        window.contentView = video
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        super.init(window: window)
        window.delegate = self
        window.center()
        Self.nextCascade = window.cascadeTopLeft(from: Self.nextCascade)
        video.input = { [weak session] event in session?.sendInput(event) }
        session.onFrame = { [weak video] frame in video?.frameImage = frame }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func windowDidResize(_ notification: Notification) {
        resizing?.cancel()
        let size = video.bounds.size
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Keep pixels bounded and independent of the host display backing scale.
            let scale = min(1.5, 1600 / max(size.width, size.height))
            self.session.resize(width: max(240, Int(size.width * scale) / 8 * 8), height: max(240, Int(size.height * scale) / 8 * 8))
        }
        resizing = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
    func windowWillClose(_ notification: Notification) { resizing?.cancel(); onClose?() }
}
