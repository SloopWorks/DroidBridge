import AppKit
import Foundation
import DroidBridgeCore
import DroidBridgeStreaming

/// Compiles unmodified shipping UI sources. All subprocesses are explicit fake
/// tools: this regression never contacts a device or starts shared ADB.
@main struct WrapperFailureVerification {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); print("PASS: shipping wrapper retains pre-frame clean exit, post-running clean exit, first failure cause, retry successor beyond stale close timer, and bounded icon shutdown cleanup"); fflush(stdout); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }
    @MainActor static func require(_ value: Bool, _ message: String) throws { if !value { throw BridgeError.message(message) } }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<400 { if condition() { return }; try await Task.sleep(nanoseconds:25_000_000) }
        throw BridgeError.message("Timed out waiting for terminal lifecycle state")
    }
    @MainActor static func buttons(_ view: NSView) -> [String] { (view as? NSButton).map { [$0.title] } ?? view.subviews.flatMap(buttons) }
    @MainActor static func assertRetained(_ launcher: LauncherController, _ session: BridgeSession, label: String) throws {
        let id = session.descriptor.id
        try require(launcher.sessions[id] === session, "\(label): intent removed")
        try require(launcher.sessionErrors[id]?.isEmpty == false, "\(label): missing visible failure reason")
        try require(launcher.window?.isVisible == true, "\(label): launcher hidden")
        try require(NSApp.activationPolicy() == .regular, "\(label): wrapper identity remained accessory")
        let titles = buttons(launcher.sessionList)
        try require(titles.contains("Retry") && titles.contains("Log") && titles.contains(session.descriptor.configuration.backend == .native ? "Try scrcpy" : "Try Native"), "\(label): missing recovery controls \(titles)")
        let output = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("verification/launcher-fix/qa")
        let name = label.replacingOccurrences(of:" ",with:"-")
        for source in [session.logURL,session.logURL.appendingPathExtension("jsonl")] {
            if FileManager.default.fileExists(atPath:source.path) {
                let target = output.appendingPathComponent(name + (source.pathExtension == "jsonl" ? ".jsonl" : ".log"))
                try? FileManager.default.removeItem(at:target); try FileManager.default.copyItem(at:source,to:target)
            }
        }
        print("PASS: \(label) retained with reason: \(launcher.sessionErrors[id]!)")
    }
    @MainActor static func run() async throws {
        let modeURL = URL(fileURLWithPath:ProcessInfo.processInfo.environment["DROIDBRIDGE_QA_MODE"]!)
        let launcher = LauncherController()
        let device = AndroidDevice(serial:"qa-no-device", model:"No-device lifecycle fixture")
        let application = AndroidApplication(packageName:"dev.droidbridge.testapp",name:"Failure retention fixture")
        try "native-present".write(to:modeURL, atomically:true, encoding:.utf8)
        let starting = Task { @MainActor in await launcher.launch(device:device,app:application,configuration:SessionConfiguration(backend:.native),readinessChecked:true) }
        try await wait { launcher.hosts.values.first?.session.state == .starting }
        let host = launcher.hosts.values.first!
        host.window?.miniaturize(nil); host.window?.orderOut(nil)
        try require(host.window?.isVisible == false, "Could not establish hidden startup host")
        guard let presented = await starting.value else { throw BridgeError.message("Missing presentation session") }
        try require(presented.state == .running && presented.metrics.frames > 0, "Synthetic fixture did not produce a real decoded first frame")
        try require(host.window?.isMiniaturized == true, "First decoded frame undid deliberate loading minimize")
        func presentationEvents() throws -> [[String:Any]] {
            let text = try String(contentsOf:presented.logURL.appendingPathExtension("jsonl"),encoding:.utf8)
            return text.split(separator:"\n").compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String:Any] }
        }
        let firstEvents = try presentationEvents()
        try require(firstEvents.contains { event in
            let details = event["details"] as? [String:String]
            return event["event"] as? String == "native_window_presented" && details?["reason"] == "first_frame" && details?["minimized"] == "true"
        }, "Missing accurate first-frame presentation receipt")
        launcher.hideLauncherIfUsable(presented)
        host.window?.orderOut(nil)
        let previousIDs = Set(launcher.sessions.keys)
        launcher.reopen()
        try require(host.window?.isVisible == true && !host.window!.isMiniaturized && Set(launcher.sessions.keys) == previousIDs, "Reopen failed to reveal existing window without admitting another Android session")
        let reopenEvents = try presentationEvents()
        try require(reopenEvents.contains { ($0["details"] as? [String:String])?["reason"] == "application_reopen" }, "Missing reopen presentation receipt")
        let output = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("verification/launcher-fix/qa/presentation.json")
        try JSONSerialization.data(withJSONObject:reopenEvents,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("PASS: decoded first frame preserves deliberate loading minimize; Reopen reveals same session; accurate receipts; OS foreground focus unasserted")
        launcher.close(presented.descriptor.id)
        await presented.stopAndWait()
        try "native-clean".write(to:modeURL, atomically:true, encoding:.utf8)
        let native = await launcher.launch(device:device,app:application,configuration:SessionConfiguration(backend:.native),readinessChecked:true)!
        try await wait { native.state == .stopped || native.state == .failed }
        try require(native.metrics.frames == 0, "Pre-frame fixture unexpectedly decoded a frame")
        try assertRetained(launcher,native,label:"clean child exit before first native frame")
        try require(native.state == .failed && launcher.sessionErrors[native.descriptor.id]?.contains("before the first decoded video frame (exit status 0)") == true, "Clean pre-frame exit lost explicit phase or clean exit status")
        launcher.close(native.descriptor.id)
        try "native-fault".write(to:modeURL, atomically:true, encoding:.utf8)
        let fault = await launcher.launch(device:device,app:application,configuration:SessionConfiguration(backend:.native),readinessChecked:true)!
        try await wait { fault.state == .stopped || fault.state == .failed }
        try assertRetained(launcher,fault,label:"specific native transport failure during startup")
        try require(launcher.sessionErrors[fault.descriptor.id]?.contains("Invalid video packet size") == true, "Startup cancellation overwrote initiating failure: \(launcher.sessionErrors[fault.descriptor.id] ?? "missing")")
        launcher.close(fault.descriptor.id)
        try "scrcpy-clean".write(to:modeURL, atomically:true, encoding:.utf8)
        let external = await launcher.launch(device:device,app:application,configuration:SessionConfiguration(backend:.scrcpy),readinessChecked:true)!
        try require(external.state == .running, "External fixture never reached running admission")
        try await wait { external.state == .stopped || external.state == .failed }
        try assertRetained(launcher,external,label:"clean child exit after external running admission")
        launcher.retry(external.descriptor.id,backend:.scrcpy)
        try await wait { !launcher.sessions.keys.contains(external.descriptor.id) && launcher.sessions.count == 1 && launcher.sessions.values.first?.state == .stopped }
        let successor = launcher.sessions.values.first!
        // Production close(old) scheduled a three-second termination. A failed
        // replacement must remain reviewable after that old deadline expires.
        try await Task.sleep(nanoseconds:3_600_000_000)
        try assertRetained(launcher,successor,label:"retry successor survives stale close deadline")
        // UI cache bounds hold across device/package histories, including failures.
        for index in 0..<180 {
            let key = "history:dev.icon.app\(index)"
            launcher.iconData[key] = Data([1]); launcher.icons[key] = NSImage(size:NSSize(width:1,height:1))
            launcher.touchIcon(key)
        }
        try require(launcher.iconData.count == 128 && launcher.icons.count == 128 && launcher.iconRecency.count == 128, "Icon cache exceeded 128-entry bound")
        try "icons-slow".write(to:modeURL, atomically:true, encoding:.utf8)
        for index in 0..<90 {
            launcher.requestIcon(device,AndroidApplication(packageName:"dev.icon.app\(index)",name:"Icon \(index)"))
        }
        try require(launcher.iconTasks.count <= 2 && launcher.iconQueue.count <= 64, "Icon queue/in-flight work exceeded admission bounds")
        let calls = URL(fileURLWithPath:modeURL.path + ".calls")
        try await wait {
            let lines = (try? String(contentsOf:calls,encoding:.utf8))?.components(separatedBy:.newlines) ?? []
            return lines.filter { $0.contains("droidbridge-icon-") && $0.contains("push") }.count == 2
        }
        // Switching away discards queued stale work; shutdown must still await
        // both canceled providers' exact temporary-file cleanup subprocesses.
        launcher.discardStaleIconRequests()
        try require(launcher.iconQueue.isEmpty, "Device selection left stale icon work queued")
        launcher.refreshDevices()
        try await wait {
            launcher.refreshTask != nil && FileManager.default.fileExists(atPath:modeURL.path + ".refresh-started")
        }
        await launcher.shutdownAndWait()
        try require(launcher.refreshTask == nil && !launcher.refreshing, "Shutdown returned with an owned asynchronous refresh/recovery still active")
        let cleaned = (try? String(contentsOfFile:modeURL.path + ".cleaned",encoding:.utf8))?.split(separator:"\n") ?? []
        try require(cleaned.count == 2 && launcher.iconTasks.isEmpty, "Shutdown returned before canceled icon providers removed exact temporary files")
        print("PASS: icon cache128, queue64, concurrency2, stale-device discard, shutdown awaited two actual provider cleanups, and canceled refresh task drained")
    }
}
