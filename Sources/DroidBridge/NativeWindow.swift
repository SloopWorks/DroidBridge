import AppKit
import CryptoKit
import DroidBridgeCore
import DroidBridgeStreaming

/// A video view with one aspect-fit transform shared by drawing and all pointer events.
@MainActor
final class AndroidVideoView: NSView {
    var frameImage: CGImage? { didSet { updateLoading(); needsDisplay = true } }
    var applicationName = "Android app" { didSet {updateLoading()} }
    var applicationIcon: NSImage?
    let progress = NSProgressIndicator()
    let revealVideoButton = NSButton(title:"Show Android Screen",target:nil,action:nil)
    var canRevealVideo = false {didSet {revealVideoButton.isHidden = !canRevealVideo}}
    var onRevealVideo: (() -> Void)?
    @objc private func revealVideo(_ sender:Any?) {onRevealVideo?()}
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        progress.style = .spinning; progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        addSubview(progress)
        revealVideoButton.bezelStyle = .rounded;revealVideoButton.target=self;revealVideoButton.action=#selector(revealVideo(_:));revealVideoButton.isHidden=true
        addSubview(revealVideoButton)
        updateLoading()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func layout() {
        super.layout()
        progress.frame = NSRect(x: bounds.midX - 8, y: bounds.height < 360 ? bounds.height-28 : bounds.midY+86, width: 16, height: 16)
        revealVideoButton.frame=NSRect(x:max(8,bounds.midX-90),y:min(bounds.midY+125,bounds.height-40),width:min(180,bounds.width-16),height:28)
    }
    func updateLoading() {
        if frameImage == nil && statusMessage == nil { progress.startAnimation(nil) }
        else { progress.stopAnimation(nil) }
        setAccessibilityLabel(statusMessage ?? (frameImage == nil ? "Loading \(applicationName)" : applicationName))
    }
    var loadingMessage = "Connecting to Android…" { didSet { updateLoading();needsDisplay = true } }
    var input: ((AndroidInputEvent) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { true }
    var statusMessage: String? { didSet { updateLoading(); needsDisplay = true } }
    var acceptsAndroidInput: Bool {frameImage != nil && statusMessage == nil}
    var dragging = false
    var videoRect: NSRect {
        guard let image = frameImage else { return bounds }
        return InputGeometry.aspectFitRect(videoWidth: image.width, videoHeight: image.height, bounds: bounds)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let frameImage, statusMessage == nil else {
            NSColor.windowBackgroundColor.setFill(); bounds.fill()
            let compact=bounds.height<360
            let extent:CGFloat=compact ? 48 : 96
            let icon = applicationIcon ?? NSImage(systemSymbolName: "apps.iphone", accessibilityDescription: nil)
            icon?.draw(in: NSRect(x: bounds.midX - extent/2, y: bounds.midY - (compact ? 90 : 110), width: extent, height: extent), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
            (applicationName as NSString).draw(in: NSRect(x: 20, y: bounds.midY + (compact ? -31 : 5), width: max(0,bounds.width - 40), height: compact ? 22 : 30), withAttributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: compact ? 16 : 22, weight: .semibold), .paragraphStyle: paragraph])
            let messageY=bounds.midY+(compact ? -4 : 43)
            let messageHeight=max(0,min(70,bounds.height-messageY-(canRevealVideo ? 48 : 32)))
            ((statusMessage ?? loadingMessage) as NSString).draw(in: NSRect(x: 24, y: messageY, width: max(0,bounds.width - 48), height: messageHeight), withAttributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: compact ? 11 : 13), .paragraphStyle: paragraph])
            return
        }
        NSColor.black.setFill(); bounds.fill()
        NSImage(cgImage: frameImage, size: NSSize(width: frameImage.width, height: frameImage.height)).draw(in: videoRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
    func point(_ event: NSEvent, clamp: Bool = false) -> (Int, Int, Int, Int)? {
        guard let image = frameImage, statusMessage == nil else { return nil }
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
    override func rightMouseDown(with event: NSEvent) { if acceptsAndroidInput {input?(.back)} }
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
    func key(_ code: UInt32, action: UInt8 = 0, meta: UInt32 = 0) { guard acceptsAndroidInput else {return};input?(.key(action: action, keycode: code, metastate: meta)) }
    override func keyDown(with event: NSEvent) {
        guard acceptsAndroidInput else {return}
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
    @objc func paste(_ sender: Any?) { guard acceptsAndroidInput else {return};if let text = NSPasteboard.general.string(forType: .string) { input?(.clipboard(text, paste: true)) } }
    @objc override func selectAll(_ sender: Any?) { key(29, meta: 0x1000); key(29, action: 1, meta: 0x1000) }
}

@MainActor
final class NativeWindowController: NSWindowController, NSWindowDelegate {
    static var nextCascade: NSPoint = .zero
    let video = AndroidVideoView()
    private(set) var session: BridgeSession!
    let frameName: String
    var onClose: (() -> Void)?
    var resizing: DispatchWorkItem?
    private var pendingBlankFrame:CGImage?
    private var firstBlankFrameAt: Double?
    private var blankNoticeTask: Task<Void,Never>?
    private var initialBlankFrames=0
    private var blankVideoNotice = false
    private var opticalCorrection: (x:CGFloat,y:CGFloat,width:CGFloat,height:CGFloat)?
    convenience init(session: BridgeSession) {
        self.init(deviceSerial: session.descriptor.device.serial, application: session.descriptor.application, configuration: session.descriptor.configuration)
        attach(session)
    }
    init(deviceSerial: String, application: AndroidApplication, configuration config: SessionConfiguration, icon: NSImage? = nil) {
        frameName = "AndroidApp." + SHA256.hash(data: Data((deviceSerial + ":" + application.packageName).utf8)).map { String(format:"%02x",$0) }.joined()
        video.applicationName = application.name
        video.applicationIcon = icon
        let size = NSSize(width: CGFloat(config.width) * 0.65, height: CGFloat(config.height) * 0.65)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = application.name
        window.minSize = NSSize(width: 240, height: 240)
        window.contentView = video
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.managed, .fullScreenPrimary]
        super.init(window: window)
        window.center()
        Self.nextCascade = window.cascadeTopLeft(from: Self.nextCascade)
        if window.setFrameUsingName(frameName) {
            // A removed display must not strand the restored window offscreen.
            if let screen = window.screen ?? NSScreen.main {
                let visible = screen.visibleFrame
                var frame = window.frame
                frame.size.width = min(max(240,frame.width), visible.width)
                frame.size.height = min(max(240,frame.height), visible.height)
                frame.origin.x = min(max(frame.minX,visible.minX),visible.maxX-frame.width)
                frame.origin.y = min(max(frame.minY,visible.minY),visible.maxY-frame.height)
                window.setFrame(frame, display:false)
            }
        }
        window.setFrameAutosaveName(frameName)
        window.delegate = self
    }
    func attach(_ session: BridgeSession) {
        self.session = session
        video.onRevealVideo={ [weak self] in
            guard let self,let image=self.pendingBlankFrame,self.session?.state == .running else {return}
            self.video.statusMessage=nil;self.video.canRevealVideo=false;self.blankVideoNotice=false
            self.video.frameImage=image;self.pendingBlankFrame=nil;self.blankNoticeTask?.cancel();self.blankNoticeTask=nil
            self.session?.recordClientEvent("native_blank_video_revealed",details:["window_number":String(self.window?.windowNumber ?? -1)])
            self.resizeDisplay()
        }
        video.input = { [weak session] event in session?.sendInput(event) }
        session.onStartupProgress = { [weak video] message in video?.loadingMessage = message }
        session.onFrame = { [weak self] frame in
            guard let self else { return }
            let first = self.video.frameImage == nil
            if first && !StartupFrameVisibility.hasVisibleContent(frame) {
                self.initialBlankFrames += 1;self.pendingBlankFrame=frame
                if self.firstBlankFrameAt == nil {
                    self.firstBlankFrameAt=ProcessInfo.processInfo.systemUptime
                    self.blankNoticeTask=Task { [weak self] in
                        do {try await Task.sleep(for:.seconds(5))} catch {return}
                        guard let self,self.video.frameImage == nil,self.session?.state == .running else {return}
                        self.video.statusMessage="Android video is blank.\nThe app may still be starting.\nOpen Window → Launcher for diagnostics."
                        self.blankVideoNotice=true;self.video.canRevealVideo=true
                    }
                }
                self.video.loadingMessage="Waiting for \(self.video.applicationName) to draw…"
                return
            }
            if self.blankVideoNotice {self.video.statusMessage=nil;self.blankVideoNotice=false}
            self.video.frameImage = frame;self.pendingBlankFrame=nil;self.video.canRevealVideo=false
            if first {
                self.blankNoticeTask?.cancel();self.blankNoticeTask=nil
                self.session?.recordClientEvent("native_content_presented",details:["window_number":String(self.window?.windowNumber ?? -1),"initial_blank_frames":String(self.initialBlankFrames)])
                self.resizeDisplay()
            }
        }
    }
    func prepareExternalHandoff() {
        guard let window,let screen=NSScreen.screens.first else {return}
        // macOS may report the optical WindowServer rectangle, inset from the
        // true AppKit frame. Calibrate on our own same-style window, never a
        // hardcoded titlebar/shadow size or another application's geometry.
        if let info=(CGWindowListCopyWindowInfo(.optionIncludingWindow,CGWindowID(window.windowNumber)) as? [[String:Any]])?.first,
           let dictionary=info[kCGWindowBounds as String] as? [String:Any],let optical=CGRect(dictionaryRepresentation:dictionary as CFDictionary) {
            let actual=CGRect(x:window.frame.minX,y:screen.frame.maxY-window.frame.maxY,width:window.frame.width,height:window.frame.height)
            let delta=(x:actual.minX-optical.minX,y:actual.minY-optical.minY,width:actual.width-optical.width,height:actual.height-optical.height)
            if [delta.x,delta.y,delta.width,delta.height].allSatisfy({$0.isFinite && abs($0)<100}) {opticalCorrection=delta}
        }
        onClose=nil
        window.delegate=nil
        close()
    }
    func rememberExternalFrame(_ optical:CGRect) {
        guard let window, let main=NSScreen.screens.first,let delta=opticalCorrection else {return}
        let bounds=CGRect(x:optical.minX+delta.x,y:optical.minY+delta.y,width:optical.width+delta.width,height:optical.height+delta.height)
        window.setFrame(NSRect(x:bounds.minX,y:main.frame.maxY-bounds.maxY,width:bounds.width,height:bounds.height),display:false)
        window.saveFrame(usingName:frameName)
    }
    func resizeDisplay() {
        guard let session else { return }
        let size = video.bounds.size
        let scale = min(1.5, 1600 / max(size.width, size.height))
        session.resize(width: max(240, Int(size.width * scale) / 8 * 8), height: max(240, Int(size.height * scale) / 8 * 8))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    func windowDidResize(_ notification: Notification) {
        resizing?.cancel()
        window?.saveFrame(usingName: frameName)
        let item = DispatchWorkItem { [weak self] in self?.resizeDisplay() }
        resizing = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }
    func windowDidMove(_ notification: Notification) { window?.saveFrame(usingName: frameName) }
    func windowWillClose(_ notification: Notification) { blankNoticeTask?.cancel();blankNoticeTask=nil;window?.saveFrame(usingName: frameName); resizing?.cancel(); onClose?() }
}
