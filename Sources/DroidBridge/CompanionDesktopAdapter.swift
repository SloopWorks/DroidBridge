import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

struct CompanionDesktopDevice: Equatable {
    let id: String, name: String, serial: String
    let aliases: [String], capabilities: Set<String>
    let connected: Bool, paired: Bool
    let profile: CompanionPerformanceProfile
    let error: String?
    init?(_ value: CompanionJSON) {
        guard let o = value.object, let id = o["device_id"]?.string, UUID(uuidString: id) != nil,
              let serial = o["serial"]?.string, (try? AndroidDiscovery.validateSerial(serial)) != nil else { return nil }
        self.id = id; self.serial = serial; name = String((o["device_name"]?.string ?? "Android phone").prefix(256))
        aliases = o["aliases"]?.array?.compactMap(\.string) ?? [serial]
        capabilities = Set(o["capabilities"]?.array?.compactMap(\.string) ?? [])
        connected = o["connected"]?.bool == true; paired = o["paired"]?.bool == true
        profile = CompanionPerformanceProfile(rawValue: o["profile"]?.string ?? "balanced") ?? .balanced
        error = o["connection_error"]?.string
    }
}

struct CompanionDesktopPendingPairing: Equatable {
    let id: String, serial: String, phase: String
    let expires: Date
    init?(_ value: CompanionJSON) {
        guard let object = value.object, let id = object["device_id"]?.string, UUID(uuidString: id) != nil,
              let serial = object["serial"]?.string, (try? AndroidDiscovery.validateSerial(serial)) != nil,
              let phase = object["phase"]?.string, ["staged", "committed"].contains(phase),
              let expiry = object["expires"]?.number, expiry.isFinite else { return nil }
        self.id = id; self.serial = serial; self.phase = phase; expires = Date(timeIntervalSinceReferenceDate: expiry)
    }
}

/// AppKit's sole adapter to the per-user broker. It never creates a phone HTTP
/// client or handles long-lived phone credentials. Optional broker work runs
/// after immediate wrapper presentation and cannot gate video startup.
@MainActor final class CompanionDesktopAdapter {
    weak var launcher: LauncherController?
    let broker: CompanionBrokerIPCClient
    private(set) var devices: [CompanionDesktopDevice] = []
    private(set) var pendingPairings: [CompanionDesktopPendingPairing] = []
    private(set) var sessionSnapshot: [[String: CompanionJSON]] = []
    private(set) var statusMessage = "Companion not connected. Existing Android app windows work independently."
    var onChange: (() -> Void)?
    var windowController: CompanionWindowController?
    private var lifecycle: Task<Void, Never>?
    private var commands: [String: Task<Void, Never>] = [:]
    private var receipts: [String: (String, [String: CompanionJSON])] = [:]
    private var receiptOrder: [String] = []
    private var lastStatus = Date.distantPast
    private var lastPublish = Date.distantPast
    private var publishRevision: UInt64 = 0
    private var markedSessionFingerprint: [String]?
    private var stopped = false
    private var started = false
    private let generation: Double = 1
    private var publishedDeviceIDs = Set<String>()

    init(launcher: LauncherController, broker: CompanionBrokerIPCClient = CompanionBrokerIPCClient()) { self.launcher = launcher; self.broker = broker }

    func start(installService: Bool = true) {
        guard !started else { return }; started = true
        lifecycle = Task { [weak self] in
            guard let self, let launcher = self.launcher else { return }
            if installService, !launcher.isWrapper {
                let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Runtime/bin/DroidBridgeCompanionBroker")
                let development = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).deletingLastPathComponent().appendingPathComponent("DroidBridgeCompanionBroker")
                let candidate = FileManager.default.isExecutableFile(atPath: executable.path) ? executable : development
                do {
                    try await CompanionBrokerInstaller.ensureInstalled(executable: candidate, adb: URL(fileURLWithPath: launcher.toolchain.adb))
                    if Bundle.main.bundleURL.pathExtension == "app" { _ = try await self.broker.request(operation: "host_register", payload: ["app_path": .string(Bundle.main.bundleURL.path)]) }
                }
                catch { self.statusMessage = "Companion service unavailable: \(String(error.localizedDescription.prefix(350)))"; self.onChange?() }
            }
            while !Task.isCancelled, !self.stopped {
                do {
                    if Date().timeIntervalSince(self.lastStatus) >= self.statusWorkInterval { try await self.refreshStatus() }
                    if Date().timeIntervalSince(self.lastPublish) >= self.statusWorkInterval { try await self.publish() }
                    try await self.pollCommands()
                } catch {
                    if !Task.isCancelled { self.statusMessage = "Companion unavailable. \(String(error.localizedDescription.prefix(350))) Existing app windows continue."; self.onChange?() }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    func refreshStatus() async throws {
        let reply = try await broker.request(operation: "status")
        guard !stopped, !Task.isCancelled else { return }
        devices = (reply.data["devices"]?.array ?? []).compactMap(CompanionDesktopDevice.init)
        pendingPairings = (reply.data["pending_pairings"]?.array ?? []).prefix(32).compactMap(CompanionDesktopPendingPairing.init)
        sessionSnapshot = (reply.data["sessions"]?.array ?? []).compactMap(\.object)
        lastStatus = Date()
        let online = devices.filter(\.connected).count
        if online > 0 { statusMessage = "\(online) paired phone\(online == 1 ? "" : "s") connected" }
        else if !pendingPairings.isEmpty { statusMessage = "Phone approval needs local completion. In Connection, choose Finish Approved Pairing or Forget Pending Pairing." }
        else { statusMessage = "No paired companion connected. Existing Android app windows work independently." }
        launcher?.pollAudioControls()
        onChange?()
    }
    func device(for serial: String) -> CompanionDesktopDevice? { devices.first { $0.aliases.contains(serial) } }
    func configuration(_ value: SessionConfiguration, serial: String) -> SessionConfiguration { device(for: serial)?.profile.applying(to: value) ?? value }
    var statusWorkInterval: TimeInterval {
        guard let launcher else { return CompanionPerformanceProfile.balanced.statusInterval }
        let serials = Set(launcher.sessions.values.map { $0.descriptor.device.serial } + [launcher.preferredSerial].compactMap { $0 })
        return devices.filter { phone in phone.connected && (!launcher.isWrapper || phone.aliases.contains(where: serials.contains)) }.map(\.profile.statusInterval).min() ?? CompanionPerformanceProfile.balanced.statusInterval
    }
    func markSessionsChanged() {
        guard let launcher else { return }
        let fingerprint = launcher.sessions.values.map { "\($0.descriptor.id.uuidString):\(launcher.sessionStates[$0.descriptor.id] ?? $0.state.rawValue)" }.sorted()
        guard fingerprint != markedSessionFingerprint else { return }
        markedSessionFingerprint = fingerprint; publishRevision &+= 1; lastPublish = .distantPast
    }
    func show() {
        if windowController == nil { windowController = CompanionWindowController(adapter: self) }
        windowController?.showWindow(nil); windowController?.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    private func publish() async throws {
        guard let launcher, !launcher.quitting else { return }
        let revision = publishRevision
        let activeSerials = Set(launcher.sessions.values.map { $0.descriptor.device.serial })
        for phone in devices where phone.paired && phone.connected {
            // Main registers an empty cohort to receive Open. Wrappers register
            // only their immutable phone identity and owned sessions.
            guard !launcher.isWrapper || activeSerials.contains(where: { phone.aliases.contains($0) }) || launcher.preferredSerial.map({ phone.aliases.contains($0) }) == true else { continue }
            let serial = activeSerials.first(where: { phone.aliases.contains($0) }) ?? phone.serial
            let rows: [CompanionJSON] = launcher.sessions.values.filter { phone.aliases.contains($0.descriptor.device.serial) }.prefix(32).map { session in
                let d = session.descriptor
                let phase = launcher.sessionStates[d.id] == "disconnected" ? "reconnecting" : session.state.rawValue
                return .object(["session_id": .string(d.id.uuidString), "package_name": .string(d.application.packageName), "label": .string(d.application.name), "backend": .string(d.configuration.backend.rawValue), "phase": .string(phase)])
            }
            let audio = launcher.audioControls.presentation(for: serial)
            _ = try await broker.request(operation: "session_publish", payload: ["device_id": .string(phone.id), "serial": .string(serial), "role": .string(launcher.isWrapper ? "wrapper" : "launcher"), "generation": .number(generation), "sessions": .array(rows), "audio_status": .object(["route": .string(audio.route == .macAndPhone ? "mac_and_phone" : audio.route.rawValue), "phase": .string(audio.phase.rawValue), "message": .string(String(audio.message.prefix(512)))])])
            publishedDeviceIDs.insert(phone.id)
        }
        lastPublish = revision == publishRevision ? Date() : .distantPast
    }
    private func pollCommands() async throws {
        guard !publishedDeviceIDs.isEmpty else { return }
        let reply = try await broker.request(operation: "command_poll", payload: ["generation": .number(generation)])
        for value in reply.data["commands"]?.array ?? [] {
            guard let command = value.object, let id = command["id"]?.string, UUID(uuidString: id) != nil, commands[id] == nil else { continue }
            if let old = receipts[id] { try await acknowledge(id, status: old.0, result: old.1); continue }
            guard commands.count < 4 else { break }
            commands[id] = Task { [weak self] in
                guard let self else { return }
                var status = "rejected", result: [String: CompanionJSON] = ["code": .string("cancelled")]
                do { result = try await self.apply(command); status = "applied" }
                catch { result = ["code": .string((error as? CompanionBoundaryError)?.code ?? "host_action_failed"), "message": .string(String(error.localizedDescription.prefix(350)))] }
                self.receipts[id] = (status, result); self.receiptOrder.append(id)
                if self.receiptOrder.count > 256 { self.receipts.removeValue(forKey: self.receiptOrder.removeFirst()) }
                if !self.stopped { do { try await self.acknowledge(id, status: status, result: result) } catch { /* Replay returns the saved result; action is never rerun. */ } }
                self.commands.removeValue(forKey: id); self.lastPublish = .distantPast
            }
        }
    }
    private func acknowledge(_ id: String, status: String, result: [String: CompanionJSON]) async throws {
        _ = try await broker.request(operation: "command_ack", payload: ["command_id": .string(id), "generation": .number(generation), "status": .string(status), "result": .object(result)])
    }
    private func apply(_ command: [String: CompanionJSON]) async throws -> [String: CompanionJSON] {
        guard !stopped, !Task.isCancelled, let launcher, !launcher.quitting,
              let deviceID = command["device_id"]?.string, let phone = devices.first(where: { $0.id == deviceID && $0.connected && $0.paired }),
              let kind = command["kind"]?.string, let payload = command["payload"]?.object,
              let device = launcher.devices.first(where: { phone.aliases.contains($0.serial) && $0.state == "device" }) else { throw CompanionBoundaryError("phone_unavailable", "The paired authorized Android device is unavailable.") }
        guard command["generation"]?.number == generation, let expiry = command["expires"]?.number,
              expiry.isFinite, Date(timeIntervalSinceReferenceDate: expiry) > Date() else { throw CompanionBoundaryError("command_expired", "This command expired or belongs to an older Mac owner.") }
        // Commands carry only the canonical phone ID; the explicit serial is
        // selected from that broker-verified alias set, never from the payload.
        switch kind {
        case "open_app":
            guard !launcher.isWrapper, let package = payload["package_name"]?.string else { throw CompanionBoundaryError("launcher_unavailable", "Open DroidBridge on the Mac to launch an app.") }
            try AndroidDiscovery.validatePackage(package)
            let app = launcher.appsDeviceSerial == device.serial ? launcher.applications.first(where: { $0.packageName == package }) : nil
            let value = app ?? AndroidApplication(packageName: package, name: package)
            let config = configuration(SessionConfiguration(backend: launcher.backend, showSystemDecorations: (try? DroidBridgePreferences.load().showAndroidSystemDecorations) ?? true), serial: device.serial)
            guard let session = await launcher.launch(device: device, app: value, configuration: config), session.state == .running else { throw CompanionBoundaryError("launch_failed", "The Android app did not reach a running Mac window. See DroidBridge diagnostics.") }
            return ["session_id": .string(session.descriptor.id.uuidString), "phase": .string("running")]
        case "stop_session":
            guard let raw = payload["session_id"]?.string, let id = UUID(uuidString: raw), let session = launcher.sessions[id], phone.aliases.contains(session.descriptor.device.serial) else { throw CompanionBoundaryError("session_unavailable", "This process no longer owns that Android session.") }
            launcher.close(id, reason: "companion_stop"); await session.stopAndWait()
            return ["session_id": .string(raw), "phase": .string("stopped")]
        case "set_audio_route":
            let raw = payload["route"]?.string ?? payload["audio_route"]?.string ?? ""
            let route = raw == "mac_and_phone" ? DeviceAudioRoute.macAndPhone : DeviceAudioRoute(rawValue: raw)
            guard let route else { throw CompanionBoundaryError("invalid_route", "Choose Mac, Phone or Mac + Phone.") }
            try launcher.audioControls.setRoute(route, serial: device.serial)
            return try await waitForAudio(route, serial: device.serial, launcher: launcher)
        case "retry_audio":
            let route = launcher.audioControls.presentation(for: device.serial).route
            guard route != .phone else { throw CompanionBoundaryError("phone_audio_selected", "Phone audio is selected. Choose Mac or Mac + Phone before retrying Mac output.") }
            launcher.audioControls.retry(serial: device.serial)
            return try await waitForAudio(route, serial: device.serial, launcher: launcher)
        case "set_screen_power":
            guard let off = payload["off"]?.bool else { throw CompanionBoundaryError("invalid_screen_power", "The phone screen request must specify off as true or false.") }
            let power = PhoneDisplayPower(toolchain: launcher.toolchain)
            _ = try DroidBridgePreferences.update { preferences in if off { preferences.screenOffDeviceSerials.insert(device.serial) } else { preferences.screenOffDeviceSerials.remove(device.serial) } }
            let actual = try await (off ? power.setScreenOffIfRequested(device: device) : power.turnScreenOn(device: device))
            guard (off && actual == .offVerified) || (!off && actual == .onVerified) else { throw CompanionBoundaryError("screen_superseded", "A newer phone-screen request superseded this action.") }
            launcher.pollPhoneDisplayControls(); return ["state": .string(off ? "off" : "on"), "verified": .bool(true)]
        case "set_profile":
            guard let raw = payload["profile"]?.string, CompanionPerformanceProfile(rawValue: raw) != nil else { throw CompanionBoundaryError("invalid_profile", "Unsupported performance profile.") }
            try await refreshStatus(); return ["profile": .string(raw), "applies_to": .string("new_sessions")]
        case "set_export":
            guard !launcher.isWrapper, let package = payload["package_name"]?.string, let selected = payload["selected"]?.bool else { throw CompanionBoundaryError("launcher_unavailable", "Open DroidBridge on the Mac to update Spotlight apps.") }
            try AndroidDiscovery.validatePackage(package)
            return try await launcher.applyCompanionExport(device: device, package: package, selected: selected)
        case "diagnostics_request": return ["broker": .string("connected"), "owned_sessions": .number(Double(launcher.sessions.count)), "content_included": .bool(false)]
        default: throw CompanionBoundaryError("unsupported_command", "This Mac does not support that companion action.")
        }
    }
    private func waitForAudio(_ route: DeviceAudioRoute, serial: String, launcher: LauncherController) async throws -> [String: CompanionJSON] {
            let deadline = Date().addingTimeInterval(24)
            repeat {
                try Task.checkCancellation(); launcher.pollAudioControls()
                let state = launcher.audioControls.presentation(for: serial)
                if state.phase == .failed { throw CompanionBoundaryError("audio_unavailable", state.message) }
                if (route == .phone && state.phase == .phone) || (route != .phone && [.ready, .shared].contains(state.phase)) { return ["route": .string(route == .macAndPhone ? "mac_and_phone" : route.rawValue), "phase": .string(state.phase.rawValue)] }
                let ownRunning = launcher.sessions.values.contains { $0.descriptor.device.serial == serial && $0.state == .running }
                let sharedRunning = sessionSnapshot.contains { $0["serial"]?.string == serial && $0["phase"]?.string == "running" }
                if !ownRunning && !sharedRunning { return ["route": .string(route == .macAndPhone ? "mac_and_phone" : route.rawValue), "phase": .string("saved_for_next_session")] }
                try await Task.sleep(nanoseconds: 150_000_000)
            } while Date() < deadline
            throw CompanionBoundaryError("audio_timeout", "Audio output did not initialize. Video continues; use Phone audio or Retry Audio.")
    }

    func shutdown() async {
        guard !stopped else { return }; stopped = true; lifecycle?.cancel()
        windowController?.shutdown()
        for task in commands.values { task.cancel() }
        await broker.invalidate()
        for task in commands.values { await task.value }
        if let lifecycle { await lifecycle.value }
    }
}
