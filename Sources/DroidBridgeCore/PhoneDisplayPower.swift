import Foundation
import CryptoKit
import Darwin

public enum PhoneDisplayState: String, Sendable { case on = "ON", off = "OFF", doze = "DOZE", dozeSuspend = "DOZE_SUSPEND", onSuspend = "ON_SUSPEND", vr = "VR" }
public enum PhoneDisplayPowerResult: Sendable { case offVerified, onVerified, intentNoLongerRequested }

/// Operates on Android's physical display 0 only. This is independent of app
/// streams, and an unsupported or failed power command never stops a session.
public actor PhoneDisplayPower {
    private let preferencesURL: URL
    private let lockDirectory: URL
    private let run: ([String]) async throws -> String
    private let lockTimeout: TimeInterval
    public init(toolchain:Toolchain = Toolchain(),preferencesURL:URL = DroidBridgePreferences.defaultURL,lockDirectory:URL? = nil) {
        self.preferencesURL=preferencesURL
        self.lockDirectory=lockDirectory ?? preferencesURL.deletingLastPathComponent().appendingPathComponent("PhoneDisplayPower.noindex")
        self.lockTimeout=5
        self.run={args in
            let help=args.last=="help"
            let result=try await ProcessRunner.run(toolchain.adb,arguments:args,environment:toolchain.environment,timeout:2.5,allowNonZeroExit:help)
            guard result.status==0 || (help && result.status==255) else {throw BridgeError.message("Android help probe failed; check device authorization")}
            return result.output
        }
    }
    init(preferencesURL:URL,lockDirectory:URL,lockTimeout:TimeInterval = 5,run:@escaping ([String]) async throws ->String) {
        self.preferencesURL=preferencesURL;self.lockDirectory=lockDirectory;self.lockTimeout=lockTimeout;self.run=run
    }
    /// Returns only a positively identified INTERNAL display 0 state. Android
    /// may report ON for virtual displays and committedState independently.
    public static func physicalDisplayState(in output:String) ->PhoneDisplayState? {
        let lines=output.components(separatedBy:.newlines).filter {$0.range(of:#"^\s*Display id 0:\s"#,options:.regularExpression) != nil}
        guard lines.count==1,let line=lines.first,line.range(of:#"\btype INTERNAL\b"#,options:.regularExpression) != nil else {return nil}
        let regex=try! NSRegularExpression(pattern:#"(?:^|[\s,{])state\s+([A-Z_]+)(?=[\s,}])"#)
        let range=NSRange(line.startIndex..<line.endIndex,in:line)
        let matches=regex.matches(in:line,range:range)
        guard matches.count==1,let value=Range(matches[0].range(at:1),in:line) else {return nil}
        return PhoneDisplayState(rawValue:String(line[value]))
    }
    static func lockName(serial:String) ->String {
        SHA256.hash(data:Data(serial.utf8)).prefix(16).map{String(format:"%02x",$0)}.joined()+".lock"
    }
    private func acquire(serial:String) async throws ->Int32 {
        try FileManager.default.createDirectory(at:lockDirectory,withIntermediateDirectories:true)
        let fd=open(lockDirectory.appendingPathComponent(Self.lockName(serial:serial)).path,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd>=0 else {throw BridgeError.message("Cannot safely open phone display control lock")}
        var metadata=stat()
        guard fstat(fd,&metadata)==0,(metadata.st_mode&S_IFMT)==S_IFREG,metadata.st_uid==getuid() else {close(fd);throw BridgeError.message("Invalid phone display control lock")}
        let deadline=ProcessInfo.processInfo.systemUptime+max(0.05,min(5,lockTimeout))
        do {
            while true {
                try Task.checkCancellation()
                if flock(fd,LOCK_EX|LOCK_NB)==0 {return fd}
                guard errno==EWOULDBLOCK || errno==EINTR else {throw BridgeError.message("Cannot lock phone display controls")}
                guard ProcessInfo.processInfo.systemUptime<deadline else {throw BridgeError.message("Phone display controls are busy; the request will retry")}
                try await Task.sleep(for:.milliseconds(40))
            }
        } catch {close(fd);throw error}
    }
    private func requested(_ serial:String) throws ->Bool {
        try DroidBridgePreferences.load(url:preferencesURL).screenOffDeviceSerials.contains(serial)
    }
    private func command(_ device:AndroidDevice,_ arguments:[String]) async throws ->String {
        try await run(["-s",device.serial,"shell"]+arguments)
    }
    private func validate(_ device:AndroidDevice) throws {
        try AndroidDiscovery.validateSerial(device.serial)
        guard device.state=="device" else {throw BridgeError.message("Authorize and connect this Android device to control its phone screen")}
    }
    private func onCommand(_ device:AndroidDevice) async throws ->String {
        let output=try await command(device,["getprop","ro.build.version.sdk"])
        guard let api=Int(output.trimmingCharacters(in:.whitespacesAndNewlines)),api>=35 else {throw BridgeError.message("Phone screen controls require Android 15 (API 35) or later")}
        let help=try await command(device,["cmd","display","help"])
        guard help.hasPrefix("Display manager commands:") else {throw BridgeError.message("Android did not return recognized display manager help")}
        let advertisesOff=help.range(of:#"(?m)^\s*power-off\s+DISPLAY_ID"#,options:.regularExpression) != nil
        if advertisesOff {
            if help.range(of:#"(?m)^\s*power-reset\s+DISPLAY_ID"#,options:.regularExpression) != nil {return "power-reset"}
            if help.range(of:#"(?m)^\s*power-on\s+DISPLAY_ID"#,options:.regularExpression) != nil {return "power-on"}
        }
        // Stock Android 15 implements power-off/power-on but omits both from
        // its help text. This exact legacy API path is emulator-verified;
        // newer releases must advertise their command pair. Actuation still
        // requires a positively identified physical display and verified state.
        if api==35,help.range(of:#"(?m)^\s*get-displays(?:\s|$)"#,options:.regularExpression) != nil {return "power-on"}
        throw BridgeError.message("Android does not advertise supported physical display power controls")
    }
    private func state(_ device:AndroidDevice) async throws ->PhoneDisplayState {
        let output=try await command(device,["cmd","display","get-displays"])
        guard let state=Self.physicalDisplayState(in:output) else {throw BridgeError.message("Android did not report a verifiable physical display 0 state")}
        return state
    }
    private func verify(_ expected:PhoneDisplayState,device:AndroidDevice) async throws {
        for attempt in 0..<3 {
            if try await state(device)==expected {return}
            if attempt<2 {await Task.detached {try? await Task.sleep(for:.milliseconds(200))}.value}
        }
        throw BridgeError.message("Android did not confirm that the phone screen is \(expected.rawValue.lowercased()); app sessions are unchanged")
    }
    private func apply(off:Bool,onCommand:String,device:AndroidDevice) async throws ->Bool {
        _=try await command(device,["cmd","display",off ? "power-off" : onCommand,"0"])
        if !off && onCommand=="power-reset",try await state(device) != .on {
            guard try !requested(device.serial) else {return false}
            let help=try await command(device,["cmd","power","help"])
            guard help.contains("Power manager (power) commands:"),help.range(of:#"(?m)^\s*wakeup\b"#,options:.regularExpression) != nil else {throw BridgeError.message("Android restored normal display policy but is asleep. This device does not advertise a supported display wake command.")}
            guard try !requested(device.serial) else {return false}
            _=try await command(device,["cmd","power","wakeup","--display-id","0"])
        }
        try await verify(off ? .off : .on,device:device)
        return true
    }
    private func actuate(device:AndroidDevice,initialOff:Bool) async throws ->PhoneDisplayPowerResult {
        try validate(device)
        let fd=try await acquire(serial:device.serial);defer {flock(fd,LOCK_UN);close(fd)}
        guard try requested(device.serial)==initialOff else {return .intentNoLongerRequested}
        let on=try await onCommand(device)
        guard try requested(device.serial)==initialOff else {return .intentNoLongerRequested}
        var hasActuated=false
        for _ in 0..<3 {
            if !hasActuated {try Task.checkCancellation()}
            let desired=try requested(device.serial)
            do {
                let observed=try await state(device)
                // Explicit ON must clear a pending forced-OFF override even if
                // panel state has not caught up yet. Every compensating round
                // also writes its target rather than trusting an old sample.
                if observed != (desired ? .off : .on) || !initialOff || hasActuated {
                    if !hasActuated {try Task.checkCancellation()}
                    guard try requested(device.serial)==desired else {continue}
                    hasActuated=true
                    guard try await apply(off:desired,onCommand:on,device:device) else {continue}
                }
                guard try requested(device.serial)==desired else {continue}
                return desired ? .offVerified : .onVerified
            } catch {
                // The effect may already have happened. Changed intent must be
                // reconciled under this same mutex before returning to a caller.
                if let latest=try? requested(device.serial),latest != desired {continue}
                throw error
            }
        }
        throw BridgeError.message("Phone screen intent changed repeatedly; the latest setting will retry")
    }
    /// The caller persists OFF intent before queuing. Fresh preferences fence
    /// stale operations after mutex acquisition and every asynchronous boundary.
    public func setScreenOffIfRequested(device:AndroidDevice) async throws ->PhoneDisplayPowerResult {
        try await actuate(device:device,initialOff:true)
    }
    /// The caller clears OFF intent before queuing ON. A newer OFF intent wins;
    /// neither session close nor application quit implicitly requests ON.
    public func turnScreenOn(device:AndroidDevice) async throws ->PhoneDisplayPowerResult {
        try await actuate(device:device,initialOff:false)
    }
}
