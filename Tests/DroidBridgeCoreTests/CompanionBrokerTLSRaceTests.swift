import XCTest
@testable import DroidBridgeCore

#if DEBUG
private actor BrokerRaceGate {
    private var blocked:CheckedContinuation<Void,Never>?
    private(set) var entered=false
    func wait() async {entered=true;await withCheckedContinuation {blocked=$0}}
    func release() {blocked?.resume();blocked=nil}
}
private actor BrokerEndpointSwitch {
    var url:URL
    init(_ url:URL){self.url=url}
    func set(_ value:URL){url=value}
    func get()->URL{url}
}
private actor PairRaceGates {
    var count=0
    let first=BrokerRaceGate(),second=BrokerRaceGate()
    func enter() async throws {count+=1;if count==1{await first.wait()}else{await second.wait()};try Task.checkCancellation()}
}
private final class BrokerFaultSwitch:@unchecked Sendable {
    private let lock=NSLock();private var point:String?
    init(_ point:String?){self.point=point}
    func clear(){lock.lock();point=nil;lock.unlock()}
    func check(_ name:String)throws{lock.lock();let fail=point==name;lock.unlock();if fail{throw CompanionBoundaryError("injected_"+name,"Deterministic test fault")}}
}
final class CompanionBrokerTLSRaceTests:XCTestCase {
    private func root()throws->(URL,ManagedAppsPaths){let url=FileManager.default.temporaryDirectory.appendingPathComponent("broker-tls-race-\(UUID().uuidString)");try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);return(url,ManagedAppsPaths(privateRoot:url.appendingPathComponent("Managed.noindex"),activeRoot:url.appendingPathComponent("Apps")))}
    private func wait(_ gate:BrokerRaceGate) async throws {for _ in 0..<300{if await gate.entered{return};try await Task.sleep(nanoseconds:10_000_000)};XCTFail("Race checkpoint did not arrive");throw CancellationError()}
    private func hello(_ id:String,_ request:String)->Data{CompanionTLSFixture.response(try! JSONSerialization.data(withJSONObject:["protocol":1,"request_id":request,"data":["device_id":id,"device_name":"Owned TLS race","protocol_min":1,"protocol_max":1,"capabilities":[]]]))}
    func testForgetWhileRealPinnedTLSHelloIsSuspendedNeverSendsStoredBearer() async throws {
        let (directory,paths)=try root();defer{try? FileManager.default.removeItem(at:directory)}
        let id=UUID().uuidString.lowercased(),trust=UUID().uuidString.lowercased(),gate=BrokerRaceGate()
        let peer=try CompanionTLSFixture{request in self.hello(id,request)};defer{peer.close();try? CompanionCredentialStore.remove(deviceID:id)}
        try CompanionCredentialStore.save(.init(deviceID:id,trustID:trust,credential:String(repeating:"A",count:43),serverPin:peer.serverPin))
        try ManagedAppCatalog(paths:paths).bindCompanionExportAuthority(deviceID:id,trustID:trust,aliases:["emulator-5580"])
        let state:[String:Any]=["macID":UUID().uuidString,"devices":[["deviceID":id,"name":"Test","aliases":["emulator-5580"],"preferredSerial":"emulator-5580","trustID":trust,"sequence":0,"profile":"balanced","exportSelection":[:],"enabled":true]],"registry":["hosts":[],"sessions":[],"commands":[]],"inbox":[]]
        let url=directory.appendingPathComponent("state.json");try JSONSerialization.data(withJSONObject:state).write(to:url);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        let hooks=CompanionBrokerTestingHooks(endpoint:{_ in peer.url},checkpoint:{name,_ in if name=="hello_received"{await gate.wait()}})
        let broker=CompanionBrokerEngine(directory:directory,managedPaths:paths,testingHooks:hooks);await broker.start();let owner=CompanionBrokerOwner.live(getpid())!
        let connect=Task{await broker.exchange(.init(operation:"connect",payload:["serial":.string("emulator-5580")],nonce:"test"),owner:owner)}
        try await wait(gate)
        let forgotten=await broker.exchange(.init(operation:"forget",payload:["device_id":.string(id)],nonce:"test"),owner:owner)
        XCTAssertNil(forgotten.error);await gate.release()
        let failed=await connect.value;XCTAssertEqual(failed.error?.code,"trust_changed")
        XCTAssertFalse(peer.request.contains("Bearer"));XCTAssertFalse(peer.request.contains(String(repeating:"A",count:43)))
        XCTAssertNil(try CompanionCredentialStore.load(deviceID:id));await broker.shutdown()
    }
    func testEnrollmentReplacementBeforeSecretRechecksRealTLSPinAndUUID() async throws {
        let (directory,paths)=try root();defer{try? FileManager.default.removeItem(at:directory)}
        let id=UUID().uuidString.lowercased()
        let first=try CompanionTLSFixture{request in self.hello(id,request)},second=try CompanionTLSFixture{request in self.hello(id,request)}
        defer{first.close();second.close();try? CompanionCredentialStore.remove(deviceID:id)}
        let endpoint=BrokerEndpointSwitch(first.url),gates=PairRaceGates()
        let hooks=CompanionBrokerTestingHooks(endpoint:{_ in await endpoint.get()},checkpoint:{name,_ in if name=="before_pair_transport_bind"{try await gates.enter()}})
        let broker=CompanionBrokerEngine(directory:directory,managedPaths:paths,testingHooks:hooks);await broker.start();let owner=CompanionBrokerOwner.live(getpid())!
        func payload(_ pin:String,_ secret:String)->[String:CompanionJSON]{["serial":.string("emulator-5580"),"expected_device_id":.string(id),"server_pin":.string(pin),"secret":.string(secret),"pairing_expires":.number(Date().timeIntervalSince1970.rounded(.down)+120)]}
        let a=Task{await broker.exchange(.init(operation:"begin_pair",payload:payload(first.serverPin,String(repeating:"A",count:43)),nonce:"test"),owner:owner)}
        try await wait(gates.first);await endpoint.set(second.url)
        let b=Task{await broker.exchange(.init(operation:"begin_pair",payload:payload(second.serverPin,String(repeating:"B",count:43)),nonce:"test"),owner:owner)}
        try await wait(gates.second);await gates.first.release()
        let resultA = await a.value
        XCTAssertEqual(resultA.error?.code,"pairing_superseded")
        b.cancel();await gates.second.release();_ = await b.value
        XCTAssertFalse(first.request.contains(String(repeating:"A",count:43)));XCTAssertFalse(second.request.contains(String(repeating:"B",count:43)))
        XCTAssertTrue(first.request.hasPrefix("GET /v1/hello"));XCTAssertTrue(second.request.hasPrefix("GET /v1/hello"));await broker.shutdown()
    }
    func testBlockedTerminalReceiptShutdownCancelsWaveBeforeOwnerLeaseRelease() async throws {
        let (directory, paths) = try root(); defer { try? FileManager.default.removeItem(at: directory) }
        let commandID = UUID().uuidString.lowercased()
        let peer = try BrokerAdmissionTLSPeer(blockedPath: "/v1/commands/\(commandID)/receipt")
        defer { peer.releaseBlocked(); peer.close(); try? CompanionCredentialStore.remove(deviceID: peer.deviceID) }
        let owner = try XCTUnwrap(CompanionBrokerOwner.live(getpid()))
        try CompanionCredentialStore.save(.init(deviceID: peer.deviceID, trustID: peer.trustID, credential: String(repeating: "A", count: 43), serverPin: peer.serverPin))
        let now = CompanionClock.nowMS(), boot = CompanionClock.bootID
        let state: [String: Any] = ["macID": UUID().uuidString, "devices": [["deviceID": peer.deviceID, "name": "Receipt shutdown fixture", "aliases": ["emulator-5580"], "preferredSerial": "emulator-5580", "trustID": peer.trustID, "sequence": 0, "profile": "balanced", "exportSelection": [:], "enabled": true]], "registry": ["hosts": [["owner": ["pid": owner.pid, "start": owner.start], "generation": 1, "role": "launcher", "deviceID": peer.deviceID, "serial": "emulator-5580", "updated": Date().timeIntervalSinceReferenceDate]], "sessions": [], "commands": [["id": commandID, "deviceID": peer.deviceID, "kind": "open_app", "payload": [:], "owner": ["pid": owner.pid, "start": owner.start], "generation": 1, "expires": Date().timeIntervalSinceReferenceDate, "continuousDeadline": ["bootID": boot, "issuedMS": now - 121000, "expiresMS": now - 91000], "admitted": true, "admittedAtMS": now - 121000, "status": "accepted", "result": [:]]]], "inbox": []]
        let stateURL = directory.appendingPathComponent("state.json")
        try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
        let broker = CompanionBrokerEngine(directory: directory, managedPaths: paths, testingHooks: .init(endpoint: { _ in peer.url }))
        await broker.start()
        let connected = await broker.exchange(.init(operation: "connect", payload: ["serial": .string("emulator-5580")], nonce: "test"), owner: owner)
        XCTAssertNil(connected.error)
        for _ in 0..<300 { if peer.blockedRequestSeen { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(peer.blockedRequestSeen)
        let start = CompanionClock.nowMS(); await broker.shutdown()
        XCTAssertLessThan(CompanionClock.nowMS() - start, 1000, "Shutdown cancels the in-flight TLS wave rather than draining eight timeouts")
        let stoppedBytes = try Data(contentsOf: stateURL), pathsAtStop = peer.requestedPaths
        peer.releaseBlocked(); try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(try Data(contentsOf: stateURL), stoppedBytes, "A late TLS reply cannot publish after shutdown")
        XCTAssertEqual(peer.requestedPaths, pathsAtStop, "The stopped delivery task cannot send another receipt")
    }
    func testRealAdmissionPeerProtocol() async throws {
        let peer=try BrokerAdmissionTLSPeer();defer{peer.close()}
        let client=try CompanionClient(baseURL:peer.url,serverPin:peer.serverPin)
        let hello=try await client.hello();XCTAssertEqual(hello.deviceId,peer.deviceID)
        let pair=try await client.beginPair(secret:String(repeating:"Q",count:43),macID:UUID(),name:"Test")
        XCTAssertEqual(pair.status,"pending")
    }
    func testHeartbeatRequiresCapabilityAndRecoversMissingPeerSnapshot() async throws {
        for heartbeat in [false,true] {
            let(directory,paths)=try root();defer{try? FileManager.default.removeItem(at:directory)}
            let peer=try BrokerAdmissionTLSPeer(heartbeat:heartbeat);defer{peer.close();try? CompanionCredentialStore.remove(deviceID:peer.deviceID)}
            let broker=CompanionBrokerEngine(directory:directory,managedPaths:paths,testingHooks:.init(endpoint:{_ in peer.url}));await broker.start();let owner=CompanionBrokerOwner.live(getpid())!
            let begun=await broker.exchange(.init(operation:"begin_pair",payload:["serial":.string("emulator-5580"),"expected_device_id":.string(peer.deviceID),"server_pin":.string(peer.serverPin),"secret":.string(String(repeating:"Q",count:43)),"pairing_expires":.number(Date().timeIntervalSince1970.rounded(.down)+120)],nonce:"test"),owner:owner);XCTAssertNil(begun.error)
            let approved=await broker.exchange(.init(operation:"poll_pair",payload:["pairing_id":.string(peer.pairingID.uuidString.lowercased())],nonce:"test"),owner:owner);XCTAssertNil(approved.error)
            let metadata:[String:CompanionJSON]=["device_id":.string(peer.deviceID),"serial":.string("emulator-5580"),"role":.string("launcher"),"generation":.number(1),"sessions":.array([])]
            let first=await broker.exchange(.init(operation:"session_publish",payload:metadata,nonce:"test"),owner:owner);XCTAssertNil(first.error)
            peer.resetSnapshot()
            let second=await broker.exchange(.init(operation:"session_publish",payload:metadata,nonce:"test"),owner:owner);XCTAssertNil(second.error)
            let bodies=peer.stateBodies
            XCTAssertTrue(bodies.contains{$0["sessions"] != nil})
            if heartbeat {XCTAssertTrue(bodies.contains{$0["unchanged"] as? Bool==true});XCTAssertNotNil(bodies.last?["sessions"],"snapshot_required must trigger a full snapshot retry")}
            else {XCTAssertFalse(bodies.contains{$0["unchanged"] != nil},"Legacy peers must always receive full state")}
            _ = await broker.exchange(.init(operation:"forget",payload:["device_id":.string(peer.deviceID)],nonce:"test"),owner:owner);await broker.shutdown()
        }
    }
    func testBlockedRealTLSHelloDoesNotStallAnotherPhysicalPhone() async throws {
        try await assertHealthyPhoneBypassesBlockedTLS(path:"/v1/hello",storedCredential:false)
    }
    func testBlockedRealTLSAuthenticatedIdentityDoesNotStallAnotherPhone() async throws {
        try await assertHealthyPhoneBypassesBlockedTLS(path:"/v1/identity",storedCredential:true)
    }
    private func assertHealthyPhoneBypassesBlockedTLS(path:String,storedCredential:Bool) async throws {
        let(directory,paths)=try root();defer{try? FileManager.default.removeItem(at:directory)}
        let blocked=try BrokerAdmissionTLSPeer(blockedPath:path),healthy=try BrokerAdmissionTLSPeer()
        defer{blocked.releaseBlocked();blocked.close();healthy.close();try? CompanionCredentialStore.remove(deviceID:blocked.deviceID);try? CompanionCredentialStore.remove(deviceID:healthy.deviceID)}
        if storedCredential {
            try CompanionCredentialStore.save(.init(deviceID:blocked.deviceID,trustID:blocked.trustID,credential:String(repeating:"A",count:43),serverPin:blocked.serverPin))
            let state:[String:Any]=["macID":UUID().uuidString,"devices":[["deviceID":blocked.deviceID,"name":"Blocked TLS","aliases":["qa-blocked"],"preferredSerial":"qa-blocked","trustID":blocked.trustID,"sequence":0,"profile":"balanced","exportSelection":[:],"enabled":true]],"registry":["hosts":[],"sessions":[],"commands":[]],"inbox":[]]
            let file=directory.appendingPathComponent("state.json");try JSONSerialization.data(withJSONObject:state).write(to:file);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
        }
        let broker=CompanionBrokerEngine(directory:directory,managedPaths:paths,testingHooks:.init(endpoint:{$0=="qa-blocked" ? blocked.url : healthy.url}));await broker.start();let owner=CompanionBrokerOwner.live(getpid())!
        let first=Task {
            if storedCredential{return await broker.exchange(.init(operation:"connect",payload:["serial":.string("qa-blocked")],nonce:"test"),owner:owner)}
            return await broker.exchange(.init(operation:"begin_pair",payload:["serial":.string("qa-blocked"),"expected_device_id":.string(blocked.deviceID),"server_pin":.string(blocked.serverPin),"secret":.string(String(repeating:"Q",count:43)),"pairing_expires":.number(Date().timeIntervalSince1970.rounded(.down)+120)],nonce:"test"),owner:owner)
        }
        for _ in 0..<200 {if blocked.blockedRequestSeen{break};try await Task.sleep(nanoseconds:5_000_000)}
        XCTAssertTrue(blocked.blockedRequestSeen)
        let start=Date()
        let response=await broker.exchange(.init(operation:"begin_pair",payload:["serial":.string("qa-healthy"),"expected_device_id":.string(healthy.deviceID),"server_pin":.string(healthy.serverPin),"secret":.string(String(repeating:"R",count:43)),"pairing_expires":.number(Date().timeIntervalSince1970.rounded(.down)+120)],nonce:"test"),owner:owner)
        XCTAssertNil(response.error);XCTAssertEqual(response.data["status"]?.string,"pending")
        XCTAssertLessThan(Date().timeIntervalSince(start),1,"A blocked phone must not consume every other phone's control lane")
        first.cancel();blocked.releaseBlocked();_ = await first.value;await broker.shutdown()
    }
    func testActualTLSApprovedAdmissionFaultsRemainExplicitAndRecoverable() async throws {
        for fault in ["candidate_stage","policy_bind","candidate_finalize"] {
            let (directory,paths)=try root();defer{try? FileManager.default.removeItem(at:directory)}
            let peer=try BrokerAdmissionTLSPeer();defer{peer.close();try? CompanionCredentialStore.remove(deviceID:peer.deviceID);try? CompanionPendingCredentialStore.remove(id:peer.pairingID)}
            let failures=BrokerFaultSwitch(fault)
            let hooks=CompanionBrokerTestingHooks(endpoint:{_ in peer.url},fault:{try failures.check($0)})
            let broker=CompanionBrokerEngine(directory:directory,managedPaths:paths,testingHooks:hooks);await broker.start();let owner=CompanionBrokerOwner.live(getpid())!
            let begun=await broker.exchange(.init(operation:"begin_pair",payload:["serial":.string("emulator-5580"),"expected_device_id":.string(peer.deviceID),"server_pin":.string(peer.serverPin),"secret":.string(String(repeating:"Q",count:43)),"pairing_expires":.number(Date().timeIntervalSince1970.rounded(.down)+120)],nonce:"test"),owner:owner)
            XCTAssertNil(begun.error)
            let approved=await broker.exchange(.init(operation:"poll_pair",payload:["pairing_id":.string(peer.pairingID.uuidString.lowercased())],nonce:"test"),owner:owner)
            XCTAssertEqual(approved.error?.code,"injected_"+fault)
            XCTAssertNil(try CompanionCredentialStore.load(deviceID:peer.deviceID))
            let blocked=await broker.exchange(.init(operation:"connect",payload:["serial":.string("emulator-5580")],nonce:"test"),owner:owner)
            // A still-open unapproved transport can return public metadata; it
            // cannot authenticate/promote the pending account automatically.
            XCTAssertNotEqual(blocked.data["paired"]?.bool,true)
            failures.clear()
            if fault != "candidate_stage" {
                let recovered=await broker.exchange(.init(operation:"recover_pairing",payload:["device_id":.string(peer.deviceID)],nonce:"test"),owner:owner)
                XCTAssertNil(recovered.error);XCTAssertEqual(recovered.data["status"]?.string,"approved")
                XCTAssertNotNil(try CompanionCredentialStore.load(deviceID:peer.deviceID))
            }
            _ = await broker.exchange(.init(operation:"forget",payload:["device_id":.string(peer.deviceID)],nonce:"test"),owner:owner)
            await broker.shutdown()
        }
    }
}
#endif
