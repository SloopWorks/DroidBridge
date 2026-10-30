import AppKit
import Darwin

// Test-only lower bound: no DroidBridge modules, ADB, broker or product prefs.
@MainActor final class BaselineDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var phases: [String: Double]
    let output: URL
    init(phases: [String: Double], output: URL) { self.phases = phases; self.output = output }
    func record(_ name: String) {
        phases[name] = ProcessInfo.processInfo.systemUptime
    }
    func flush() {
        try? JSONSerialization.data(withJSONObject: phases, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
    }
    func applicationWillFinishLaunching(_ notification: Notification) {
        record("will_finish_launching")
        NSApp.setActivationPolicy(.regular)
        let host = NSWindow(contentRect: NSRect(x: 240, y: 180, width: 480, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        host.title = "DroidBridge AppKit Baseline"; host.isRestorable = false
        let label = NSTextField(labelWithString: "Loading Android application…")
        label.frame = NSRect(x: 24, y: 350, width: 400, height: 24)
        host.contentView?.addSubview(label); window = host
        record("window_constructed")
        host.makeKeyAndOrderFront(nil)
        record("window_ordered"); flush()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        record("did_finish_launching"); flush()
        NSApp.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in MainActor.assumeIsolated { NSApp.terminate(nil) } }
    }
}
MainActor.assumeIsolated {
    guard CommandLine.arguments.count == 3 else { exit(64) }
    let root = URL(fileURLWithPath: CommandLine.arguments[1]), output = URL(fileURLWithPath: CommandLine.arguments[2])
    var metadata = stat()
    guard lstat(root.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o700,
          root.path == root.resolvingSymlinksInPath().path, output.deletingLastPathComponent() == root, output.lastPathComponent == "phases.json" else { exit(65) }
    umask(0o077)
    var phases = ["app_entry": ProcessInfo.processInfo.systemUptime, "pid": Double(getpid())]
    let app = NSApplication.shared
    phases["appkit_shared_ready"] = ProcessInfo.processInfo.systemUptime
    let delegate = BaselineDelegate(phases: phases, output: output)
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
