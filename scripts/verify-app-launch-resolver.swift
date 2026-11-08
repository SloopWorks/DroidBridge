import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin
import DroidBridgeCore

/// Executes shipping resolver helpers against metadata-only dependency fixtures.
/// It never starts an Android session, opens a Mac app or modifies a managed catalog.
@main struct VerifyAppLaunchResolver {
    static let device = AndroidDevice(serial: "emulator-5580", model: "Resolver fixture")
    static var checks: [String] = []
    static var timings: [String: Double] = [:]

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw BridgeError.message(message) }
        checks.append(message); print("PASS: \(message)")
    }
    static func app(_ suffix: String) -> AndroidApplication {
        .init(packageName: "dev.droidbridge.resolver." + suffix, name: "Resolver " + suffix)
    }
    static func makeCandidate(root: URL, name: String, app: AndroidApplication, serial: String,
                              backend: BackendKind, identifier: String) throws -> URL {
        let url = root.appendingPathComponent(name + ".app", isDirectory: true)
        let resources = url.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "DroidBridge",
                                   "DroidBridgeWrapperFormat": 2, "CFBundleVersion": "fixture",
                                   "CFBundleShortVersionString": "fixture"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try JSONEncoder().encode(["serial": serial, "package": app.packageName, "backend": backend.rawValue, "name": app.name])
            .write(to: resources.appendingPathComponent("launch.json"))
        return url
    }
    static func png(size: Int) throws -> Data {
        guard let color = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BridgeError.message("Cannot create icon fixture")
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let bytes = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw BridgeError.message("Cannot encode icon fixture")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw BridgeError.message("Cannot finish icon fixture") }
        return bytes as Data
    }

    static func verifyPreparationLease(scope: CompanionQAScope) async throws {
        let fm = FileManager.default
        let application = app("preparationlease")
        let root = AppLaunchResolver.directory(device: device, app: application, backend: .native)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = root.appendingPathComponent(".launch.lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BridgeError.message("Cannot create exact owned preparation lock fixture") }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw BridgeError.message("Cannot hold preparation lock fixture") }
        let baseline = Set(try fm.contentsOfDirectory(atPath: root.path))

        let host = scope.root.appendingPathComponent("LeaseFixtureHost.app", isDirectory: true)
        let executable = host.appendingPathComponent("Contents/MacOS/DroidBridge")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: host.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let hostInfo = ["CFBundleIdentifier": "app.droidbridge.leasefixture", "CFBundleExecutable": "DroidBridge",
                        "CFBundleShortVersionString": "fixture", "CFBundleVersion": "fixture"]
        try PropertyListSerialization.data(fromPropertyList: hostInfo, format: .binary, options: 0)
            .write(to: host.appendingPathComponent("Contents/Info.plist"))
        let icon = try png(size: 512)
        // Warm the read-only process inventory outside the measured lock interval.
        _ = await MainActor.run { NSWorkspace.shared.runningApplications.count }
        let busyStart = ProcessInfo.processInfo.systemUptime
        var wasBusy = false
        do {
            _ = try await MacAppWrapper.createOnDemand(application: application, device: device, backend: .native,
                                                       iconPNG: icon, hostBundleURL: host, destinationRoot: root)
        } catch {
            wasBusy = error.localizedDescription.contains("Another DroidBridge process is preparing this app")
        }
        let busyElapsed = ProcessInfo.processInfo.systemUptime - busyStart
        timings["heldLockBusySeconds"] = busyElapsed
        try require(wasBusy && busyElapsed >= 0.9 && busyElapsed < 2.5,
                    "Held preparation lock reports busy after a bounded approximately one-second wait")
        try require(Set(try fm.contentsOfDirectory(atPath: root.path)) == baseline,
                    "Busy preparation leaves no staging bundle or published app")

        let cancelledBuild = Task { @MainActor in
            try await MacAppWrapper.createOnDemand(application: application, device: device, backend: .native,
                                                    iconPNG: icon, hostBundleURL: host, destinationRoot: root)
        }
        try await Task.sleep(for: .milliseconds(100))
        let cancelStart = ProcessInfo.processInfo.systemUptime
        cancelledBuild.cancel()
        var wasCancelled = false
        do { _ = try await cancelledBuild.value }
        catch is CancellationError { wasCancelled = true }
        catch { throw BridgeError.message("Expected preparation CancellationError, received \(error)") }
        let cancelElapsed = ProcessInfo.processInfo.systemUptime - cancelStart
        timings["heldLockCancellationSeconds"] = cancelElapsed
        try require(wasCancelled && cancelElapsed < 0.7,
                    "Cancelling a held-lock preparation returns CancellationError within 700ms")
        try require(Set(try fm.contentsOfDirectory(atPath: root.path)) == baseline,
                    "Cancelled preparation leaves no staging bundle or published app")

        guard flock(descriptor, LOCK_UN) == 0 else { throw BridgeError.message("Cannot release owned preparation lock") }
        var reachedMissingRuntime = false
        do {
            _ = try await MacAppWrapper.createOnDemand(application: application, device: device, backend: .native,
                                                       iconPNG: icon, hostBundleURL: host, destinationRoot: root)
        } catch {
            let cocoa = error as NSError
            reachedMissingRuntime = cocoa.domain == NSCocoaErrorDomain &&
                [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoa.code)
        }
        try require(reachedMissingRuntime && !fm.fileExists(atPath: host.appendingPathComponent("Contents/Resources/Runtime").path),
                    "After lock release preparation reaches the intentionally missing runtime")
        try require(Set(try fm.contentsOfDirectory(atPath: root.path)) == baseline,
                    "Failed runtime preparation cleans its staging bundle without publishing")
        try require(flock(descriptor, LOCK_EX | LOCK_NB) == 0,
                    "Preparation failure releases its kernel lease for the next attempt")
    }

    static func run(scope: CompanionQAScope) async throws {
        let fm = FileManager.default
        let owner = try CompanionBrokerOwner.live(getpid()).unwrap("Current process identity unavailable")
        try JSONEncoder().encode(DroidBridgePreferences(bulkWrapperOnboardingEnabled: false)).write(to: scope.preferencesURL)
        let catalog = ManagedAppCatalog(paths: scope.managedPaths)
        let manual = scope.root.appendingPathComponent("ManualApps", isDirectory: true)
        let missingHost = scope.root.appendingPathComponent("NoHost.app", isDirectory: true)
        try require(!fm.fileExists(atPath: missingHost.path), "Fixture has no installed host; live selection cannot depend on stopped-wrapper freshness")

        // A stopped manual candidate is searched before the cache. A later live
        // cache must win without touching the missing host or updating a wrapper.
        let preferred = app("livepreference")
        let manualID = "app.droidbridge.wrapper." + preferred.packageName
        _ = try makeCandidate(root: manual, name: "Earlier stopped manual", app: preferred, serial: device.serial,
                              backend: .native, identifier: manualID)
        let cacheID = MacAppWrapper.onDemandIdentifier(device: device, application: preferred, backend: .native)
        let cacheURL = try makeCandidate(root: AppLaunchResolver.directory(device: device, app: preferred, backend: .native),
                                        name: "Later live cache", app: preferred, serial: device.serial,
                                        backend: .native, identifier: cacheID)
        let listedURL = try fm.contentsOfDirectory(at: cacheURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .first(where: { $0.path == cacheURL.path }).unwrap("Cache candidate was not enumerated")
        let observedURL = URL(fileURLWithPath: cacheURL.path, isDirectory: !listedURL.hasDirectoryPath)
        try require(listedURL.standardizedFileURL != observedURL.standardizedFileURL &&
                    listedURL.standardizedFileURL.path == observedURL.standardizedFileURL.path,
                    "Live-app fixture uses the opposite directory URL hint from the enumerated wrapper")
        let observed = RunningAppLaunch(url: observedURL, identifier: cacheID, owner: owner)
        let selected = try await AppLaunchResolver.find(device: device, app: preferred, backend: .native,
                                                        host: missingHost, catalog: catalog, running: [observed])
        try require(selected?.url.path == cacheURL.path && selected?.running?.owner == owner,
                    "Live private cache wins over an earlier stopped manual candidate")

        let otherPhone = app("wrongserial")
        let otherPhoneID = "app.droidbridge.wrapper." + otherPhone.packageName
        let otherPhoneURL = try makeCandidate(root: manual, name: "Different phone", app: otherPhone, serial: "emulator-5582",
                                             backend: .native, identifier: otherPhoneID)
        let phoneResult = try await AppLaunchResolver.find(device: device, app: otherPhone, backend: .native,
                                                           host: missingHost, catalog: catalog,
                                                           running: [.init(url: otherPhoneURL, identifier: otherPhoneID, owner: owner)])
        try require(phoneResult == nil, "A live-looking manual wrapper saved for a different serial is ignored")

        let otherBackend = app("wrongbackend")
        let otherBackendID = "app.droidbridge.wrapper." + otherBackend.packageName
        let otherBackendURL = try makeCandidate(root: manual, name: "Different backend", app: otherBackend, serial: device.serial,
                                               backend: .scrcpy, identifier: otherBackendID)
        let backendResult = try await AppLaunchResolver.find(device: device, app: otherBackend, backend: .native,
                                                             host: missingHost, catalog: catalog,
                                                             running: [.init(url: otherBackendURL, identifier: otherBackendID, owner: owner)])
        try require(backendResult == nil, "A live-looking manual wrapper saved for a different backend is ignored")

        let secondDevice = AndroidDevice(serial: "emulator-5582", model: "Identity-only fixture")
        let identityApp = app("identities")
        let firstID = MacAppWrapper.onDemandIdentifier(device: device, application: identityApp, backend: .native)
        let secondID = MacAppWrapper.onDemandIdentifier(device: secondDevice, application: identityApp, backend: .native)
        let backendID = MacAppWrapper.onDemandIdentifier(device: device, application: identityApp, backend: .scrcpy)
        try require(Set([firstID, secondID, backendID]).count == 3,
                    "One package has distinct private bundle identities for each phone and backend")
        try require(firstID == MacAppWrapper.onDemandIdentifier(device: device, application: identityApp, backend: .native),
                    "Private bundle identity is deterministic")
        let firstPath = AppLaunchResolver.directory(device: device, app: identityApp, backend: .native)
        let secondPath = AppLaunchResolver.directory(device: secondDevice, app: identityApp, backend: .native)
        let backendPath = AppLaunchResolver.directory(device: device, app: identityApp, backend: .scrcpy)
        try require(Set([firstPath, secondPath, backendPath]).count == 3,
                    "One package has distinct private cache directories for each phone and backend")

        let malformed = app("malformed")
        let malformedID = "app.droidbridge.wrapper." + malformed.packageName
        let brokenPlist = try makeCandidate(root: manual, name: "Broken plist", app: malformed, serial: device.serial,
                                           backend: .native, identifier: malformedID)
        try Data("not a property list".utf8).write(to: brokenPlist.appendingPathComponent("Contents/Info.plist"))
        let brokenJSON = try makeCandidate(root: manual, name: "Broken launch JSON", app: malformed, serial: device.serial,
                                          backend: .native, identifier: malformedID)
        try Data("{not JSON".utf8).write(to: brokenJSON.appendingPathComponent("Contents/Resources/launch.json"))
        let malformedResult = try await AppLaunchResolver.find(device: device, app: malformed, backend: .native,
                                                               host: missingHost, catalog: catalog,
                                                               running: [.init(url: brokenPlist, identifier: malformedID, owner: owner),
                                                                         .init(url: brokenJSON, identifier: malformedID, owner: owner)])
        try require(malformedResult == nil, "Malformed wrapper plist or launch JSON is never returned as launchable")

        let actual = scope.root.appendingPathComponent("RealManualApps", isDirectory: true)
        try fm.moveItem(at: manual, to: actual)
        try fm.createSymbolicLink(at: manual, withDestinationURL: actual)
        var refusedLink = false
        do {
            _ = try await AppLaunchResolver.find(device: device, app: preferred, backend: .native,
                                                  host: missingHost, catalog: catalog, running: [observed])
        } catch { refusedLink = true }
        try fm.removeItem(at: manual); try fm.moveItem(at: actual, to: manual)
        try require(refusedLink, "A symbolic link in the wrapper directory is refused")

        try require(!AppLaunchResolver.usableIcon(try png(size: 128)), "Companion-sized 128px icon is rejected for a Mac wrapper")
        try require(AppLaunchResolver.usableIcon(try png(size: 512)), "A 512px Android icon is accepted for a Mac wrapper")
        try require(!AppLaunchResolver.usableIcon(Data("not an image".utf8)), "Malformed icon bytes are rejected")
        try await verifyPreparationLease(scope: scope)
        try require(!fm.fileExists(atPath: scope.managedPaths.privateRoot.path) && !fm.fileExists(atPath: scope.managedPaths.activeRoot.path),
                    "Resolver fixture leaves managed catalog and managed apps untouched")
    }

    static func main() async {
        do {
            guard let scope = CompanionQAScope.current, scope.serial == device.serial,
                  scope.root.path.hasPrefix("/private/tmp/droidbridge-resolver.") else {
                throw BridgeError.message("Dedicated private resolver QA root and emulator-5580 scope required")
            }
            try await run(scope: scope)
            guard let path = ProcessInfo.processInfo.environment["DROIDBRIDGE_RESOLVER_EVIDENCE"] else {
                throw BridgeError.message("Resolver evidence directory required")
            }
            let report: [String: Any] = ["passed": checks, "checkCount": checks.count,
                                         "scope": scope.root.path, "serial": scope.serial,
                                         "fixtureOnly": true, "openedApplications": 0, "androidCommands": 0,
                                         "timings": timings]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: path).appendingPathComponent("resolver-results.json"))
            print("PASS: \(checks.count) shipping resolver checks; no applications or Android sessions launched")
        } catch {
            fputs("FAIL: \(error)\n", stderr); exit(1)
        }
    }
}

private extension Optional {
    func unwrap(_ message: String) throws -> Wrapped {
        guard let value = self else { throw BridgeError.message(message) }
        return value
    }
}
