import XCTest
import Foundation
import CryptoKit
@testable import DroidBridgeCore

/// Independent naming/migration tests. These operate on real catalog files and
/// exact owned fixture bundles, without Android or LaunchServices assertions.
extension ManagedAppsTests {
    private func qaNamingStage(_ claim: ManagedAppReservation) throws {
        let bundle = try stage(claim)
        let url = bundle.appendingPathComponent("Contents/Info.plist")
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(from:Data(contentsOf:url),format:nil) as? [String:Any])
        info["DroidBridgeManagedNamingVersion"] = 2
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:url)
        let launchURL = bundle.appendingPathComponent("Contents/Resources/launch.json")
        var launch = try JSONDecoder().decode([String:String].self,from:Data(contentsOf:launchURL))
        launch["qa_saved_option"] = "preserve this value"
        try JSONEncoder().encode(launch).write(to:launchURL)
        try Data("saved Android icon fixture".utf8).write(to:bundle.appendingPathComponent("Contents/Resources/AndroidApp.png"))
    }
    private func qaNamingLegacy(_ app: AndroidApplication? = nil, backend: BackendKind = .native) throws -> ManagedAppRecord {
        let app = app ?? application
        let claim = try catalog.reserve(device:device,application:app,backend:backend)
        try qaNamingStage(claim)
        let accepted = try catalog.commit(claim)
        let suffix = SHA256.hash(data:Data(app.packageName.utf8)).prefix(8).map { String(format:"%02x",$0) }.joined()
        let filename = app.name + "-" + suffix + ".app"
        let active = paths.activeRoot.appendingPathComponent(accepted.deviceHash).appendingPathComponent(filename)
        let inactive = paths.privateRoot.appendingPathComponent("inactive/\(accepted.deviceHash)/\(filename)")
        if accepted.inactiveBundleURL.path != inactive.path { try FileManager.default.moveItem(at:accepted.inactiveBundleURL,to:inactive) }
        let infoURL = inactive.appendingPathComponent("Contents/Info.plist")
        var info = try XCTUnwrap(PropertyListSerialization.propertyList(from:Data(contentsOf:infoURL),format:nil) as? [String:Any])
        info.removeValue(forKey:"DroidBridgeManagedNamingVersion")
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:infoURL)
        let manifestURL = paths.privateRoot.appendingPathComponent("catalog.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as? [String:Any])
        var records = try XCTUnwrap(manifest["records"] as? [String:[String:Any]])
        var row = try XCTUnwrap(records[accepted.key])
        row["bundleFilename"] = filename; row["activeBundleURL"] = active.absoluteString; row["inactiveBundleURL"] = inactive.absoluteString
        row.removeValue(forKey:"namingVersion"); records[accepted.key] = row; manifest["records"] = records
        try JSONSerialization.data(withJSONObject:manifest).write(to:manifestURL,options:.atomic)
        return try JSONDecoder().decode(ManagedAppRecord.self,from:JSONSerialization.data(withJSONObject:row))
    }
    private func qaNamingUpgrade(_ legacy: ManagedAppRecord) throws -> ManagedAppRecord {
        let app = AndroidApplication(packageName:legacy.packageName,name:legacy.name)
        let claim = try catalog.reserve(device:device,application:app,backend:legacy.backend,preserveLegacyFilename:true)
        XCTAssertEqual(claim.bundleFilename,legacy.bundleFilename)
        try qaNamingStage(claim)
        return try catalog.commit(claim)
    }

    func testNamingUniqueAppsHaveOnlyFriendlyFilename() throws {
        XCTAssertEqual(ManagedAppCatalog.bundleFilename(application.packageName,name:application.name),"Example.app")
        let claim = try catalog.reserve(device:device,application:application,backend:.native)
        XCTAssertEqual(claim.bundleFilename,"Example.app")
        try catalog.abandon(claim)
    }
    func testNamingReservationsDisambiguateOnlyActualSameDeviceCollision() throws {
        let first = try catalog.reserve(device:device,application:application,backend:.native)
        let other = AndroidApplication(packageName:"dev.example.other",name:application.name)
        let second = try catalog.reserve(device:device,application:other,backend:.native)
        XCTAssertEqual(first.bundleFilename,"Example.app")
        XCTAssertEqual(second.bundleFilename,"Example (dev.example.other).app")
        let different = try catalog.reserve(device:device,application:AndroidApplication(packageName:"dev.example.different",name:"Different"),backend:.native)
        XCTAssertEqual(different.bundleFilename,"Different.app")
        let secondDevice = try catalog.reserve(device:AndroidDevice(serial:"another-device",model:"Other"),application:application,backend:.native)
        XCTAssertEqual(secondDevice.bundleFilename,"Example.app")
        XCTAssertNotEqual(secondDevice.activeBundleURL,first.activeBundleURL)
        for claim in [first,second,different,secondDevice] {try catalog.abandon(claim)}
    }
    func testNamingInactiveAcceptedOwnerAndUnicodeCaseCollisions() throws {
        let first = try catalog.reserve(device:device,application:AndroidApplication(packageName:"dev.example.cafe",name:"Café"),backend:.native)
        try qaNamingStage(first);_ = try catalog.commit(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath:first.activeBundleURL.path))
        let second = try catalog.reserve(device:device,application:AndroidApplication(packageName:"dev.example.cafesecond",name:"CAFE\u{301}"),backend:.native)
        XCTAssertTrue(second.bundleFilename.contains("dev.example.cafesecond"),"Inactive ownership and canonical Unicode/case equivalence must participate in collision checks")
        try catalog.abandon(second)
    }
    func testNamingForeignPathsRemainUntouchedAndReadableQualifierAdvances() throws {
        let deviceRoot = paths.activeRoot.appendingPathComponent(ManagedAppCatalog.deviceHash(device.serial))
        for filename in ["Example.app","Example (dev.example.test).app"] {
            let foreign = deviceRoot.appendingPathComponent(filename)
            try FileManager.default.createDirectory(at:foreign,withIntermediateDirectories:true)
            try Data([1,2,3]).write(to:foreign.appendingPathComponent("foreign-sentinel"))
        }
        let claim = try catalog.reserve(device:device,application:application,backend:.native)
        XCTAssertTrue(claim.bundleFilename.contains(application.packageName))
        XCTAssertTrue(claim.bundleFilename.hasSuffix(" 2).app"))
        try qaNamingStage(claim);_ = try catalog.commit(claim)
        try execute(catalog.reconcile(availableSerials:[device.serial],enabled:true))
        for filename in ["Example.app","Example (dev.example.test).app"] {
            XCTAssertEqual(try Data(contentsOf:deviceRoot.appendingPathComponent(filename).appendingPathComponent("foreign-sentinel")),Data([1,2,3]))
        }
    }
    func testNamingAbandonedClaimDoesNotPermanentlyDisambiguateSuccessor() throws {
        let first = try catalog.reserve(device:device,application:application,backend:.native)
        try catalog.abandon(first)
        let next = try catalog.reserve(device:device,application:AndroidApplication(packageName:"dev.example.next",name:application.name),backend:.native)
        XCTAssertEqual(next.bundleFilename,"Example.app")
        try catalog.abandon(next)
    }
    func testNamingLegacyBarrierWaitsForAllOtherAcceptedBundles() throws {
        let first = try qaNamingLegacy()
        let second = try qaNamingLegacy(AndroidApplication(packageName:"dev.example.oldsecond",name:"Second"))
        let upgradedFirst = try qaNamingUpgrade(first)
        let blocked = try catalog.reserve(device:device,application:application,backend:.native)
        XCTAssertEqual(blocked.bundleFilename,upgradedFirst.bundleFilename,"An old wrapper on another row still globally validates the catalog")
        try catalog.abandon(blocked)
        _ = try qaNamingUpgrade(second)
        let clean = try catalog.reserve(device:device,application:application,backend:.native)
        XCTAssertEqual(clean.bundleFilename,"Example.app")
        try catalog.abandon(clean)
    }
    func testNamingLegacyOfflineMigrationPreservesIdentityAndPriorBytes() throws {
        let legacy = try qaNamingLegacy(backend:.scrcpy)
        let oldConfig = try Data(contentsOf:legacy.bundleURL.appendingPathComponent("Contents/Resources/launch.json"))
        let oldIcon = try Data(contentsOf:legacy.bundleURL.appendingPathComponent("Contents/Resources/AndroidApp.png"))
        let upgraded = try qaNamingUpgrade(legacy)
        let claim = try catalog.reserve(device:device,application:AndroidApplication(packageName:application.packageName,name:"Changed Android name"),backend:.native)
        XCTAssertEqual(claim.bundleFilename,"Example.app")
        XCTAssertEqual(claim.bundleIdentifier,legacy.bundleIdentifier)
        XCTAssertEqual(claim.application.name,legacy.name)
        XCTAssertEqual(claim.backend,.scrcpy)
        try qaNamingStage(claim);let renamed = try catalog.commit(claim)
        XCTAssertEqual(renamed.availability,.inactive);XCTAssertEqual(renamed.location,.inactive)
        XCTAssertFalse(FileManager.default.fileExists(atPath:renamed.activeBundleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:renamed.inactiveBundleURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:upgraded.inactiveBundleURL.path))
        let backup = paths.privateRoot.appendingPathComponent("backups/\(legacy.deviceHash)/\(legacy.packageName)-\(legacy.generation.uuidString).app")
        XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("Contents/Resources/launch.json")),oldConfig)
        XCTAssertEqual(try Data(contentsOf:backup.appendingPathComponent("Contents/Resources/AndroidApp.png")),oldIcon)
    }
    func testNamingOnlineMigrationUnregistersOldURLAndCompensatesLateRegister() throws {
        let legacy = try qaNamingLegacy()
        let upgraded = try qaNamingUpgrade(legacy)
        let oldRegister = try XCTUnwrap(catalog.reconcile(availableSerials:[device.serial],enabled:true).first(where:\.register))
        // The old register is already externally dispatched, but is not acked.
        let claim = try catalog.reserve(device:device,application:application,backend:.native)
        XCTAssertEqual(claim.bundleFilename,"Example.app")
        try qaNamingStage(claim);_ = try catalog.commit(claim)
        let oldUnregister = try XCTUnwrap(catalog.reconcile(availableSerials:[device.serial],enabled:true).first(where:{!$0.register}))
        XCTAssertEqual(oldUnregister.bundleURL,upgraded.activeBundleURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath:upgraded.activeBundleURL.path))
        try execute([oldUnregister])
        let newRegister = try XCTUnwrap(catalog.reconcile(availableSerials:[device.serial],enabled:true).first(where:\.register))
        XCTAssertEqual(newRegister.bundleURL.lastPathComponent,"Example.app")
        XCTAssertFalse(try catalog.completeRegistration(oldRegister))
        XCTAssertTrue(try catalog.registrationIsCurrent(newRegister),"Late old-path completion must not replace the successor receipt")
        let repaired = try catalog.reconcile(availableSerials:[device.serial],enabled:true)
        XCTAssertTrue(repaired.contains{!$0.register && $0.bundleURL == upgraded.activeBundleURL})
        try execute(repaired)
        XCTAssertTrue(try catalog.isLaunchAllowed(bundleURL:newRegister.bundleURL,serial:device.serial,packageName:application.packageName))
        XCTAssertFalse(try catalog.isLaunchAllowed(bundleURL:upgraded.activeBundleURL,serial:device.serial,packageName:application.packageName))
    }
    func testNamingAccentDistinctNamesDoNotNeedQualifier() throws {
        let plain = try catalog.reserve(device:device,application:AndroidApplication(packageName:"dev.example.plain",name:"Cafe"),backend:.native)
        let accent = try catalog.reserve(device:device,application:AndroidApplication(packageName:"dev.example.accent",name:"Café"),backend:.native)
        XCTAssertEqual(plain.bundleFilename,"Cafe.app")
        XCTAssertEqual(accent.bundleFilename,"Café.app","Canonical normalization must not erase meaningful accents")
        try catalog.abandon(plain);try catalog.abandon(accent)
    }
    func testNamingLegacyLiveReservationBlocksCleanPhaseUntilReleased() throws {
        let legacy = try qaNamingLegacy();_ = try qaNamingUpgrade(legacy)
        let other = AndroidApplication(packageName:"dev.example.legacyclaim",name:"Other")
        let claim = try catalog.reserve(device:device,application:other,backend:.native,preserveLegacyFilename:true)
        let manifestURL = paths.privateRoot.appendingPathComponent("catalog.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as? [String:Any])
        var claims = try XCTUnwrap(json["reservations"] as? [String:[String:Any]])
        claims[claim.key]?.removeValue(forKey:"namingVersion");json["reservations"] = claims
        try JSONSerialization.data(withJSONObject:json).write(to:manifestURL,options:.atomic)
        XCTAssertFalse(try catalog.canRepairNames())
        let blocked = try catalog.reserve(device:device,application:application,backend:.native)
        XCTAssertEqual(blocked.bundleFilename,legacy.bundleFilename)
        try catalog.abandon(blocked);try catalog.abandon(claim)
        XCTAssertTrue(try catalog.canRepairNames())
        let clean = try catalog.reserve(device:device,application:application,backend:.native)
        XCTAssertEqual(clean.bundleFilename,"Example.app");try catalog.abandon(clean)
    }
    func testNamingRegisterDispatchedBeforeCodeUpgradeStillCompensatesAfterRename() throws {
        let legacy = try qaNamingLegacy()
        let preUpgradeRegister = try XCTUnwrap(catalog.reconcile(availableSerials:[device.serial],enabled:true).first(where:\.register))
        _ = try qaNamingUpgrade(legacy)
        try execute(catalog.reconcile(availableSerials:[device.serial],enabled:true))
        try execute(catalog.reconcile(availableSerials:[device.serial],enabled:true))
        let clean = try catalog.reserve(device:device,application:application,backend:.native)
        XCTAssertEqual(clean.bundleFilename,"Example.app")
        try qaNamingStage(clean);_ = try catalog.commit(clean)
        try execute(catalog.reconcile(availableSerials:[device.serial],enabled:true))
        let current = try XCTUnwrap(catalog.reconcile(availableSerials:[device.serial],enabled:true).first(where:\.register))
        XCTAssertFalse(try catalog.completeRegistration(preUpgradeRegister))
        XCTAssertTrue(try catalog.registrationIsCurrent(current))
        let actions = try catalog.reconcile(availableSerials:[device.serial],enabled:true)
        XCTAssertTrue(actions.contains{!$0.register && $0.bundleURL == legacy.activeBundleURL})
        try execute(actions)
        XCTAssertTrue(try catalog.isLaunchAllowed(bundleURL:current.bundleURL,serial:device.serial,packageName:application.packageName))
    }

    func testNamingSavedAssetsPreserveOptionsAndRejectStaleOrSymlinkedReads() throws {
        let legacy = try qaNamingLegacy(backend:.scrcpy)
        XCTAssertEqual(try catalog.savedLaunchConfiguration(for:legacy)["qa_saved_option"],"preserve this value")
        XCTAssertEqual(try catalog.savedIcon(for:legacy),Data("saved Android icon fixture".utf8))
        let upgraded = try qaNamingUpgrade(legacy)
        XCTAssertThrowsError(try catalog.savedIcon(for:legacy))
        XCTAssertThrowsError(try catalog.savedLaunchConfiguration(for:legacy))
        let png = upgraded.bundleURL.appendingPathComponent("Contents/Resources/AndroidApp.png")
        let foreign = root.appendingPathComponent("foreign-icon.png")
        try Data([9,8,7]).write(to:foreign)
        try FileManager.default.removeItem(at:png)
        try FileManager.default.createSymbolicLink(at:png,withDestinationURL:foreign)
        XCTAssertThrowsError(try catalog.savedIcon(for:upgraded))
        XCTAssertEqual(try Data(contentsOf:foreign),Data([9,8,7]))
    }
    func testNamingForeignPublicDestinationAppearingAfterStageRemainsUntouched() throws {
        let claim = try catalog.reserve(device:device,application:application,backend:.native)
        try qaNamingStage(claim);let accepted = try catalog.commit(claim)
        try FileManager.default.createDirectory(at:accepted.activeBundleURL,withIntermediateDirectories:true)
        let foreign = accepted.activeBundleURL.appendingPathComponent("foreign-sentinel")
        try Data([4,5,6]).write(to:foreign)
        _ = try catalog.reconcile(availableSerials:[device.serial],enabled:true)
        XCTAssertEqual(try Data(contentsOf:foreign),Data([4,5,6]))
        XCTAssertTrue(FileManager.default.fileExists(atPath:accepted.inactiveBundleURL.path),"The complete owned generation remains recoverable")
        XCTAssertFalse(try catalog.isLaunchAllowed(bundleURL:accepted.activeBundleURL,serial:device.serial,packageName:application.packageName))
        XCTAssertFalse(try catalog.issues().isEmpty,"Foreign occupancy must produce an actionable diagnostic")
    }
    func testNamingDeadLegacyReservationWithoutAcceptedAppDoesNotBlockForever() throws {
        let legacy = try qaNamingLegacy();_ = try qaNamingUpgrade(legacy)
        let claim = try catalog.reserve(device:device,application:AndroidApplication(packageName:"dev.example.deadclaim",name:"Unfinished"),backend:.native,preserveLegacyFilename:true)
        let manifestURL = paths.privateRoot.appendingPathComponent("catalog.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as? [String:Any])
        var claims = try XCTUnwrap(json["reservations"] as? [String:[String:Any]])
        claims[claim.key]?.removeValue(forKey:"namingVersion");claims[claim.key]?["ownerPID"] = 2_000_000_000;json["reservations"] = claims
        try JSONSerialization.data(withJSONObject:json).write(to:manifestURL,options:.atomic)
        XCTAssertTrue(try catalog.canRepairNames())
        let clean = try catalog.reserve(device:device,application:application,backend:.native)
        XCTAssertEqual(clean.bundleFilename,"Example.app");try catalog.abandon(clean)
    }

    func testNamingLateOldPathUnregisterCannotMoveNewPathBeforeItsOwnAck() throws {
        let legacy = try qaNamingLegacy();_ = try qaNamingUpgrade(legacy)
        try execute(catalog.reconcile(availableSerials:[device.serial],enabled:true))
        let clean = try catalog.reserve(device:device,application:application,backend:.native)
        try qaNamingStage(clean);_ = try catalog.commit(clean)
        let oldPathUnregister = try XCTUnwrap(catalog.reconcile(availableSerials:[device.serial],enabled:true).first(where:{!$0.register}))
        try execute([oldPathUnregister])
        try execute(catalog.reconcile(availableSerials:[device.serial],enabled:true))
        let current = try XCTUnwrap(catalog.records().first)
        let newPathUnregister = try XCTUnwrap(catalog.reconcile(availableSerials:[],enabled:true).first(where:{!$0.register}))
        XCTAssertNotEqual(oldPathUnregister.bundleURL,newPathUnregister.bundleURL)
        _ = try catalog.completeRegistration(oldPathUnregister)
        XCTAssertTrue(FileManager.default.fileExists(atPath:current.activeBundleURL.path),"Only completion of the new URL's unregister may hide its bytes")
        XCTAssertTrue(try catalog.registrationIsCurrent(newPathUnregister))
        try execute([newPathUnregister])
        XCTAssertFalse(FileManager.default.fileExists(atPath:current.activeBundleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath:current.inactiveBundleURL.path))
    }

    func testNamingAbsentLegacyAppDoesNotBlockHealthyUpgradeAndKeepsHistory() throws {
        let healthy = try qaNamingLegacy()
        let missing = try qaNamingLegacy(AndroidApplication(packageName:"dev.example.missing",name:"Deleted App"))
        try FileManager.default.removeItem(at:missing.inactiveBundleURL)
        _ = try qaNamingUpgrade(healthy)
        XCTAssertTrue(try catalog.canRepairNames())
        let clean = try catalog.reserve(device:device,application:application,backend:.native)
        XCTAssertEqual(clean.bundleFilename,"Example.app")
        try catalog.abandon(clean)
        let retained = try XCTUnwrap(catalog.records().first(where:{$0.key == missing.key}))
        XCTAssertEqual(retained.generation,missing.generation)
        XCTAssertEqual(retained.bundleIdentifier,missing.bundleIdentifier)
        XCTAssertEqual(retained.bundleFilename,missing.bundleFilename)
    }
    func testNamingDeletedButRunningLegacyPathStillBlocksCompatibilityBarrier() throws {
        let healthy = try qaNamingLegacy()
        let missing = try qaNamingLegacy(AndroidApplication(packageName:"dev.example.deletedrunning",name:"Deleted Running App"))
        try FileManager.default.removeItem(at:missing.inactiveBundleURL)
        _ = try qaNamingUpgrade(healthy)
        for runningPath in [missing.activeBundleURL.path,missing.inactiveBundleURL.path] {
            XCTAssertFalse(try catalog.canRepairNames(runningBundlePaths:[runningPath]))
            let blocked = try catalog.reserve(device:device,application:application,backend:.native,runningBundlePaths:[runningPath])
            XCTAssertEqual(blocked.bundleFilename,healthy.bundleFilename,"An unlinked executable can still be mapped by a running old reader")
            try catalog.abandon(blocked)
        }
        XCTAssertTrue(try catalog.canRepairNames())
    }

}
