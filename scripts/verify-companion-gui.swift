import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

/// Shipping AppKit screens with an anonymous in-process NSXPC peer. No ADB,
/// launch agent, phone credential, user's clipboard or persistent policy writes.
private final class FixtureBroker: NSObject, NSXPCListenerDelegate, CompanionBrokerXPCProtocol {
    let device = "ac147b36-e0b4-48fa-965c-c694a98ed5d0"
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []
    private var transferBytes = Data()
    private var metadata: [String: CompanionJSON] = [:]
    private var recoveryFinished = false
    private var activeProfile = "balanced"
    private var activeTrustID = "9bf0e385-15bd-4d61-9650-26221a8af695"
    private var notificationChoices: [Bool] = []
    private var notificationOriginTrust: String? = "9bf0e385-15bd-4d61-9650-26221a8af695"
    private var registrationFailures = 0
    private var queuedCommands: [[String: CompanionJSON]] = []
    private var admissionStatuses: [String: String] = [:]
    private var admissionGrants: [String: Bool] = [:]
    private var admissionCalls = Set<String>()
    private var acknowledgments: [String: [String: CompanionJSON]] = [:]
    var operations: [String] = []
    func setProfile(_ profile: String) { lock.lock(); activeProfile = profile; lock.unlock() }
    func captureNotificationTrust() { lock.lock(); notificationOriginTrust = activeTrustID; lock.unlock() }
    func omitNotificationTrust() { lock.lock(); notificationOriginTrust = nil; lock.unlock() }
    func setTrustID(_ id: String) { lock.lock(); activeTrustID = id; lock.unlock() }
    func notificationRequests() -> [Bool] { lock.lock(); defer { lock.unlock() }; return notificationChoices }
    func failRegistrations(_ count: Int) { lock.lock(); registrationFailures = count; lock.unlock() }
    func enqueue(_ command: [String: CompanionJSON], admission: String = "accepted", executionGranted: Bool = true) { lock.lock(); queuedCommands.append(command); let id = command["id"]!.string!; admissionStatuses[id] = admission; admissionGrants[id] = executionGranted; lock.unlock() }
    func admissionCalled(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return admissionCalls.contains(id) }
    func acknowledgment(_ id: String) -> [String: CompanionJSON]? { lock.lock(); defer { lock.unlock() }; return acknowledgments[id] }
    func count(_ operation: String) -> Int { lock.lock(); defer { lock.unlock() }; return operations.filter { $0 == operation }.count }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: CompanionBrokerXPCProtocol.self); connection.exportedObject = self; connection.resume(); lock.lock(); connections.append(connection); lock.unlock(); return true
    }
    func exchange(_ bytes: Data, reply: @escaping (Data) -> Void) {
        lock.lock(); defer { lock.unlock() }
        do {
            let input = try JSONDecoder().decode(CompanionBrokerRequest.self, from: bytes); operations.append(input.operation)
            guard input.nonce == "fixture-nonce" else { throw CompanionBoundaryError("unauthorized", "Fixture nonce mismatch") }
            let p = input.payload
            var data: [String: CompanionJSON] = [:]
            switch input.operation {
            case "notification_preferences":
                guard p["expected_trust_id"]?.string == activeTrustID else { throw CompanionBoundaryError("trust_superseded", "Exact original trust required") }
                notificationChoices.append(p["payload"]?.object?["enabled"]?.bool == true); data = ["status": .string("applied")]
            case "session_publish":
                guard p["command_protocol"]?.number == 2 else { throw CompanionBoundaryError("legacy_host", "Current adapter must advertise command execution protocol2") }
            case "command_poll": data = ["commands": .array(queuedCommands.isEmpty ? [] : [.object(queuedCommands.removeFirst())])]
            case "command_admit":
                let id = p["command_id"]?.string ?? "", status = admissionStatuses[id] ?? "unknown"; admissionCalls.insert(id)
                data = ["status": .string(status), "admitted": .bool(status == "accepted"), "execution_granted": .bool(status == "accepted" && admissionGrants[id] == true), "result": .object(["phase": .string("canonical_prior_effect")])]
            case "command_ack":
                let id = p["command_id"]!.string!; acknowledgments[id] = p
                data = ["status": p["status"] ?? .string("unknown"), "result": p["result"] ?? .object([:])]
            case "host_register":
                guard p["app_path"]?.string == "/Fixture.app" else { throw CompanionBoundaryError("host_identity_mismatch", "Only the expected fixture host may register") }
                if registrationFailures > 0 { registrationFailures -= 1; throw CompanionBoundaryError("broker_unavailable", "Fixture first bootstrap not ready", retryable: true) }
                data = ["status": .string("registered")]
            case "status": data = ["devices": .array([.object(["device_id": .string(device), "device_name": .string("QA Phone with a Long Readable Name"), "serial": .string("qa-companion-ui"), "aliases": .array([.string("qa-companion-ui")]), "connected": .bool(true), "paired": .bool(true), "profile": .string("balanced"), "capabilities": .array(["catalog", "icons", "share", "clipboard", "notifications", "notification_scope_v2", "profiles"].map(CompanionJSON.string))])]), "sessions": .array([.object(["session_id": .string("6803ee5e-496c-413e-ac22-e740b23043eb"), "device_id": .string(device), "label": .string("Independent wrapper fixture"), "backend": .string("native"), "phase": .string("running")])])]
            case "export_selection_get": data = ["selection": .object([:])]
            case "recover_pairing":
                guard p["device_id"]?.string == device else { throw CompanionBoundaryError("invalid_recovery", "Recovery must target the exact pending phone") }
                recoveryFinished = true; data = ["status": .string("approved"), "device_id": .string(device)]
            case "catalog":
                let start = Int(p["cursor"]?.string ?? "0") ?? 0, end = min(start + 64, 1000)
                data = ["generation": .string("fixture-generation"), "items": .array((start..<end).map { .object(["package_name": .string("dev.droidbridge.fixture.app\($0)"), "label": .string($0 == 17 ? "Distinct Companion Search" : "Android Application \($0)"), "launchable": .bool(true), "export_to_mac": .bool(true)]) }), "next_cursor": end < 1000 ? .string(String(end)) : .null]
            case "inbox_list": data = ["items": .array([.object(["id": .string("d39a1ccc-7d17-4839-a17e-671b18e6ea93"), "device_id": .string(device), "kind": .string("share_text"), "payload": .object(["text": .string("Fixture text stays in the inbox until Copy is clicked.")])]), .object(["id": .string("9444cc0e-bd58-44bc-aa6c-7c23a05b7c85"), "kind": .string("notification_posted"), "payload": .object(["title": .string("Fixture notification"), "text": .string("In-app only, no OS permission requested."), "package_name": .string("dev.droidbridge.fixture"), "can_reply": .bool(false)])])])]
            case "host_command", "export_selection_set", "profile_set": data = ["status": .string("accepted")]
            case "command_status": data = ["status": .string("applied"), "result": .object(["phase": .string("fixture_effect")])]
            case "trust_list": data = ["items": .array([.object(["trust_id": .string("9bf0e385-15bd-4d61-9650-26221a8af695"), "mac_name": .string("QA Mac")])])]
            case "transfer_begin": metadata = p; transferBytes = Data(); data = ["status": .string("receiving")]
            case "transfer_chunk": guard let text = p["bytes"]?.string, let chunk = Data(base64Encoded: text), chunk.count <= 65_536 else { throw CompanionBoundaryError("invalid_chunk", "Bad fixture chunk") }; transferBytes.append(chunk); data = ["accepted_bytes": .number(Double(transferBytes.count))]
            case "transfer_commit": guard metadata["sha256"]?.string == CompanionClient.sha256(transferBytes), metadata["size"]?.number == Double(transferBytes.count) else { throw CompanionBoundaryError("integrity", "Fixture transfer mismatch") }; data = ["committed": .bool(true), "transfer_id": metadata["transfer_id"]!, "accepted_bytes": .number(Double(transferBytes.count))]
            case "transfer_receipt": guard p["accepted_bytes"]?.number == Double(transferBytes.count), p["sha256"]?.string == CompanionClient.sha256(transferBytes) else { throw CompanionBoundaryError("integrity", "Fixture download receipt mismatch") }; data = ["status": .string("downloaded"), "transfer_id": p["transfer_id"]!, "accepted_bytes": p["accepted_bytes"]!]
            case "transfer_download": let index = Int(p["index"]?.number ?? 0), start = index * 65_536; data = ["bytes": .string(transferBytes.subdata(in: start..<min(start + 65_536, transferBytes.count)).base64EncodedString())]
            default: break
            }
            if input.operation == "inbox_list", var inbox = data["items"]?.array, var notification = inbox.last?.object {
                if let notificationOriginTrust { notification["trust_id"] = .string(notificationOriginTrust) }
                inbox[inbox.count - 1] = .object(notification); data["items"] = .array(inbox)
            }
            if input.operation == "status", !recoveryFinished {
                data["pending_pairings"] = .array([.object(["device_id": .string(device), "serial": .string("qa-companion-ui"), "phase": .string("staged"), "expires": .number(Date().addingTimeInterval(1200).timeIntervalSinceReferenceDate)])])
            }
            if input.operation == "status", var devices = data["devices"]?.array, var device = devices.first?.object {
                device["profile"] = .string(activeProfile); devices[0] = .object(device); data["devices"] = .array(devices)
                device["trust_id"] = .string(activeTrustID); devices[0] = .object(device); data["devices"] = .array(devices)
            }
            reply(try JSONEncoder().encode(CompanionBrokerReply(requestID: input.requestID, data: data)))
        } catch { let id = (try? JSONDecoder().decode(CompanionBrokerRequest.self, from: bytes).requestID) ?? UUID(); reply((try? JSONEncoder().encode(CompanionBrokerReply(requestID: id, error: error as? CompanionBoundaryError ?? .init("fixture_error", "Fixture failed")))) ?? Data()) }
    }
}

@main struct VerifyCompanionGUI {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular); NSApplication.shared.finishLaunching()
        Task { @MainActor in do { try await run(); print("PASS: companion native UI, bounded catalog, action receipt and file transfer fixtures"); fflush(stdout); exit(0) } catch { fputs("FAIL: companion GUI \(error)\n", stderr); exit(1) } }
        NSApplication.shared.run()
    }
    static func require(_ value: Bool, _ message: String) throws { if !value { throw BridgeError.message(message) } }
    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func capture(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded(); for child in descendants(view) { child.needsDisplay = true }; view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw BridgeError.message("No AppKit capture") }; view.cacheDisplay(in: view.bounds, to: bitmap)
        try require(bitmap.representation(using: .png, properties: [:])?.write(to: url) != nil, "Unable to write capture")
    }
    @MainActor static func wait(seconds: Double = 6, _ condition: () -> Bool) async throws {
        for _ in 0..<Int(seconds * 50) { if condition() { return }; try await Task.sleep(nanoseconds: 20_000_000) }; throw BridgeError.message("Fixture operation timed out")
    }
    @MainActor static func run() async throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DROIDBRIDGE_GUI_EVIDENCE"] ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("verification/companion/macos-ui").path)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let peer = FixtureBroker(), listener = NSXPCListener.anonymous(); listener.delegate = peer; listener.resume(); defer { listener.invalidate() }
        let broker = CompanionBrokerIPCClient(endpoint: listener.endpoint, nonce: "fixture-nonce")
        let launcher = LauncherController(); launcher.onboardingPending = true
        launcher.devices = [AndroidDevice(serial: "qa-companion-ui", model: "QA Phone")]; launcher.readySerials = ["qa-companion-ui"]
        var admissionChecks = 0
        let refused = await launcher.launch(device: launcher.devices[0], app: AndroidApplication(packageName: "dev.droidbridge.fixture.expired", name: "Expired fixture"), configuration: SessionConfiguration(backend: .native), readinessChecked: true, admissionCheck: {
            admissionChecks += 1
            throw CompanionBoundaryError("command_expired", "Expired before session admission")
        })
        try require(refused == nil && launcher.sessions.isEmpty && admissionChecks == 1, "Expired post-readiness admission created an Android session")
        let adapter = CompanionDesktopAdapter(launcher: launcher, broker: broker)
        try await adapter.refreshStatus(); adapter.show()
        try require(peer.count("host_register") == 0, "A status read must not register a host")
        peer.failRegistrations(2); adapter.retryHostRegistration(bundleURL: URL(fileURLWithPath: "/Fixture.app"))
        try await wait { adapter.hostRegistrationMessage.contains("can reopen") }
        try require(peer.count("host_register") == 3, "Fresh bootstrap did not retry exactly twice before success")
        try await adapter.refreshStatus()
        try require(adapter.hostRegistrationMessage.contains("can reopen"), "Status polling erased the independent registration result")
        peer.failRegistrations(20); let registrationBefore = peer.count("host_register")
        adapter.retryHostRegistration(bundleURL: URL(fileURLWithPath: "/Fixture.app"))
        try await wait(seconds: 16) { adapter.hostRegistrationMessage.contains("registration failed") }
        try require(peer.count("host_register") - registrationBefore == 8, "Registration retry budget was not finite")
        try await adapter.refreshStatus()
        try require(adapter.hostRegistrationMessage.contains("Retry Mac Launch Registration"), "Status polling hid actionable exhausted registration")
        let controller = try XCT(adapter.windowController, "Companion controller missing"), window = try XCT(controller.window, "Companion window missing"), content = try XCT(window.contentView, "Companion content missing")
        let tabs = try XCT(descendants(content).compactMap { $0 as? NSTabView }.first, "Companion tabs missing")
        try require(tabs.numberOfTabViewItems == 8, "Expected eight complete companion surfaces")
        controller.loadCatalog()
        let table = try XCT(descendants(tabs.tabViewItems[1].view!).compactMap { $0 as? NSTableView }.first, "Catalog table missing")
        try await wait { table.numberOfRows == 1000 }
        let search = try XCT(descendants(tabs.tabViewItems[1].view!).compactMap { $0 as? NSSearchField }.first, "Catalog search missing")
        search.stringValue = "distinct companion"; controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        try require(table.numberOfRows == 1, "Companion local search did not match")
        search.stringValue = ""; controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        var captures: [String] = []
        for width in [900, 700] {
            window.setContentSize(NSSize(width: width, height: width == 900 ? 760 : 570))
            for (index, item) in tabs.tabViewItems.enumerated() {
                let nav = try XCT(descendants(content).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Companion section \(item.label)" }, "Missing native navigation action")
                nav.performClick(nil); try require(tabs.selectedTabViewItem === item, "Section navigation selected wrong surface")
                content.layoutSubtreeIfNeeded(); try await Task.sleep(nanoseconds: 50_000_000)
                let name = "\(width)-\(index)-\(item.label.replacingOccurrences(of: " ", with: "-")).png"
                try capture(content, to: output.appendingPathComponent(name)); captures.append(name)
                try require(tabs.frame.width > 600 && tabs.frame.height > 200, "Companion tab content collapsed at \(width)")
            }
        }
        try require(!peer.operations.contains("recover_pairing"), "Approved pairing recovery must require an explicit action")
        tabs.selectTabViewItem(at: 0)
        let finishPairing = try XCT(descendants(content).compactMap { $0 as? NSButton }.first { $0.title == "Finish Approved Pairing" }, "Pending pairing completion action missing")
        finishPairing.performClick(nil)
        try await wait { peer.operations.contains("recover_pairing") && adapter.pendingPairings.isEmpty }
        tabs.selectTabViewItem(at: 2)
        let stop = try XCT(descendants(tabs.tabViewItems[2].view!).compactMap { $0 as? NSButton }.first { $0.title == "Stop" }, "Registered wrapper Stop missing")
        stop.performClick(nil); try await wait { peer.operations.contains("command_status") }
        try require(peer.operations.contains("host_command"), "Stop did not dispatch to broker-local exact-owner command")
        let transfer = CompanionTransfers(broker: broker)
        let source = output.appendingPathComponent(".fixture-source"), saved = output.appendingPathComponent(".fixture-received")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: saved) }
        let fixture = Data((0..<160_123).map { UInt8($0 % 251) }); try fixture.write(to: source)
        transfer.send(source, device: peer.device); try await wait { !transfer.running }
        try require(transfer.message.contains("received and verified"), "Upload did not confirm actual final hash: \(transfer.message)")
        transfer.receive(["transfer_id": .string(UUID().uuidString), "size": .number(Double(fixture.count)), "sha256": .string(CompanionClient.sha256(fixture))], destination: saved, device: peer.device)
        try await wait { !transfer.running }; try require((try? Data(contentsOf: saved)) == fixture, "Downloaded fixture bytes differ")
        try require(transfer.message.contains("SHA-256 verification"), "Download incorrectly reported completion")
        let wireless = CompanionWirelessSetup(tools: Toolchain()); wireless.showWindow(nil)
        let wirelessWindow = try XCT(wireless.window, "Wireless setup missing"), wirelessContent = try XCT(wireless.window?.contentView, "Wireless content missing")
        wirelessWindow.setContentSize(NSSize(width: 500, height: 380))
        let pair = try XCT(descendants(wirelessContent).compactMap { $0 as? NSButton }.first { $0.title == "Pair" }, "Native ADB pairing action missing")
        pair.performClick(nil); wirelessContent.layoutSubtreeIfNeeded(); try capture(wirelessContent, to: output.appendingPathComponent("wireless-narrow-validation.png"))
        try require(descendants(wirelessContent).compactMap { $0 as? NSScrollView }.contains { $0.hasVerticalScroller }, "Wireless setup cannot scroll its long explanations")
        wireless.close()
        let scanner = CompanionPairingScanner(); scanner.showWindow(nil); scanner.window?.setContentSize(NSSize(width: 480, height: 380))
        let scannerContent = try XCT(scanner.window?.contentView, "Scanner missing")
        let use = try XCT(descendants(scannerContent).compactMap { $0 as? NSButton }.first { $0.title == "Use Pairing Link" }, "Manual pairing alternate missing")
        use.performClick(nil); scannerContent.layoutSubtreeIfNeeded(); try capture(scannerContent, to: output.appendingPathComponent("scanner-narrow-validation.png"))
        try require(descendants(scannerContent).compactMap { $0 as? NSScrollView }.contains { $0.hasVerticalScroller }, "Scanner alternates cannot scroll")
        scanner.close()
        peer.setProfile("battery"); try await adapter.refreshStatus()
        try require(adapter.statusWorkInterval == 5, "Battery profile did not select its actual status cadence")
        let batteryStatusBefore = peer.count("status"), batteryPublishBefore = peer.count("session_publish"), batteryCommandsBefore = peer.count("command_poll")
        adapter.start(installService: false)
        for _ in 0..<50 { adapter.markSessionsChanged() }
        try await Task.sleep(nanoseconds: 6_200_000_000)
        let batteryStatus = peer.count("status") - batteryStatusBefore, batteryPublish = peer.count("session_publish") - batteryPublishBefore, batteryCommands = peer.count("command_poll") - batteryCommandsBefore
        peer.setProfile("responsive"); try await adapter.refreshStatus()
        try require(adapter.statusWorkInterval == 1, "Responsive profile did not select its actual status cadence")
        let responsiveStatusBefore = peer.count("status"), responsivePublishBefore = peer.count("session_publish"), responsiveCommandsBefore = peer.count("command_poll")
        try await Task.sleep(nanoseconds: 6_200_000_000)
        let responsiveStatus = peer.count("status") - responsiveStatusBefore, responsivePublish = peer.count("session_publish") - responsivePublishBefore, responsiveCommands = peer.count("command_poll") - responsiveCommandsBefore
        try require(batteryStatus <= 2 && batteryPublish <= 2 && responsiveStatus >= 5 && responsivePublish >= 5 && batteryCommands >= 10 && responsiveCommands >= 10, "Actual profile cadence did not reduce status work while preserving command polling")
        let cadence: [String: Any] = ["scope": "Actual shipping desktop adapter timers over anonymous NSXPC; no battery-savings claim", "observation_seconds_each": 6.2, "battery": ["status": batteryStatus, "publish": batteryPublish, "command_poll": batteryCommands], "responsive": ["status": responsiveStatus, "publish": responsivePublish, "command_poll": responsiveCommands], "unchanged_session_marks": 50]
        try JSONSerialization.data(withJSONObject: cadence, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("profile-cadence.json"))
        func command(_ kind: String, deadline: [String: CompanionJSON]?, payload: [String: CompanionJSON]) -> [String: CompanionJSON] {
            var value: [String: CompanionJSON] = ["id": .string(UUID().uuidString), "device_id": .string(peer.device), "generation": .number(1), "kind": .string(kind), "payload": .object(payload)]
            if let deadline { value["continuous_deadline"] = .object(deadline) }; return value
        }
        let now = CompanionClock.nowMS()
        let expired = command("open_app", deadline: ["boot_id": .string(CompanionClock.bootID), "issued_ms": .number(now - 31_000), "expires_ms": .number(now - 1_000)], payload: ["package_name": .string("dev.droidbridge.fixture.expired")])
        peer.enqueue(expired); let expiredID = expired["id"]!.string!
        try await wait { peer.acknowledgment(expiredID) != nil }
        try require(peer.acknowledgment(expiredID)?["result"]?.object?["code"]?.string == "command_expired" && launcher.sessions.isEmpty, "Expired continuous command admitted an Android session")
        let completed = command("open_app", deadline: nil, payload: ["package_name": .string("invalid package must never execute")])
        peer.enqueue(completed, admission: "applied"); let completedID = completed["id"]!.string!
        try await wait { peer.acknowledgment(completedID) != nil }
        try require(peer.acknowledgment(completedID)?["status"]?.string == "applied" && peer.acknowledgment(completedID)?["result"]?.object?["phase"]?.string == "canonical_prior_effect" && launcher.sessions.isEmpty, "Canonical prior result replayed its effect")
        let fresh = CompanionClock.nowMS()
        let noGrant = command("open_app", deadline: ["boot_id": .string(CompanionClock.bootID), "issued_ms": .number(fresh), "expires_ms": .number(fresh + 30_000)], payload: ["package_name": .string("dev.droidbridge.fixture.repeatedadmission")])
        peer.enqueue(noGrant, executionGranted: false); let noGrantID = noGrant["id"]!.string!
        try await wait { peer.admissionCalled(noGrantID) }; try await Task.sleep(nanoseconds: 600_000_000)
        try require(peer.acknowledgment(noGrantID) == nil && launcher.sessions.isEmpty, "Repeated durable admission executed or acknowledged an existing effect")
        try JSONEncoder().encode(["scope": CompanionJSON.string("Actual shipping adapter over anonymous NSXPC fixture; no Android acceptance"), "command": .object(noGrant), "execution_granted": .bool(false), "command_admit_called": .bool(peer.admissionCalled(noGrantID)), "acknowledged": .bool(peer.acknowledgment(noGrantID) != nil), "sessions_created": .number(Double(launcher.sessions.count))]).write(to: output.appendingPathComponent("one-time-admission-no-replay.json"))
        let valid = command("set_profile", deadline: ["boot_id": .string(CompanionClock.bootID), "issued_ms": .number(fresh), "expires_ms": .number(fresh + 30_000)], payload: ["profile": .string("battery")])
        peer.setProfile("battery"); peer.enqueue(valid); let validID = valid["id"]!.string!
        try await wait { peer.acknowledgment(validID) != nil }
        try require(peer.acknowledgment(validID)?["status"]?.string == "applied" && peer.acknowledgment(validID)?["result"]?.object?["profile"]?.string == "battery", "Valid snake-case boot-bound command was not applied")
        let wrongBoot = command("open_app", deadline: ["boot_id": .string(UUID().uuidString), "issued_ms": .number(fresh), "expires_ms": .number(fresh + 30_000)], payload: ["package_name": .string("dev.droidbridge.fixture.wrongboot")])
        peer.enqueue(wrongBoot); let wrongBootID = wrongBoot["id"]!.string!
        try await wait { peer.acknowledgment(wrongBootID) != nil }
        try require(peer.acknowledgment(wrongBootID)?["result"]?.object?["code"]?.string == "command_expired" && launcher.sessions.isEmpty, "A deadline from another boot caused an effect")
        try JSONEncoder().encode([expiredID, completedID, validID, wrongBootID].compactMap(peer.acknowledgment)).write(to: output.appendingPathComponent("adapter-admission-receipts.json"))
        // A native permission sheet can suspend indefinitely. Exercise the
        // shipping controller with a deferred authorization callback and real
        // anonymous NSXPC, without requesting any OS permission in this fixture.
        var authorization: CheckedContinuation<Bool, Error>?
        let permissionController = CompanionWindowController(adapter: adapter, authorizeNotifications: {
            try await withCheckedThrowingContinuation { authorization = $0 }
        })
        let permissionWindowContent = try XCT(permissionController.window?.contentView, "Notification controller missing")
        let permissionTabs = try XCT(descendants(permissionWindowContent).compactMap { $0 as? NSTabView }.first, "Notification tabs missing")
        permissionTabs.selectTabViewItem(at: 4)
        let permissionContent = try XCT(permissionTabs.tabViewItems[4].view, "Notification content missing")
        let mirror = try XCT(descendants(permissionContent).compactMap { $0 as? NSButton }.first { $0.title == "Mirror permitted phone notifications" }, "Notification opt-in missing")
        let applyNotifications = try XCT(descendants(permissionContent).compactMap { $0 as? NSButton }.first { $0.title == "Apply Notification Filters" }, "Notification apply missing")
        let notificationBefore = peer.notificationRequests().count
        mirror.performClick(nil); try await wait { authorization != nil }
        mirror.performClick(nil) // Supersede while the first authorization awaits.
        authorization?.resume(returning: true); authorization = nil
        try await Task.sleep(nanoseconds: 150_000_000)
        try require(peer.notificationRequests().count == notificationBefore, "Late permission approval sent a superseded enabled preference")
        applyNotifications.performClick(nil)
        try await wait { peer.notificationRequests().count == notificationBefore + 1 }
        try require(peer.notificationRequests().last == false, "Explicit retry did not apply the current disabled choice")
        mirror.performClick(nil); try await wait { authorization != nil }
        peer.setTrustID(UUID().uuidString.lowercased()); try await adapter.refreshStatus()
        authorization?.resume(returning: true); authorization = nil
        try await Task.sleep(nanoseconds: 150_000_000)
        try require(peer.notificationRequests().count == notificationBefore + 1, "Late approval crossed a replaced phone trust identity")
        mirror.state = .off; mirror.performClick(nil); try await wait { authorization != nil }
        let notificationFilter = try XCT(descendants(permissionContent).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Advanced notification package allowlist" }, "Notification filter missing")
        notificationFilter.stringValue = "invalid package"
        permissionController.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: notificationFilter))
        authorization?.resume(returning: true); authorization = nil
        try await Task.sleep(nanoseconds: 150_000_000)
        try require(peer.notificationRequests().count == notificationBefore + 1, "Invalid edited allowlist resurrected a prior all-app preference")
        notificationFilter.stringValue = ""
        mirror.state = .off; mirror.performClick(nil); try await wait { authorization != nil }
        permissionController.showWindow(nil); permissionController.window?.performClose(nil)
        permissionController.showWindow(nil) // Reopening must not revive the old intent.
        authorization?.resume(returning: true); authorization = nil
        try await Task.sleep(nanoseconds: 150_000_000)
        try require(peer.notificationRequests().count == notificationBefore + 1, "Red-close/reopen revived a pending notification authorization")
        // A stopped controller must never publish a preference after its sheet
        // finishes, even when the OS callback does not honor task cancellation.
        mirror.state = .off; mirror.performClick(nil); try await wait { authorization != nil }
        permissionController.shutdown(); authorization?.resume(returning: true); authorization = nil
        try await Task.sleep(nanoseconds: 150_000_000)
        try require(peer.notificationRequests().count == notificationBefore + 1, "A shutdown controller published a late notification preference")
        permissionController.window?.orderOut(nil)
        let deniedController = CompanionWindowController(adapter: adapter, authorizeNotifications: { false })
        let deniedTabs = try XCT(descendants(try XCT(deniedController.window?.contentView, "Denied controller missing")).compactMap { $0 as? NSTabView }.first, "Denied tabs missing")
        deniedTabs.selectTabViewItem(at: 4)
        let deniedMirror = try XCT(descendants(try XCT(deniedTabs.tabViewItems[4].view, "Denied notification content missing")).compactMap { $0 as? NSButton }.first { $0.title == "Mirror permitted phone notifications" }, "Denied opt-in missing")
        deniedMirror.performClick(nil); try await wait { peer.notificationRequests().count == notificationBefore + 2 }
        try require(peer.notificationRequests().last == true, "Denied banner permission incorrectly disabled the explicitly requested in-app notification list")
        deniedController.shutdown(); deniedController.window?.orderOut(nil)
        var settingsContinuation: CheckedContinuation<Bool, Never>?
        var postContinuation: CheckedContinuation<Void, Error>?
        var postedIdentifiers: [String] = [], removedIdentifiers: [String] = []
        let bannerController = CompanionWindowController(adapter: adapter, authorizeNotifications: { false }, notificationsAuthorized: {
            await withCheckedContinuation { settingsContinuation = $0 }
        }, postNotification: { request in
            postedIdentifiers.append(request.identifier)
            try await withCheckedThrowingContinuation { postContinuation = $0 }
        }, removeNotifications: { removedIdentifiers += $0 })
        let bannerTabs = try XCT(descendants(try XCT(bannerController.window?.contentView, "Banner controller missing")).compactMap { $0 as? NSTabView }.first, "Banner tabs missing")
        bannerTabs.selectTabViewItem(at: 4)
        let bannerMirror = try XCT(descendants(try XCT(bannerTabs.tabViewItems[4].view, "Banner content missing")).compactMap { $0 as? NSButton }.first { $0.title == "Mirror permitted phone notifications" }, "Banner opt-in missing")
        peer.captureNotificationTrust(); await bannerController.loadInbox(force: true)
        bannerMirror.state = .on
        let staleSettings = Task { await bannerController.showNotifications() }
        try await wait { settingsContinuation != nil }; bannerMirror.state = .off
        settingsContinuation?.resume(returning: true); settingsContinuation = nil; await staleSettings.value
        try require(postedIdentifiers.isEmpty, "Late settings callback posted a banner after opt-out")
        bannerMirror.state = .on
        let staleAdd = Task { await bannerController.showNotifications() }
        try await wait { settingsContinuation != nil }; settingsContinuation?.resume(returning: true); settingsContinuation = nil
        try await wait { postContinuation != nil }
        bannerController.showWindow(nil); bannerController.window?.performClose(nil); bannerController.showWindow(nil)
        postContinuation?.resume(); postContinuation = nil; await staleAdd.value
        try require(postedIdentifiers.count == 1 && removedIdentifiers == postedIdentifiers, "A banner completing after close/reopen was not retracted by its exact identifier")
        let staleTrust = Task { await bannerController.showNotifications() }
        try await wait { settingsContinuation != nil }; peer.setTrustID(UUID().uuidString.lowercased()); try await adapter.refreshStatus()
        settingsContinuation?.resume(returning: true); settingsContinuation = nil; await staleTrust.value
        try require(postedIdentifiers.count == 1, "A late notification-settings callback crossed a replaced trust")
        try require(bannerMirror.state == .off, "Trust replacement did not reset local banner opt-in")
        let historicalContent = try XCT(bannerTabs.tabViewItems[4].view, "Historical content missing")
        try require(!descendants(historicalContent).compactMap { $0 as? NSButton }.contains { $0.title == "Dismiss on Phone" || $0.title == "Reply…" }, "Old-trust inbox row retained phone actions")
        peer.omitNotificationTrust(); await bannerController.loadInbox(force: true)
        bannerMirror.state = .on
        let missingOrigin = Task { await bannerController.showNotifications() }
        try await wait { settingsContinuation != nil }; settingsContinuation?.resume(returning: true); settingsContinuation = nil; await missingOrigin.value
        try require(postedIdentifiers.count == 1, "An originless historical inbox row posted a banner")
        bannerController.shutdown(); bannerController.window?.orderOut(nil)
        try JSONSerialization.data(withJSONObject: ["passed": true, "scope": "Shipping AppKit controller + deferred authorization/settings/add seams + anonymous NSXPC; no OS permission requested", "superseded_approval_no_rpc": true, "explicit_off_retry_applied": true, "replaced_trust_no_rpc": true, "invalid_edited_allowlist_no_rpc": true, "red_close_reopen_no_rpc": true, "shutdown_late_approval_no_rpc": true, "denied_banners_preserve_explicit_in_app_list": true, "late_settings_opt_out_no_banner": true, "late_add_close_reopen_exact_retraction": true, "late_settings_replaced_trust_no_banner": true], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("notification-authorization-fences.json"))
        await adapter.shutdown(); window.orderOut(nil); launcher.window?.orderOut(nil)
        let result: [String: Any] = ["passed": true, "scope": "Shipping AppKit + anonymous NSXPC fixture; no Android or installed-app acceptance", "surfaces": 8, "catalog_count": 1000, "local_search": true, "exact_owner_command_route": true, "explicit_pending_pairing_recovery": true, "registration_transient_retry": true, "registration_exhaustion_attempts": 8, "registration_result_survives_status_read": true, "post_readiness_admission_refused_without_session": true, "chunked_file_roundtrip_bytes": fixture.count, "sha256_match": true, "camera_capture_verified": false, "phone_pairing_verified": false, "physical_focus_verified": false, "clipboard_read": false, "setup_narrow_validation_scroll": true, "captures": captures + ["wireless-narrow-validation.png", "scanner-narrow-validation.png"]]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
    }
    static func XCT<T>(_ value: T?, _ message: String) throws -> T { guard let value else { throw BridgeError.message(message) }; return value }
}
