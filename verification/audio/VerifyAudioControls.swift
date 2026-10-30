import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

/// No devices, subprocesses, shared preference mutations or real audio output
/// are used. Audio preferences are an injected in-memory store.
@MainActor final class FixtureAudioRouter: DeviceAudioRouting {
    var onStatusChange: ((String, DeviceAudioStatus) -> Void)?
    var statuses: [String: DeviceAudioStatus] = [:]
    var reconciliations: [(Set<String>, Set<String>, [String: DeviceAudioRoute])] = []
    var retries: [String] = []
    var stopped = false
    func reconcile(activeSerials: Set<String>, connectedSerials: Set<String>, routes: [String: DeviceAudioRoute]) {
        reconciliations.append((activeSerials, connectedSerials, routes))
    }
    func retry(serial: String) { retries.append(serial) }
    func status(for serial: String) -> DeviceAudioStatus {
        statuses[serial] ?? DeviceAudioStatus(route: .phone, phase: .phone, message: "Phone route available")
    }
    func publish(_ serial: String, route: DeviceAudioRoute, phase: DeviceAudioPhase, message: String) {
        statuses[serial] = DeviceAudioStatus(route: route, phase: phase, message: message)
        onStatusChange?(serial, statuses[serial]!)
    }
    func shutdown() async { stopped = true }
}

@main struct VerifyAudioControls {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run(); print("PASS: shipping audio UI route scope, readiness, transition/error/retry, persistence refusal and shutdown fixtures"); fflush(stdout); exit(0) }
            catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
        }
        NSApplication.shared.run()
    }
    @MainActor static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw BridgeError.message(message) }
    }
    @MainActor static func run() async throws {
        let router = FixtureAudioRouter()
        var saved: [String: DeviceAudioRoute] = [:]
        var readFails = false, writeFails = false
        let controls = AudioControls(router: router, loadRoutes: {
            if readFails { throw BridgeError.message("Fixture preference read unavailable") }
            return saved
        }, saveRoute: { serial, route in
            if writeFails { throw BridgeError.message("Fixture preference lock busy") }
            if saved[serial] == nil && saved.count >= 32 { throw BridgeError.message("Audio preferences support at most 32 devices") }
            saved[serial] = route
        })
        let launcher = LauncherController(audioControls: controls)
        defer { launcher.window?.orderOut(nil) }
        try require(controls.presentation(for: nil).route == .mac, "New-device default is not Mac")
        try require(!launcher.audioRoutePicker.isEnabled, "No-device chooser must be disabled")
        let device = AndroidDevice(serial: "qa-audio-A", model: "Audio Fixture A")
        launcher.devices = [device]
        launcher.devicePicker.removeAllItems(); launcher.devicePicker.addItem(withTitle: device.model)
        launcher.devicePicker.selectItem(at: 0)
        launcher.readySerials = [device.serial]
        controls.reconcile(activeSerials: [device.serial], connectedSerials: [device.serial])
        router.publish(device.serial, route: .mac, phase: .starting, message: "Initializing Mac output")
        try require(launcher.audioStatus.stringValue.contains("Starting audio"), "Starting state not visible")
        router.publish(device.serial, route: .mac, phase: .ready, message: "Output initialized; this does not confirm audible sound")
        try require(launcher.audioStatus.stringValue.contains("Mac output initialized"), "Initialized state not visible")
        try require(!launcher.audioStatus.stringValue.contains("playing"), "Ready state claims audible playback")
        let longFailure = "No Mac audio output is available. Select an output in System Settings → Sound, then Retry, or choose Phone. Video sessions continue independently."
        router.publish(device.serial, route: .mac, phase: .failed, message: longFailure)
        launcher.window?.contentView?.layoutSubtreeIfNeeded()
        try require(launcher.audioStatus.lineBreakMode == .byWordWrapping && launcher.audioStatus.maximumNumberOfLines == 5,
            "Audio error must wrap within five lines")
        try require(launcher.audioStatus.toolTip == launcher.audioStatus.stringValue && launcher.audioStatus.stringValue.contains(longFailure),
            "Full actionable audio error was lost")
        let messageWidth = launcher.audioStatus.bounds.width
        let measuredHeight = launcher.audioStatus.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: messageWidth, height: 1000)).height ?? 0
        try require(messageWidth > 100 && measuredHeight > 3 * (launcher.audioStatus.font?.pointSize ?? 11),
            "Long audio error did not occupy multiple visible wrapped lines")
        try require(launcher.audioStatus.bounds.height >= min(measuredHeight, 5 * 14) - 2,
            "Audio error view clipped its wrapped line layout")
        try require(!launcher.audioRetry.isHidden && launcher.audioRetry.isEnabled && !launcher.audioUsePhone.isHidden && launcher.audioUsePhone.isEnabled, "Failed audio lacks recovery controls")
        launcher.audioRetry.performClick(nil)
        try require(router.retries == [device.serial], "Retry targeted a different device")
        launcher.audioUsePhone.performClick(nil)
        try require(saved[device.serial] == .phone, "Phone fallback did not update exact shared-route identity")
        try require(controls.presentation(for: device.serial).phase == .failed && controls.presentation(for: device.serial).canRetry,
            "Phone ownership probe failure was hidden")
        router.publish(device.serial, route: .mac, phase: .shared, message: "Mac owner is releasing")
        try require(controls.presentation(for: device.serial).phase == .starting, "Phone selection incorrectly claims an old Mac owner has stopped")
        router.publish(device.serial, route: .phone, phase: .phone, message: "Phone selected")
        try require(controls.presentation(for: device.serial).phase == .phone, "Phone confirmation not reflected")
        launcher.audioRoutePicker.selectItem(at: 2); launcher.audioRouteChanged(launcher.audioRoutePicker)
        try require(saved[device.serial] == .macAndPhone && saved.count == 1, "Chooser mutated another device or wrong route")
        router.publish(device.serial, route: .mac, phase: .shared, message: "Another wrapper owns Mac routing")
        try require(controls.presentation(for: device.serial).phase == .starting, "Requested/actual route mismatch claims ready")
        router.publish(device.serial, route: .macAndPhone, phase: .shared, message: "Another wrapper owns this route")
        try require(controls.presentation(for: device.serial).phase == .shared, "Shared ownership not visible")
        let appDelegate = AppDelegate(); appDelegate.launcher = launcher; appDelegate.updateAudioMenu()
        try require(appDelegate.audioMenu.items.contains(where: { $0.title == "Device-wide · includes other Android apps" }), "Menu omits device-wide scope")
        try require(appDelegate.audioMenu.items.first(where: { $0.title == "Mac + Phone" })?.state == .on, "Menu route does not match this device's preference")
        router.publish(device.serial, route: .macAndPhone, phase: .failed, message: "Output initialization failed; video remains available")
        appDelegate.updateAudioMenu()
        try require(appDelegate.audioMenu.items.contains(where: { $0.title == "Retry Audio" && $0.isEnabled }) && appDelegate.audioMenu.items.contains(where: { $0.title == "Use Phone" && $0.isEnabled }), "Wrapper menu omits failed-state recovery")
        writeFails = true
        do { try controls.setRoute(.phone, serial: device.serial); throw BridgeError.message("Expected settings refusal") }
        catch { try require(saved[device.serial] == .macAndPhone, "Refused write changed route") }
        try require(controls.presentation(for: device.serial).phase == .failed, "Preference write error hidden")
        writeFails = false; readFails = true
        controls.reconcile(activeSerials: [device.serial], connectedSerials: [device.serial])
        try require(router.reconciliations.last?.0.isEmpty == true, "Unknown shared decision admitted Mac capture")
        try require(router.reconciliations.last?.2[device.serial] == .macAndPhone,
            "Preference read failure rewrote the last accepted shared audio route")
        readFails = false; controls.retry(serial: device.serial)
        launcher.readySerials = []; controls.reconcile(activeSerials: [], connectedSerials: [])
        try require(launcher.audioRoutePicker.item(at: 0)?.isEnabled == false && launcher.audioRoutePicker.item(at: 1)?.isEnabled == true, "Offline capture admission or phone escape invalid")
        // Capacity must remain bounded; a new device gets the safe Phone
        // decision without inventing a 33rd saved preference or claiming Mac.
        saved = Dictionary(uniqueKeysWithValues: (0..<32).map { ("qa-known-\($0)", DeviceAudioRoute.mac) })
        let freshSerial = "qa-new-33"
        controls.reconcile(activeSerials: [freshSerial], connectedSerials: [freshSerial])
        router.publish(freshSerial, route: .mac, phase: .shared, message: "Previous Mac owner is releasing")
        try require(controls.presentation(for: freshSerial).phase == .starting,
            "Capacity fallback prematurely claimed Phone while old Mac owner remained")
        router.publish(freshSerial, route: .phone, phase: .phone, message: "No owner at last check")
        let capacity = controls.presentation(for: freshSerial)
        try require(capacity.route == .phone && capacity.phase == .phone && !capacity.canUsePhone,
            "Unknown device at preference capacity did not select safe Phone")
        try require(capacity.message.contains("32 devices") && capacity.message.contains("without adding a saved preference") && capacity.message.contains("Mac capture will not start"),
            "Preference capacity explanation is missing or claims Mac capture")
        try require(router.reconciliations.last?.2.count == 32 && router.reconciliations.last?.2[freshSerial] == nil && saved.count == 32,
            "Capacity fallback manufactured a 33rd saved preference")
        try require(controls.presentation(for: "qa-known-0").route == .mac,
            "Capacity fallback changed a known device's route")
        do { try controls.setRoute(.mac, serial: freshSerial); throw BridgeError.message("Expected capacity refusal") }
        catch { try require(saved[freshSerial] == nil && saved.count == 32, "Capacity refusal changed saved routes") }
        try require(controls.presentation(for: freshSerial).route == .phone && controls.presentation(for: freshSerial).phase == .failed,
            "Explicit Mac capacity refusal was hidden or selected Mac")
        controls.retry(serial: freshSerial)
        try require(controls.presentation(for: freshSerial).phase == .phone,
            "Retry bypassed safe capacity fallback")
        let sessionCount = launcher.sessions.count
        await controls.shutdown()
        try require(router.stopped && launcher.sessions.count == sessionCount, "Audio shutdown altered video session registry")
        let count = router.reconciliations.count
        controls.reconcile(activeSerials: [device.serial], connectedSerials: [device.serial])
        try require(router.reconciliations.count == count, "Late reconciliation resurrected shutdown audio")
    }
}
