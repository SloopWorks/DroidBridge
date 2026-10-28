import XCTest
import Foundation
import Darwin
import DroidBridgeCore

/// Independent ordering regressions for actual durable catalog transitions;
/// no Android, Launch Services or fake successful video is involved.
extension ManagedAppsTests {
    func testUnregisterFinishingAfterCurrentRegisterRetainsCompensation() throws {
        let reservation = try catalog.reserve(device:device,application:application,backend:.native)
        try stage(reservation)
        _ = try catalog.commit(reservation)
        try execute(catalog.reconcile(availableSerials:[device.serial],enabled:true))
        let unregister = try XCTUnwrap(catalog.reconcile(availableSerials:[],enabled:true).first)
        XCTAssertFalse(unregister.register)
        XCTAssertTrue(try catalog.registrationIsCurrent(unregister)) // dispatched effect now in flight
        let register = try XCTUnwrap(catalog.reconcile(availableSerials:[device.serial],enabled:true).first(where: \.register))
        XCTAssertTrue(try catalog.completeRegistration(register)) // newer effect finishes first
        _ = try catalog.completeRegistration(unregister)         // older effect finishes last
        let repair = try catalog.reconcile(availableSerials:[device.serial],enabled:true)
        XCTAssertTrue(repair.contains { $0.register }, "Last external effect was unregister; an active record needs durable compensating register")
    }
}

extension ManagedAppsTests {
    func testDuplicateUnregisterCompletionStillCompensatesAfterRegisterAck() throws {
        let claim = try catalog.reserve(device:device,application:application,backend:.native)
        try stage(claim); _ = try catalog.commit(claim)
        try execute(catalog.reconcile(availableSerials:[device.serial],enabled:true))
        let stale = try XCTUnwrap(catalog.reconcile(availableSerials:[],enabled:true).first)
        let online = try catalog.reconcile(availableSerials:[device.serial],enabled:true)
        for action in online where action.register { _ = try catalog.completeRegistration(action) }
        _ = try catalog.completeRegistration(stale)
        for action in try catalog.reconcile(availableSerials:[device.serial],enabled:true) where action.register { _ = try catalog.completeRegistration(action) }
        // A second process already dispatched the same unregister before either
        // worker acknowledged it. Its effect can land after the repair register.
        _ = try catalog.completeRegistration(stale)
        XCTAssertTrue(try catalog.reconcile(availableSerials:[device.serial],enabled:true).contains { $0.register })
    }
    func testUnregisterAdmissionRefusesForeignReplacementAtOwnedURL() throws {
        let claim = try catalog.reserve(device:device,application:application,backend:.native)
        try stage(claim); let record = try catalog.commit(claim)
        try execute(catalog.reconcile(availableSerials:[device.serial],enabled:true))
        let action = try XCTUnwrap(catalog.reconcile(availableSerials:[],enabled:true).first)
        let preserved = root.appendingPathComponent("owned-preserved.app")
        try FileManager.default.moveItem(at:record.activeBundleURL,to:preserved)
        try FileManager.default.createDirectory(at:record.activeBundleURL.appendingPathComponent("Contents"),withIntermediateDirectories:true)
        let foreign:[String:Any] = ["CFBundleIdentifier":"dev.foreign.mustremain","CFBundleName":"Foreign"]
        try PropertyListSerialization.data(fromPropertyList:foreign,format:.xml,options:0).write(to:record.activeBundleURL.appendingPathComponent("Contents/Info.plist"))
        let sentinel = record.activeBundleURL.appendingPathComponent("untouched")
        try Data([7]).write(to:sentinel)
        let allowed = (try? catalog.registrationIsCurrent(action)) ?? false
        XCTAssertFalse(allowed,"Do not dispatch lsregister -u against a foreign application now occupying an originally-owned URL")
        XCTAssertEqual(try Data(contentsOf:sentinel),Data([7]))
    }
}

extension ManagedAppsTests {
    func testLateOldGenerationRegisterPreservesSuccessorReceipt() throws {
        let first=try catalog.reserve(device:device,application:application,backend:.native)
        try stage(first);_ = try catalog.commit(first)
        let oldRegister=try XCTUnwrap(catalog.reconcile(availableSerials:[device.serial],enabled:true).first)
        try execute(catalog.reconcile(availableSerials:[],enabled:true))
        let second=try catalog.reserve(device:device,application:application,backend:.scrcpy)
        try stage(second);_ = try catalog.commit(second)
        let successor=try XCTUnwrap(catalog.reconcile(availableSerials:[device.serial],enabled:true).first(where: \.register))
        XCTAssertFalse(try catalog.completeRegistration(oldRegister))
        XCTAssertTrue(try catalog.registrationIsCurrent(successor),"Compensation must preserve a newer in-flight receipt instead of replacing its identity")
        let actions=try catalog.reconcile(availableSerials:[device.serial],enabled:true)
        XCTAssertTrue(actions.contains { !$0.register })
        XCTAssertTrue(actions.contains { $0.id==successor.id })
    }
    func testCatalogHeldLockRefusesWithinBoundAndHonorsCancellation() async throws {
        _ = try catalog.records()
        let fd=open(paths.privateRoot.appendingPathComponent("catalog.lock").path,O_RDWR)
        XCTAssertGreaterThanOrEqual(fd,0)
        defer { flock(fd,LOCK_UN);close(fd) }
        XCTAssertEqual(flock(fd,LOCK_EX|LOCK_NB),0)
        let start=ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try catalog.records())
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,1,"Held cross-process lock must not block indefinitely")
        let owned=catalog!
        let waiting=Task.detached { try owned.records() }
        waiting.cancel()
        do { _=try await waiting.value;XCTFail("Cancelled lock admission must not proceed") }
        catch { XCTAssertTrue(error is CancellationError,"Expected terminal cancellation, got \(error)") }
    }
}

extension ManagedAppsTests {
    func testManagedUpgradePreservesAcceptedFriendlyNameAndBackend() throws {
        let originalApp=AndroidApplication(packageName:application.packageName,name:"My accepted app name")
        let first=try catalog.reserve(device:device,application:originalApp,backend:.scrcpy)
        try stage(first);_ = try catalog.commit(first)
        let refreshed=AndroidApplication(packageName:application.packageName,name:"Fresh Android label")
        let upgrade=try catalog.reserve(device:device,application:refreshed,backend:.native)
        XCTAssertEqual(upgrade.application.name,originalApp.name)
        XCTAssertEqual(upgrade.backend,.scrcpy)
        XCTAssertEqual(upgrade.bundleFilename,first.bundleFilename)
        try catalog.abandon(upgrade)
    }
}
