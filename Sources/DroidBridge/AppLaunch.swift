import AppKit
import ImageIO
import Darwin
import DroidBridgeCore

struct AppLaunchProgress {
    let name: String
    var message: String
    var busy = true
    var canCancel = true
}

struct RunningAppLaunch: Sendable {
    let url: URL
    let identifier: String
    let owner: CompanionBrokerOwner
}

struct ResolvedAppLaunch: Sendable {
    let url: URL
    let identifier: String
    let running: RunningAppLaunch?
}

/// Filesystem/signature work stays off AppKit's actor. Existing manual wrappers
/// retain their saved phone and backend; a different selection gets a private app.
enum AppLaunchResolver {
    static var cacheRoot: URL {
        (CompanionQAScope.current?.root ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DroidBridge"))
            .appendingPathComponent("Launchers.noindex", isDirectory: true)
    }

    static func directory(device: AndroidDevice, app: AndroidApplication, backend: BackendKind) -> URL {
        cacheRoot.appendingPathComponent(ManagedAppCatalog.deviceHash(device.serial)).appendingPathComponent(backend.rawValue).appendingPathComponent(app.packageName)
    }

    static func find(device: AndroidDevice, app: AndroidApplication, backend: BackendKind, host: URL,
                     catalog: ManagedAppCatalog, running: [RunningAppLaunch]) async throws -> ResolvedAppLaunch? {
        try AndroidDiscovery.validateSerial(device.serial)
        try AndroidDiscovery.validatePackage(app.packageName)
        let fm = FileManager.default
        var candidates: [(URL, String)] = []
        if (try? DroidBridgePreferences.load().bulkWrapperOnboardingEnabled) == true {
            for record in try catalog.records() where record.deviceSerial == device.serial && record.packageName == app.packageName && record.backend == backend {
                if try catalog.isLaunchAllowed(bundleURL: record.bundleURL, serial: device.serial, packageName: app.packageName) {
                    candidates.append((record.bundleURL, record.bundleIdentifier))
                }
            }
        }
        let manual = CompanionQAScope.current?.root.appendingPathComponent("ManualApps") ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/DroidBridge Apps")
        let cache = directory(device: device, app: app, backend: backend)
        for (root, identifier) in [(manual, "app.droidbridge.wrapper." + app.packageName),
                                   (cache, MacAppWrapper.onDemandIdentifier(device: device, application: app, backend: backend))] {
            try rejectSymlinks(root)
            guard fm.fileExists(atPath: root.path) else { continue }
            let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            guard children.count <= 20_000 else { throw BridgeError.message("The Mac app directory contains too many items.") }
            for url in children where url.pathExtension == "app" && !url.lastPathComponent.hasPrefix(".") {
                if let info = try? dictionary(url.appendingPathComponent("Contents/Info.plist"), plist: true), info["CFBundleIdentifier"] as? String == identifier {
                    candidates.append((url, identifier))
                }
            }
        }
        var validated: [(URL, String, [String: Any])] = []
        for (url, identifier) in candidates {
            try Task.checkCancellation()
            try rejectSymlinks(url)
            guard let info = try? dictionary(url.appendingPathComponent("Contents/Info.plist"), plist: true),
                  info["CFBundleIdentifier"] as? String == identifier, info["CFBundleExecutable"] as? String == "DroidBridge",
                  info["DroidBridgeWrapperFormat"] as? Int == 2,
                  let config = try? dictionary(url.appendingPathComponent("Contents/Resources/launch.json"), plist: false),
                  config["serial"] as? String == device.serial, config["package"] as? String == app.packageName,
                  config["backend"] as? String == backend.rawValue else { continue }
            validated.append((url, identifier, info))
        }
        // Search every location for a live exact match before selecting a
        // stopped app. Onboarding must not duplicate an already running app.
        for (url, identifier, _) in validated {
            if let live = running.first(where: { $0.url.standardizedFileURL.path == url.standardizedFileURL.path && $0.identifier == identifier && $0.owner.isAlive }) {
                return ResolvedAppLaunch(url: url, identifier: identifier, running: live)
            }
        }
        for (url, identifier, info) in validated {
            try Task.checkCancellation()
            let hostInfo = try dictionary(host.appendingPathComponent("Contents/Info.plist"), plist: true)
            guard info["CFBundleVersion"] as? String == hostInfo["CFBundleVersion"] as? String,
                  info["CFBundleShortVersionString"] as? String == hostInfo["CFBundleShortVersionString"] as? String else { continue }
            let executable = url.appendingPathComponent("Contents/MacOS/DroidBridge")
            try rejectSymlinks(executable)
            guard info["DroidBridgeAppIdentityVersion"] as? Int == AppBinaryIdentity.format,
                  try await AppBinaryIdentity.matches(executable, source: host.appendingPathComponent("Contents/MacOS/DroidBridge"), identifier: identifier) else { continue }
            _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", url.path], timeout: 20)
            return ResolvedAppLaunch(url: url, identifier: identifier, running: nil)
        }
        return nil
    }

    static func dictionary(_ url: URL, plist: Bool) throws -> [String: Any] {
        try rejectSymlinks(url)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == geteuid(), metadata.st_size > 0, metadata.st_size <= 65_536 else {
            throw BridgeError.message("The Mac app's launch metadata is invalid.")
        }
        let data = try Data(contentsOf: url)
        let value = try plist ? PropertyListSerialization.propertyList(from: data, format: nil) : JSONSerialization.jsonObject(with: data)
        guard let dictionary = value as? [String: Any] else { throw BridgeError.message("The Mac app's launch metadata is invalid.") }
        return dictionary
    }

    static func rejectSymlinks(_ url: URL) throws {
        // Foundation standardization can turn /private/tmp into the /tmp
        // symlink on macOS. Walk the supplied lexical path without that alias.
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw BridgeError.message("The Mac app path is invalid.")
        }
        var current = url
        while current.path != "/" {
            var metadata = stat()
            if lstat(current.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFLNK {
                throw BridgeError.message("A symbolic link in the Mac app path prevents safe launching.")
            }
            current.deleteLastPathComponent()
        }
    }

    static func usableIcon(_ data: Data) -> Bool {
        guard data.count <= 2 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        return (props[kCGImagePropertyPixelWidth] as? Int) == 512 && (props[kCGImagePropertyPixelHeight] as? Int) == 512
    }
}

extension LauncherController {
    /// Called synchronously from buttons, Return and double-click: the busy
    /// state exists before the first suspension and repeated clicks coalesce.
    func openApp(device: AndroidDevice, app: AndroidApplication, backend: BackendKind, host: URL = Bundle.main.bundleURL) {
        guard appLaunchTask == nil, !quitting else { return }
        let request = UUID()
        appLaunchRequest = request
        appLaunchProgress = AppLaunchProgress(name: app.name, message: "Checking existing app…")
        updateLauncherPresentation()
        appLaunchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.appLaunchRequest == request { self.appLaunchTask = nil; self.appLaunchRequest = nil }
                self.updateLauncherPresentation(); self.pumpIcons()
            }
            do {
                try AndroidDiscovery.validateSerial(device.serial)
                try AndroidDiscovery.validatePackage(app.packageName)
                let running = self.runningAppLaunches()
                let catalog = self.managedCatalog
                let lookup = Task.detached(priority: .userInitiated) {
                    try await AppLaunchResolver.find(device: device, app: app, backend: backend, host: host, catalog: catalog, running: running)
                }
                let found = try await withTaskCancellationHandler(operation: { try await lookup.value }, onCancel: { lookup.cancel() })
                try self.checkAppLaunch(request)
                let resolved: ResolvedAppLaunch
                if let found { resolved = found }
                else {
                    self.setAppLaunchMessage("Loading Android launcher icon…", request: request)
                    let cached = self.iconData[self.iconKey(device, app)]
                    let png: Data
                    if let cached, AppLaunchResolver.usableIcon(cached) { png = cached }
                    else { png = try await self.iconProvider.icon(device: device, application: app) }
                    try self.checkAppLaunch(request)
                    self.setAppLaunchMessage("Preparing Mac app…", request: request)
                    let url = try await MacAppWrapper.createOnDemand(application: app, device: device, backend: backend, iconPNG: png,
                                                                   hostBundleURL: host, destinationRoot: AppLaunchResolver.directory(device: device, app: app, backend: backend))
                    try self.checkAppLaunch(request)
                    resolved = ResolvedAppLaunch(url: url, identifier: MacAppWrapper.onDemandIdentifier(device: device, application: app, backend: backend), running: nil)
                }
                try self.checkAppLaunch(request)
                // NSWorkspace may reuse an application by bundle identity. Refuse
                // an ambiguous copy rather than focusing the wrong installed app.
                let conflicts = self.runningAppLaunches().filter { $0.identifier == resolved.identifier && $0.url.standardizedFileURL.path != resolved.url.standardizedFileURL.path }
                guard conflicts.isEmpty else { throw BridgeError.message("Another copy of this Mac app is running. Quit that copy, then retry.") }
                self.setAppLaunchMessage(resolved.running == nil ? "Opening app…" : "Bringing app to front…", request: request)
                self.appLaunchProgress?.canCancel = false; self.updateLauncherPresentation()
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = false
                configuration.activates = true
                if let scope = CompanionQAScope.current { configuration.arguments = ["--companion-qa-root", scope.root.path, "--serial", device.serial] }
                let launched = try await NSWorkspace.shared.openApplication(at: resolved.url, configuration: configuration)
                if CompanionQAScope.current != nil {
                    print("QA handoff expected=\(resolved.identifier) at=\(resolved.url.path) observed=\(launched.bundleIdentifier ?? "nil") at=\(launched.bundleURL?.path ?? "nil") pid=\(launched.processIdentifier)")
                }
                guard launched.bundleIdentifier == resolved.identifier, launched.bundleURL?.standardizedFileURL.path == resolved.url.standardizedFileURL.path,
                      let owner = CompanionBrokerOwner.live(launched.processIdentifier) else {
                    throw BridgeError.message("macOS opened a different copy of the app. Close it and retry from DroidBridge.")
                }
                self.trackAppLaunch(launched, owner: owner, device: device, app: app, backend: backend)
                if !self.quitting {
                    self.appLaunchProgress = AppLaunchProgress(name: app.name, message: resolved.running == nil ? "Opened in its own app window." : "App brought to front.", busy: false, canCancel: false)
                }
            } catch {
                guard !self.quitting else { return }
                let cancelled = error is CancellationError || Task.isCancelled
                self.appLaunchProgress = AppLaunchProgress(name: app.name, message: cancelled ? "Opening cancelled." : "Couldn’t open app: " + String(error.localizedDescription.prefix(350)), busy: false, canCancel: false)
            }
        }
    }

    private func checkAppLaunch(_ request: UUID) throws {
        try Task.checkCancellation()
        guard !quitting, appLaunchRequest == request else { throw CancellationError() }
    }
    private func setAppLaunchMessage(_ message: String, request: UUID) {
        guard appLaunchRequest == request else { return }
        appLaunchProgress?.message = message; updateLauncherPresentation()
    }
    @objc func cancelAppLaunch() {
        guard appLaunchProgress?.canCancel == true else { return }
        appLaunchProgress?.message = "Cancelling…"; appLaunchProgress?.canCancel = false
        appLaunchTask?.cancel(); updateLauncherPresentation()
    }
    @objc func dismissAppLaunchProgress() {
        guard appLaunchProgress?.busy != true else { return }
        appLaunchProgress = nil; updateLauncherPresentation()
    }
    func runningAppLaunches() -> [RunningAppLaunch] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let url = app.bundleURL, let identifier = app.bundleIdentifier, identifier.hasPrefix("app.droidbridge."),
                  let owner = CompanionBrokerOwner.live(app.processIdentifier) else { return nil }
            return RunningAppLaunch(url: url, identifier: identifier, owner: owner)
        }
    }
}
