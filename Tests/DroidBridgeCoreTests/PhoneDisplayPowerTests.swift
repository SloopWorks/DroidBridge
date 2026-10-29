import XCTest
import Darwin
@testable import DroidBridgeCore

final class PhoneDisplayPowerTests:XCTestCase {
    var root:URL!,preferences:URL!,locks:URL!
    let device=AndroidDevice(serial:"qa-phone",model:"Test")
    override func setUpWithError() throws {
        root=FileManager.default.temporaryDirectory.appendingPathComponent("PhonePower-"+UUID().uuidString)
        preferences=root.appendingPathComponent("preferences.json");locks=root.appendingPathComponent("locks")
    }
    override func tearDownWithError() throws {try? FileManager.default.removeItem(at:root)}
    actor Fixture {
        var state="ON",commands:[[String]]=[]
        var apply=true
        var displayHelp:String?
        var afterOff:(() throws ->Void)?
        func run(_ args:[String]) throws ->String {
            commands.append(args)
            if args.contains("getprop") {return "35\n"}
            if args.contains("help"),let displayHelp {return displayHelp}
            if args.contains("help") {return "Display manager commands:\n  power-off DISPLAY_ID\n  power-on DISPLAY_ID\n"}
            if args.contains("power-off") {if apply {state="OFF"};try afterOff?();return ""}
            if args.contains("power-on") {state="ON";return ""}
            return "Display id 4: DisplayInfo{state ON, committedState ON, type VIRTUAL}\nDisplay id 0: DisplayInfo{state \(state), committedState ON, type INTERNAL}\n"
        }
        func configure(apply:Bool=true,state:String?=nil,displayHelp:String?=nil,afterOff:(() throws ->Void)?=nil) {self.apply=apply;self.afterOff=afterOff;self.displayHelp=displayHelp;if let state {self.state=state}}
    }
    func service(_ fixture:Fixture,timeout:Double=5) ->PhoneDisplayPower {
        PhoneDisplayPower(preferencesURL:preferences,lockDirectory:locks,lockTimeout:timeout,run:{try await fixture.run($0)})
    }
    func requestOff() throws {try DroidBridgePreferences.update(url:preferences){$0.screenOffDeviceSerials.insert(device.serial)}}
    func testParserUsesPhysicalZeroNotCommittedOrVirtualState() {
        XCTAssertEqual(PhoneDisplayPower.physicalDisplayState(in:"Display id 5: DisplayInfo{state ON, type VIRTUAL}\nDisplay id 0: DisplayInfo{state OFF, committedState ON, type INTERNAL}"),.off)
        XCTAssertEqual(PhoneDisplayPower.physicalDisplayState(in:"Display id 0: DisplayInfo{state DOZE, committedState DOZE, type INTERNAL}"),.doze)
        for text in ["Display id 5: DisplayInfo{state OFF, type VIRTUAL}","Display id 0: DisplayInfo{committedState OFF, type INTERNAL}","Display id 0: DisplayInfo{state UNKNOWN, type INTERNAL}","Display id 0: DisplayInfo{state OFF, type VIRTUAL}","Display id 0: DisplayInfo{state ON, type INTERNAL}\nDisplay id 0: DisplayInfo{state OFF, type INTERNAL}"] {XCTAssertNil(PhoneDisplayPower.physicalDisplayState(in:text))}
    }
    func testNoOptInDoesNotExecuteADBAndExitZeroIsNotProof() async throws {
        let fixture=Fixture(),power=service(fixture)
        _=try await power.setScreenOffIfRequested(device:device)
        let count=await fixture.commands.count;XCTAssertEqual(count,0)
        try requestOff();await fixture.configure(apply:false)
        do {_=try await power.setScreenOffIfRequested(device:device);XCTFail("Exit0 must not prove OFF")}
        catch {XCTAssertTrue(error.localizedDescription.contains("did not confirm"))}
    }
    func testClearedIntentDuringOffCompensatesOnBeforeUnlock() async throws {
        try requestOff();let fixture=Fixture();let url=preferences!,serial=device.serial
        await fixture.configure(afterOff:{try DroidBridgePreferences.update(url:url){$0.screenOffDeviceSerials.remove(serial)}})
        _=try await service(fixture).setScreenOffIfRequested(device:device)
        let state=await fixture.state;XCTAssertEqual(state,"ON")
        let commands=await fixture.commands
        XCTAssertEqual(commands.filter{$0.contains("power-off")}.count,1)
        XCTAssertEqual(commands.filter{$0.contains("power-on")}.count,1)
    }
    func testHeldMutexFreshIntentRecheckAndCancellation() async throws {
        try requestOff();try FileManager.default.createDirectory(at:locks,withIntermediateDirectories:true)
        let path=locks.appendingPathComponent(PhoneDisplayPower.lockName(serial:device.serial)).path
        let fd=open(path,O_CREAT|O_RDWR,0o600);defer{flock(fd,LOCK_UN);close(fd)}
        XCTAssertEqual(flock(fd,LOCK_EX|LOCK_NB),0)
        let fixture=Fixture(),power=service(fixture)
        let request=Task {try await power.setScreenOffIfRequested(device:device)}
        try await Task.sleep(for:.milliseconds(80))
        try DroidBridgePreferences.update(url:preferences){$0.screenOffDeviceSerials.remove(device.serial)}
        flock(fd,LOCK_UN);_=try await request.value
        let firstCount=await fixture.commands.count;XCTAssertEqual(firstCount,0)
        XCTAssertEqual(flock(fd,LOCK_EX|LOCK_NB),0)
        let cancelled=Task {try await power.turnScreenOn(device:device)}
        try await Task.sleep(for:.milliseconds(50));cancelled.cancel()
        do {_=try await cancelled.value;XCTFail("Cancelled lock wait must terminate")}
        catch is CancellationError {} catch {XCTFail("Unexpected \(error)")}
        let secondCount=await fixture.commands.count;XCTAssertEqual(secondCount,0)
    }
    func testSymlinkLockRefusedWithoutTouchingTarget() async throws {
        try requestOff();try FileManager.default.createDirectory(at:locks,withIntermediateDirectories:true)
        let target=root.appendingPathComponent("untouched");try Data("original".utf8).write(to:target)
        try FileManager.default.createSymbolicLink(at:locks.appendingPathComponent(PhoneDisplayPower.lockName(serial:device.serial)),withDestinationURL:target)
        let fixture=Fixture()
        do {_=try await service(fixture).setScreenOffIfRequested(device:device);XCTFail("Symlink lock must fail")}
        catch {}
        XCTAssertEqual(try String(contentsOf:target),"original")
        let count=await fixture.commands.count;XCTAssertEqual(count,0)
    }
    func testReadOnlyHelpCanRetainExpectedNonzeroOutputWithoutWeakeningDefaultExecution() async throws {
        let script="printf 'Display manager commands:\\n'; printf '%06000d' 0; exit 255"
        do {_=try await ProcessRunner.run("/bin/sh",arguments:["-c",script]);XCTFail("Default execution must reject nonzero")}
        catch {}
        let result=try await ProcessRunner.run("/bin/sh",arguments:["-c",script],allowNonZeroExit:true)
        XCTAssertEqual(result.status,255);XCTAssertTrue(result.output.hasPrefix("Display manager commands:"));XCTAssertGreaterThan(result.output.count,6000)
    }

    func testAlwaysOnDisplayDozeCanBeExplicitlyTurnedOff() async throws {
        try requestOff();let fixture=Fixture();await fixture.configure(state:"DOZE")
        _=try await service(fixture).setScreenOffIfRequested(device:device)
        let state=await fixture.state;XCTAssertEqual(state,"OFF")
        let commands=await fixture.commands;XCTAssertTrue(commands.contains{$0.contains("power-off")})
    }

    func testCapturedStockAPI35HelpWithoutPowerCommandsSupportsVerifiedOffAndOn() async throws {
        let repository=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let help=try String(contentsOf:repository.appendingPathComponent("verification/screen-off/android/api35/display-command-help-direct.txt"))
        XCTAssertTrue(help.hasPrefix("Display manager commands:"))
        XCTAssertFalse(help.contains("power-off"));XCTAssertFalse(help.contains("power-on"))
        let fixture=Fixture();await fixture.configure(displayHelp:help)
        let power=service(fixture)
        try requestOff();_=try await power.setScreenOffIfRequested(device:device)
        let off=await fixture.state;XCTAssertEqual(off,"OFF")
        try DroidBridgePreferences.update(url:preferences){$0.screenOffDeviceSerials.remove(device.serial)}
        _=try await power.turnScreenOn(device:device)
        let on=await fixture.state;XCTAssertEqual(on,"ON")
        let commands=await fixture.commands
        XCTAssertTrue(commands.contains{$0.suffix(4)==["cmd","display","power-off","0"]})
        XCTAssertTrue(commands.contains{$0.suffix(4)==["cmd","display","power-on","0"]})
    }

}
