import AppKit
import DroidBridgeCore

/// A copied Mach-O executable under a unique bundle gives Launch Services a real
/// independent application identity. Runtime resources remain shared with the host.
enum MacAppWrapper {
    static func create(application: AndroidApplication, device: AndroidDevice, backend: BackendKind) throws -> URL {
        guard let executable = Bundle.main.executableURL, Bundle.main.bundleURL.pathExtension == "app" else { throw BridgeError.message("Install DroidBridge.app before creating Mac app wrappers.") }
        let fm = FileManager.default
        let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/DroidBridge Apps")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let safeName = application.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let destination = root.appendingPathComponent("\(safeName).app")
        if fm.fileExists(atPath: destination.path) { throw BridgeError.message("\(destination.lastPathComponent) already exists. Remove it in Finder to create a new wrapper.") }
        let contents = destination.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        let resources = contents.appendingPathComponent("Resources")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try fm.copyItem(at: executable, to: macOS.appendingPathComponent("DroidBridge"))
        if let hostResources = Bundle.main.resourceURL {
            try fm.createSymbolicLink(at: resources.appendingPathComponent("Runtime"), withDestinationURL: hostResources.appendingPathComponent("Runtime"))
            let icon = hostResources.appendingPathComponent("DroidBridge.icns")
            if fm.fileExists(atPath: icon.path) { try fm.copyItem(at: icon, to: resources.appendingPathComponent("DroidBridge.icns")) }
        }
        let options: [String: String] = ["package": application.packageName, "name": application.name, "serial": device.serial, "backend": backend.rawValue]
        try JSONEncoder().encode(options).write(to: resources.appendingPathComponent("launch.json"))
        let plist: [String: Any] = ["CFBundleIdentifier": "app.droidbridge.wrapper.\(application.packageName)", "CFBundleName": application.name, "CFBundleDisplayName": application.name, "CFBundleExecutable": "DroidBridge", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1", "CFBundleIconFile": "DroidBridge", "LSMinimumSystemVersion": "26.0", "NSHighResolutionCapable": true]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let sign = Process(); sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign"); sign.arguments = ["--force", "--sign", "-", destination.path]; try sign.run(); sign.waitUntilExit()
        guard sign.terminationStatus == 0 else { throw BridgeError.message("Could not ad-hoc sign the app wrapper.") }
        let register = Process(); register.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"); register.arguments = ["-f", destination.path]; try? register.run()
        return destination
    }
}
