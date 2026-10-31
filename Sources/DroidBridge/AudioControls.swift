import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

/// Narrow injectable boundary for no-device AppKit verification. Production uses
/// the same device-wide router for native and external video sessions.
@MainActor protocol DeviceAudioRouting: AnyObject {
    var onStatusChange: ((String, DeviceAudioStatus) -> Void)? { get set }
    func reconcile(activeSerials: Set<String>, connectedSerials: Set<String>, routes: [String: DeviceAudioRoute])
    func retry(serial: String)
    func status(for serial: String) -> DeviceAudioStatus
    func shutdown() async
}

extension DeviceAudioRouter: DeviceAudioRouting {}

struct AudioPresentation: Equatable {
    let route: DeviceAudioRoute
    let phase: DeviceAudioPhase
    let message: String
    let canRetry: Bool
    let canUsePhone: Bool

    var title: String {
        switch phase {
        case .phone: return route == .phone ? "Phone audio" : "Audio waiting"
        case .starting: return route == .phone ? "Switching to phone…" : "Starting audio…"
        case .ready: return "Mac output initialized"
        case .shared: return "Shared device audio"
        case .failed: return "Audio unavailable"
        }
    }
}

/// Audio settings/failures never admit, stop or change a video session.
@MainActor final class AudioControls {
    var onChange: ((String?) -> Void)?
    private let router: any DeviceAudioRouting
    private let loadRoutes: () throws -> [String: DeviceAudioRoute]
    private let saveRoute: (String, DeviceAudioRoute) throws -> Void
    private var routes: [String: DeviceAudioRoute] = [:]
    private var activeSerials = Set<String>()
    private var connectedSerials = Set<String>()
    private var preferenceError: String?
    private var mutationErrors: [String: String] = [:]
    private var stopped = false

    convenience init(toolchain: Toolchain) {
        self.init(router: DeviceAudioRouter(toolchain: toolchain), loadRoutes: {
            try DeviceAudioPreferences.loadRoutes()
        }, saveRoute: { serial, route in
            _ = try DeviceAudioPreferences.setRoute(route, for: serial)
        })
    }

    init(router: any DeviceAudioRouting,
         loadRoutes: @escaping () throws -> [String: DeviceAudioRoute],
         saveRoute: @escaping (String, DeviceAudioRoute) throws -> Void) {
        self.router = router; self.loadRoutes = loadRoutes; self.saveRoute = saveRoute
        do { routes = try loadRoutes() }
        catch { preferenceError = "Could not read audio settings. \(error.localizedDescription)" }
        router.onStatusChange = { [weak self] serial, _ in
            guard let self, !self.stopped else { return }
            self.onChange?(serial)
        }
    }

    func reconcile(activeSerials: Set<String>, connectedSerials: Set<String>) {
        guard !stopped else { return }
        self.activeSerials = activeSerials; self.connectedSerials = connectedSerials
        do {
            routes = try loadRoutes(); preferenceError = nil
            router.reconcile(activeSerials: activeSerials, connectedSerials: connectedSerials, routes: routes)
        } catch {
            // Fail closed to normal phone routing when the shared preference
            // decision cannot be read. A later poll or Retry may recover it.
            preferenceError = "Could not read audio settings. \(error.localizedDescription)"
            router.reconcile(activeSerials: [], connectedSerials: connectedSerials, routes: routes)
        }
        onChange?(nil)
    }

    func setRoute(_ route: DeviceAudioRoute, serial: String) throws {
        guard !stopped else { return }
        try AndroidDiscovery.validateSerial(serial)
        do {
            try saveRoute(serial, route); mutationErrors.removeValue(forKey: serial)
            reconcile(activeSerials: activeSerials, connectedSerials: connectedSerials)
        } catch {
            mutationErrors[serial] = "Could not save this device’s audio route. \(error.localizedDescription)"
            onChange?(serial)
            throw error
        }
    }

    func retry(serial: String) {
        guard !stopped else { return }
        mutationErrors.removeValue(forKey: serial)
        reconcile(activeSerials: activeSerials, connectedSerials: connectedSerials)
        if preferenceError == nil { router.retry(serial: serial) }
    }

    func presentation(for serial: String?) -> AudioPresentation {
        guard let serial else {
            return AudioPresentation(route: .mac, phase: .phone,
                message: "Select a device to choose its audio output.", canRetry: false, canUsePhone: false)
        }
        let capacityFallback = routes[serial] == nil && DeviceAudioPreferences.capacityCount(routes) >= DroidBridgePreferences.maximumAudioDevices
        let route = routes[serial] ?? (capacityFallback ? .phone : .mac)
        if let error = mutationErrors[serial] ?? preferenceError {
            return AudioPresentation(route: route, phase: .failed,
                message: error + " Video sessions continue independently.", canRetry: true, canUsePhone: route != .phone)
        }
        if capacityFallback {
            let current = router.status(for: serial)
            let explanation = "Audio settings already contain \(DroidBridgePreferences.maximumAudioDevices) devices. Phone routing is requested without adding a saved preference. Mac capture will not start for this device."
            if current.phase == .failed {
                return AudioPresentation(route: .phone, phase: .failed,
                    message: explanation + " " + current.message, canRetry: true, canUsePhone: false)
            }
            let applying = current.route != .phone || current.phase == .starting || current.phase == .shared
            return AudioPresentation(route: .phone, phase: applying ? .starting : .phone,
                message: explanation + (applying ? " Releasing the previous device-wide Mac audio route; changes may take a moment." : " Audio follows Android’s normal output."), canRetry: false, canUsePhone: false)
        }
        if route == .phone {
            let current = router.status(for: serial)
            if current.phase == .failed {
                return AudioPresentation(route: route, phase: .failed,
                    message: current.message + " Video sessions continue independently.", canRetry: true, canUsePhone: false)
            }
            let applying = current.route != .phone || current.phase == .starting || current.phase == .shared
            return AudioPresentation(route: route, phase: applying ? .starting : .phone,
                message: applying ? "Phone selected. Releasing the device-wide Mac audio route; changes may take a moment." : "Phone route selected. Audio follows Android’s normal output.", canRetry: false, canUsePhone: false)
        }
        guard connectedSerials.contains(serial) else {
            return AudioPresentation(route: route, phase: .phone,
                message: "Waiting for this device to connect and finish starting.", canRetry: false, canUsePhone: true)
        }
        guard activeSerials.contains(serial) else {
            return AudioPresentation(route: route, phase: .phone,
                message: "\(route == .macAndPhone ? "Mac + Phone" : "Mac") selected. Audio starts when an app is running.", canRetry: false, canUsePhone: true)
        }
        let current = router.status(for: serial)
        if current.route != route {
            return AudioPresentation(route: route, phase: .starting,
                message: "Updating the device-wide audio route. Another DroidBridge process may still be releasing the previous route.", canRetry: false, canUsePhone: true)
        }
        return AudioPresentation(route: route, phase: current.phase, message: current.message,
            canRetry: current.phase == .failed, canUsePhone: current.phase == .failed)
    }

    func shutdown() async {
        guard !stopped else { return }
        stopped = true; router.onStatusChange = nil
        await router.shutdown()
        activeSerials.removeAll(); connectedSerials.removeAll()
    }
}

extension LauncherController {
    /// A menu follows the focused native session, then a wrapper's immutable
    /// identity. Sidebar actions always use the explicitly selected device.
    func audioMenuDevice() -> AndroidDevice? {
        if let focused = hosts.values.first(where: { $0.window === NSApp.keyWindow }) {
            return focused.session.descriptor.device
        }
        if isWrapper, let serial = preferredSerial {
            return devices.first(where: { $0.serial == serial })
                ?? sessions.values.first(where: { $0.descriptor.device.serial == serial })?.descriptor.device
                ?? AndroidDevice(serial: serial, model: "Android device")
        }
        return selectedDevice
    }

    func pollAudioControls() {
        guard !quitting else { return }
        var active = Set(sessions.values.filter { $0.state == .running && sessionStates[$0.descriptor.id] != "disconnected" }.map { $0.descriptor.device.serial })
        // Main's phone dashboard also controls independent wrappers. Their
        // broker-verified running sessions participate in the same device-wide
        // shared audio lease; no new connection or phone authority is inferred.
        if !isWrapper { active.formUnion(companion.sessionSnapshot.filter { $0["phase"]?.string == "running" }.compactMap { $0["serial"]?.string }.filter { readySerials.contains($0) }) }
        audioControls.reconcile(activeSerials: active, connectedSerials: readySerials)
    }

    @objc func audioRouteChanged(_ sender: NSPopUpButton) {
        guard let device = selectedDevice,
              let value = sender.selectedItem?.representedObject as? String,
              let route = DeviceAudioRoute(rawValue: value) else { return }
        setAudioRoute(route, device: device)
    }

    func setAudioRoute(_ route: DeviceAudioRoute, device: AndroidDevice) {
        guard !quitting else { return }
        do { try audioControls.setRoute(route, serial: device.serial) }
        catch { status.stringValue = "Audio settings could not be saved. \(error.localizedDescription)" }
        updateAudioPresentation()
    }

    @objc func retrySelectedAudio() { if let device = selectedDevice { audioControls.retry(serial: device.serial) } }
    @objc func usePhoneAudio() { if let device = selectedDevice { setAudioRoute(.phone, device: device) } }

    func updateAudioPresentation() {
        guard launcherUI != nil else { return }
        guard !quitting else { return }
        let device = selectedDevice, presentation = audioControls.presentation(for: device?.serial)
        let connected = device.map { $0.state == "device" && readySerials.contains($0.serial) } ?? false
        for item in audioRoutePicker.itemArray {
            item.state = (item.representedObject as? String) == presentation.route.rawValue ? .on : .off
            item.isEnabled = device != nil && (connected || (item.representedObject as? String) == DeviceAudioRoute.phone.rawValue)
        }
        if let item = audioRoutePicker.itemArray.first(where: { ($0.representedObject as? String) == presentation.route.rawValue }) { audioRoutePicker.select(item) }
        audioRoutePicker.isEnabled = device != nil
        audioStatus.stringValue = presentation.title + "\n" + presentation.message
        audioStatus.toolTip = audioStatus.stringValue
        audioRetry.isEnabled = presentation.canRetry && device != nil
        audioUsePhone.isEnabled = presentation.canUsePhone && device != nil
        audioRetry.isHidden = presentation.phase != .failed
        audioUsePhone.isHidden = presentation.phase != .failed
    }
}
