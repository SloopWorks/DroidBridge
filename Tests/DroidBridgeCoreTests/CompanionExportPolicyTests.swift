import XCTest
import Foundation
@testable import DroidBridgeCore

extension ManagedAppsTests {
    func testCompanionSelectionDeniesStaleLaunchAndLateRegistration() throws {
        let reservation = try catalog.reserve(device: device, application: application, backend: .native)
        try stage(reservation); let record = try catalog.commit(reservation)
        let oldRegister = try XCTUnwrap(catalog.reconcile(availableSerials: [device.serial], enabled: true).first)
        try execute([oldRegister])
        let id = UUID().uuidString
        try catalog.updateCompanionExports(deviceID: id, aliases: [device.serial, "127.0.0.1:45678"], selection: [application.packageName: false])
        XCTAssertFalse(try catalog.isLaunchAllowed(bundleURL: record.activeBundleURL, serial: device.serial, packageName: application.packageName))
        XCTAssertFalse(try catalog.companionExportAllowed(serial: "127.0.0.1:45678", packageName: application.packageName))
        XCTAssertFalse(try catalog.registrationIsCurrent(oldRegister))
        let removal = try catalog.reconcile(availableSerials: [device.serial], enabled: true)
        XCTAssertTrue(removal.allSatisfy { !$0.register })
        try execute(removal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.activeBundleURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.inactiveBundleURL.path))
        try catalog.updateCompanionExports(deviceID: id, aliases: [device.serial], selection: [application.packageName: true])
        try execute(catalog.reconcile(availableSerials: [device.serial], enabled: true))
        XCTAssertTrue(try catalog.isLaunchAllowed(bundleURL: record.activeBundleURL, serial: device.serial, packageName: application.packageName))
    }

    func testCompanionPolicySurvivesLegacyCatalogRewrite() throws {
        try catalog.updateCompanionExports(deviceID: UUID().uuidString, aliases: [device.serial], selection: [application.packageName: false])
        let url = CompanionExportPolicy.url(paths: paths)
        let prior = try Data(contentsOf: url)
        // A pre-companion writer serializes only its known catalog fields.
        try Data(#"{"version":1,"records":{},"reservations":{},"publications":{},"actions":[],"policyEnabled":true,"availableSerials":["emulator-5580"]}"#.utf8)
            .write(to: paths.privateRoot.appendingPathComponent("catalog.json"))
        let oldWriterSuccessor = ManagedAppCatalog(paths: paths)
        XCTAssertFalse(try oldWriterSuccessor.companionExportAllowed(serial: device.serial, packageName: application.packageName))
        XCTAssertEqual(try Data(contentsOf: url), prior)
        XCTAssertThrowsError(try oldWriterSuccessor.reserve(device: device, application: application, backend: .native))
    }

    func testCompanionCorruptPolicyDeniesAndRecoversWithoutCacheLeak() throws {
        let id = UUID().uuidString
        try catalog.updateCompanionExports(deviceID: id, aliases: [device.serial], selection: [:])
        let url = CompanionExportPolicy.url(paths: paths), prior = try Data(contentsOf: url)
        XCTAssertTrue(try catalog.companionExportAllowed(serial: device.serial, packageName: application.packageName))
        try Data("broken".utf8).write(to: url)
        XCTAssertFalse(try catalog.companionExportAllowed(serial: device.serial, packageName: application.packageName))
        try prior.write(to: url)
        XCTAssertTrue(try catalog.companionExportAllowed(serial: device.serial, packageName: application.packageName))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertFalse(try catalog.companionExportAllowed(serial: device.serial, packageName: application.packageName))
    }

    func testCompanionAliasConflictRefusesWithoutLosingAcceptedPolicy() throws {
        try catalog.updateCompanionExports(deviceID: UUID().uuidString, aliases: [device.serial], selection: [application.packageName: false])
        let url = CompanionExportPolicy.url(paths: paths), prior = try Data(contentsOf: url)
        XCTAssertThrowsError(try catalog.updateCompanionExports(deviceID: UUID().uuidString, aliases: [device.serial], selection: [:]))
        XCTAssertEqual(try Data(contentsOf: url), prior)
        XCTAssertFalse(try catalog.companionExportAllowed(serial: device.serial, packageName: application.packageName))
    }
}

extension ManagedAppsTests {
    func testCompanionExportRevisionsArePerPackageAndCanonical() throws {
        let id = UUID().uuidString, trust = UUID().uuidString, other = "com.example.other"
        try catalog.bindCompanionExportAuthority(deviceID: id, trustID: trust, aliases: [device.serial])
        XCTAssertTrue(try catalog.applyCompanionExport(deviceID: id, trustID: trust, packageName: other, selected: false, revision: 8))
        XCTAssertTrue(try catalog.applyCompanionExport(deviceID: id, trustID: trust, packageName: application.packageName, selected: false, revision: 7))
        XCTAssertTrue(try catalog.applyCompanionExport(deviceID: id, trustID: trust, packageName: application.packageName, selected: true, revision: 9))
        XCTAssertFalse(try catalog.applyCompanionExport(deviceID: id, trustID: trust, packageName: application.packageName, selected: false, revision: 7))
        XCTAssertTrue(try catalog.applyCompanionExport(deviceID: id, trustID: trust, packageName: application.packageName, selected: true, revision: 9))
        XCTAssertThrowsError(try catalog.applyCompanionExport(deviceID: id, trustID: trust, packageName: application.packageName, selected: false, revision: 9))
        let fresh = ManagedAppCatalog(paths: paths)
        XCTAssertEqual(try fresh.companionExportSelection(deviceID: id), [other: false, application.packageName: true])
        XCTAssertFalse(try fresh.companionExportAllowed(serial: device.serial, packageName: other))
        XCTAssertTrue(try fresh.companionExportAllowed(serial: device.serial, packageName: application.packageName))
    }
    func testCompanionRePairPreservesSelectionAndFencesOldAuthority() throws {
        let id = UUID().uuidString, old = UUID().uuidString, new = UUID().uuidString
        try catalog.bindCompanionExportAuthority(deviceID: id, trustID: old, aliases: [device.serial])
        try catalog.applyCompanionExport(deviceID: id, trustID: old, packageName: application.packageName, selected: false, revision: 99)
        try catalog.bindCompanionExportAuthority(deviceID: id, trustID: new, aliases: [device.serial])
        XCTAssertFalse(try catalog.companionExportAllowed(serial: device.serial, packageName: application.packageName))
        XCTAssertThrowsError(try catalog.applyCompanionExport(deviceID: id, trustID: old, packageName: application.packageName, selected: true, revision: 100))
        try catalog.applyCompanionExport(deviceID: id, trustID: new, packageName: application.packageName, selected: true, revision: 1)
        XCTAssertTrue(try catalog.companionExportAllowed(serial: device.serial, packageName: application.packageName))
    }
}

extension ManagedAppsTests {
    func testCompanionPolicyPermanentlyAdvancesLegacyReaderFence() throws {
        let id = UUID().uuidString, trust = UUID().uuidString
        try catalog.bindCompanionExportAuthority(deviceID: id, trustID: trust, aliases: [device.serial])
        try catalog.applyCompanionExport(deviceID: id, trustID: trust, packageName: application.packageName, selected: false, revision: 1)
        let url = paths.privateRoot.appendingPathComponent("catalog.json")
        func version() throws -> Int { try XCTUnwrap((JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["version"] as? Int) }
        XCTAssertEqual(try version(), 2)
        let fresh = ManagedAppCatalog(paths: paths)
        _ = try fresh.reconcile(availableSerials: [device.serial], enabled: true)
        XCTAssertEqual(try version(), 2)
        XCTAssertFalse(try fresh.companionExportAllowed(serial: device.serial, packageName: application.packageName))
    }
}

extension ManagedAppsTests {
    func testExplicitForgetPreservesChoicesAndRevisionBytes() throws {
        let oldID = UUID().uuidString, trust = UUID().uuidString
        try catalog.bindCompanionExportAuthority(deviceID: oldID, trustID: trust, aliases: [device.serial])
        try catalog.applyCompanionExport(deviceID: oldID, trustID: trust, packageName: application.packageName, selected: false, revision: 44)
        try catalog.forgetCompanionExportAuthority(deviceID: oldID)
        XCTAssertTrue(try catalog.companionExportWasForgotten(deviceID: oldID))
        XCTAssertEqual(try catalog.companionExportSelection(deviceID: oldID)[application.packageName], false)
        XCTAssertFalse(try catalog.companionExportAllowed(serial: device.serial, packageName: application.packageName))
        let document = try CompanionExportPolicy.read(CompanionExportPolicy.url(paths: paths))
        XCTAssertEqual(document.devices[oldID.lowercased()]?.revisions?[application.packageName], 44)
        XCTAssertEqual(document.devices[oldID.lowercased()]?.authorityTrustID, trust.lowercased())
    }
    func testNewInstallationCannotStealAliasWithoutExplicitForgetAndPair() throws {
        let oldID = UUID().uuidString, newID = UUID().uuidString
        try catalog.bindCompanionExportAuthority(deviceID: oldID, trustID: UUID().uuidString, aliases: [device.serial])
        let url = CompanionExportPolicy.url(paths: paths)
        let prior = try Data(contentsOf: url)
        XCTAssertThrowsError(try catalog.bindCompanionExportAuthority(deviceID: newID, trustID: UUID().uuidString, aliases: [device.serial], allowingForgottenAliasTransfer: true))
        XCTAssertEqual(try Data(contentsOf: url), prior)
        try catalog.forgetCompanionExportAuthority(deviceID: oldID)
        let forgotten = try Data(contentsOf: url)
        XCTAssertThrowsError(try catalog.bindCompanionExportAuthority(deviceID: newID, trustID: UUID().uuidString, aliases: [device.serial]))
        XCTAssertEqual(try Data(contentsOf: url), forgotten)
    }
    func testExplicitNewInstallationAliasMoveInheritsChoicesAndStartsNewAuthority() throws {
        let oldID = UUID().uuidString, newID = UUID().uuidString, oldTrust = UUID().uuidString, newTrust = UUID().uuidString
        try catalog.bindCompanionExportAuthority(deviceID: oldID, trustID: oldTrust, aliases: [device.serial])
        try catalog.applyCompanionExport(deviceID: oldID, trustID: oldTrust, packageName: application.packageName, selected: false, revision: 99)
        try catalog.forgetCompanionExportAuthority(deviceID: oldID)
        try catalog.bindCompanionExportAuthority(deviceID: newID, trustID: newTrust, aliases: [device.serial], allowingForgottenAliasTransfer: true)
        XCTAssertFalse(try catalog.companionExportAllowed(serial: device.serial, packageName: application.packageName))
        let document = try CompanionExportPolicy.read(CompanionExportPolicy.url(paths: paths))
        XCTAssertEqual(document.devices[oldID.lowercased()]?.aliases, [])
        XCTAssertEqual(document.devices[oldID.lowercased()]?.revisions?[application.packageName], 99)
        XCTAssertEqual(document.devices[newID.lowercased()]?.selection[application.packageName], false)
        XCTAssertEqual(document.devices[newID.lowercased()]?.revisions, [:])
        try catalog.applyCompanionExport(deviceID: newID, trustID: newTrust, packageName: application.packageName, selected: true, revision: 1)
        XCTAssertTrue(try catalog.companionExportAllowed(serial: device.serial, packageName: application.packageName))
        XCTAssertThrowsError(try catalog.applyCompanionExport(deviceID: newID, trustID: oldTrust, packageName: application.packageName, selected: false, revision: 100))
    }
    func testAliasMoveKeepsExistingNewChoicesAndMostRestrictiveInheritedChoices() throws {
        let oldID = UUID().uuidString, otherID = UUID().uuidString, newID = UUID().uuidString
        let oldTrust = UUID().uuidString, otherTrust = UUID().uuidString, newTrust = UUID().uuidString
        let second = "127.0.0.1:45999", third = "127.0.0.1:45998", pkg = "com.example.other"
        try catalog.bindCompanionExportAuthority(deviceID: oldID, trustID: oldTrust, aliases: [device.serial])
        try catalog.applyCompanionExport(deviceID: oldID, trustID: oldTrust, packageName: pkg, selected: true, revision: 1)
        try catalog.applyCompanionExport(deviceID: oldID, trustID: oldTrust, packageName: application.packageName, selected: false, revision: 2)
        try catalog.bindCompanionExportAuthority(deviceID: otherID, trustID: otherTrust, aliases: [second])
        try catalog.applyCompanionExport(deviceID: otherID, trustID: otherTrust, packageName: pkg, selected: false, revision: 1)
        try catalog.bindCompanionExportAuthority(deviceID: newID, trustID: newTrust, aliases: [third])
        try catalog.applyCompanionExport(deviceID: newID, trustID: newTrust, packageName: application.packageName, selected: true, revision: 1)
        try catalog.forgetCompanionExportAuthority(deviceID: oldID); try catalog.forgetCompanionExportAuthority(deviceID: otherID)
        try catalog.bindCompanionExportAuthority(deviceID: newID, trustID: newTrust, aliases: [device.serial, second, third], allowingForgottenAliasTransfer: true)
        XCTAssertEqual(try catalog.companionExportSelection(deviceID: newID), [application.packageName: true, pkg: false])
    }
}

extension ManagedAppsTests {
    func testCompanionExportAtomicOutcomePreservesCanonicalBooleanCompatibility() throws {
        let id = UUID().uuidString, trust = UUID().uuidString
        try catalog.bindCompanionExportAuthority(deviceID: id, trustID: trust, aliases: [device.serial])
        XCTAssertEqual(try catalog.applyCompanionExportOutcome(deviceID: id, trustID: trust, packageName: application.packageName, selected: true, revision: 10), .committed)
        XCTAssertEqual(try catalog.applyCompanionExportOutcome(deviceID: id, trustID: trust, packageName: application.packageName, selected: true, revision: 10), .replayed)
        XCTAssertEqual(try catalog.applyCompanionExportOutcome(deviceID: id, trustID: trust, packageName: application.packageName, selected: false, revision: 9), .stale)
        XCTAssertThrowsError(try catalog.applyCompanionExportOutcome(deviceID: id, trustID: trust, packageName: application.packageName, selected: false, revision: 10))
        XCTAssertTrue(try catalog.applyCompanionExport(deviceID: id, trustID: trust, packageName: application.packageName, selected: true, revision: 10))
        XCTAssertFalse(try catalog.applyCompanionExport(deviceID: id, trustID: trust, packageName: application.packageName, selected: false, revision: 9))
    }
    func testCompanionExportConcurrentOutcomeCommitsExactlyOnce() async throws {
        let id = UUID().uuidString, trust = UUID().uuidString, package = application.packageName, paths = try XCTUnwrap(self.paths)
        try catalog.bindCompanionExportAuthority(deviceID: id, trustID: trust, aliases: [device.serial])
        let outcomes = try await withThrowingTaskGroup(of: ManagedAppCatalog.CompanionExportOutcome.self) { group in
            for _ in 0..<2 { group.addTask { try ManagedAppCatalog(paths: paths).applyCompanionExportOutcome(deviceID: id, trustID: trust, packageName: package, selected: true, revision: 10) } }
            var values: [ManagedAppCatalog.CompanionExportOutcome] = []
            for try await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(outcomes.filter { $0 == .committed }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .replayed }.count, 1)
    }
}
