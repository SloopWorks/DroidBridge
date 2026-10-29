import XCTest
import Foundation
import Darwin
@testable import DroidBridgeCore

/// Independent adversarial fixtures. Simulated command success never counts as
/// device evidence; real API35/API37 integration is a separate release gate.
final class PhoneDisplayPowerQATests:XCTestCase {
    var root:URL!,preferences:URL!,locks:URL!
    let first=AndroidDevice(serial:"qa-power-first",model:"First")
    let second=AndroidDevice(serial:"qa-power-second",model:"Second")
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("PhonePowerQA-"+UUID().uuidString)
        preferences=root.appendingPathComponent("preferences.json");locks=root.appendingPathComponent("locks")
    }
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:root)}

    actor Gate {
        private var entered=false
        private var continuation:CheckedContinuation<Void,Never>?
        func pause() async {entered=true;await withCheckedContinuation {continuation=$0}}
        func hasEntered()->Bool {entered}
        func release(){continuation?.resume();continuation=nil}
    }
    actor Android {
        struct Channel:Sendable {
            var api=35,reported="ON",target="ON"
            var ignoreEffects=false,deferOff=false,deferOn=false
            var displayHelp:String?,powerHelp:String?,reportedOutput:String?
        }
        var base:Channel
        var channels:[String:Channel]=[:],commands:[[String]]=[]
        var hooks:[String:() async throws->Void]=[:]
        init(api:Int=35,state:String="ON",ignoreEffects:Bool=false,deferOff:Bool=false,deferOn:Bool=false) {
            base=Channel(api:api,reported:state,target:state,ignoreEffects:ignoreEffects,deferOff:deferOff,deferOn:deferOn)
        }
        func configure(displayHelp:String?=nil,powerHelp:String?=nil,reportedOutput:String?=nil) {
            base.displayHelp=displayHelp;base.powerHelp=powerHelp;base.reportedOutput=reportedOutput
        }
        func hook(_ operation:String,_ closure:@escaping () async throws->Void) {hooks[operation]=closure}
        func snapshot(_ serial:String)->Channel {channels[serial] ?? base}
        func run(_ args:[String]) async throws->String {
            guard args.count>=4,args[0]=="-s",args[2]=="shell" else {throw BridgeError.message("Unexpected argv fixture")}
            commands.append(args)
            let serial=args[1],tail=Array(args.dropFirst(3)),operation=tail.joined(separator:" ")
            var channel=channels[serial] ?? base
            var output=""
            switch operation {
            case "getprop ro.build.version.sdk":output=String(channel.api)+"\n"
            case "cmd display help":
                output=channel.displayHelp ?? "Display manager commands:\n  power-off DISPLAY_ID\n  \(channel.api>=37 ? "power-reset" : "power-on") DISPLAY_ID\n"
            case "cmd power help":output=channel.powerHelp ?? "Power manager (power) commands:\n  wakeup [--display-id DISPLAY_ID]\n"
            case "cmd display get-displays":
                output=channel.reportedOutput ?? "Display id 8: DisplayInfo{state ON, committedState ON, type VIRTUAL}\nDisplay id 0: DisplayInfo{state \(channel.reported), committedState ON, type INTERNAL}\n"
            case "cmd display power-off 0":
                if !channel.ignoreEffects {channel.target="OFF";if !channel.deferOff {channel.reported="OFF"}}
            case "cmd display power-on 0":
                if !channel.ignoreEffects {channel.target="ON";if !channel.deferOn {channel.reported="ON"}}
            case "cmd display power-reset 0":
                // API37 can restore policy while the device remains asleep.
                if !channel.ignoreEffects {channel.target="NORMAL"}
            case "cmd power wakeup --display-id 0":
                if !channel.ignoreEffects {channel.target="ON";channel.reported="ON"}
            default:throw BridgeError.message("Unexpected command \(operation)")
            }
            channels[serial]=channel
            if let hook=hooks.removeValue(forKey:operation) {try await hook()}
            return output
        }
    }
    private func power(_ android:Android,timeout:Double=2)->PhoneDisplayPower {
        PhoneDisplayPower(preferencesURL:preferences,lockDirectory:locks,lockTimeout:timeout,run:{try await android.run($0)})
    }
    private func setIntent(_ off:Bool,serial:String?=nil) throws {
        let serial=serial ?? first.serial
        try DroidBridgePreferences.update(url:preferences) {if off {$0.screenOffDeviceSerials.insert(serial)} else {$0.screenOffDeviceSerials.remove(serial)}}
    }
    private func resultName(_ value:PhoneDisplayPowerResult)->String {
        switch value {case .offVerified:return "OFF";case .onVerified:return "ON";case .intentNoLongerRequested:return "STALE"}
    }
    private func wait(_ gate:Gate) async throws {
        for _ in 0..<200 {if await gate.hasEntered(){return};try await Task.sleep(for:.milliseconds(5))}
        throw BridgeError.message("Fixture did not reach its controlled async boundary")
    }
    /// A separate interpreter really holds flock; this is not a fake lock result.
    private func holdLock(_ serial:String) throws ->(Process,URL) {
        try FileManager.default.createDirectory(at:locks,withIntermediateDirectories:true)
        let marker=root.appendingPathComponent("ready-"+UUID().uuidString),release=root.appendingPathComponent("release-"+UUID().uuidString)
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/python3")
        process.arguments=["-c","import fcntl,pathlib,sys,time\nf=open(sys.argv[1],'a');fcntl.flock(f,fcntl.LOCK_EX)\npathlib.Path(sys.argv[2]).touch()\nwhile not pathlib.Path(sys.argv[3]).exists():time.sleep(.01)",locks.appendingPathComponent(PhoneDisplayPower.lockName(serial:serial)).path,marker.path,release.path]
        try process.run()
        for _ in 0..<200 {if FileManager.default.fileExists(atPath:marker.path){return(process,release)};Thread.sleep(forTimeInterval:0.01)}
        self.release((process,release));throw BridgeError.message("External lock holder did not start")
    }
    private func release(_ held:(Process,URL)) {
        // Foundation waitUntilExit can stall when called repeatedly from an
        // async XCTest executor after its child was already reaped. Wait for
        // the actual owned PID with finite budgets instead; deferred release
        // is idempotent and never signals a reused PID.
        guard !FileManager.default.fileExists(atPath:held.1.path) else {return}
        try? Data().write(to:held.1)
        let pid=held.0.processIdentifier
        let deadline=ProcessInfo.processInfo.systemUptime+1
        while kill(pid,0)==0 && ProcessInfo.processInfo.systemUptime<deadline {Thread.sleep(forTimeInterval:0.01)}
        guard kill(pid,0)==0 else {return}
        held.0.terminate()
        let grace=ProcessInfo.processInfo.systemUptime+0.5
        while kill(pid,0)==0 && ProcessInfo.processInfo.systemUptime<grace {Thread.sleep(forTimeInterval:0.01)}
        if kill(pid,0)==0 {kill(pid,SIGKILL);XCTFail("Owned lock fixture exceeded its finite shutdown budget")}
    }

    func testQAQueuedBothDirectionsRecheckIntentAfterRealCrossProcessLock() async throws {
        for off in [true,false] {
            try setIntent(off)
            let held=try holdLock(first.serial)
            defer {release(held)}
            let android=Android(state:off ? "ON" : "OFF"),service=power(android)
            let request=Task {try await (off ? service.setScreenOffIfRequested(device:first) : service.turnScreenOn(device:first))}
            try await Task.sleep(for:.milliseconds(80));try setIntent(!off);release(held)
            let result=try await request.value
            XCTAssertEqual(resultName(result),"STALE")
            let commands=await android.commands;XCTAssertTrue(commands.isEmpty)
        }
    }
    func testQAInFlightOffAndQueuedOnReconcileBeforeMutexRelease() async throws {
        try setIntent(true)
        let android=Android(),gate=Gate(),service=power(android),other=power(android)
        await android.hook("cmd display power-off 0",{await gate.pause()})
        let old=Task {try await service.setScreenOffIfRequested(device:first)}
        try await wait(gate);try setIntent(false)
        let fresh=Task {try await other.turnScreenOn(device:first)}
        await gate.release()
        let oldResult=try await old.value,freshResult=try await fresh.value
        XCTAssertEqual(resultName(oldResult),"ON");XCTAssertEqual(resultName(freshResult),"ON")
        let state=await android.snapshot(first.serial),calls=await android.commands
        XCTAssertEqual(state.target,"ON")
        XCTAssertEqual(calls.filter{$0.suffix(4)==["cmd","display","power-off","0"]}.count,1)
        XCTAssertGreaterThanOrEqual(calls.filter{$0.suffix(4)==["cmd","display","power-on","0"]}.count,1)
    }
    func testQAInFlightOnAndNewOffRespectLatestIntent() async throws {
        try setIntent(false)
        let android=Android(state:"OFF"),gate=Gate(),service=power(android)
        await android.hook("cmd display power-on 0",{await gate.pause()})
        let request=Task {try await service.turnScreenOn(device:first)}
        try await wait(gate);try setIntent(true);await gate.release()
        let result=try await request.value
        XCTAssertEqual(resultName(result),"OFF")
        let state=await android.snapshot(first.serial);XCTAssertEqual(state.target,"OFF")
    }
    func testQADeferredOffCannotClaimOnFromStaleOnSample() async throws {
        try setIntent(true)
        let android=Android(deferOff:true),url=preferences!,serial=first.serial
        await android.hook("cmd display power-off 0",{try DroidBridgePreferences.update(url:url){$0.screenOffDeviceSerials.remove(serial)}})
        let result=try await power(android).setScreenOffIfRequested(device:first)
        XCTAssertEqual(resultName(result),"ON")
        let state=await android.snapshot(first.serial),calls=await android.commands
        XCTAssertEqual(state.target,"ON","A stale reported ON must not leave a forced-OFF override queued")
        XCTAssertTrue(calls.contains{$0.suffix(4)==["cmd","display","power-on","0"]})
    }
    func testQADeferredOnCannotClaimOffFromStaleOffSample() async throws {
        try setIntent(false)
        let android=Android(state:"OFF",deferOn:true),url=preferences!,serial=first.serial
        await android.hook("cmd display power-on 0",{try DroidBridgePreferences.update(url:url){$0.screenOffDeviceSerials.insert(serial)}})
        let result=try await power(android).turnScreenOn(device:first)
        XCTAssertEqual(resultName(result),"OFF")
        let state=await android.snapshot(first.serial),calls=await android.commands
        XCTAssertEqual(state.target,"OFF")
        XCTAssertTrue(calls.contains{$0.suffix(4)==["cmd","display","power-off","0"]})
    }
    func testQAHeldFirstDeviceDoesNotBlockSecondDevice() async throws {
        try setIntent(true);try setIntent(true,serial:second.serial)
        let held=try holdLock(first.serial),android=Android(),service=power(android)
        defer {release(held)}
        let waiting=Task {try await service.setScreenOffIfRequested(device:first)}
        let started=ProcessInfo.processInfo.systemUptime
        let result=try await service.setScreenOffIfRequested(device:second)
        XCTAssertEqual(resultName(result),"OFF")
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-started,1)
        let beforeRelease=await android.commands;XCTAssertTrue(beforeRelease.allSatisfy{$0[1]==second.serial})
        release(held);_=try await waiting.value
        let firstState=await android.snapshot(first.serial),secondState=await android.snapshot(second.serial)
        XCTAssertEqual(firstState.target,"OFF");XCTAssertEqual(secondState.target,"OFF")
    }
    func testQAAPI35UsesLegacyOnAndAPI37ResetsThenWakesDisplayZero() async throws {
        for api in [35,37] {
            try setIntent(false)
            let android=Android(api:api,state:"OFF")
            let result=try await power(android).turnScreenOn(device:first)
        XCTAssertEqual(resultName(result),"ON")
            let calls=await android.commands
            XCTAssertTrue(calls.contains{$0.suffix(4)==["cmd","display",api==35 ? "power-on" : "power-reset","0"]})
            XCTAssertEqual(calls.contains{$0.suffix(5)==["cmd","power","wakeup","--display-id","0"]},api==37)
            XCTAssertFalse(calls.contains{$0.contains("input") || $0.contains("KEYCODE_POWER") || $0.contains("settings")})
        }
    }
    func testQAExitZeroWithoutStateChangeDoesNotVerifyEitherDirection() async throws {
        for off in [true,false] {
            try setIntent(off)
            let android=Android(state:off ? "ON" : "OFF",ignoreEffects:true),service=power(android)
            do {_=try await (off ? service.setScreenOffIfRequested(device:first) : service.turnScreenOn(device:first));XCTFail("Successful process exit alone is not screen state evidence")}
            catch {XCTAssertTrue(error.localizedDescription.contains("did not confirm"))}
        }
    }
    func testQAMissingStateAndUnsupportedHelpNeverActuate() async throws {
        for unsupported in [true,false] {
            try setIntent(true)
            let android=Android()
            if unsupported {await android.configure(displayHelp:"Unknown command; power-off DISPLAY_ID is unavailable")}
            else {await android.configure(reportedOutput:"Display id 4: DisplayInfo{state OFF, type VIRTUAL}")}
            do {_=try await power(android).setScreenOffIfRequested(device:first);XCTFail("No positive capability/state must refuse")} catch {}
            let calls=await android.commands
            XCTAssertFalse(calls.contains{$0.contains("power-off") || $0.contains("power-on") || $0.contains("power-reset")})
        }
    }
    func testQAAPI37AsleepWithoutAdvertisedWakeRemainsAnError() async throws {
        try setIntent(false)
        let android=Android(api:37,state:"OFF")
        await android.configure(powerHelp:"Power manager (power) commands:\n  unrelated-command\n")
        do {_=try await power(android).turnScreenOn(device:first);XCTFail("Reset while asleep cannot be reported as ON")}
        catch {XCTAssertTrue(error.localizedDescription.contains("wake"))}
        let calls=await android.commands;XCTAssertFalse(calls.contains{$0.contains("wakeup")})
    }
    func testQAKnownDozeActuatesAndRequiresVerifiedOff() async throws {
        try setIntent(true)
        let android=Android(state:"DOZE")
        let result=try await power(android).setScreenOffIfRequested(device:first)
        XCTAssertEqual(resultName(result),"OFF")
        let calls=await android.commands;XCTAssertTrue(calls.contains{$0.suffix(4)==["cmd","display","power-off","0"]})
    }
    func testQAAodOnExplicitlyRestoresPolicy() async throws {
        for state in ["DOZE","DOZE_SUSPEND","ON_SUSPEND","VR"] {
            try setIntent(false)
            let android=Android(state:state)
            let result=try await power(android).turnScreenOn(device:first)
            XCTAssertEqual(resultName(result),"ON")
            let calls=await android.commands
            XCTAssertTrue(calls.contains{$0.suffix(4)==["cmd","display","power-on","0"]})
        }
    }
    func testQAHeldMutexCancellationAndTimeoutNeverReachAndroid() async throws {
        try setIntent(true)
        let held=try holdLock(first.serial)
        defer {release(held)}
        let android=Android(),service=power(android,timeout:0.12)
        let began=ProcessInfo.processInfo.systemUptime
        do {_=try await service.setScreenOffIfRequested(device:first);XCTFail("A held cross-process mutex must refuse")}
        catch {XCTAssertTrue(error.localizedDescription.contains("busy"))}
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-began,0.6)
        let waiting=Task {try await power(android).setScreenOffIfRequested(device:first)}
        try await Task.sleep(for:.milliseconds(50));waiting.cancel()
        do {_=try await waiting.value;XCTFail("Cancelled admission must remain terminal")}
        catch {XCTAssertTrue(error is CancellationError)}
        let calls=await android.commands;XCTAssertTrue(calls.isEmpty)
    }

    func testQALegacyUnadvertisedCommandsAreLimitedToAPI35AndVerifiedState() async throws {
        for api in [35,36,37] {
            try setIntent(false)
            let android=Android(api:api,state:"OFF")
            await android.configure(displayHelp:"Display manager commands:\n  get-displays [CATEGORY]\n")
            do {
                let result=try await power(android).turnScreenOn(device:first)
                XCTAssertEqual(api,35,"Undocumented legacy commands cannot be inferred on newer Android")
                XCTAssertEqual(resultName(result),"ON")
            } catch {XCTAssertNotEqual(api,35,"Verified API35 legacy path must remain usable: \(error)")}
            let calls=await android.commands
            XCTAssertEqual(calls.contains{$0.contains("power-on")},api==35)
        }
    }

}
