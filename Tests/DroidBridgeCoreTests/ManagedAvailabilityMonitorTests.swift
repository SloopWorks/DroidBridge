import XCTest
import Foundation
@testable import DroidBridgeCore

final class ManagedAvailabilityMonitorTests: XCTestCase {
    var root:URL!, catalog:ManagedAppCatalog!, preferences:URL!
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("Availability-"+UUID().uuidString)
        catalog=ManagedAppCatalog(paths:ManagedAppsPaths(privateRoot:root.appendingPathComponent("Private.noindex"),activeRoot:root.appendingPathComponent("Apps")))
        preferences=root.appendingPathComponent("preferences.json")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at:root) }
    func add(_ serial:String) throws {
        let r=try catalog.reserve(device:AndroidDevice(serial:serial,model:"Test"),application:AndroidApplication(packageName:"dev.example.test",name:"Test"),backend:.native)
        let url=r.stagedBundleURL
        try FileManager.default.createDirectory(at:url.appendingPathComponent("Contents/MacOS"),withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:url.appendingPathComponent("Contents/Resources"),withIntermediateDirectories:true)
        try Data([0]).write(to:url.appendingPathComponent("Contents/MacOS/DroidBridge"))
        try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:url.appendingPathComponent("Contents/MacOS/DroidBridge").path)
        let info:[String:Any]=["CFBundleIdentifier":r.bundleIdentifier,"CFBundleShortVersionString":"0.1.2","CFBundleVersion":"3","DroidBridgeManagedGeneration":r.id.uuidString,"DroidBridgeManagedDevice":r.deviceHash]
        try PropertyListSerialization.data(fromPropertyList:info,format:.xml,options:0).write(to:url.appendingPathComponent("Contents/Info.plist"))
        let launch=["managed_key":r.key,"managed_generation":r.id.uuidString,"serial":r.device.serial,"package":r.application.packageName,"name":r.application.name,"backend":r.backend.rawValue]
        try JSONEncoder().encode(launch).write(to:url.appendingPathComponent("Contents/Resources/launch.json"))
        _=try catalog.commit(r)
    }
    final class State { var connected:[AndroidDevice]=[]; var probes:[String]=[]; var queries=0; var time=Date(); var slow=false }
    func monitor(_ state:State, readiness:((AndroidDevice) async ->Bool)?=nil) ->ManagedAvailabilityMonitor {
        ManagedAvailabilityMonitor(catalog:catalog,preferencesURL:preferences,devices:{state.queries += 1; return state.connected},readiness:readiness ?? {device in state.probes.append(device.serial); if state.slow {state.time.addTimeInterval(13)}; return true},registration:{_ in},now:{state.time})
    }
    func testMoreThanEightDevicesDoNotAlternateOfflineAndAbsentInvalidatesImmediately() async throws {
        let s=State()
        for i in 0..<16 {let serial=String(format:"device-%02d",i);try add(serial);s.connected.append(AndroidDevice(serial:serial,model:"Test"))}
        let m=monitor(s)
        let first=await m.cycle();XCTAssertEqual(first.available,8)
        let second=await m.cycle();XCTAssertEqual(second.available,16)
        let third=await m.cycle();XCTAssertEqual(third.available,16)
        s.connected.removeFirst()
        let absent=await m.cycle();XCTAssertEqual(absent.available,15)
        XCTAssertEqual(try catalog.records().filter{$0.availability == .active}.count,15)
    }
    func testSlowReadinessAdvancesOnlyVisitedCursorAndTTLExpires() async throws {
        let s=State();s.slow=true
        for i in 0..<10 {let serial=String(format:"device-%02d",i);try add(serial);s.connected.append(AndroidDevice(serial:serial,model:"Test"))}
        let m=monitor(s)
        for _ in 0..<10 {_=await m.cycle()}
        XCTAssertEqual(Set(s.probes).count,10,"Deadline must not skip the unvisited tail of each batch")
        s.time.addTimeInterval(121)
        let expired=await m.cycle();XCTAssertEqual(expired.available,1,"Unprobed old positives expire")
    }
    func testFeatureOffNeverCallsADBAndHidesAcceptedHistory() async throws {
        try add("device-one")
        let s=State();s.connected=[AndroidDevice(serial:"device-one",model:"Test")]
        let m=monitor(s);_=await m.cycle()
        try DroidBridgePreferences.update(url:preferences){$0.bulkWrapperOnboardingEnabled=false}
        let result=await m.cycle()
        XCTAssertFalse(result.enabled);XCTAssertEqual(s.queries,1);XCTAssertEqual(result.probed,0)
        XCTAssertEqual(try catalog.records().count,1);XCTAssertEqual(try catalog.records().first?.availability,.inactive)
    }
    func testFlagChangedDuringProbePreventsPublicationAndCancellationDoesNotPublish() async throws {
        try add("device-one")
        let s=State();s.connected=[AndroidDevice(serial:"device-one",model:"Test")]
        let m=monitor(s,readiness:{_ in _ = try? DroidBridgePreferences.update(url:self.preferences){$0.bulkWrapperOnboardingEnabled=false}; return true})
        let result=await m.cycle();XCTAssertFalse(result.enabled);XCTAssertEqual(result.available,0)
        XCTAssertEqual(try catalog.records().first?.availability,.inactive)
        let task=Task { await m.cycle() };task.cancel();let cancelled=await task.value
        XCTAssertEqual(cancelled.messages,["Cycle cancelled"])
    }
    func testDeviceQueryFailureHidesPreviouslyAcceptedApps() async throws {
        try add("device-one")
        let s=State();s.connected=[AndroidDevice(serial:"device-one",model:"Test")]
        let healthy=monitor(s);_=await healthy.cycle()
        let broken=ManagedAvailabilityMonitor(catalog:catalog,preferencesURL:preferences,devices:{throw BridgeError.message("failure")},readiness:{_ in XCTFail("No readiness after failed transport observation");return true},registration:{_ in})
        let result=await broken.cycle();XCTAssertEqual(result.available,0);XCTAssertFalse(result.messages.isEmpty)
        XCTAssertEqual(try catalog.records().first?.availability,.inactive)
    }
    func testFlagChangedDuringRegistrationStopsRemainingAdmission() async throws {
        try add("device-one");try add("device-two")
        let devices=[AndroidDevice(serial:"device-one",model:"Test"),AndroidDevice(serial:"device-two",model:"Test")]
        var registers=0
        let monitor=ManagedAvailabilityMonitor(catalog:catalog,preferencesURL:preferences,devices:{devices},readiness:{_ in true},registration:{action in
            if action.register {registers += 1;try DroidBridgePreferences.update(url:self.preferences){$0.bulkWrapperOnboardingEnabled=false}}
        })
        let result=await monitor.cycle()
        XCTAssertFalse(result.enabled);XCTAssertEqual(registers,1)
        XCTAssertEqual(try catalog.records().filter{$0.availability == .active}.count,0)
    }

    func testPoisonedPrecheckDoesNotLoseEarlierReceiptsOrStarveLaterHealthyActions() async throws {
        for name in ["first-device","second-device","third-device"] {try add(name)}
        let connected=["first-device","second-device","third-device"].map{AndroidDevice(serial:$0,model:"Test")}
        let online=ManagedAvailabilityMonitor(catalog:catalog,preferencesURL:preferences,devices:{connected},readiness:{_ in true},registration:{_ in})
        _=await online.cycle()
        let actions=try catalog.reconcile(availableSerials:[],enabled:true)
        XCTAssertEqual(actions.count,3)
        let poison=actions[1]
        try FileManager.default.removeItem(at:poison.bundleURL)
        try FileManager.default.createDirectory(at:poison.bundleURL,withIntermediateDirectories:true)
        try Data("foreign directory must survive".utf8).write(to:poison.bundleURL.appendingPathComponent("foreign"))
        var effects:[UUID]=[]
        let offline=ManagedAvailabilityMonitor(catalog:catalog,preferencesURL:preferences,devices:{[]},readiness:{_ in false},registration:{effects.append($0.id)})
        let result=await offline.cycle()
        XCTAssertTrue(effects.contains(actions[0].id),"Earlier real effect was dispatched")
        XCTAssertTrue(effects.contains(actions[2].id),"Later healthy effect must not starve behind poisoned ownership")
        XCTAssertFalse(effects.contains(poison.id),"Foreign ownership never reaches LaunchServices")
        let remaining=try catalog.reconcile(availableSerials:[],enabled:true)
        XCTAssertEqual(remaining.map(\.id),[poison.id],"Both real healthy effects must be durably acknowledged")
        XCTAssertTrue(FileManager.default.fileExists(atPath:poison.bundleURL.appendingPathComponent("foreign").path))
        XCTAssertFalse(result.messages.isEmpty)
    }

}
