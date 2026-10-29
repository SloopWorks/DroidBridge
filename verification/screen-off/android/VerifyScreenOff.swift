import AppKit
import CryptoKit
import DroidBridgeCore
import DroidBridgeStreaming

@main struct VerifyScreenOff {
    @MainActor static func main() {
        let app = NSApplication.shared
        Task { @MainActor in
            do { try await run(); print("SCREEN OFF NATIVE PASS"); exit(0) }
            catch { fputs("SCREEN OFF NATIVE FAIL: \(error)\n", stderr); exit(1) }
        }
        app.run()
    }
    @MainActor static func run() async throws {
        let env = ProcessInfo.processInfo.environment
        let serial = env["DROIDBRIDGE_TEST_SERIAL"] ?? "emulator-5580"
        guard ["emulator-5580", "emulator-5582"].contains(serial), let path = env["DROIDBRIDGE_SCREEN_OFF_EVIDENCE"] else { throw BridgeError.message("Dedicated test serial and evidence directory required") }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("native-results.json"))
        let tools = Toolchain(), device = AndroidDevice(serial: serial, model: "Screen-off dedicated AVD")
        func adb(_ args: [String]) async throws -> String { try await ProcessRunner.run(tools.adb, arguments: ["-s", serial] + args).output }
        let api = Int(try await adb(["shell", "getprop", "ro.build.version.sdk"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        func save(_ data: String, _ name: String) throws { try data.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        func displayFacts(_ name: String) async throws -> String {
            let text = try await adb(["shell", "cmd", "display", "get-displays"])
            try save(text, name); return text
        }
        func panelState(_ text: String) throws -> String {
            let line = text.components(separatedBy: .newlines).first { $0.hasPrefix("Display id 0:") } ?? ""
            let pattern = #"\bstate ([A-Z_]+)"#
            let expression = try NSRegularExpression(pattern: pattern)
            guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let range = Range(match.range(at: 1), in: line) else { throw BridgeError.message("Cannot establish the physical display state: \(line)") }
            return String(line[range])
        }
        func waitPanel(_ wanted: String, file: String) async throws {
            for _ in 0..<30 {
                let facts = try await displayFacts(file)
                if try panelState(facts) == wanted { return }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            throw BridgeError.message("Physical display did not reach \(wanted)")
        }
        func restorePanel() async throws {
            if api >= 37 {
                _ = try await adb(["shell", "cmd", "display", "power-reset", "0"])
                let afterReset = try await displayFacts("restore-reset-displays.txt")
                if try panelState(afterReset) != "ON" { _ = try await adb(["shell", "cmd", "power", "wakeup", "--display-id", "0"]) }
            } else { _ = try await adb(["shell", "cmd", "display", "power-on", "0"]) }
            try await waitPanel("ON", file: "restored-displays.txt")
        }
        func forwards(_ text: String) -> Set<String> { Set(text.split(separator: "\n").map(String.init).filter { $0.hasPrefix(serial + " ") }) }
        func png(_ image: CGImage?, _ name: String) throws {
            guard let image, let output = CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil) else { throw BridgeError.message("No actual decoded frame") }
            CGImageDestinationAddImage(output, image, nil)
            guard CGImageDestinationFinalize(output) else { throw BridgeError.message("PNG export failed") }
        }
        let baseline = try await displayFacts("baseline-displays.txt")
        let baselineState = try panelState(baseline)
        guard ["ON", "OFF"].contains(baselineState) else { throw BridgeError.message("Cannot safely alter baseline panel state \(baselineState)") }
        let baselineForwards = forwards(try await adb(["forward", "--list"]))
        let baselineDeviceCount = try await adb(["shell", "dumpsys", "display"]).components(separatedBy: "DisplayDeviceInfo{").count
        let settingsBefore = try await adb(["shell", "settings", "get", "global", "stay_on_while_plugged_in"]) + adb(["shell", "settings", "get", "system", "screen_off_timeout"])
        try save(settingsBefore, "settings-before.txt")
        _ = try await adb(["logcat", "-c"])
        let a = BridgeSession(descriptor: SessionDescriptor(device: device, application: AndroidApplication(packageName: "dev.droidbridge.testapp", name: "Screen off A"), configuration: SessionConfiguration(backend: .native, showSystemDecorations: false)), toolchain: tools)
        let b = BridgeSession(descriptor: SessionDescriptor(device: device, application: AndroidApplication(packageName: "dev.droidbridge.testapp2", name: "Screen off B"), configuration: SessionConfiguration(backend: .native, showSystemDecorations: false)), toolchain: tools)
        var latestA: CGImage?, latestB: CGImage?, hashesA = Set<Data>(), hashesB = Set<Data>()
        a.onFrame = { latestA = $0; if let bytes = $0.dataProvider?.data { hashesA.insert(Data(SHA256.hash(data: bytes as Data))) } }
        b.onFrame = { latestB = $0; if let bytes = $0.dataProvider?.data { hashesB.insert(Data(SHA256.hash(data: bytes as Data))) } }
        var changedPanel = false
        do {
            try await a.start(); try await b.start()
            func launchedDisplay(_ session: BridgeSession) async throws -> Int {
                let expression = try NSRegularExpression(pattern: #"Starting app .* on display (\d+)"#)
                for _ in 0..<40 {
                    let text = (try? String(contentsOf: session.logURL, encoding: .utf8)) ?? ""
                    if let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let range = Range(match.range(at: 1), in: text), let id = Int(text[range]) { return id }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                throw BridgeError.message("No display-specific package launch receipt")
            }
            let displayA = try await launchedDisplay(a), displayB = try await launchedDisplay(b)
            guard displayA != displayB else { throw BridgeError.message("The two sessions did not receive distinct Android displays") }
            let processes = try await ProcessRunner.run("/bin/ps", arguments: ["-ww", "-axo", "pid=,command="])
            let serverCommands = processes.output.components(separatedBy: .newlines).filter { line in
                let command = line.replacingOccurrences(of: #"^\s*\d+\s+"#, with: "", options: .regularExpression)
                return command.hasPrefix(tools.adb + " -s " + serial + " shell CLASSPATH=/data/local/tmp/droidbridge-") && command.contains(" com.genymobile.scrcpy.Server 5.0.1 ")
            }
            guard serverCommands.count == 2, serverCommands.allSatisfy({ $0.contains("keep_active=true") && $0.contains("power_on=false") && $0.contains("display_ime_policy=local") }) else { throw BridgeError.message("The two actual production server processes do not carry the tested keep-active/power-on/local-IME policy") }
            try save(serverCommands.joined(separator: "\n") + "\n", "native-production-server-processes.txt")
            try await Task.sleep(nanoseconds: 800_000_000)
            try png(latestA, "native-a-before.png"); try png(latestB, "native-b-before.png")
            _ = try await adb(["shell", "cmd", "display", "power-off", "0"]); changedPanel = baselineState == "ON"
            try await waitPanel("OFF", file: "off-displays.txt")
            try save(try await adb(["shell", "dumpsys", "power"]), "off-power.txt")
            let framesOffA = a.metrics.frames, framesOffB = b.metrics.frames
            let hashesOffA = hashesA.count, hashesOffB = hashesB.count
            // Three keep-active cycles with no interaction first.
            try await Task.sleep(nanoseconds: 12_000_000_000)
            guard a.metrics.frames > framesOffA + 10, b.metrics.frames > framesOffB + 10, hashesA.count > hashesOffA + 10, hashesB.count > hashesOffB + 10 else { throw BridgeError.message("Independent streams did not keep producing changing frames while panel was off") }
            try await waitPanel("OFF", file: "off-after-idle-displays.txt")
            var receipts = ""
            for (session, word, display) in [(a, "PanelOffA", displayA), (b, "PanelOffB", displayB)] {
                for action: UInt8 in [0, 1] { session.sendInput(.touch(action: action, x: 300, y: 225, width: 720, height: 1080)) }
                for action: UInt8 in [0, 1] { session.sendInput(.touch(action: action, x: 300, y: 295, width: 720, height: 1080)) }
                try await Task.sleep(nanoseconds: 400_000_000)
                session.sendInput(.text(word))
                for _ in 0..<40 {
                    try await Task.sleep(nanoseconds: 200_000_000)
                    receipts = try await adb(["logcat", "-d", "-s", "DroidBridgeProbe:I", "*:S"])
                    if receipts.contains("text=\(word) display=\(display)") { break }
                }
                guard receipts.contains("text=\(word) display=\(display)"), receipts.contains("click=1 display=\(display)") else {
                    try save(receipts, "native-failed-input.log")
                    try save(try await adb(["shell", "dumpsys", "input"]), "native-failed-input-state.txt")
                    try save(try await adb(["shell", "dumpsys", "input_method"]), "native-failed-input-method.txt")
                    try png(session === a ? latestA : latestB, "native-failed-input-frame.png")
                    _ = try await adb(["shell", "input", "-d", String(display), "text", "ADBDiagnostic"])
                    try await Task.sleep(nanoseconds: 400_000_000)
                    try save(try await adb(["logcat", "-d", "-s", "DroidBridgeProbe:I", "*:S"]), "native-failed-input-adb-diagnostic.log")
                    throw BridgeError.message("Input while physical display off did not reach the correct app: \(receipts)")
                }
            }
            try save(receipts, "native-input.log")
            try await waitPanel("OFF", file: "off-after-input-displays.txt")
            try png(latestA, "native-a-off-input.png"); try png(latestB, "native-b-off-input.png")
            a.resize(width: 896, height: 640)
            for _ in 0..<80 {
                if latestA?.width == 896, latestA?.height == 640 { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard latestA?.width == 896, latestA?.height == 640 else { throw BridgeError.message("Resize while panel off failed") }
            try png(latestA, "native-a-off-resized.png")
            let bFrames = b.metrics.frames
            await a.stopAndWait()
            try await Task.sleep(nanoseconds: 1_000_000_000)
            try await waitPanel("OFF", file: "off-one-session-closed.txt")
            guard b.metrics.frames > bFrames else { throw BridgeError.message("Other stream stopped when the first session closed") }
            await b.stopAndWait()
            try await waitPanel("OFF", file: "off-all-sessions-closed-before-restore.txt")
            if changedPanel { try await restorePanel(); changedPanel = false }
            let settingsAfter = try await adb(["shell", "settings", "get", "global", "stay_on_while_plugged_in"]) + adb(["shell", "settings", "get", "system", "screen_off_timeout"])
            try save(settingsAfter, "settings-after.txt")
            guard settingsAfter == settingsBefore else { throw BridgeError.message("Experiment changed a global timeout/awake setting") }
            try await Task.sleep(nanoseconds: 400_000_000)
            guard forwards(try await adb(["forward", "--list"])) == baselineForwards else { throw BridgeError.message("Owned forward was not cleaned") }
            guard try await adb(["shell", "dumpsys", "display"]).components(separatedBy: "DisplayDeviceInfo{").count == baselineDeviceCount else { throw BridgeError.message("Virtual display count was not restored") }
            let report: [String: Any] = ["serial": serial, "api": api, "displayIDs": [displayA, displayB], "usesUnmodifiedProductionADB": true, "baselinePanel": baselineState, "physicalPanelOffObserved": true, "idleSeconds": 12, "aFramesWhileOff": a.metrics.frames - framesOffA, "bFramesWhileOff": b.metrics.frames - framesOffB, "aDistinctFramesWhileOff": hashesA.count - hashesOffA, "bDistinctFramesWhileOff": hashesB.count - hashesOffB, "twoAppClickAndText": true, "independentClose": true, "resize": "896x640", "settingsUnchanged": true, "cleanup": true]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("native-results.json"))
        } catch {
            await a.stopAndWait(); await b.stopAndWait()
            if changedPanel { try? await restorePanel() }
            throw error
        }
    }
}
