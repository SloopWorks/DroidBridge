import AppKit
import Foundation
import CryptoKit
import DroidBridgeCore

@main struct ManagedAppsVerification {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "worker" { try worker(); exit(0) }
                try await verify(); print("PASS: managed factory, live Spotlight availability, cross-process fencing and bounded catalog performance"); exit(0)
            } catch { fputs("FAIL: \(error)\n",stderr); exit(1) }
        }; app.run()
    }
    static func worker() throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[2])
        let catalog = ManagedAppCatalog(paths:ManagedAppsPaths(privateRoot:root.appendingPathComponent("Private.noindex"),activeRoot:root.appendingPathComponent("Apps/Devices")))
        do {
            _ = try catalog.reserve(device:AndroidDevice(serial:"worker-device",model:"QA"),application:AndroidApplication(packageName:"dev.qa.concurrent",name:"Concurrent"),backend:.native)
            print("ADMITTED"); fflush(stdout); Thread.sleep(forTimeInterval:0.8)
        } catch ManagedAppCatalogError.busy { print("BUSY"); exit(3) }
    }
    static func timed(_ body: () throws -> Void) rethrows -> Double { let start = Date(); try body(); return Date().timeIntervalSince(start) }
    static func free(_ path: URL) throws -> Int64 { (try FileManager.default.attributesOfFileSystem(forPath:path.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0 }
    @MainActor static func verify() async throws {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
        let evidence = URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("verification/onboarding")
        try fm.createDirectory(at:evidence,withIntermediateDirectories:true)
        let host = URL(fileURLWithPath:ProcessInfo.processInfo.environment["DROIDBRIDGE_TEST_HOST"] ?? home.appendingPathComponent("Applications/DroidBridge.app").path)
        let id = UUID().uuidString
        let paths = ManagedAppsPaths(privateRoot:home.appendingPathComponent("Library/Application Support/DroidBridge/ManagedQA-\(id).noindex"),activeRoot:home.appendingPathComponent("Applications/DroidBridge Managed QA \(id)/Devices"))
        try JSONSerialization.data(withJSONObject:["private_root":paths.privateRoot.path,"active_root":paths.activeRoot.path]).write(to:evidence.appendingPathComponent("current-test-paths.json"))
        let catalog = ManagedAppCatalog(paths:paths)
        let device = AndroidDevice(serial:"managed-qa-" + id,model:"Managed QA fixture")
        let application = AndroidApplication(packageName:"com.android.settings",name:"Managed QA Android Settings")
        let png = try Data(contentsOf:URL(fileURLWithPath:fm.currentDirectoryPath).appendingPathComponent("verification/launcher-fix/wrappers/app.droidbridge.wrapper.com.android.settings-android-icon.png"))
        var report: [String:Any] = ["host":host.path,"host_sha256":SHA256.hash(data:try Data(contentsOf:host.appendingPathComponent("Contents/MacOS/DroidBridge"))).map{String(format:"%02x",$0)}.joined(),"private_root":paths.privateRoot.path,"active_root":paths.activeRoot.path]
        let reservation = try catalog.reserve(device:device,application:application,backend:.native)
        let start = Date()
        _ = try await MacAppWrapper.createManaged(application:application,device:device,backend:.native,iconPNG:png,reservation:reservation,hostBundleURL:host)
        let first = try catalog.commit(reservation)
        report["factory_seconds"] = Date().timeIntervalSince(start)
        report["strict_signature"] = try await ProcessRunner.run("/usr/bin/codesign",arguments:["--verify","--deep","--strict",first.inactiveBundleURL.path]).status == 0
        let otherDevice = AndroidDevice(serial:"managed-qa-second-" + id,model:"Other device fixture")
        let other = try catalog.reserve(device:otherDevice,application:application,backend:.native)
        _ = try await MacAppWrapper.createManaged(application:application,device:otherDevice,backend:.native,iconPNG:png,reservation:other,hostBundleURL:host)
        let second = try catalog.commit(other)
        guard first.bundleIdentifier != second.bundleIdentifier, first.activeBundleURL != second.activeBundleURL else { throw BridgeError.message("Device identities collided") }
        report["two_device_identities"] = [first.bundleIdentifier,second.bundleIdentifier]
        // Clone the real packaged Runtime once and measure, without changing source.
        let clone = paths.privateRoot.appendingPathComponent("runtime-clone")
        let before = try free(paths.privateRoot); let cloneStart = Date()
        let stats = try ManagedAppCloneCopy.copy(host.appendingPathComponent("Contents/Resources/Runtime"),to:clone)
        let allocated = before - (try free(paths.privateRoot))
        report["runtime_copy"] = ["cloned_files":stats.clonedFiles,"copied_files":stats.copiedFiles,"logical_bytes":stats.logicalBytes,"free_space_delta_bytes":allocated,"seconds":Date().timeIntervalSince(cloneStart)]
        try fm.removeItem(at:clone)
        func settle(_ serials: Set<String>, _ enabled: Bool) async throws {
            for _ in 0..<3 {
                let actions = try catalog.reconcile(availableSerials:serials,enabled:enabled)
                for action in actions where try catalog.registrationIsCurrent(action) { try await ManagedAppRegistrationExecutor.perform(action); try catalog.completeRegistration(action) }
            }
        }
        do {
        try await settle([device.serial],true)
        _ = try await ProcessRunner.run("/usr/bin/mdimport",arguments:[first.activeBundleURL.path])
        let query = "kMDItemCFBundleIdentifier == '\(first.bundleIdentifier)'"
        func queryIndex(expectPresent: Bool) async throws -> (String,Double) {
            let start = Date(); var output = ""
            for _ in 0..<30 {
                output = try await ProcessRunner.run("/usr/bin/mdfind",arguments:(expectPresent ? ["-onlyin",paths.activeRoot.path,query] : [query]),timeout:3).output
                if (!output.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty) == expectPresent { return (output,Date().timeIntervalSince(start)) }
                try await Task.sleep(nanoseconds:500_000_000)
            }
            throw BridgeError.message("Spotlight failed bounded \(expectPresent ? "positive" : "negative") check: \(output)")
        }
        let online = try await queryIndex(expectPresent:true)
        report["online_mdfind"] = online.0; report["online_index_seconds"] = online.1
        report["online_mdls"] = try await ProcessRunner.run("/usr/bin/mdls",arguments:["-name","kMDItemCFBundleIdentifier","-name","kMDItemContentType","-name","kMDItemDisplayName",first.activeBundleURL.path]).output
        report["friendly_name_query"] = try await ProcessRunner.run("/usr/bin/mdfind",arguments:["-onlyin",paths.activeRoot.path,"kMDItemDisplayName == '*Managed QA Android Settings*'c"]).output
        guard !(report["friendly_name_query"] as? String ?? "").isEmpty else { throw BridgeError.message("Spotlight friendly application name missing") }
        guard try catalog.isLaunchAllowed(bundleURL:first.activeBundleURL,serial:device.serial,packageName:application.packageName) else { throw BridgeError.message("Online launch denied") }
        try await settle([],true)
        let offline = try await queryIndex(expectPresent:false)
        report["offline_mdfind"] = offline.0; report["offline_index_seconds"] = offline.1
        guard !fm.fileExists(atPath:first.activeBundleURL.path), !(try catalog.isLaunchAllowed(bundleURL:first.activeBundleURL,serial:device.serial,packageName:application.packageName)) else { throw BridgeError.message("Offline app remained available") }
        try await settle([device.serial],true)
        try await settle([device.serial],false)
        guard !fm.fileExists(atPath:first.activeBundleURL.path) else { throw BridgeError.message("Feature flag did not hide apps") }
        report["feature_off_history_count"] = try catalog.records().count
        // Two independent executable processes contend for the same manifest/key.
        let concurrencyRoot = paths.privateRoot.appendingPathComponent("concurrency")
        let logs = [evidence.appendingPathComponent("worker-a.log"),evidence.appendingPathComponent("worker-b.log")]
        let processes = try logs.map { log -> Process in
            fm.createFile(atPath:log.path,contents:nil)
            let process = Process(); process.executableURL = URL(fileURLWithPath:CommandLine.arguments[0]); process.arguments = ["worker",concurrencyRoot.path]
            process.standardOutput = try FileHandle(forWritingTo:log); process.standardError = process.standardOutput; try process.run(); return process
        }
        for process in processes { process.waitUntilExit() }
        let statuses = processes.map(\.terminationStatus).sorted()
        guard statuses == [0,3] else { throw BridgeError.message("Cross-process admission was not exclusive: \(statuses)") }
        report["cross_process_statuses"] = statuses
        // Synthetic metadata fixture: stable 1000-entry cohort polling. No Android
        // activity, icon work, signing or code copies are included in this timing.
        let perfPaths = ManagedAppsPaths(privateRoot:paths.privateRoot.appendingPathComponent("Performance.noindex"),activeRoot:paths.privateRoot.appendingPathComponent("PerfApps/Devices"))
        let perfCatalog = ManagedAppCatalog(paths:perfPaths)
        _ = try perfCatalog.records()
        var entries: [String:Any] = [:]
        let template = try JSONSerialization.jsonObject(with:JSONEncoder().encode(first)) as! [String:Any]
        for i in 0..<1000 {
            let package = "dev.qa.performance.p\(i)", hash = ManagedAppCatalog.deviceHash(device.serial), key = hash + ":" + package
            let active = perfPaths.activeRoot.appendingPathComponent(hash).appendingPathComponent(ManagedAppCatalog.bundleFilename(package))
            let inactive = perfPaths.privateRoot.appendingPathComponent("inactive/\(hash)/\(ManagedAppCatalog.bundleFilename(package))")
            try fm.createDirectory(at:inactive,withIntermediateDirectories:true)
            try fm.createDirectory(at:inactive.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
            try fm.createDirectory(at:inactive.appendingPathComponent("Contents/Resources"),withIntermediateDirectories:true)
            let bundleID = ManagedAppCatalog.bundleIdentifier(serial:device.serial,packageName:package)
            let fixtureInfo: [String:Any] = ["CFBundleIdentifier":bundleID,"DroidBridgeManagedGeneration":first.generation.uuidString,"DroidBridgeManagedDevice":hash]
            try PropertyListSerialization.data(fromPropertyList:fixtureInfo,format:.xml,options:0).write(to:inactive.appendingPathComponent("Contents/Info.plist"))
            try JSONEncoder().encode(["managed_key":key,"managed_generation":first.generation.uuidString,"serial":device.serial,"package":package,"name":first.name,"backend":"native"]).write(to:inactive.appendingPathComponent("Contents/Resources/launch.json"))
            try Data([0]).write(to:inactive.appendingPathComponent("Contents/MacOS/DroidBridge"))
            try fm.setAttributes([.posixPermissions:0o700],ofItemAtPath:inactive.appendingPathComponent("Contents/MacOS/DroidBridge").path)
            var entry = template; entry["key"] = key; entry["packageName"] = package; entry["bundleFilename"] = ManagedAppCatalog.bundleFilename(package); entry["bundleIdentifier"] = ManagedAppCatalog.bundleIdentifier(serial:device.serial,packageName:package)
            entry["activeBundleURL"] = active.absoluteString; entry["inactiveBundleURL"] = inactive.absoluteString; entry["availability"] = "inactive"; entry["location"] = "inactive"
            entries[key] = entry
        }
        let manifest: [String:Any] = ["version":1,"records":entries,"reservations":[:],"publications":[:],"actions":[]]
        try JSONSerialization.data(withJSONObject:manifest).write(to:perfPaths.privateRoot.appendingPathComponent("catalog.json"))
        var samples: [Double] = []
        for _ in 0..<10 { samples.append(try timed { _ = try perfCatalog.reconcile(availableSerials:[],enabled:true) }) }
        report["stable_1000_record_reconcile_seconds"] = samples
        var transitionMetrics: [String:Any] = [:]
        for (phase,available) in [("online",Set([device.serial])),("offline",Set<String>())] {
            let phaseStart = Date(); var reconcileTimes: [Double] = [], completionTimes: [Double] = [], admissionTimes: [Double] = []; var waves = 0
            repeat {
                var actions: [ManagedAppRegistrationAction] = []
                reconcileTimes.append(try timed { actions = try perfCatalog.reconcile(availableSerials:available,enabled:true) })
                let batch = Array(actions.prefix(64)); var completed: [ManagedAppRegistrationAction] = []
                admissionTimes.append(try timed { for action in batch where try perfCatalog.registrationIsCurrent(action) { completed.append(action) } })
                completionTimes.append(try timed { _ = try perfCatalog.completeRegistrations(completed) })
                waves += 1
                guard waves <= 32 else { throw BridgeError.message("1000-record transition failed finite drain") }
            } while try perfCatalog.pendingTransitionCount() > 0
            transitionMetrics[phase] = ["seconds":Date().timeIntervalSince(phaseStart),"waves":waves,"max_reconcile_seconds":Double(reconcileTimes.max() ?? 0),"max_completion_seconds":Double(completionTimes.max() ?? 0),"max_64_admissions_seconds":Double(admissionTimes.max() ?? 0)]
        }
        report["synthetic_1000_record_transitions"] = transitionMetrics

        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:evidence.appendingPathComponent("managed-apps.json"))
        try fm.removeItem(at:perfPaths.privateRoot); try fm.removeItem(at:perfPaths.activeRoot.deletingLastPathComponent())
        // Keep the two signed, inactive/noindex bundles for independent inspection.
        } catch { try? await settle([],false); throw error }
        print("Managed factory/index/performance evidence saved")
    }
}
