import XCTest
@testable import DroidBridgeCore

final class CompanionPendingAdmissionTests: XCTestCase {
    func testCandidateNeverAppearsInNormalAccountsAndWrongFinalizeIsFenced() throws {
        let device = UUID().uuidString.lowercased(), trust = UUID().uuidString.lowercased(), id = UUID()
        defer { try? CompanionPendingCredentialStore.remove(id:id); try? CompanionCredentialStore.remove(deviceID:device) }
        let record = try CompanionCredentialRecord(deviceID:device,trustID:trust,credential:String(repeating:"A",count:43),serverPin:String(repeating:"a",count:64))
        let candidate = CompanionPendingCredentialStore.Candidate(record:record,expires:Date().addingTimeInterval(600))
        try CompanionPendingCredentialStore.stage(candidate,id:id)
        XCTAssertNil(try CompanionCredentialStore.load(deviceID:device))
        XCTAssertEqual(try CompanionPendingCredentialStore.load(id:id),candidate)
        XCTAssertThrowsError(try CompanionPendingCredentialStore.finalize(id:id,deviceID:device,trustID:UUID().uuidString,serverPin:record.serverPin))
        XCTAssertNil(try CompanionCredentialStore.load(deviceID:device))
        try CompanionPendingCredentialStore.finalize(id:id,deviceID:device,trustID:trust,serverPin:record.serverPin)
        XCTAssertEqual(try CompanionCredentialStore.load(deviceID:device),record)
        try CompanionPendingCredentialStore.remove(id:id)
        XCTAssertNil(try CompanionPendingCredentialStore.load(id:id))
        XCTAssertEqual(try CompanionCredentialStore.load(deviceID:device),record)
    }
    func testConflictingStageSaveAndExpiredCallbackCannotFinalize() async throws {
        let device = UUID().uuidString.lowercased(), trust = UUID().uuidString.lowercased(), id = UUID()
        defer { try? CompanionPendingCredentialStore.remove(id:id); try? CompanionCredentialStore.remove(deviceID:device) }
        let record = try CompanionCredentialRecord(deviceID:device,trustID:trust,credential:String(repeating:"A",count:43),serverPin:String(repeating:"a",count:64))
        let candidate = CompanionPendingCredentialStore.Candidate(record:record,expires:Date().addingTimeInterval(0.1))
        try CompanionPendingCredentialStore.stage(candidate,id:id)
        let changed = try CompanionCredentialRecord(deviceID:device,trustID:trust,credential:String(repeating:"B",count:43),serverPin:String(repeating:"a",count:64))
        XCTAssertThrowsError(try CompanionPendingCredentialStore.stage(.init(record:changed,expires:candidate.expires),id:id))
        try await Task.sleep(nanoseconds:150_000_000)
        XCTAssertThrowsError(try CompanionPendingCredentialStore.finalize(id:id,deviceID:device,trustID:trust,serverPin:record.serverPin))
        XCTAssertNil(try CompanionCredentialStore.load(deviceID:device))
    }
    func testPolicyBindFailureDoesNotPromoteCandidateAndForgetCanRetireIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("candidate-bind-fault-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at:root) }
        let paths = ManagedAppsPaths(privateRoot:root.appendingPathComponent("Private.noindex"),activeRoot:root.appendingPathComponent("Apps")), catalog = ManagedAppCatalog(paths:ManagedAppsPaths(privateRoot:root.appendingPathComponent("Private.noindex"),activeRoot:root.appendingPathComponent("Apps")))
        let old = UUID().uuidString, device = UUID().uuidString, trust = UUID().uuidString, id = UUID()
        defer { try? CompanionPendingCredentialStore.remove(id:id); try? CompanionCredentialStore.remove(deviceID:device) }
        try catalog.bindCompanionExportAuthority(deviceID:old,trustID:UUID().uuidString,aliases:["emulator-5580"])
        let prior = try Data(contentsOf:CompanionExportPolicy.url(paths:paths))
        let record = try CompanionCredentialRecord(deviceID:device,trustID:trust,credential:String(repeating:"A",count:43),serverPin:String(repeating:"a",count:64))
        try CompanionPendingCredentialStore.stage(.init(record:record,expires:Date().addingTimeInterval(600)),id:id)
        XCTAssertThrowsError(try catalog.bindCompanionExportAuthority(deviceID:device,trustID:trust,aliases:["emulator-5580"],allowingForgottenAliasTransfer:true))
        XCTAssertEqual(try Data(contentsOf:CompanionExportPolicy.url(paths:paths)),prior)
        XCTAssertNil(try CompanionCredentialStore.load(deviceID:device))
        try CompanionPendingCredentialStore.remove(id:id)
        XCTAssertNil(try CompanionPendingCredentialStore.load(id:id))
    }
    func testPendingJournalRefusesAutomaticConnectAndExpiredRecoveryBeforePhoneIO() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pending-broker-fault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        defer { try? FileManager.default.removeItem(at:root) }
        let device = UUID().uuidString.lowercased(), trust = UUID().uuidString.lowercased(), id = UUID()
        let state:[String:Any] = ["macID":UUID().uuidString,"devices":[],"registry":["hosts":[],"sessions":[],"commands":[]],"inbox":[],"pendingAdmissions":[["id":id.uuidString,"deviceID":device,"trustID":trust,"serverPin":String(repeating:"a",count:64),"serial":"emulator-5580","expires":Date().addingTimeInterval(-1).timeIntervalSinceReferenceDate,"phase":"staged"]]]
        let url = root.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject:state).write(to:url); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        let paths = ManagedAppsPaths(privateRoot:root.appendingPathComponent("Managed.noindex"),activeRoot:root.appendingPathComponent("Apps"))
        let broker = CompanionBrokerEngine(directory:root,automaticReconnect:false,managedPaths:paths); await broker.start()
        let owner = try XCTUnwrap(CompanionBrokerOwner.live(getpid()))
        let automatic = await broker.exchange(.init(operation:"connect",payload:["serial":.string("emulator-5580")],nonce:"direct-test"),owner:owner)
        XCTAssertEqual(automatic.error?.code,"pairing_admission_pending")
        let recovery = await broker.exchange(.init(operation:"recover_pairing",payload:["device_id":.string(device)],nonce:"direct-test"),owner:owner)
        XCTAssertEqual(recovery.error?.code,"pairing_recovery_expired")
        let forgotten = await broker.exchange(.init(operation:"forget",payload:["device_id":.string(device)],nonce:"direct-test"),owner:owner)
        XCTAssertNil(forgotten.error); XCTAssertEqual(forgotten.data["status"]?.string,"forgotten")
        let status = await broker.exchange(.init(operation:"status",nonce:"direct-test"),owner:owner)
        XCTAssertEqual(status.data["pending_pairings"]?.array?.count,0)
        await broker.shutdown()
    }
}
