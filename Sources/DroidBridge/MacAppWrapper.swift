import AppKit
import CoreGraphics
import ImageIO
import Darwin
import DroidBridgeCore

/// Each wrapper is an independent, signed application with its own pinned runtime.
/// Builds are private until signing succeeds; updates atomically swap complete
/// bundles and retain the previous generation without altering launch intent.
enum MacAppWrapper {
    @MainActor
    static func create(application: AndroidApplication, device: AndroidDevice, backend: BackendKind, iconPNG: Data,
                       hostBundleURL: URL = Bundle.main.bundleURL, destinationRoot: URL? = nil) async throws -> URL {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL.map { canonicalPath($0) } })
        let root = destinationRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/DroidBridge Apps")
        let work = Task.detached(priority: .userInitiated) {
            try await build(application: application, device: device, backend: backend, iconPNG: iconPNG, host: hostBundleURL, root: root, running: running, managed: nil)
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    @MainActor
    static func createManaged(application: AndroidApplication, device: AndroidDevice, backend: BackendKind, iconPNG: Data,
                              reservation: ManagedAppReservation, hostBundleURL: URL = Bundle.main.bundleURL,
                              preservingConfiguration: [String:String]? = nil) async throws -> URL {
        guard reservation.device.serial == device.serial, reservation.application.packageName == application.packageName,
              reservation.bundleIdentifier == ManagedAppCatalog.bundleIdentifier(serial: device.serial, packageName: application.packageName) else { throw ManagedAppCatalogError.invalid("factory reservation identity") }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL.map { canonicalPath($0) } })
        guard !running.contains(canonicalPath(reservation.activeBundleURL)) else { throw ManagedAppCatalogError.running }
        let work = Task.detached(priority: .userInitiated) {
            try await build(application: reservation.application, device: device, backend: reservation.backend, iconPNG: iconPNG, host: hostBundleURL, root: reservation.stagingRoot, running: running, managed: reservation, preservingConfiguration:preservingConfiguration)
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }

    private static func build(application: AndroidApplication, device: AndroidDevice, backend: BackendKind, iconPNG: Data,
                              host: URL, root: URL, running: Set<String>, managed: ManagedAppReservation?, preservingConfiguration: [String:String]? = nil) async throws -> URL {
        try AndroidDiscovery.validatePackage(application.packageName)
        try AndroidDiscovery.validateSerial(device.serial)
        guard host.pathExtension == "app" else { throw BridgeError.message("Install DroidBridge.app before creating Mac app wrappers.") }
        let fm = FileManager.default
        let hostInfo = readPlist(host) ?? [:]
        if managed != nil, hostInfo["DroidBridgeManagedNamingVersion"] as? Int != 2 {
            throw BridgeError.message("Install the current DroidBridge application before updating managed Mac apps.")
        }
        let executable = host.appendingPathComponent("Contents/MacOS/DroidBridge")
        guard fm.isExecutableFile(atPath: executable.path) else { throw BridgeError.message("DroidBridge's installed executable is missing.") }
        if managed != nil {
            var current = root.standardizedFileURL
            while current.path != "/" {
                var metadata = stat()
                if lstat(current.path, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFLNK { throw ManagedAppCatalogError.invalid("symbolic link in factory staging path") }
                current.deleteLastPathComponent()
            }
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let label = application.name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var safeName = ""
        for character in label { guard (safeName + String(character)).utf8.count <= 180 else { break }; safeName.append(character) }
        guard !safeName.isEmpty else { throw BridgeError.message("The Android application name is empty.") }
        let identifier = managed?.bundleIdentifier ?? "app.droidbridge.wrapper.\(application.packageName)"
        let proposed = managed?.stagedBundleURL ?? root.appendingPathComponent("\(safeName).app")
        let matching = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { candidate in
            guard candidate.pathExtension == "app", !candidate.lastPathComponent.hasPrefix("."),
                  let info = readPlist(candidate), info["CFBundleIdentifier"] as? String == identifier else { return false }
            return true
        }
        guard matching.count <= 1 else { throw BridgeError.message("More than one Mac wrapper exists for \(application.packageName). Keep one before updating it.") }
        let destination = matching.first ?? proposed
        guard !running.contains(canonicalPath(destination)) else { throw BridgeError.message("Quit \(destination.deletingPathExtension().lastPathComponent) before updating its Mac app.") }
        var options = ["package": application.packageName, "name": application.name, "serial": device.serial, "backend": backend.rawValue]
        if let saved = preservingConfiguration {
            guard managed != nil, saved["package"] == application.packageName, saved["name"] == application.name,
                  saved["serial"] == device.serial, saved["backend"] == backend.rawValue else { throw ManagedAppCatalogError.invalid("saved wrapper launch identity") }
            options = saved
        }
        if let managed {
            options["managed_key"] = managed.key
            options["managed_generation"] = managed.id.uuidString
        }
        var previousConfig: Data?
        var previousInfo: Data?
        if fm.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true, let info = readPlist(destination), info["CFBundleIdentifier"] as? String == identifier else {
                throw BridgeError.message("\(destination.lastPathComponent) is not a matching DroidBridge wrapper; it will not be replaced.")
            }
            let config = try Data(contentsOf: destination.appendingPathComponent("Contents/Resources/launch.json"))
            let saved = try JSONDecoder().decode([String: String].self, from: config)
            guard saved["package"] == application.packageName, let serial = saved["serial"], let backend = saved["backend"], BackendKind(rawValue: backend) != nil,
                  let name = saved["name"], !name.isEmpty else { throw BridgeError.message("The existing wrapper's launch configuration is invalid; it was preserved.") }
            try AndroidDiscovery.validateSerial(serial)
            options = saved; previousConfig = config
            previousInfo = try Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist"))
        }
        let stage = root.appendingPathComponent(".building-\(UUID().uuidString).app")
        var removeStage = true
        defer { if removeStage { try? fm.removeItem(at: stage) } }
        let contents = stage.appendingPathComponent("Contents"), resources = stage.appendingPathComponent("Contents/Resources")
        try fm.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try ManagedAppCloneCopy.copy(executable, to: contents.appendingPathComponent("MacOS/DroidBridge"))
        let hostResources = host.appendingPathComponent("Contents/Resources")
        try ManagedAppCloneCopy.copy(hostResources.appendingPathComponent("Runtime"), to: resources.appendingPathComponent("Runtime"))
        for name in ["licenses", "THIRD_PARTY.md"] {
            let source = hostResources.appendingPathComponent(name)
            if fm.fileExists(atPath: source.path) { try ManagedAppCloneCopy.copy(source, to: resources.appendingPathComponent(name)) }
        }
        try Task.checkCancellation()
        try iconPNG.write(to: resources.appendingPathComponent("AndroidApp.png"))
        try await writeIcon(iconPNG, resources: resources)
        let player = resources.appendingPathComponent("Runtime/Player.app")
        if fm.fileExists(atPath: player.path) {
            var playerInfo = readPlist(player) ?? [:]
            playerInfo["CFBundleIdentifier"] = identifier + ".player"
            playerInfo["CFBundleName"] = options["name"] ?? application.name
            playerInfo["CFBundleDisplayName"] = options["name"] ?? application.name
            playerInfo["CFBundleIconFile"] = "AndroidApp.icns"
            let playerResources = player.appendingPathComponent("Contents/Resources")
            try fm.createDirectory(at: playerResources, withIntermediateDirectories: true)
            for name in ["AndroidApp.png", "AndroidApp.icns"] { try fm.copyItem(at: resources.appendingPathComponent(name), to: playerResources.appendingPathComponent(name)) }
            try PropertyListSerialization.data(fromPropertyList: playerInfo, format: .xml, options: 0).write(to: player.appendingPathComponent("Contents/Info.plist"))
            _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", player.path], timeout: 30)
        }
        let config = try previousConfig ?? JSONEncoder().encode(options)
        try config.write(to: resources.appendingPathComponent("launch.json"))
        let name = options["name"] ?? application.name
        var plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundleDisplayName": name, "CFBundleExecutable": "DroidBridge", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": hostInfo["CFBundleShortVersionString"] as? String ?? "0.1.2", "CFBundleVersion": hostInfo["CFBundleVersion"] as? String ?? "3", "CFBundleIconFile": "AndroidApp.icns", "LSMinimumSystemVersion": "26.0", "NSHighResolutionCapable": true, "DroidBridgeWrapperFormat": 2]
        if let managed {
            plist["DroidBridgeManagedGeneration"] = managed.id.uuidString
            plist["DroidBridgeManagedDevice"] = managed.deviceHash
            plist["DroidBridgeManagedNamingVersion"] = 2
        }
        plist["CFBundleDevelopmentRegion"] = "en"
        let localized = resources.appendingPathComponent("en.lproj")
        try fm.createDirectory(at:localized,withIntermediateDirectories:true)
        try PropertyListSerialization.data(fromPropertyList:["CFBundleName":name,"CFBundleDisplayName":name],format:.binary,options:0).write(to:localized.appendingPathComponent("InfoPlist.strings"))
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--force", "--sign", "-", stage.path], timeout: 30)
        _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", stage.path], timeout: 30)
        try Task.checkCancellation()
        let activeNow = await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL.map { canonicalPath($0) } }) }
        try Task.checkCancellation()
        guard !activeNow.contains(canonicalPath(managed?.activeBundleURL ?? destination)) else { throw BridgeError.message("Quit \(destination.deletingPathExtension().lastPathComponent) before completing its Mac app update.") }
        if let previousConfig, let previousInfo {
            guard try Data(contentsOf: destination.appendingPathComponent("Contents/Resources/launch.json")) == previousConfig,
                  try Data(contentsOf: destination.appendingPathComponent("Contents/Info.plist")) == previousInfo else { throw BridgeError.message("The existing Mac app changed while its update was being built. Retry the update.") }
            let backups = root.appendingPathComponent(".DroidBridge Backups")
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            let backup = backups.appendingPathComponent("\(destination.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).app")
            guard renamex_np(stage.path, destination.path, UInt32(RENAME_SWAP)) == 0 else { throw BridgeError.message("Could not atomically update the Mac app (errno \(errno)); the previous app was preserved.") }
            removeStage = false // The staging path now contains the previous generation.
            if renamex_np(stage.path, backup.path, UInt32(RENAME_EXCL)) != 0 {
                if renamex_np(stage.path, destination.path, UInt32(RENAME_SWAP)) == 0 { removeStage = true }
                throw BridgeError.message("Could not retain the previous app generation; the update was rolled back or retained at \(stage.path).")
            }
        } else {
            guard renamex_np(stage.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw BridgeError.message("The destination appeared while building; no existing app was replaced.") }
            removeStage = false
        }
        if managed == nil { _ = try? await ProcessRunner.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", arguments: ["-f", destination.path], timeout: 10) }
        return destination
    }

    private static func canonicalPath(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
    private static func readPlist(_ app: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
    private static func writeIcon(_ png: Data, resources: URL) async throws {
        guard png.count <= 4 * 1024 * 1024, png.starts(with: [137,80,78,71,13,10,26,10]),
              let source = CGImageSourceCreateWithData(png as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 512,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 512,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw BridgeError.message("The Android launcher icon must be a valid 512×512 PNG.") }
        let iconset = resources.appendingPathComponent("AndroidApp.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: iconset) }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw BridgeError.message("Could not convert the Android launcher icon.") }
                context.interpolationQuality = .high; context.draw(image, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
                let path = iconset.appendingPathComponent("icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png")
                guard let scaled = context.makeImage(), let destination = CGImageDestinationCreateWithURL(path as CFURL, "public.png" as CFString, 1, nil) else { throw BridgeError.message("Could not encode the Android launcher icon.") }
                CGImageDestinationAddImage(destination, scaled, nil)
                guard CGImageDestinationFinalize(destination) else { throw BridgeError.message("Could not save the Android launcher icon.") }
            }
        }
        _ = try await ProcessRunner.run("/usr/bin/iconutil", arguments: ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AndroidApp.icns").path], timeout: 20)
    }
}
