import Foundation

public struct ManagedAvailabilityCycle: Codable {
    public let enabled: Bool
    public let probed: Int
    public let available: Int
    public let registrations: Int
    public let pendingRegistrations: Int
    public let messages: [String]
    public var transitions: Int = 0
}

/// Finite cycles independent of GET/UI traffic. Only a positive authorized ADB
/// transport plus boot/package-service readiness admits visible managed apps.
public actor ManagedAvailabilityMonitor {
    private let devices: () async throws -> [AndroidDevice]
    private let readiness: (AndroidDevice) async -> Bool
    private let registration: (ManagedAppRegistrationAction) async throws -> Void
    private let now: () -> Date
    private var cycling = false
    private let catalog: ManagedAppCatalog
    private let preferencesURL: URL
    private var cursor = 0
    private var verified: [String:Date] = [:]
    private var registrationRetry: [UUID:(Int,Date)] = [:]
    public static let readinessTTL: TimeInterval = 120
    public init(toolchain: Toolchain, catalog: ManagedAppCatalog = ManagedAppCatalog(), preferencesURL: URL = DroidBridgePreferences.defaultURL) {
        self.catalog = catalog; self.preferencesURL = preferencesURL
        devices = {
            let result = try await ProcessRunner.run(toolchain.adb,arguments:["devices","-l"],environment:toolchain.environment,timeout:3)
            return AndroidDiscovery.parseDevices(result.output)
        }
        readiness = { await DeviceReadiness.isReady(device:$0,toolchain:toolchain,timeout:1.5) }
        registration = { try await ManagedAppRegistrationExecutor.perform($0) }
        now = Date.init
    }
    // Internal dependencies make admission, cancellation, budgets and publication
    // races executable without touching the user's ADB or LaunchServices state.
    init(catalog:ManagedAppCatalog,preferencesURL:URL,devices:@escaping () async throws ->[AndroidDevice],readiness:@escaping (AndroidDevice) async ->Bool,registration:@escaping (ManagedAppRegistrationAction) async throws ->Void,now:@escaping () ->Date = Date.init) {
        self.catalog=catalog; self.preferencesURL=preferencesURL; self.devices=devices
        self.readiness=readiness; self.registration=registration; self.now=now
    }
    public func cycle() async -> ManagedAvailabilityCycle {
        guard !Task.isCancelled else { return ManagedAvailabilityCycle(enabled:false,probed:0,available:0,registrations:0,pendingRegistrations:0,messages:["Cycle cancelled"]) }
        guard !cycling else { return ManagedAvailabilityCycle(enabled:false,probed:0,available:0,registrations:0,pendingRegistrations:0,messages:["Availability cycle already in progress"]) }
        cycling=true; defer { cycling=false }
        var messages: [String] = []; var ready = Set<String>(); var probed = 0; var registrations = 0
        var enabled: Bool
        do { enabled = try DroidBridgePreferences.load(url: preferencesURL).bulkWrapperOnboardingEnabled }
        catch { enabled = false; messages.append("Preferences unavailable; managed apps remain hidden") }
        if enabled {
            do {
                let serials = Array(Set(try catalog.records().map(\.deviceSerial))).sorted()
                if !serials.isEmpty {
                    let connected = Dictionary((try await devices()).filter { $0.state == "device" }.map { ($0.serial,$0) },uniquingKeysWith:{ first,_ in first })
                    let observed = now()
                    verified = verified.filter { connected[$0.key] != nil && observed.timeIntervalSince($0.value) <= Self.readinessTTL }
                    let deadline = now().addingTimeInterval(12)
                    let count = min(8,serials.count)
                    var advanced = 0
                    for offset in 0..<count {
                        guard !Task.isCancelled, now() < deadline else { break }
                        let serial = serials[(cursor+offset)%serials.count]
                        advanced = offset+1
                        guard let device = connected[serial] else { continue }
                        probed += 1
                        if await readiness(device) { verified[serial] = now() }
                        else { verified.removeValue(forKey:serial) }
                    }
                    cursor = (cursor+advanced)%serials.count
                    ready = Set(verified.keys).intersection(serials)
                }
            } catch { verified.removeAll(); messages.append("Device availability could not be confirmed") }
        } else { verified.removeAll() }
        guard !Task.isCancelled else { return ManagedAvailabilityCycle(enabled: enabled,probed: probed,available: ready.count,registrations: 0,pendingRegistrations: 0,messages: ["Cycle cancelled"]) }
        // A flag changed while a readiness subprocess was suspended must stop
        // publication in this same cycle, not wait for the next polling interval.
        if (try? DroidBridgePreferences.load(url:preferencesURL).bulkWrapperOnboardingEnabled) != true {
            enabled=false; ready.removeAll(); verified.removeAll()
        }
        var pending = 0
        let deadline = now().addingTimeInterval(2)
        var attempted = 0
        var transitions = 0
        do {
            // Waves allow unregister acknowledgement to publish a new location,
            // then register it. A finite batch continues promptly next cycle.
            for _ in 0..<3 {
                if enabled && (try? DroidBridgePreferences.load(url:preferencesURL).bulkWrapperOnboardingEnabled) != true { enabled=false;ready.removeAll();verified.removeAll() }
                let beforeMoves=try catalog.pendingTransitionCount()
                let actions = try catalog.reconcile(availableSerials: ready,enabled: enabled)
                let afterMoves=try catalog.pendingTransitionCount()
                transitions += max(0,beforeMoves-afterMoves)
                pending = actions.count + afterMoves
                var completed: [ManagedAppRegistrationAction] = []
                let liveIDs = Set(actions.map(\.id))
                registrationRetry = registrationRetry.filter { liveIDs.contains($0.key) }
                for action in actions {
                    guard !Task.isCancelled, attempted < 64, now() < deadline else { break }
                    if enabled && (try? DroidBridgePreferences.load(url:preferencesURL).bulkWrapperOnboardingEnabled) != true { enabled=false;ready.removeAll();verified.removeAll();break }
                    if let retry = registrationRetry[action.id], now() < retry.1 { continue }
                    attempted += 1
                    do {
                        guard try catalog.registrationIsCurrent(action) else { continue }
                        try await registration(action)
                        completed.append(action)
                        registrationRetry.removeValue(forKey:action.id); registrations += 1
                    } catch {
                        let failures = min(3,(registrationRetry[action.id]?.0 ?? 0)+1)
                        registrationRetry[action.id] = (failures,now().addingTimeInterval(failures == 3 ? 60 : 5))
                        messages.append("\(action.key.split(separator:":").last.map(String.init) ?? "Device app"): Spotlight registration will retry (\(String(error.localizedDescription.prefix(200))))")
                    }
                }
                // Acknowledge only real completed effects, including after
                // cancellation; detached metadata work has its own finite lock
                // budget and does not inherit a cancelled caller's task fence.
                if !completed.isEmpty {
                    let catalog=self.catalog, effects=completed
                    _ = try await Task.detached { try catalog.completeRegistrations(effects) }.value
                }
                if attempted >= 64 || now() >= deadline || Task.isCancelled { break }
            }
            if enabled && (try? DroidBridgePreferences.load(url:preferencesURL).bulkWrapperOnboardingEnabled) != true { enabled=false;ready.removeAll();verified.removeAll() }
            let beforeMoves=try catalog.pendingTransitionCount()
            let actions=try catalog.reconcile(availableSerials:ready,enabled:enabled)
            let afterMoves=try catalog.pendingTransitionCount()
            transitions += max(0,beforeMoves-afterMoves)
            pending=actions.count+afterMoves
        } catch { messages.append("Managed app availability could not be reconciled: \(error.localizedDescription)") }
        do {
            let issues=try catalog.issues()
            for issue in issues.prefix(7) { messages.append("\(issue.key.split(separator:":").last.map(String.init) ?? "Device app"): \(String(issue.message.prefix(400)))") }
            if issues.count>7 {messages.append("\(issues.count-7) additional managed app repairs are waiting for retry")}
        } catch {messages.append("Managed app repair diagnostics are unavailable")}
        var result=ManagedAvailabilityCycle(enabled: enabled,probed: probed,available: ready.count,registrations: registrations,pendingRegistrations: pending,messages: Array(messages.prefix(8)))
        result.transitions=transitions
        return result
    }
}
