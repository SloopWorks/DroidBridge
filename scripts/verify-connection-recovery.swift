import AppKit
import ImageIO
import UniformTypeIdentifiers
import DroidBridgeCore
import DroidBridgeStreaming

/// Shipping launcher + real Android video. Only the private QA root and
/// emulator-5580 may be used; no physical device or shared ADB lifecycle control.
@main struct VerifyConnectionRecovery {
    static let device = AndroidDevice(serial: "emulator-5580", model: "Recovery API35")
    static let application = AndroidApplication(packageName: "dev.droidbridge.testapp7", name: "Recovery Probe")
    static let evidence = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DROIDBRIDGE_RECOVERY_EVIDENCE"]!)
    @MainActor static var reports: [[String: Any]] = []
    @MainActor static var seen: [BridgeSession] = []
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
        Task { @MainActor in
            let launcher = LauncherController()
            do {
                guard let scope = CompanionQAScope.current, scope.serial == device.serial else { throw BridgeError.message("Dedicated private QA scope required") }
                try await run(launcher)
                await launcher.shutdownAndWait()
                try saveLogs()
                try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("fixture-results.json"))
                print("PASS: actual native recovery, bounded flapping, sleep wait, manual Retry, close/quit fencing and exact resource cleanup")
                fflush(stdout); exit(0)
            } catch {
                await launcher.shutdownAndWait(); try? saveLogs()
                fputs("FAIL: \(error)\n", stderr); exit(1)
            }
        }
        NSApplication.shared.run()
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw BridgeError.message(message) } }
    @MainActor static func wait(_ message: String, seconds: Double = 12, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return }; try await Task.sleep(for: .milliseconds(25)) }
        throw BridgeError.message("Timed out: \(message)")
    }
    static func android(_ arguments: [String]) async throws -> String {
        let tools = Toolchain()
        return try await ProcessRunner.run(tools.adb, arguments: ["-s",device.serial] + arguments, environment: tools.environment, timeout: 10).output
    }
    @MainActor static func saveLogs() throws {
        for session in seen {
            for source in [session.logURL, session.logURL.appendingPathExtension("jsonl")] where FileManager.default.fileExists(atPath: source.path) {
                let destination = evidence.appendingPathComponent(source.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }
    }
    @MainActor static func capture(_ host: NativeWindowController, _ name: String) throws {
        guard let image = host.video.frameImage,
              let writer = CGImageDestinationCreateWithURL(evidence.appendingPathComponent(name + "-video.png") as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw BridgeError.message("Missing decoded Android frame") }
        CGImageDestinationAddImage(writer, image, nil); try require(CGImageDestinationFinalize(writer), "PNG encoding failed")
    }
    @MainActor static func captureStatus(_ host: NativeWindowController, _ name: String) throws {
        host.video.layoutSubtreeIfNeeded(); host.video.displayIfNeeded()
        guard let bitmap = host.video.bitmapImageRepForCachingDisplay(in: host.video.bounds) else { throw BridgeError.message("No AppKit bitmap") }
        host.video.cacheDisplay(in: host.video.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: evidence.appendingPathComponent(name + "-window.png"))
    }
    @MainActor static func launch(_ launcher: LauncherController) async throws -> BridgeSession {
        guard let session = await launcher.launch(device: device, app: application, configuration: SessionConfiguration(backend: .native), readinessChecked: true) else { throw BridgeError.message("Launch refused") }
        seen.append(session)
        try require(session.state == .running, "Actual native launch failed: \(launcher.sessionErrors[session.descriptor.id] ?? "unknown")")
        try await wait("changing native frames") { session.metrics.frames >= 5 && launcher.hosts[session.descriptor.id]?.video.frameImage != nil }
        return session
    }
    @MainActor static func killOwnedServer(_ session: BridgeSession) async throws {
        guard let scope = CompanionQAScope.current else { throw BridgeError.message("Missing scope") }
        let files = try FileManager.default.contentsOfDirectory(at: scope.receiptDirectory, includingPropertiesForKeys: nil)
        let receipts = try files.compactMap { file -> [String: Any]? in
            let value = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            return value?["ownerPID"] as? Int32 == getpid() ? value : nil
        }
        let events = try String(contentsOf: session.logURL.appendingPathExtension("jsonl"), encoding: .utf8).split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        guard let scid = events.first(where: { $0["event"] as? String == "native_resources" })?["scid"] as? String else { throw BridgeError.message("Missing native resource identity") }
        try require(receipts.contains { $0["scid"] as? String == scid && $0["serial"] as? String == device.serial }, "Missing exact owned session receipt")
        let processes = try await android(["shell", "ps", "-A", "-o", "PID,ARGS"])
        let owned = processes.split(separator: "\n").filter {
            let fields = $0.split(whereSeparator: { $0.isWhitespace })
            return fields.count > 1 && fields[1] == "app_process" && $0.contains("com.genymobile.scrcpy.Server 5.0.1 scid=" + scid + " ")
        }
        try require(owned.count == 1, "Cannot identify exact owned Android server: \(owned)")
        let pid = owned[0].split(whereSeparator: { $0.isWhitespace }).first!
        try require(Int(pid) != nil, "Invalid PID")
        print("Disrupt exact owned Android server scid=\(scid), pid=\(pid), session=\(session.descriptor.id)"); fflush(stdout)
        _ = try await android(["shell", "kill", String(pid)])
    }
    @MainActor static func interrupted(_ launcher: LauncherController, _ session: BridgeSession) async throws {
        try await killOwnedServer(session)
        try await wait("recoverable EOF without device absence") { launcher.sessionStates[session.descriptor.id] == "disconnected" }
        try require(launcher.sessions[session.descriptor.id] === session && launcher.reconnectRetries[session.descriptor.id] != nil, "Transport failure lost recovery intent")
        try require(try await android(["get-state"]).trimmingCharacters(in: .whitespacesAndNewlines) == "device", "Emulator must remain ADB-connected during stream failure")
    }
    @MainActor static func recover(_ launcher: LauncherController, _ previous: BridgeSession) async throws -> BridgeSession {
        if let next = launcher.reconnectRetries[previous.descriptor.id]?.nextAttempt {
            let delay = next.timeIntervalSinceNow
            if delay > 0 { try await Task.sleep(for: .seconds(delay + 0.05)) }
        }
        await launcher.recoverInterruptedSessions(ready: [device.serial])
        guard let session = launcher.sessions.values.first else { throw BridgeError.message("Recovery removed intent") }
        try require(session !== previous && session.state == .running, "Recovery did not create a running successor")
        seen.append(session)
        try await wait("successor decoded content") { session.metrics.frames >= 5 && launcher.hosts[session.descriptor.id]?.video.frameImage != nil }
        return session
    }
    @MainActor static func run(_ launcher: LauncherController) async throws {
        launcher.devices = [device]; launcher.devicePicker.addItems(withTitles: [device.model]); launcher.devicePicker.selectItem(at: 0)
        launcher.readySerials = [device.serial]; launcher.reconnect.state = .on
        _ = try await android(["shell", "input", "keyevent", "224"])
        _ = try await android(["shell", "wm", "dismiss-keyguard"])
        var session = try await launch(launcher)
        let host = launcher.hosts[session.descriptor.id]!, windowNumber = host.window!.windowNumber
        try capture(host, "initial")
        if ProcessInfo.processInfo.arguments.contains("--screen-off-check") {
            let power = PhoneDisplayPower(toolchain: launcher.toolchain)
            try DroidBridgePreferences.update { $0.screenOffDeviceSerials.insert(device.serial) }
            _ = try await power.setScreenOffIfRequested(device: device)
            let frames = session.metrics.frames
            try await wait("frames continue with physical screen off") { session.metrics.frames >= frames + 10 }
            try require(await DeviceVideoReadiness.probe(device: device, toolchain: launcher.toolchain) == .awake, "Physical panel OFF was misclassified as system sleep")
            try capture(host, "physical-panel-off")
            try await interrupted(launcher, session)
            session = try await recover(launcher, session)
            try require(session.state == .running, "Screen-off preference prevented virtual display recovery")
            reports.append(["case": "explicit_physical_panel_off", "continued_frames": frames + 10, "recovered_frames": session.metrics.frames, "policy_preserved": true])
            try DroidBridgePreferences.update { $0.screenOffDeviceSerials.remove(device.serial) }
            _ = try await power.turnScreenOn(device: device)
            host.window?.miniaturize(nil)
            try await wait("test window minimized") { host.window?.isMiniaturized == true }
            try await interrupted(launcher, session)
            session = try await recover(launcher, session)
            try require(host.window?.isMiniaturized == true && host.window?.windowNumber == windowNumber, "Recovery undid minimize or replaced the window")
            host.window?.deminiaturize(nil)
            reports.append(["case": "minimized_recovery", "same_window": true, "remained_minimized": true, "frames": session.metrics.frames])
            launcher.close(session.descriptor.id); await session.stopAndWait()
            return
        }
        for attempt in 1...3 {
            try await interrupted(launcher, session)
            session = try await recover(launcher, session)
            try require(launcher.hosts[session.descriptor.id] === host && host.window?.windowNumber == windowNumber, "Recovery replaced/focused a different Mac window")
            try require(launcher.reconnectRetries[session.descriptor.id]?.failures == attempt, "Running successor reset retry budget")
            reports.append(["case": "connected_transport_failure_\(attempt)", "frames": session.metrics.frames, "attempts": attempt, "same_window": true, "device_absence_observed": false])
        }
        try capture(host, "recovered")
        try await interrupted(launcher, session)
        await launcher.recoverInterruptedSessions(ready: [device.serial])
        try await Task.sleep(for: .seconds(8.1))
        await launcher.recoverInterruptedSessions(ready: [device.serial])
        try require(launcher.sessions[session.descriptor.id] === session && launcher.reconnectRetries[session.descriptor.id]?.failures == 3, "Flapping bypassed the retry ceiling")
        try require(host.video.statusMessage?.contains("three attempts") == true && !host.video.retryButton.isHidden, "Missing actionable exhausted state")
        try captureStatus(host, "retry-limit")
        reports.append(["case": "flapping_ceiling", "attempts": 3, "no_fourth_automatic_launch": true])
        host.video.retryButton.performClick(nil)
        try await wait("manual Retry after exhaustion", seconds: 25) { launcher.sessions.values.contains { $0 !== session && $0.state == .running } }
        session = launcher.sessions.values.first!; seen.append(session)
        try require(launcher.hosts[session.descriptor.id] === host && launcher.reconnectRetries[session.descriptor.id] == nil, "Manual Retry did not reset the recovery intent in the same window")

        let invalid = await launcher.launch(device: device, app: application, configuration: SessionConfiguration(width: 100), readinessChecked: true)!
        seen.append(invalid)
        try require(launcher.sessionStates[invalid.descriptor.id] == "failed" && launcher.reconnectRetries[invalid.descriptor.id] == nil, "Invalid configuration entered automatic recovery")
        await launcher.recoverInterruptedSessions(ready: [device.serial])
        try require(launcher.sessions[invalid.descriptor.id] === invalid, "Permanent failure was relaunched automatically")
        launcher.close(invalid.descriptor.id)
        reports.append(["case": "permanent_failure", "automatic_launches": 0])

        launcher.reconnect.state = .off
        try await interrupted(launcher, session)
        await launcher.recoverInterruptedSessions(ready: [device.serial])
        try require(launcher.sessions[session.descriptor.id] === session && launcher.reconnectRetries[session.descriptor.id]?.failures == 0, "Disabled recovery launched a successor")
        reports.append(["case": "reconnect_disabled", "automatic_launches": 0])
        launcher.reconnect.state = .on
        session = try await recover(launcher, session)

        // End the active virtual display before sleeping the phone. A healthy
        // keep-active virtual display can legitimately keep the system awake.
        try await interrupted(launcher, session)
        _ = try await android(["shell", "input", "-d", "0", "keyevent", "223"])
        try await Task.sleep(for: .seconds(1))
        try require(await DeviceVideoReadiness.probe(device: device, toolchain: launcher.toolchain) == .sleeping, "Dedicated emulator did not sleep")
        let attempts = launcher.reconnectRetries[session.descriptor.id]!.failures
        // Sleep waits must not consume the next retry or open another display.
        try await Task.sleep(for: .seconds(8.1))
        for _ in 0..<3 { await launcher.recoverInterruptedSessions(ready: [device.serial]) }
        try require(launcher.sessions[session.descriptor.id] === session && launcher.reconnectRetries[session.descriptor.id]?.failures == attempts, "Sleeping device consumed recovery launches")
        try require(host.video.statusMessage?.contains("Phone is asleep") == true, "No wake/unlock guidance")
        try captureStatus(host, "waiting-for-wake")
        _ = try await android(["shell", "input", "keyevent", "224"])
        _ = try await android(["shell", "wm", "dismiss-keyguard"])
        session = try await recover(launcher, session)
        reports.append(["case": "sleep_wait_and_wake", "attempts_consumed_while_asleep": 0, "resumed_frames": session.metrics.frames])
        launcher.close(session.descriptor.id); await session.stopAndWait()

        // Launching while asleep returns a wait state without starting a server.
        _ = try await android(["shell", "input", "keyevent", "223"])
        try await Task.sleep(for: .seconds(1))
        let sleeping = await launcher.launch(device: device, app: application, configuration: SessionConfiguration(), readinessChecked: true)!
        seen.append(sleeping)
        try require(sleeping.state == .failed && sleeping.recoveryReason == .deviceSleeping, "Sleeping startup was not classified")
        let sleepingHost = launcher.hosts[sleeping.descriptor.id]!
        try require(launcher.reconnectRetries[sleeping.descriptor.id]?.failures == 0, "Initial sleeping launch consumed recovery budget")
        sleepingHost.window?.performClose(nil)
        _ = try await android(["shell", "input", "keyevent", "224"])
        _ = try await android(["shell", "wm", "dismiss-keyguard"])
        await launcher.recoverInterruptedSessions(ready: [device.serial])
        try require(launcher.sessions.isEmpty && launcher.reconnectRetries.isEmpty, "Closing sleep wait resurrected its window")
        reports.append(["case": "close_sleeping_intent", "resurrected": false])

        // The proxy only delays a real power probe. Close/Quit race against the
        // shipping continuation, not a simulated launch or fake video frame.
        let scope = CompanionQAScope.current!
        for action in ["close", "quit"] {
            let live = try await launch(launcher)
            try await interrupted(launcher, live)
            let delay = scope.root.appendingPathComponent("delay-power"), reached = scope.root.appendingPathComponent("power-reached")
            try? FileManager.default.removeItem(at: reached)
            try Data().write(to: delay)
            let task = Task { await launcher.recoverInterruptedSessions(ready: [device.serial]) }
            try await wait("delayed readiness boundary") { FileManager.default.fileExists(atPath: reached.path) }
            if action == "close" { launcher.close(live.descriptor.id) }
            else { await launcher.shutdownAndWait() }
            await task.value
            try FileManager.default.removeItem(at: delay)
            try require(action == "quit" ? launcher.sessions.values.allSatisfy { $0.state == .stopped } : launcher.sessions.isEmpty, "\(action) resurrected a recovery successor")
            reports.append(["case": "\(action)_during_readiness", "resurrected": false])
        }
        for session in seen { await session.stopAndWait() }
        let forwards = try await android(["forward", "--list"])
        let ownedDeviceForwards = forwards.split(separator: "\n").filter { $0.split(whereSeparator: { $0.isWhitespace }).first == Substring(device.serial) }
        try require(!ownedDeviceForwards.contains(where: { $0.contains("localabstract:scrcpy_") }), "Owned session forward leaked")
        let processes = try await android(["shell", "ps", "-A", "-o", "PID,ARGS"])
        try require(!processes.contains("com.genymobile.scrcpy.Server 5.0.1"), "Owned Android server leaked")
        let receipts = try FileManager.default.contentsOfDirectory(at: scope.receiptDirectory, includingPropertiesForKeys: nil)
        try require(receipts.isEmpty, "Online cleanup left session receipts: \(receipts.map(\.lastPathComponent))")
        reports.append(["case": "exact_cleanup", "remaining_scrcpy_forwards": 0, "remaining_servers": 0, "remaining_receipts": 0])
    }
}
