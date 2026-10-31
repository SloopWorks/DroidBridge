import XCTest
import Darwin
@testable import DroidBridgeCore
@testable import DroidBridgeStreaming

final class CanonicalAliasAdmissionTests: XCTestCase {
    let usb = "emulator-5580", wifi = "127.0.0.1:45987"
    func fixture() throws -> (URL, ManagedAppsPaths, ManagedAppCatalog, String, String) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("canonical-alias-\(UUID().uuidString)")
        let paths = ManagedAppsPaths(privateRoot: root.appendingPathComponent("Private.noindex"), activeRoot: root.appendingPathComponent("Apps"))
        let catalog = ManagedAppCatalog(paths: paths), id = UUID().uuidString.lowercased(), trust = UUID().uuidString.lowercased()
        try catalog.bindCompanionExportAuthority(deviceID: id, trustID: trust, aliases: [usb,wifi])
        return (root, paths, catalog, id, trust)
    }
    func testSameAliasConcurrentAndOtherAliasRefusedUntilLastLeaseDrains() async throws {
        let (root, paths, _, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var first = try await CanonicalAliasAdmission.acquire(serial: usb, paths: paths)
        var second = try await CanonicalAliasAdmission.acquire(serial: usb, paths: paths)
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        do { _ = try await CanonicalAliasAdmission.acquire(serial: wifi, paths: paths); XCTFail("Second transport admitted") } catch { XCTAssertEqual((error as? CompanionBoundaryError)?.code,"transport_in_use") }
        withExtendedLifetime(first) {}; first = nil
        do { _ = try await CanonicalAliasAdmission.acquire(serial: wifi, paths: paths); XCTFail("Remaining owner bypassed") } catch { XCTAssertEqual((error as? CompanionBoundaryError)?.code,"transport_in_use") }
        withExtendedLifetime(second) {}; second = nil
        let replacement = try await CanonicalAliasAdmission.acquire(serial: wifi, paths: paths)
        XCTAssertNotNil(replacement); withExtendedLifetime(replacement) {}
    }
    func testExplicitInstallationMoveCannotRekeyLiveCaptureAndPreservesStableLeaseIdentity() async throws {
        let (root, paths, catalog, id, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var lease = try await CanonicalAliasAdmission.acquire(serial: usb, paths: paths)
        try catalog.forgetCompanionExportAuthority(deviceID: id)
        let next = UUID().uuidString, trust = UUID().uuidString
        XCTAssertThrowsError(try catalog.bindCompanionExportAuthority(deviceID: next, trustID: trust, aliases: [usb,wifi], allowingForgottenAliasTransfer: true))
        XCTAssertEqual(try CanonicalAliasAdmission.identity(for: usb, paths: paths),id)
        withExtendedLifetime(lease) {}; lease = nil
        try catalog.bindCompanionExportAuthority(deviceID: next, trustID: trust, aliases: [usb,wifi], allowingForgottenAliasTransfer: true)
        XCTAssertEqual(try CanonicalAliasAdmission.identity(for: usb, paths: paths),id)
    }
    func testCanonicalAudioIntentSharesAliasesAndKeepsLegacyPhoneChoice() throws {
        let (root, paths, _, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("audio.json")
        _ = try DroidBridgePreferences.update(url: url) { $0.deviceAudioRoutes[usb] = .mac; $0.deviceAudioRoutes[wifi] = .phone }
        let legacy = try DeviceAudioPreferences.loadRoutes(url: url, paths: paths)
        XCTAssertEqual(legacy[usb],.phone); XCTAssertEqual(legacy[wifi],.phone)
        let shared = try DeviceAudioPreferences.setRoute(.macAndPhone,for: wifi,url: url,paths: paths)
        XCTAssertEqual(shared[usb],.macAndPhone); XCTAssertEqual(shared[wifi],.macAndPhone)
        XCTAssertEqual(DeviceAudioPreferences.capacityCount(shared,paths: paths),1)
        XCTAssertEqual(try DroidBridgePreferences.load(url: url).deviceAudioRoutes.count,1)
        XCTAssertEqual(try CanonicalAliasAdmission.audioKey(for: usb,paths: paths),try CanonicalAliasAdmission.audioKey(for: wifi,paths: paths))
    }
    func testAbsentPolicyPreservesStandaloneAndCorruptPolicyFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("absent-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ManagedAppsPaths(privateRoot: root.appendingPathComponent("Private.noindex"),activeRoot: root.appendingPathComponent("Apps"))
        let standalone = try await CanonicalAliasAdmission.acquire(serial: usb,paths: paths)
        XCTAssertNotNil(standalone)
        withExtendedLifetime(standalone) {}
        try FileManager.default.createDirectory(at: paths.privateRoot,withIntermediateDirectories: true,attributes:[.posixPermissions:0o700])
        let policy = CompanionExportPolicy.url(paths: paths)
        try Data("broken".utf8).write(to: policy); try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:policy.path)
        do { _ = try await CanonicalAliasAdmission.acquire(serial: usb,paths: paths); XCTFail("Corrupt policy bypassed") } catch {}
    }
    func testFirstPairingRefusesToRekeyStandaloneCaptureUntilDrained() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("first-pair-alias-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = ManagedAppsPaths(privateRoot: root.appendingPathComponent("Private.noindex"), activeRoot: root.appendingPathComponent("Apps"))
        var lease = try await CanonicalAliasAdmission.acquire(serial: usb, paths: paths)
        let catalog = ManagedAppCatalog(paths: paths), id = UUID().uuidString, trust = UUID().uuidString
        XCTAssertThrowsError(try catalog.bindCompanionExportAuthority(deviceID: id,trustID: trust,aliases: [usb,wifi]))
        XCTAssertNil(try CanonicalAliasAdmission.identity(for: usb,paths: paths))
        withExtendedLifetime(lease) {}; lease = nil
        try catalog.bindCompanionExportAuthority(deviceID: id,trustID: trust,aliases: [usb,wifi])
        XCTAssertEqual(try CanonicalAliasAdmission.identity(for: usb,paths: paths), id.lowercased())
    }
    func testSupervisorRetainsLeaseAndCrashGuardDrainsOwnedChild() async throws {
        let (root, paths, _, _, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var provisional = try await CanonicalAliasAdmission.acquire(serial: usb,paths: paths)
        let arguments = try XCTUnwrap(provisional).supervisorArguments
        let log = root.appendingPathComponent("supervisor.log"); FileManager.default.createFile(atPath:log.path,contents:nil)
        let file = try FileHandle(forWritingTo:log); defer { try? file.close() }
        let supervisor = Process(); supervisor.executableURL = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/debug/DroidBridgeSupervisor")
        supervisor.arguments = ["--parent",String(getpid())] + arguments + ["--","/bin/sleep","60"]
        supervisor.standardOutput = file; supervisor.standardError = file; supervisor.standardInput = FileHandle.nullDevice
        try supervisor.run()
        let supervisorIdentity = try XCTUnwrap(CompanionBrokerOwner.live(supervisor.processIdentifier))
        defer { if supervisorIdentity.isAlive { kill(supervisor.processIdentifier,SIGKILL) } }
        var child:Int32?
        for _ in 0..<100 {
            let text = (try? String(contentsOf:log)) ?? ""
            for line in text.split(separator:"\n") {
                if let event = try? JSONSerialization.jsonObject(with:Data(line.utf8)) as? [String:Any], event["event"] as? String == "supervisor_started" { child = event["child"] as? Int32 }
            }
            if child != nil { break }; try await Task.sleep(nanoseconds:10_000_000)
        }
        let childPID = try XCTUnwrap(child)
        let childIdentity = try XCTUnwrap(CompanionBrokerOwner.live(childPID))
        withExtendedLifetime(provisional) {}; provisional = nil
        do { _ = try await CanonicalAliasAdmission.acquire(serial:wifi,paths:paths); XCTFail("Live supervisor bypassed") } catch {}
        guard supervisorIdentity.isAlive else { throw NSError(domain: "OwnedAliasFixtureIdentity", code: Int(ESRCH)) }
        kill(supervisor.processIdentifier,SIGKILL)
        // The guard must keep the alias pinned until that exact process has died.
        var switched:CanonicalAliasLease?
        for _ in 0..<100 {
            if let lease = try? await CanonicalAliasAdmission.acquire(serial:wifi,paths:paths) { switched = lease; break }
            try await Task.sleep(nanoseconds:30_000_000)
        }
        XCTAssertNotNil(switched)
        XCTAssertFalse(childIdentity.isAlive)
        XCTAssertTrue((try String(contentsOf:log)).contains("supervisor_crash_guard_cleanup"))
        withExtendedLifetime(switched) {}
        // Foundation can miss the exit run-loop notification after the crash
        // guard and Process have already observed/reaped this child. Do not
        // turn a successful cleanup assertion into an unbounded suite hang.
        var exitStatus: Int32 = 0
        let reapDeadline = ProcessInfo.processInfo.systemUptime + 2
        while true {
            let result = waitpid(supervisor.processIdentifier, &exitStatus, WNOHANG)
            if result == supervisor.processIdentifier || (result == -1 && errno == ECHILD) { break }
            if result == -1 && errno != EINTR { throw NSError(domain: "OwnedAliasFixtureReap", code: Int(errno)) }
            guard ProcessInfo.processInfo.systemUptime < reapDeadline else { throw NSError(domain: "OwnedAliasFixtureReap", code: Int(ETIMEDOUT)) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

#if DEBUG
private actor AliasCancellationGate {
    private var pending:CheckedContinuation<Void,Never>?
    private(set) var entered=false
    func wait()async{entered=true;await withCheckedContinuation{pending=$0}}
    func release(){pending?.resume();pending=nil}
}
extension CanonicalAliasAdmissionTests {
    @MainActor func testStopDuringAliasAdmissionDoesNotRetainLateLeaseOrRunADB() async throws {
        let(root,paths,_,_,_)=try fixture();defer{try? FileManager.default.removeItem(at:root)}
        let gate=AliasCancellationGate()
        let session=BridgeSession(descriptor:.init(device:.init(serial:usb,model:"Owned test"),application:.init(packageName:"dev.droidbridge.testapp",name:"Fixture"),configuration:.init(backend:.native)),toolchain:Toolchain(adb:"/not-installed",scrcpy:"/not-installed",server:"/not-installed"))
        let serial=usb
        session.testingAliasAdmission={await gate.wait();return try await CanonicalAliasAdmission.acquire(serial:serial,paths:paths)}
        let start=Task{@MainActor in try await session.start()}
        for _ in 0..<100 {if await gate.entered{break};try await Task.sleep(nanoseconds:1_000_000)}
        let entered=await gate.entered
        XCTAssertTrue(entered)
        session.stop();await gate.release()
        do{try await start.value;XCTFail("Stopped startup resumed")}catch{XCTAssertTrue(error is CancellationError)}
        await session.stopAndWait()
        let replacement=try await CanonicalAliasAdmission.acquire(serial:wifi,paths:paths)
        XCTAssertNotNil(replacement);withExtendedLifetime(replacement){}
    }
}
#endif
