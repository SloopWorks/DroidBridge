import AppKit
import Darwin
import DroidBridgeCore

struct ManagedAppNameRepairProgress {
    var message: String
    var completed: Int = 0
    var total: Int = 0
}

/// Repairs only accepted catalog entries. A compatibility pass first upgrades
/// their readers without changing paths; a separate pass can then rename them.
@MainActor final class ManagedAppNameRepair {
    let toolchain: Toolchain
    let catalog: ManagedAppCatalog
    let hostBundleURL: URL
    var mayProceed: () -> Bool = { true }
    var onProgress: ((ManagedAppNameRepairProgress) -> Void)?
    var onDetail: ((String) -> Void)?
    private(set) var isRunning = false
    private var work: Task<Void,Never>?
    private var retryAfter: [String:Date] = [:]
    private var nextSweep = Date.distantPast

    init(toolchain:Toolchain,catalog:ManagedAppCatalog,hostBundleURL:URL = Bundle.main.bundleURL) {
        self.toolchain=toolchain;self.catalog=catalog;self.hostBundleURL=hostBundleURL
    }
    static func catalogExists(paths:ManagedAppsPaths = .userDefault) ->Bool {
        FileManager.default.fileExists(atPath:paths.privateRoot.appendingPathComponent("catalog.json").path)
    }
    func schedule() {
        guard !isRunning,mayProceed(),hostBundleURL.pathExtension == "app",Date() >= nextSweep,Self.catalogExists(paths:catalog.paths) else {return}
        isRunning=true
        work=Task { [self] in
            defer {isRunning=false;work=nil;onProgress?(ManagedAppNameRepairProgress(message:""))}
            do {
                let records=try await Task.detached {try self.catalog.records()}.value
                try checkAdmission()
                let liveKeys=Set(records.map(\.key));retryAfter=retryAfter.filter{liveKeys.contains($0.key)}
                let info=Bundle(url:hostBundleURL)?.infoDictionary ?? [:]
                let hostVersion=info["CFBundleShortVersionString"] as? String ?? ""
                let hostBuild=info["CFBundleVersion"] as? String ?? ""
                let observedRunning=runningPaths()
                let oldReaders=await Task.detached {records.filter {
                    (($0.namingVersion ?? 1)<2 || $0.sourceVersion != hostVersion || $0.sourceBuild != hostBuild) && Self.mayHaveReader($0,running:observedRunning)
                }}.value
                let cleanNamesAllowed=try await Task.detached {try self.catalog.canRepairNames(runningBundlePaths:observedRunning)}.value
                try checkAdmission()
                let compatibilityPass = !oldReaders.isEmpty
                let candidates=(compatibilityPass ? oldReaders : records.filter(ManagedAppCatalog.needsNameRepair)).sorted{$0.key<$1.key}
                guard !candidates.isEmpty else {return}
                guard cleanNamesAllowed || compatibilityPass else {
                    report("Waiting for existing Mac app updates to finish before repairing their names.",total:candidates.count)
                    nextSweep=Date().addingTimeInterval(8);return
                }
                let due=candidates.filter {Date() >= (retryAfter[$0.key] ?? .distantPast)}
                guard !due.isEmpty else {return}
                let lease=try DeviceOnboardingLease(root:catalog.paths.privateRoot)
                defer {lease.release()}
                try checkAdmission()
                // Reverify each batch: another old main process may have
                // replaced the per-user job since the previous batch.
                report("Preparing background availability for existing Mac app updates…",total:candidates.count)
                try await DeviceOnboardingAgent.ensureInstalled(hostBundleURL:hostBundleURL,toolchain:toolchain,paths:catalog.paths)
                try checkAdmission()
                let deadline=Date().addingTimeInterval(20)
                var completed=0,attempted=0,deferred=0
                for record in due.prefix(4) {
                    guard Date()<deadline else {break}
                    try checkAdmission();attempted += 1
                    let prefix=compatibilityPass ? "Preparing existing Mac apps" : "Repairing Mac app names"
                    report("\(prefix): \(record.name)",completed:completed,total:candidates.count)
                    var reservation:ManagedAppReservation?
                    do {
                        let running=runningPaths()
                        guard !isRunning(record:record,reservation:nil,paths:running) else {throw ManagedAppCatalogError.running}
                        let device=AndroidDevice(serial:record.deviceSerial,model:record.deviceModel)
                        let application=AndroidApplication(packageName:record.packageName,name:record.name)
                        let claim=try await Task.detached {try self.catalog.reserve(device:device,application:application,backend:record.backend,runningBundlePaths:running,preserveLegacyFilename:compatibilityPass)}.value
                        reservation=claim
                        try checkAdmission()
                        // A newly admitted old-reader reservation may have closed
                        // the global barrier after planning this batch.
                        if !compatibilityPass && canonicalPath(claim.activeBundleURL) == canonicalPath(record.activeBundleURL) {throw ManagedAppCatalogError.busy}
                        let saved=try await Task.detached {(try self.catalog.savedIcon(for:record),try self.catalog.savedLaunchConfiguration(for:record))}.value
                        try checkAdmission()
                        _=try await MacAppWrapper.createManaged(application:claim.application,device:device,backend:claim.backend,iconPNG:saved.0,reservation:claim,hostBundleURL:hostBundleURL,preservingConfiguration:saved.1)
                        try checkAdmission()
                        let currentRunning=runningPaths()
                        guard !isRunning(record:record,reservation:claim,paths:currentRunning) else {throw ManagedAppCatalogError.running}
                        _=try await Task.detached {try self.catalog.commit(claim,runningBundlePaths:currentRunning)}.value
                        reservation=nil;completed += 1
                        // Publication is asynchronous. Do not rebuild the same
                        // accepted intent while its unregister receipts drain.
                        retryAfter[record.key]=Date().addingTimeInterval(12)
                    } catch ManagedAppCatalogError.running {
                        deferred += 1;retryAfter[record.key]=Date().addingTimeInterval(12)
                    } catch ManagedAppCatalogError.busy {
                        deferred += 1;retryAfter[record.key]=Date().addingTimeInterval(12)
                    } catch is CancellationError {
                        if let reservation {await abandon(reservation)}
                        throw CancellationError()
                    } catch {
                        deferred += 1;retryAfter[record.key]=Date().addingTimeInterval(60)
                        onDetail?("\(record.name) [\(record.packageName)]: \(String(error.localizedDescription.prefix(500)))")
                    }
                    if let reservation {await abandon(reservation)}
                }
                nextSweep=Date().addingTimeInterval(4)
                let phase=compatibilityPass ? "Existing Mac app preparation" : "Mac app name repair"
                report("\(phase): \(completed) updated; \(deferred) deferred. Running apps are retried after they quit; remaining updates continue in the background.",completed:completed,total:max(attempted,candidates.count))
            } catch is CancellationError {
                nextSweep=Date().addingTimeInterval(4)
            } catch {
                nextSweep=Date().addingTimeInterval(60)
                let message="Existing Mac app name repair will retry: "+String(error.localizedDescription.prefix(500))
                report(message);onDetail?(message)
            }
        }
    }
    private func checkAdmission() throws {
        try Task.checkCancellation()
        guard mayProceed() else {throw CancellationError()}
    }
    nonisolated private static func mayHaveReader(_ record:ManagedAppRecord,running:Set<String>) ->Bool {
        for url in [record.activeBundleURL,record.inactiveBundleURL] {
            if running.contains(url.standardizedFileURL.resolvingSymlinksInPath().path) {return true}
            var metadata=stat()
            if lstat(url.path,&metadata)==0 || errno != ENOENT {return true}
        }
        return false
    }
    private func canonicalPath(_ url:URL) ->String {url.standardizedFileURL.resolvingSymlinksInPath().path}
    private func runningPaths() ->Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap{$0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path})
    }
    private func isRunning(record:ManagedAppRecord,reservation:ManagedAppReservation?,paths:Set<String>) ->Bool {
        var urls=[record.activeBundleURL,record.inactiveBundleURL]
        if let reservation {urls += [reservation.activeBundleURL,reservation.stagedBundleURL]}
        return urls.contains {paths.contains($0.standardizedFileURL.resolvingSymlinksInPath().path)}
    }
    private func abandon(_ reservation:ManagedAppReservation) async {
        let catalog=self.catalog
        _=try? await Task.detached {try catalog.abandon(reservation)}.value
    }
    private func report(_ message:String,completed:Int=0,total:Int=0) {
        onProgress?(ManagedAppNameRepairProgress(message:message,completed:completed,total:total))
    }
    func cancel() {work?.cancel()}
    func cancelAndWait() async {cancel();if let work {await work.value}}
}

extension LauncherController {
    func scheduleManagedNameRepair() {
        guard !isWrapper,!quitting,!creatingWrapper,!onboardingPending,!onboarding.isRunning,
              ManagedAppNameRepair.catalogExists() else {return}
        if managedNameRepair == nil {
            let repair=ManagedAppNameRepair(toolchain:toolchain,catalog:managedCatalog)
            repair.mayProceed={ [weak self] in
                guard let self else {return false}
                return !self.quitting && !self.isWrapper && !self.creatingWrapper && !self.onboardingPending && !self.onboarding.isRunning
            }
            repair.onProgress={ [weak self,weak repair] progress in
                guard let self,!self.quitting,!self.onboardingPending,!self.onboarding.isRunning else {return}
                if !progress.message.isEmpty {
                    self.onboardingStatus.stringValue=String(progress.message.prefix(2000));self.onboardingStatus.toolTip=self.onboardingStatus.stringValue
                    self.onboardingProgress.maxValue=Double(max(1,progress.total));self.onboardingProgress.doubleValue=Double(progress.completed)
                }
                self.onboardingButton.isEnabled=self.bulkPreference.state == .on && repair?.isRunning != true
            }
            repair.onDetail={ [weak self] message in self?.onboarding.recordMaintenanceMessage("Mac app name repair: "+message) }
            managedNameRepair=repair
        }
        managedNameRepair?.schedule()
    }
}
