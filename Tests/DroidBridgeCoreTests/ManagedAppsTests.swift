import XCTest
import Foundation
import Darwin
@testable import DroidBridgeCore

final class ManagedAppsTests: XCTestCase {
    var root: URL!
    var paths: ManagedAppsPaths!
    var catalog: ManagedAppCatalog!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DroidBridgeCatalog-\(UUID().uuidString)")
        paths = ManagedAppsPaths(privateRoot: root.appendingPathComponent("Private.noindex"), activeRoot: root.appendingPathComponent("Applications/Devices"))
        catalog = ManagedAppCatalog(paths: paths)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }
    let device = AndroidDevice(serial: "emulator-5580", model: "Pixel")
    let application = AndroidApplication(packageName: "dev.example.test", name: "Example")
    @discardableResult func stage(_ reservation: ManagedAppReservation) throws -> URL {
        let url = reservation.stagedBundleURL
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        try Data([0]).write(to: url.appendingPathComponent("Contents/MacOS/DroidBridge"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.appendingPathComponent("Contents/MacOS/DroidBridge").path)
        let info: [String:Any] = ["DroidBridgeManagedNamingVersion":2,"CFBundleIdentifier":reservation.bundleIdentifier,"CFBundleShortVersionString":"0.1.2","CFBundleVersion":"3","DroidBridgeManagedGeneration":reservation.id.uuidString,"DroidBridgeManagedDevice":reservation.deviceHash]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:url.appendingPathComponent("Contents/Info.plist"))
        let launch = ["managed_key":reservation.key,"managed_generation":reservation.id.uuidString,"serial":reservation.device.serial,"package":reservation.application.packageName,"name":reservation.application.name,"backend":reservation.backend.rawValue]
        try JSONEncoder().encode(launch).write(to:url.appendingPathComponent("Contents/Resources/launch.json")); return url
    }
    func execute(_ actions: [ManagedAppRegistrationAction]) throws {
        for start in stride(from:0,to:actions.count,by:64) {
            let batch = Array(actions[start..<min(start+64,actions.count)])
            for action in batch { XCTAssertTrue(try catalog.registrationIsCurrent(action)) }
            _ = try catalog.completeRegistrations(batch)
        }
    }
    func testAvailabilityRequiresPositiveDeviceAndUnregisterBeforeMove() throws {
        let reservation = try catalog.reserve(device:device,application:application,backend:.native)
        try stage(reservation); let initial = try catalog.commit(reservation)
        XCTAssertEqual(initial.availability,.inactive)
        XCTAssertFalse(try catalog.isLaunchAllowed(bundleURL:initial.activeBundleURL,serial:device.serial,packageName:application.packageName))
        let online = try catalog.reconcile(availableSerials:[device.serial],enabled:true)
        XCTAssertEqual(online.count,1); XCTAssertTrue(online[0].register); try execute(online)
        XCTAssertTrue(try catalog.isLaunchAllowed(bundleURL:initial.activeBundleURL,serial:device.serial,packageName:application.packageName))
        let offline = try catalog.reconcile(availableSerials:[],enabled:true)
        XCTAssertFalse(offline[0].register)
        XCTAssertTrue(FileManager.default.fileExists(atPath:initial.activeBundleURL.path),"OldURL remains valid for unregister")
        XCTAssertFalse(try catalog.isLaunchAllowed(bundleURL:initial.activeBundleURL,serial:device.serial,packageName:application.packageName))
        try execute(offline)
        XCTAssertFalse(FileManager.default.fileExists(atPath:initial.activeBundleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:initial.inactiveBundleURL.path))
        XCTAssertEqual(try catalog.records().count,1)
        XCTAssertTrue(try catalog.reconcile(availableSerials:[device.serial],enabled:false).isEmpty)
        XCTAssertEqual(try catalog.records().count,1,"Feature flag preserves accepted history")
    }
    func testDeviceIdentityAndConcurrentReservationFence() throws {
        let first = try catalog.reserve(device:device,application:application,backend:.native)
        XCTAssertThrowsError(try ManagedAppCatalog(paths:paths).reserve(device:device,application:application,backend:.native))
        let second = try catalog.reserve(device:AndroidDevice(serial:"second-device",model:"Other"),application:application,backend:.native)
        XCTAssertNotEqual(first.bundleIdentifier,second.bundleIdentifier); XCTAssertNotEqual(first.activeBundleURL,second.activeBundleURL)
        try catalog.abandon(first); try catalog.abandon(second)
    }
    func testForeignSymlinkAndCorruptReservationRefused() throws {
        let reservation = try catalog.reserve(device:device,application:application,backend:.native)
        try FileManager.default.createDirectory(at:reservation.stagingRoot.deletingLastPathComponent(),withIntermediateDirectories:true)
        let foreign = root.appendingPathComponent("foreign"); try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:reservation.stagingRoot,withDestinationURL:foreign)
        XCTAssertThrowsError(try catalog.commit(reservation))
        XCTAssertThrowsError(try catalog.abandon(reservation))
    }
    func testGenerationReplacementAndRunningRefusal() throws {
        let first = try catalog.reserve(device:device,application:application,backend:.native); try stage(first); let previous = try catalog.commit(first)
        try execute(catalog.reconcile(availableSerials:[device.serial],enabled:true))
        XCTAssertThrowsError(try catalog.reserve(device:device,application:application,backend:.native,runningBundlePaths:[previous.activeBundleURL.path]))
        let second = try catalog.reserve(device:device,application:application,backend:.scrcpy); try stage(second)
        XCTAssertThrowsError(try catalog.commit(second,runningBundlePaths:[previous.activeBundleURL.path]))
        _ = try catalog.commit(second)
        XCTAssertEqual(try catalog.records().first?.generation,first.id,"Replacement waits for oldURL unregister")
        try execute(catalog.reconcile(availableSerials:[device.serial],enabled:true))
        XCTAssertEqual(try catalog.records().first?.generation,second.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath:paths.privateRoot.appendingPathComponent("backups/\(first.deviceHash)/\(application.packageName)-\(first.id.uuidString).app").path))
        try execute(catalog.reconcile(availableSerials:[device.serial],enabled:true))
        XCTAssertThrowsError(try catalog.commit(first))
    }
    func testStaleRegistrationCreatesDurableCompensation() throws {
        let r = try catalog.reserve(device:device,application:application,backend:.native); try stage(r); _ = try catalog.commit(r)
        let register = try XCTUnwrap(catalog.reconcile(availableSerials:[device.serial],enabled:true).first)
        let offline = try catalog.reconcile(availableSerials:[],enabled:true)
        try execute(offline)
        XCTAssertFalse(try catalog.registrationIsCurrent(register))
        XCTAssertFalse(try catalog.completeRegistration(register),"Dispatched effect became stale")
        let compensation = try catalog.reconcile(availableSerials:[],enabled:true)
        XCTAssertEqual(compensation.count,1); XCTAssertFalse(compensation[0].register); try execute(compensation)
    }
    func testMoveJournalRecoveryAndTamperedActionFailClosed() throws {
        let r = try catalog.reserve(device:device,application:application,backend:.native); try stage(r); let record = try catalog.commit(r)
        _ = try catalog.reconcile(availableSerials:[device.serial],enabled:true)
        // Crash after durable location journal but before rename.
        try FileManager.default.moveItem(at:record.activeBundleURL,to:record.inactiveBundleURL)
        let recovered = ManagedAppCatalog(paths:paths)
        _ = try recovered.reconcile(availableSerials:[device.serial],enabled:true)
        XCTAssertTrue(FileManager.default.fileExists(atPath:record.activeBundleURL.path))
        let manifestURL = paths.privateRoot.appendingPathComponent("catalog.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as? [String:Any])
        var actions = try XCTUnwrap(json["actions"] as? [[String:Any]])
        actions[0]["bundleURL"] = "file:///Applications/Unrelated.app"; json["actions"] = actions
        try JSONSerialization.data(withJSONObject:json).write(to:manifestURL)
        XCTAssertThrowsError(try recovered.reconcile(availableSerials:[],enabled:false))
    }
    func testCloneCopyIsolationAndCapacityRefusal() throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let source = root.appendingPathComponent("source"), copy = root.appendingPathComponent("clone")
        let bytes = Data(repeating:42,count:2*1024*1024); try bytes.write(to:source)
        let stats = try ManagedAppCloneCopy.copy(source,to:copy,reserveBytes:0)
        XCTAssertEqual(stats.clonedFiles + stats.copiedFiles,1)
        try Data([1]).write(to:copy); XCTAssertEqual(try Data(contentsOf:source),bytes,"Never a hardlink")
        XCTAssertThrowsError(try ManagedAppCloneCopy.copy(source,to:root.appendingPathComponent("refused"),reserveBytes:Int64.max))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("refused").path))
    }
    func testManualAdoptionPreservesIntentAndArchivesOnlyAfterUnregister() throws {
        let manual = paths.activeRoot.deletingLastPathComponent().appendingPathComponent("Old name.app")
        try FileManager.default.createDirectory(at:manual.appendingPathComponent("Contents/Resources"),withIntermediateDirectories:true)
        let info: [String:Any] = ["CFBundleIdentifier":"app.droidbridge.wrapper." + application.packageName,"CFBundleExecutable":"DroidBridge","CFBundlePackageType":"APPL","DroidBridgeWrapperFormat":2]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:manual.appendingPathComponent("Contents/Info.plist"))
        let config = try JSONEncoder().encode(["name":"Preserve original", "backend":"scrcpy", "serial":device.serial,"package":application.packageName])
        try config.write(to:manual.appendingPathComponent("Contents/Resources/launch.json"))
        let r = try catalog.reserve(device:device,application:application,backend:.native,adoptManualWrappers:true)
        XCTAssertEqual(r.application.name,"Preserve original"); XCTAssertEqual(r.backend,.scrcpy)
        try stage(r); _ = try catalog.commit(r)
        try catalog.abandon(r) // Cancellation after durable admission cannot remove the candidate.
        XCTAssertTrue(FileManager.default.fileExists(atPath:r.stagedBundleURL.path))
        let actions = try catalog.reconcile(availableSerials:[device.serial],enabled:true)
        XCTAssertEqual(actions.first?.bundleURL.path,manual.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath:manual.path))
        try execute(actions)
        XCTAssertFalse(FileManager.default.fileExists(atPath:manual.path))
        let backup = paths.privateRoot.appendingPathComponent("manual-backups/\(r.deviceHash)/\(application.packageName)-\(r.id.uuidString).app/Contents/Resources/launch.json")
        XCTAssertEqual(try Data(contentsOf:backup),config)
        XCTAssertEqual(try catalog.records().first?.name,"Preserve original")
    }
    func testExpiredReservationAndMalformedPublicationFailClosed() throws {
        let r = try catalog.reserve(device:device,application:application,backend:.native)
        let manifestURL = paths.privateRoot.appendingPathComponent("catalog.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as? [String:Any])
        var reservations = try XCTUnwrap(json["reservations"] as? [String:[String:Any]])
        reservations[r.key]?["ownerPID"] = 2_000_000_000; json["reservations"] = reservations
        try JSONSerialization.data(withJSONObject:json).write(to:manifestURL)
        let successor = try catalog.reserve(device:device,application:application,backend:.native)
        XCTAssertNotEqual(r.id,successor.id)
        XCTAssertThrowsError(try catalog.commit(r))
        json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as? [String:Any])
        reservations = try XCTUnwrap(json["reservations"] as? [String:[String:Any]])
        reservations[successor.key]?["stagingRoot"] = "file:///Applications/Foreign.app"; json["reservations"] = reservations
        try JSONSerialization.data(withJSONObject:json).write(to:manifestURL)
        XCTAssertThrowsError(try catalog.reconcile(availableSerials:[],enabled:false))
    }
    func testCloneFallbackAndExternalLinkRefusal() throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let source = root.appendingPathComponent("source"), copy = root.appendingPathComponent("copy")
        try Data([1,2,3]).write(to:source)
        let stats = try ManagedAppCloneCopy.copy(source,to:copy,reserveBytes:0,preferCloning:false)
        XCTAssertEqual(stats.copiedFiles,1); XCTAssertEqual(stats.clonedFiles,0)
        XCTAssertEqual(try Data(contentsOf:source),try Data(contentsOf:copy))
        let directory = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try FileManager.default.createSymbolicLink(at:directory.appendingPathComponent("escape"),withDestinationURL:source)
        XCTAssertThrowsError(try ManagedAppCloneCopy.copy(directory,to:root.appendingPathComponent("unsafe"),reserveBytes:0))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("unsafe").path))
    }

    func testContendedCatalogLockHasFiniteAdmissionDeadline() throws {
        _ = try catalog.records()
        let descriptor = open(paths.privateRoot.appendingPathComponent("catalog.lock").path,O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor,0)
        defer { flock(descriptor,LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor,LOCK_EX | LOCK_NB),0)
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try catalog.records()) { error in
            guard case ManagedAppCatalogError.busy = error else { XCTFail("Unexpected lock error: \(error)"); return }
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,0.5)
    }
    func testLargeCohortPolicyDeniesUntouchedRowsAndBatchesDrain() throws {
        let initial = try catalog.reserve(device:device,application:application,backend:.native); try stage(initial); let template = try catalog.commit(initial)
        let manifestURL = paths.privateRoot.appendingPathComponent("catalog.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as? [String:Any])
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(template)) as? [String:Any])
        var entries: [String:Any] = [:]
        for i in 0..<192 {
            let package = "dev.qa.batch.p\(i)", filename = ManagedAppCatalog.bundleFilename(package,name:"Batch \(i)")
            let active = paths.activeRoot.appendingPathComponent(template.deviceHash).appendingPathComponent(filename)
            let inactive = paths.privateRoot.appendingPathComponent("inactive/\(template.deviceHash)/\(filename)")
            try FileManager.default.createDirectory(at:inactive.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
            try FileManager.default.createDirectory(at:inactive.appendingPathComponent("Contents/Resources"),withIntermediateDirectories:true)
            let key = template.deviceHash + ":" + package, identifier = ManagedAppCatalog.bundleIdentifier(serial:device.serial,packageName:package)
            var record = encoded; record["key"] = key; record["name"] = "Batch \(i)"; record["packageName"] = package; record["bundleFilename"] = filename; record["bundleIdentifier"] = identifier
            record["activeBundleURL"] = active.absoluteString; record["inactiveBundleURL"] = inactive.absoluteString
            entries[key] = record
            let info: [String:Any] = ["DroidBridgeManagedNamingVersion":2,"CFBundleIdentifier":identifier,"DroidBridgeManagedGeneration":template.generation.uuidString,"DroidBridgeManagedDevice":template.deviceHash]
            try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:inactive.appendingPathComponent("Contents/Info.plist"))
            try JSONEncoder().encode(["managed_key":key,"managed_generation":template.generation.uuidString,"serial":device.serial,"package":package,"name":"Batch \(i)","backend":"native"]).write(to:inactive.appendingPathComponent("Contents/Resources/launch.json"))
            try Data([0]).write(to:inactive.appendingPathComponent("Contents/MacOS/DroidBridge"))
            try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:inactive.appendingPathComponent("Contents/MacOS/DroidBridge").path)
        }
        manifest["records"] = entries
        try JSONSerialization.data(withJSONObject:manifest).write(to:manifestURL)
        var rounds = 0
        repeat {
            let actions = try catalog.reconcile(availableSerials:[device.serial],enabled:true)
            XCTAssertLessThanOrEqual(actions.count,64)
            try execute(actions); rounds += 1
        } while try catalog.pendingTransitionCount() > 0 && rounds < 8
        XCTAssertEqual(rounds,3); XCTAssertEqual(try catalog.records().filter { $0.location == .active }.count,192)
        let offline = try catalog.reconcile(availableSerials:[],enabled:true)
        let untouched = try XCTUnwrap(catalog.records().first { $0.availability == .active })
        XCTAssertFalse(try catalog.isLaunchAllowed(bundleURL:untouched.activeBundleURL,serial:device.serial,packageName:untouched.packageName),"Global availability policy denies even rows beyond the first batch")
        try execute(offline)
        let restarted = ManagedAppCatalog(paths:paths)
        for _ in 0..<8 {
            try execute(restarted.reconcile(availableSerials:[],enabled:true))
            if try restarted.pendingTransitionCount() == 0 { break }
        }
        XCTAssertEqual(try restarted.pendingTransitionCount(),0)
        XCTAssertEqual(try restarted.records().filter { $0.location == .inactive }.count,192)
    }

    func testDuplicateCurrentRegisterAcknowledgementIsIdempotent() throws {
        let claim = try catalog.reserve(device:device,application:application,backend:.native)
        try stage(claim); _ = try catalog.commit(claim)
        let register = try XCTUnwrap(catalog.reconcile(availableSerials:[device.serial],enabled:true).first)
        XCTAssertTrue(try catalog.completeRegistration(register))
        XCTAssertFalse(try catalog.completeRegistration(register))
        XCTAssertFalse(try catalog.completeRegistration(register))
        XCTAssertTrue(try catalog.reconcile(availableSerials:[device.serial],enabled:true).isEmpty)
    }
    func testManifestCacheInvalidatesAcrossIndependentCatalogWriter() throws {
        let other = ManagedAppCatalog(paths:paths)
        XCTAssertEqual(try catalog.records().count,0)
        let claim = try other.reserve(device:device,application:application,backend:.native)
        try stage(claim); _ = try other.commit(claim)
        XCTAssertEqual(try catalog.records().count,1)
        let register = try XCTUnwrap(other.reconcile(availableSerials:[device.serial],enabled:true).first)
        XCTAssertTrue(try catalog.registrationIsCurrent(register))
        _ = try other.reconcile(availableSerials:[],enabled:true)
        XCTAssertFalse(try catalog.registrationIsCurrent(register))
    }

    func testMissingRootCannotFollowReplacedParentSymlink() throws {
        let foreign = FileManager.default.temporaryDirectory.appendingPathComponent("DroidBridge-Foreign-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:foreign) }
        try FileManager.default.createSymbolicLink(at:root,withDestinationURL:foreign)
        XCTAssertThrowsError(try catalog.records())
        XCTAssertFalse(FileManager.default.fileExists(atPath:foreign.appendingPathComponent("Private.noindex").path))
    }

    func testNewDenyPolicyPersistsEvenWhenOneOwnedPathFailsValidation() throws {
        let first = try catalog.reserve(device:device,application:application,backend:.native); try stage(first); let initial = try catalog.commit(first)
        let secondApp = AndroidApplication(packageName:"dev.example.zzz",name:"Other")
        let second = try catalog.reserve(device:device,application:secondApp,backend:.native); try stage(second); let other = try catalog.commit(second)
        try execute(catalog.reconcile(availableSerials:[device.serial],enabled:true))
        try FileManager.default.moveItem(at:initial.activeBundleURL,to:root.appendingPathComponent("preserved-original.app"))
        try FileManager.default.createDirectory(at:initial.activeBundleURL,withIntermediateDirectories:true)
        let actions = try catalog.reconcile(availableSerials:[],enabled:true)
        XCTAssertFalse(try catalog.isLaunchAllowed(bundleURL:other.activeBundleURL,serial:device.serial,packageName:secondApp.packageName),"A refused move must not erase the latest global deny decision")
        XCTAssertFalse(try catalog.issues().isEmpty)
        try execute(actions)
        XCTAssertFalse(FileManager.default.fileExists(atPath:other.activeBundleURL.path))
        XCTAssertEqual(try catalog.pendingTransitionCount(),0,"Quarantined rows must not spin immediate continuation")
    }

    func testDeletedWrapperCanBeRepairedWithoutBlockingHealthyOfflineMove() throws {
        let first = try catalog.reserve(device:device,application:application,backend:.native); try stage(first); let missing = try catalog.commit(first)
        let secondApp = AndroidApplication(packageName:"dev.example.zzz",name:"Healthy")
        let second = try catalog.reserve(device:device,application:secondApp,backend:.native); try stage(second); let healthy = try catalog.commit(second)
        try execute(catalog.reconcile(availableSerials:[device.serial],enabled:true))
        try FileManager.default.removeItem(at:missing.activeBundleURL)
        try execute(catalog.reconcile(availableSerials:[],enabled:true))
        XCTAssertFalse(FileManager.default.fileExists(atPath:healthy.activeBundleURL.path))
        XCTAssertFalse(try catalog.issues().isEmpty)
        XCTAssertEqual(try catalog.pendingTransitionCount(),0)
        let repair = try catalog.reserve(device:device,application:application,backend:.native)
        try stage(repair); _ = try catalog.commit(repair)
        for _ in 0..<3 { try execute(catalog.reconcile(availableSerials:[device.serial],enabled:true)) }
        XCTAssertTrue(try catalog.isLaunchAllowed(bundleURL:missing.activeBundleURL,serial:device.serial,packageName:application.packageName))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:paths.privateRoot.appendingPathComponent("catalog.json"))) as? [String:Any])
        XCTAssertNotNil((json["missingHistory"] as? [String:Any])?[first.id.uuidString])
    }
    func testRepairRefusesForeignExistingBundleBeforePublication() throws {
        let first = try catalog.reserve(device:device,application:application,backend:.native); try stage(first); let record = try catalog.commit(first)
        try FileManager.default.removeItem(at:record.inactiveBundleURL)
        try FileManager.default.createDirectory(at:record.inactiveBundleURL,withIntermediateDirectories:true)
        let sentinel = record.inactiveBundleURL.appendingPathComponent("foreign")
        try Data([9]).write(to:sentinel)
        let repair = try catalog.reserve(device:device,application:application,backend:.native); try stage(repair)
        XCTAssertThrowsError(try catalog.commit(repair))
        XCTAssertEqual(try Data(contentsOf:sentinel),Data([9]))
        try catalog.abandon(repair)
        XCTAssertFalse(FileManager.default.fileExists(atPath:repair.stagingRoot.path))
    }

}
