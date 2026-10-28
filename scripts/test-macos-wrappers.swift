import AppKit
import Foundation
import CryptoKit
import DroidBridgeCore

@main struct WrapperVerification {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); print("PASS: transactional Android icons, preserved updates, independent native/fallback identities"); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    @MainActor static func pixels(_ image: NSImage) throws -> [UInt8] {
        var rect = CGRect(x: 0, y: 0, width: 512, height: 512)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil), let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8, bytesPerRow: 2048, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw BridgeError.message("Cannot inspect running icon") }
        context.interpolationQuality = .high; context.draw(cg, in: CGRect(x: 0, y: 0, width: 512, height: 512))
        guard let bytes = context.data else { throw BridgeError.message("Cannot read running icon") }
        return Array(UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: UInt8.self), count: 512*512*4))
    }
    @MainActor static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let host = URL(fileURLWithPath: env["DROIDBRIDGE_TEST_HOST"] ?? NSHomeDirectory() + "/Applications/DroidBridge.app")
        let evidence = URL(fileURLWithPath: env["DROIDBRIDGE_EVIDENCE"] ?? FileManager.default.currentDirectoryPath + "/verification/launcher-fix/wrappers")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DroidBridge-WrapperQA-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep completed signed bundles for independent examination.
        try root.path.write(to: evidence.appendingPathComponent("wrapper-root.txt"), atomically: true, encoding: .utf8)
        let tools = Toolchain(adb: host.appendingPathComponent("Contents/Resources/Runtime/bin/adb").path, scrcpy: host.appendingPathComponent("Contents/Resources/Runtime/bin/scrcpy").path, server: host.appendingPathComponent("Contents/Resources/Runtime/share/scrcpy/scrcpy-server").path)
        let device = AndroidDevice(serial: "emulator-5580", model: "QA AVD")
        let provider = AndroidIconProvider(toolchain: tools, helperPath: host.appendingPathComponent("Contents/Resources/Runtime/share/droidbridge/icon-helper.jar").path)
        let settings = AndroidApplication(packageName: "com.android.settings", name: "QA Android Settings")
        let fixture = AndroidApplication(packageName: "dev.droidbridge.iconfixture", name: "QA Android Alias")
        let png = try await provider.icon(device: device, application: fixture)
        let settingsPNG = try await provider.icon(device: device, application: settings)
        let alias = try await MacAppWrapper.create(application: fixture, device: device, backend: .scrcpy, iconPNG: png, hostBundleURL: host, destinationRoot: root)
        let native = try await MacAppWrapper.create(application: settings, device: device, backend: .native, iconPNG: settingsPNG, hostBundleURL: host, destinationRoot: root)
        for (bundle, expected) in [(alias, png), (native, settingsPNG)] {
            let resources = bundle.appendingPathComponent("Contents/Resources")
            guard try Data(contentsOf: resources.appendingPathComponent("AndroidApp.png")) == expected,
                  let icon = NSImage(contentsOf: resources.appendingPathComponent("AndroidApp.icns")), !icon.representations.isEmpty else { throw BridgeError.message("Android PNG/ICNS did not survive bundle creation") }
            _ = try await ProcessRunner.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", bundle.path])
        }
        let configURL = alias.appendingPathComponent("Contents/Resources/launch.json")
        let original = try Data(contentsOf: configURL)
        let update = try await MacAppWrapper.create(application: fixture, device: AndroidDevice(serial: "different-device", model: "Must not replace pin"), backend: .native, iconPNG: png, hostBundleURL: host, destinationRoot: root)
        guard update.resolvingSymlinksInPath().path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == alias.resolvingSymlinksInPath().path.trimmingCharacters(in: CharacterSet(charactersIn: "/")), try Data(contentsOf: configURL) == original else { throw BridgeError.message("Update changed the original launch intent") }
        let backups = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".DroidBridge Backups"), includingPropertiesForKeys: nil)
        guard backups.count == 1, try Data(contentsOf: backups[0].appendingPathComponent("Contents/Resources/launch.json")) == original else { throw BridgeError.message("Update failed to retain the previous complete generation") }
        var rejectedInvalid = false
        do { _ = try await MacAppWrapper.create(application: fixture, device: device, backend: .native, iconPNG: Data([0]), hostBundleURL: host, destinationRoot: root) }
        catch { rejectedInvalid = true }
        guard rejectedInvalid, try Data(contentsOf: configURL) == original else { throw BridgeError.message("Invalid icon was accepted or damaged existing wrapper") }
        let unrelated = root.appendingPathComponent("Unrelated.app")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try "keep".write(to: unrelated.appendingPathComponent("untouched"), atomically: true, encoding: .utf8)
        var rejectedUnrelated = false
        do { _ = try await MacAppWrapper.create(application: AndroidApplication(packageName: "dev.other.app", name: "Unrelated"), device: device, backend: .native, iconPNG: png, hostBundleURL: host, destinationRoot: root) }
        catch { rejectedUnrelated = true }
        guard rejectedUnrelated, try String(contentsOf: unrelated.appendingPathComponent("untouched"), encoding: .utf8) == "keep" else { throw BridgeError.message("Unrelated bundle changed or was replaced") }
        let racingApp = AndroidApplication(packageName: "dev.racing.app", name: "Race")
        let creation = Task { try await MacAppWrapper.create(application: racingApp, device: device, backend: .native, iconPNG: png, hostBundleURL: host, destinationRoot: root) }
        var sawStage = false
        for _ in 0..<500 {
            if try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix(".Race.building-") }) { sawStage = true; break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard sawStage else { throw BridgeError.message("Could not observe exclusive-publication race boundary") }
        let racingDestination = root.appendingPathComponent("Race.app")
        try FileManager.default.createDirectory(at: racingDestination, withIntermediateDirectories: true)
        try "race-owner".write(to: racingDestination.appendingPathComponent("untouched"), atomically: true, encoding: .utf8)
        var rejectedRace = false
        do { _ = try await creation.value } catch { rejectedRace = true }
        guard rejectedRace, try String(contentsOf: racingDestination.appendingPathComponent("untouched"), encoding: .utf8) == "race-owner" else { throw BridgeError.message("Concurrent destination was replaced") }
        guard !(try FileManager.default.contentsOfDirectory(atPath: root.path)).contains(where: { $0.contains(".building-") }) else { throw BridgeError.message("Staging directories leaked after failure") }
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DroidBridge")
        let baseline = Set((try? FileManager.default.contentsOfDirectory(atPath: logDirectory.path)) ?? [])
        let persistence = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DroidBridge")
        let persistencePaths = ["com.android.settings", "dev.droidbridge.iconfixture"].map { persistence.appendingPathComponent("sessions-app.droidbridge.wrapper.\($0).json") }
        let savedIntent = persistencePaths.map { try? Data(contentsOf: $0) }
        defer { for (index, path) in persistencePaths.enumerated() { if let saved = savedIntent[index] { try? saved.write(to: path, options: .atomic) } else { try? FileManager.default.removeItem(at: path) } } }
        let processes = [native, alias].map { bundle -> Process in let process = Process(); process.executableURL = bundle.appendingPathComponent("Contents/MacOS/DroidBridge"); process.environment = ProcessInfo.processInfo.environment; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; return process }
        defer { for process in processes where process.isRunning { process.terminate(); process.waitUntilExit() } }
        for process in processes { try process.run() }
        var events: [[String: Any]] = []
        for _ in 0..<200 {
            let fresh = ((try? FileManager.default.contentsOfDirectory(atPath: logDirectory.path)) ?? []).filter { !baseline.contains($0) && $0.hasSuffix(".jsonl") }
            events = fresh.flatMap { filename -> [[String: Any]] in
                guard let text = try? String(contentsOf: logDirectory.appendingPathComponent(filename), encoding: .utf8) else { return [] }
                return text.components(separatedBy: .newlines).compactMap { line in guard let data = line.data(using: .utf8) else { return nil }; return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
            }
            if events.contains(where: { $0["package"] as? String == settings.packageName && $0["state"] as? String == "running" }), events.contains(where: { $0["package"] as? String == fixture.packageName && $0["state"] as? String == "running" }), events.contains(where: { $0["package"] as? String == settings.packageName && $0["event"] as? String == "native_window_presented" }) { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard events.contains(where: { event in
            guard event["package"] as? String == settings.packageName, event["event"] as? String == "native_window_presented", let details = event["details"] as? [String: String] else { return false }
            return details["reason"] == "first_frame" && details["visible"] == "true" && details["minimized"] == "false"
        }) else { throw BridgeError.message("Final wrapper did not present its native window on the first decoded frame") }
        let fixtureEvents = events.filter { $0["package"] as? String == fixture.packageName }
        guard let sessionID = fixtureEvents.last?["session"] as? String else { throw BridgeError.message("No fallback session receipt") }
        let log = logDirectory.appendingPathComponent("session-\(sessionID).log")
        var fallbackLog = ""
        for _ in 0..<100 {
            fallbackLog = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            if fallbackLog.contains("Texture"), fallbackLog.contains("Starting app"), fallbackLog.contains("on display") { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try fallbackLog.write(to: evidence.appendingPathComponent("fallback-video.log"), atomically: true, encoding: .utf8)
        guard fallbackLog.contains("Texture"), fallbackLog.contains("Starting app"), fallbackLog.contains("on display") else { throw BridgeError.message("Fallback never decoded a live video texture with display binding") }
        guard processes.allSatisfy(\.isRunning) else { throw BridgeError.message("Wrapper disappeared during startup") }
        guard events.contains(where: { $0["package"] as? String == settings.packageName && $0["state"] as? String == "running" }) else { throw BridgeError.message("Native wrapper never decoded a live frame") }
        let liveConfig = try Data(contentsOf: native.appendingPathComponent("Contents/Resources/launch.json"))
        var refusedLiveUpdate = false
        do { _ = try await MacAppWrapper.create(application: settings, device: device, backend: .native, iconPNG: settingsPNG, hostBundleURL: host, destinationRoot: root) }
        catch { refusedLiveUpdate = error.localizedDescription.contains("Quit") }
        guard refusedLiveUpdate, try Data(contentsOf: native.appendingPathComponent("Contents/Resources/launch.json")) == liveConfig else { throw BridgeError.message("Running wrapper update was not safely refused") }
        let ids = ["app.droidbridge.wrapper.com.android.settings", "app.droidbridge.wrapper.dev.droidbridge.iconfixture.player"]
        var identities: [[String: Any]] = []
        for id in ids {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first(where: { $0.bundleURL?.path.hasPrefix(root.path) == true }), app.activationPolicy == .regular, let icon = app.icon, icon.isValid else { throw BridgeError.message("Missing regular app identity/icon: \(id)") }
            let expected = id.hasSuffix(".player") ? png : settingsPNG
            guard let expectedImage = NSImage(data: expected) else { throw BridgeError.message("Cannot decode expected icon") }
            if let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let image = bitmap.representation(using: .png, properties: [:]) { try image.write(to: evidence.appendingPathComponent(id + "-running-icon.png")) }
            try expected.write(to: evidence.appendingPathComponent(id + "-android-icon.png"))
            guard let bundle = app.bundleURL, let stored = NSImage(contentsOf: bundle.appendingPathComponent("Contents/Resources/AndroidApp.icns")) else { throw BridgeError.message("Running Android ICNS is missing") }
            let rawPixels = try pixels(stored), androidPixels = try pixels(expectedImage)
            let rawDifference = zip(rawPixels, androidPixels).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(rawPixels.count)
            guard rawDifference < 4 else { throw BridgeError.message("Bundled ICNS differs from original Android icon: \(rawDifference)") }
            // macOS 26 adds a platform container to legacy ICNS app icons. Compare
            // the running identity to that same public Launch Services rendering,
            // while independently proving the stored ICNS contains Android pixels.
            let expectedPresentation = NSWorkspace.shared.icon(forFile: bundle.path)
            let actualPixels = try pixels(icon), expectedPixels = try pixels(expectedPresentation)
            let genericPixels = try pixels(NSWorkspace.shared.icon(forFile: host.path))
            let genericDifference = zip(actualPixels, genericPixels).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(actualPixels.count)
            guard genericDifference > 10 else { throw BridgeError.message("Running identity retained the generic DroidBridge icon") }
            let difference = zip(actualPixels, expectedPixels).reduce(0.0) { $0 + Double(abs(Int($1.0) - Int($1.1))) } / Double(actualPixels.count)
            guard difference < 4 else { throw BridgeError.message("Running application icon differs from Android bitmap: \(id), mean error \(difference)") }
            identities.append(["identifier": id, "pid": app.processIdentifier, "name": app.localizedName ?? "", "regular": true, "icon_representations": icon.representations.count, "platform_icon_mean_pixel_error": difference, "original_android_icns_mean_pixel_error": rawDifference, "difference_from_generic_host": genericDifference])
        }
        guard let fallbackParent = NSRunningApplication(processIdentifier: processes[1].processIdentifier), fallbackParent.activationPolicy == .accessory else { throw BridgeError.message("Fallback parent left an extra regular Dock/Cmd+Tab identity") }
        try JSONSerialization.data(withJSONObject: identities, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("identities.json"))
        try JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("session-events.json"))
        for process in processes { _ = NSRunningApplication(processIdentifier: process.processIdentifier)?.terminate() }
        for _ in 0..<100 { if processes.allSatisfy({ !$0.isRunning }) { break }; try await Task.sleep(nanoseconds: 200_000_000) }
        guard processes.allSatisfy({ !$0.isRunning }) else { throw BridgeError.message("Wrapper normal quit did not complete") }
    }
}
