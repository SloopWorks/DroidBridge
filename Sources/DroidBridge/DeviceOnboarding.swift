import AppKit
import Darwin
import DroidBridgeCore

struct DeviceOnboardingProgress {
    var total = 0, completed = 0, created = 0, current = 0, running = 0, failed = 0
    var active: [String] = []
    var cancelled = false
    var message = "Ready to add all launchable apps from the selected device."
    var summary: String { "\(completed)/\(total) · \(created) added · \(current) current · \(running) running/skipped · \(failed) errors. " + message }
}

/// A durable admission lease, not a long-held filesystem lock. Expensive icon,
/// copy and signing work runs after the short metadata critical section exits.
private final class DeviceOnboardingLease {
    let url: URL; let token = UUID()
    init(root: URL) throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        url = root.appendingPathComponent("onboarding-owner.json")
        try locked {
            if let bytes = try? Data(contentsOf:url), let value = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any], let pid = value["pid"] as? Int32,
               kill(pid,0) == 0 || errno == EPERM { throw BridgeError.message("Another DroidBridge window is already adding device apps. Wait for that onboarding to finish.") }
            try JSONSerialization.data(withJSONObject:["pid":getpid(),"token":token.uuidString]).write(to:url,options:.atomic)
        }
    }
    func locked(_ body: () throws -> Void) throws {
        let fd = open(url.appendingPathExtension("lock").path,O_CREAT|O_RDWR|O_CLOEXEC,0o600)
        guard fd >= 0 else { throw BridgeError.message("Cannot open onboarding admission lock") }
        defer { flock(fd,LOCK_UN); close(fd) }
        let deadline=ProcessInfo.processInfo.systemUptime+0.1
        while flock(fd,LOCK_EX|LOCK_NB) != 0 {
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline, errno == EWOULDBLOCK || errno == EINTR else { throw BridgeError.message("Onboarding admission is busy. Try again.") }
            usleep(1_000)
        }
        try body()
    }
    func release() {
        try? locked {
            guard let data = try? Data(contentsOf:url), let value = try? JSONSerialization.jsonObject(with:data) as? [String:Any], value["token"] as? String == token.uuidString else { return }
            try FileManager.default.removeItem(at:url)
        }
    }
    deinit { release() }
}

@MainActor final class DeviceOnboardingController {
    let toolchain: Toolchain
    let catalog: ManagedAppCatalog
    let hostBundleURL: URL
    var onProgress: ((DeviceOnboardingProgress) -> Void)?
    private(set) var progress = DeviceOnboardingProgress()
    private(set) var isRunning = false
    private(set) var capturedSerial: String?
    private(set) var failures: [String] = []
    private(set) var omittedFailures = 0
    private var cohort: Task<Void,Never>?
    private var cancelled = false
    private var applications: [AndroidApplication] = []
    private var cursor = 0
    private var active: [String:String] = [:]
    init(toolchain: Toolchain, catalog: ManagedAppCatalog = ManagedAppCatalog(), hostBundleURL: URL = Bundle.main.bundleURL) {
        self.toolchain=toolchain; self.catalog=catalog; self.hostBundleURL=hostBundleURL
    }
    func begin(device: AndroidDevice, applications: [AndroidApplication], backend: BackendKind) throws {
        guard !isRunning else { throw BridgeError.message("Device app onboarding is already running") }
        guard try DroidBridgePreferences.load().bulkWrapperOnboardingEnabled else { throw BridgeError.message("Device apps in Spotlight are disabled") }
        let lease = try DeviceOnboardingLease(root:catalog.paths.privateRoot)
        var seen = Set<String>()
        self.applications = applications.filter { seen.insert($0.packageName).inserted }
        cursor=0; cancelled=false; isRunning=true; active.removeAll(); failures.removeAll(); omittedFailures=0; capturedSerial=device.serial
        progress=DeviceOnboardingProgress(); progress.total=self.applications.count
        progress.message="Preparing background device availability…"; publish()
        cohort = Task { [self] in
            defer { lease.release(); isRunning=false; active.removeAll(); publish() }
            do {
                try await DeviceOnboardingAgent.ensureInstalled(hostBundleURL:hostBundleURL,toolchain:toolchain,paths:catalog.paths)
                try Task.checkCancellation()
                let info = Bundle(url:hostBundleURL)?.infoDictionary ?? [:]
                let version = info["CFBundleShortVersionString"] as? String ?? "0.1.2"
                let build = info["CFBundleVersion"] as? String ?? "3"
                let records = try await Task.detached { try self.catalog.records() }.value
                let existing = Dictionary(uniqueKeysWithValues:records.filter { $0.deviceSerial == device.serial }.map { ($0.packageName,$0) })
                await withTaskGroup(of:Void.self) { group in
                    for _ in 0..<2 { group.addTask { await self.worker(device:device,backend:backend,existing:existing,version:version,build:build) } }
                }
                let monitor = ManagedAvailabilityMonitor(toolchain:toolchain,catalog:catalog)
                let result = await monitor.cycle()
                for message in result.messages { retainDetail("Background availability: "+String(message.prefix(600))) }
                progress.message = cancelled ? "Cancelled. Run Add All again to resume; completed apps are preserved." : (result.messages.isEmpty ? "Finished. \(result.pendingRegistrations) Spotlight updates pending in the background." : "Finished with availability warnings. Open Onboarding Details; the background agent will retry.")
            } catch { progress.message=error.localizedDescription; progress.cancelled=cancelled || Task.isCancelled }
        }
    }
    private func next() -> AndroidApplication? {
        guard !cancelled, !Task.isCancelled, cursor < applications.count else { return nil }
        guard (try? DroidBridgePreferences.load().bulkWrapperOnboardingEnabled) == true else { cancelled=true;return nil }
        defer { cursor += 1 }; return applications[cursor]
    }
    private func runningPaths() -> Set<String> { Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path }) }
    private func worker(device: AndroidDevice, backend: BackendKind, existing: [String:ManagedAppRecord], version: String, build: String) async {
        let provider = AndroidIconProvider(toolchain:toolchain)
        while let app = next() {
            active[app.packageName]=app.name; publish()
            var reservation: ManagedAppReservation?
            do {
                let running = runningPaths()
                if let record=existing[app.packageName] {
                    if running.contains(record.bundleURL.standardizedFileURL.resolvingSymlinksInPath().path) { progress.running += 1; finish(app); continue }
                    if try await Task.detached(operation: { try self.catalog.isCurrent(record,hostVersion:version,hostBuild:build,backend:record.backend,name:record.name) }).value { progress.current += 1; finish(app); continue }
                }
                let saved=existing[app.packageName]
                let requestedApp=AndroidApplication(packageName:app.packageName,name:saved?.name ?? app.name)
                let requestedBackend=saved?.backend ?? backend
                let claim = try await Task.detached { try self.catalog.reserve(device:device,application:requestedApp,backend:requestedBackend,runningBundlePaths:running,adoptManualWrappers:true) }.value
                reservation=claim
                let icon = try await provider.icon(device:device,application:claim.application)
                guard !cancelled, !Task.isCancelled, try DroidBridgePreferences.load().bulkWrapperOnboardingEnabled else { throw CancellationError() }
                _ = try await MacAppWrapper.createManaged(application:claim.application,device:device,backend:claim.backend,iconPNG:icon,reservation:claim,hostBundleURL:hostBundleURL)
                guard !cancelled, !Task.isCancelled, try DroidBridgePreferences.load().bulkWrapperOnboardingEnabled else { throw CancellationError() }
                let nowRunning = runningPaths()
                _ = try await Task.detached { try self.catalog.commit(claim,runningBundlePaths:nowRunning) }.value
                reservation=nil; progress.created += 1
            } catch ManagedAppCatalogError.running { progress.running += 1 }
              catch ManagedAppCatalogError.busy { progress.running += 1 }
              catch { if error is CancellationError { cancelled=true } else { progress.failed += 1; retainFailure(app,error.localizedDescription) } }
            if let reservation { try? await Task.detached { try self.catalog.abandon(reservation) }.value }
            finish(app)
        }
    }
    private func retainFailure(_ app: AndroidApplication, _ message: String) {
        let line = "\(app.name) [\(app.packageName)]: \(message.prefix(600))"
        retainDetail(line); progress.message=line
    }
    private func retainDetail(_ line:String) {
        if failures.count == 100 { failures.removeFirst(); omittedFailures += 1 }
        failures.append(line)
    }
    private func finish(_ app: AndroidApplication) { active.removeValue(forKey:app.packageName); progress.completed += 1; publish() }
    private func publish() { progress.active=Array(active.values).sorted(); progress.cancelled=cancelled; onProgress?(progress) }
    func cancel() { cancelled=true; cohort?.cancel(); progress.message="Cancelling; waiting for current icon and bundle work…"; publish() }
    func cancelAndWait() async { cancel(); if let cohort { await cohort.value }; cohort=nil }
}
