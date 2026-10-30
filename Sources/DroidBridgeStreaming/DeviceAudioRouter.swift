import Foundation
import CryptoKit
import CoreAudio
import Darwin
import DroidBridgeCore

/// One device-wide player, independent of video backend. The supervisor owns the
/// advisory lock so a GUI crash cannot admit a successor before audio teardown.
@MainActor public final class DeviceAudioRouter {
    public var onStatusChange: ((String,DeviceAudioStatus)->Void)?
    private let toolchain: Toolchain
    private let directory: URL
    private let supervisor: String
    private let outputAvailable: () -> Bool
    private let startupTimeout: TimeInterval
    private var active:Set<String>=[], connected:Set<String>=[]
    private var routes:[String:DeviceAudioRoute]=[:], statuses:[String:DeviceAudioStatus]=[:]
    private var tasks:[String:Task<Void,Never>]=[:], revisions:[String:Int]=[:]
    private var closing=false

    public convenience init(toolchain:Toolchain) {
        self.init(toolchain:toolchain,directory:CompanionQAScope.current?.audioDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DroidBridge/AudioRoutes.noindex"),supervisor:Self.defaultSupervisor(),outputAvailable:Self.hasOutputDevice)
    }
    // Injectable paths/output check support isolated executable lifecycle tests.
    public init(toolchain:Toolchain,directory:URL,supervisor:String,outputAvailable:@escaping ()->Bool,startupTimeout:TimeInterval=20) {
        self.toolchain=toolchain; self.directory=directory; self.supervisor=supervisor
        self.outputAvailable=outputAvailable; self.startupTimeout=startupTimeout
    }
    public func status(for serial:String)->DeviceAudioStatus {
        statuses[serial] ?? DeviceAudioStatus(route:route(for:serial),phase:.phone,message:"Audio starts when an Android app is running. Routing applies to the whole device.")
    }
    public func reconcile(activeSerials:Set<String>,connectedSerials:Set<String>,routes:[String:DeviceAudioRoute]) {
        guard !closing else {return}
        let requests=Set(self.routes.keys).union(routes.keys).union(activeSerials)
        for serial in requests where Self.effectiveRoute(serial,self.routes) != Self.effectiveRoute(serial,routes) {revisions[serial,default:0] += 1}
        active=activeSerials; connected=connectedSerials; self.routes=routes
        for (serial,task) in tasks where !active.contains(serial) || !connected.contains(serial) {task.cancel()}
        for serial in requests {
            do {try updateControl(serial:serial,route:route(for:serial),retry:false)}
            catch {set(serial,route(for:serial),.failed,"Cannot update device audio request: \(error.localizedDescription)");continue}
            if (route(for:serial)) == .phone && tasks[serial]==nil {publishPhoneStatus(serial)}
            startIfNeeded(serial)
        }
    }
    public func retry(serial:String) {
        guard !closing else {return}
        revisions[serial,default:0] += 1
        do {
            try updateControl(serial:serial,route:route(for:serial),retry:true)
        } catch {set(serial,route(for:serial),.failed,"Cannot submit audio Retry: \(error.localizedDescription)");return}
        startIfNeeded(serial)
    }
    public func shutdown() async {
        closing=true; active=[]
        let pending=Array(tasks.values); pending.forEach {$0.cancel()}
        for task in pending {await task.value}
        tasks.removeAll()
    }
    private func startIfNeeded(_ serial:String) {
        guard tasks[serial]==nil,active.contains(serial),connected.contains(serial),!closing else {return}
        tasks[serial]=Task { [weak self] in
            guard let self else {return}
            await self.run(serial)
            self.tasks[serial]=nil
            if !self.closing && self.active.contains(serial) && self.connected.contains(serial) {self.startIfNeeded(serial)}
        }
    }
    private func set(_ serial:String,_ route:DeviceAudioRoute,_ phase:DeviceAudioPhase,_ message:String) {
        let value=DeviceAudioStatus(route:route,phase:phase,message:message)
        guard statuses[serial] != value else {return}
        statuses[serial]=value; onStatusChange?(serial,value)
    }
    nonisolated private static func effectiveRoute(_ serial:String,_ routes:[String:DeviceAudioRoute])->DeviceAudioRoute {
        routes[serial] ?? (DeviceAudioPreferences.capacityCount(routes) >= DroidBridgePreferences.maximumAudioDevices ? .phone : .mac)
    }
    private func route(for serial:String)->DeviceAudioRoute {Self.effectiveRoute(serial,routes)}
    private func run(_ serial:String) async {
        var blockedRevision:Int?
        var blockedRetry:String?
        while !Task.isCancelled && active.contains(serial) && connected.contains(serial) && !closing {
            let route=route(for:serial), revision=revisions[serial,default:0]
            if route == .phone {
                publishPhoneStatus(serial)
            } else if blockedRevision != revision || blockedRetry != retryToken(serial) {
                let outcome=await play(serial:serial,route:route,revision:revision)
                if outcome == .failed {blockedRevision=revision;blockedRetry=retryToken(serial)}
                // Lease contention is polled at a bounded cadence, not treated as
                // a crash/restart. Only the lock winner can spawn a client.
            }
            do {try await Task.sleep(nanoseconds:1_000_000_000)} catch {break}
        }
        if !closing {
            if (route(for:serial)) == .phone {publishPhoneStatus(serial)}
            else {set(serial,route(for:serial),.phone,"Audio stopped; no connected Android app session in this host.")}
        }
    }
    private func publishPhoneStatus(_ serial:String) {
        do {
            let owner=try ownerReceipt(serial)
            if owner.busy {set(serial,owner.receipt?.route ?? .mac,.shared,"Another DroidBridge host is releasing or updating device-wide audio. Phone routing is requested.")}
            else {
                let message=routes[serial]==nil && DeviceAudioPreferences.capacityCount(routes) >= DroidBridgePreferences.maximumAudioDevices
                    ? "Phone audio. Audio settings already contain 32 devices; this device cannot start Mac capture until a setting slot is available. Existing settings were preserved."
                    : "Phone audio. No DroidBridge audio owner was active at the last check."
                set(serial,.phone,.phone,message)
            }
        } catch {set(serial,.phone,.failed,"Cannot verify device audio ownership: \(error.localizedDescription)")}
    }
    private enum Outcome {case changed, shared, failed}
    private struct FailureReceipt:Codable {let tag:String}
    private func deviceKey(_ serial:String)->String {(try? CanonicalAliasAdmission.audioKey(for:serial)) ?? "unavailable-alias-policy"}
    private func retryURL(_ serial:String)->URL {directory.appendingPathComponent(deviceKey(serial)+".retry")}
    private struct Control:Codable {let route:DeviceAudioRoute,token:String}
    private func updateControl(serial:String,route:DeviceAudioRoute,retry:Bool) throws {
        _ = try CanonicalAliasAdmission.identity(for:serial)
        try AndroidDiscovery.validateSerial(serial)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let path=directory.appendingPathComponent(deviceKey(serial)+".control.lock")
        let fd=open(path.path,O_CREAT|O_RDWR|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard fd>=0 else {throw BridgeError.message("Cannot open audio request lock")}
        defer {close(fd)}
        var metadata=stat()
        guard fstat(fd,&metadata)==0,metadata.st_mode&S_IFMT==S_IFREG,metadata.st_uid==getuid(),metadata.st_mode&0o777==0o600,flock(fd,LOCK_EX|LOCK_NB)==0 else {throw BridgeError.message("Audio request is busy or has invalid ownership. Try again.")}
        let prior=(try? Self.readBounded(retryURL(serial),limit:256)).flatMap {try? JSONDecoder().decode(Control.self,from:$0)}
        if !retry,prior?.route==route {return}
        try JSONEncoder().encode(Control(route:route,token:UUID().uuidString)).write(to:retryURL(serial),options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:retryURL(serial).path)
    }
    private func retryToken(_ serial:String)->String {
        guard let data=try? Self.readBounded(retryURL(serial),limit:256),let control=try? JSONDecoder().decode(Control.self,from:data) else {return "initial"}
        return control.token
    }
    private struct Receipt:Codable {
        let token:String,ownerPID:Int32,supervisorPID:Int32,route:DeviceAudioRoute,phase:DeviceAudioPhase
    }
    private func play(serial:String,route:DeviceAudioRoute,revision:Int) async -> Outcome {
        var child:Process?, lease:ScrcpyPortLease?, output:FileHandle?
        var aliasLease:CanonicalAliasLease?
        let token=UUID().uuidString
        let scid=String(format:"%08x",UInt32.random(in:1...0x7fffffff))
        let key=deviceKey(serial)
        let retry=retryToken(serial)
        let failureTag=SHA256.hash(data:Data((route.rawValue+":"+retry).utf8)).map {String(format:"%02x",$0)}.joined()
        let failureURL=directory.appendingPathComponent(key+".failed.json")
        let lock=directory.appendingPathComponent(key+".lock")
        let receiptURL=directory.appendingPathComponent(token+".json")
        let log=directory.appendingPathComponent(token+".log")
        var ownReceipt=false
        var outcome:Outcome = .failed
        var failureMessage:String?
        do {
            if let bytes=try? Self.readBounded(failureURL,limit:4096),let previous=try? JSONDecoder().decode(FailureReceipt.self,from:bytes),previous.tag==failureTag {
                set(serial,route,.failed,"Another DroidBridge audio attempt failed for this route. Video continues. Retry or choose Phone.")
                return .failed
            }
            try AndroidDiscovery.validateSerial(serial)
            aliasLease = try await CanonicalAliasAdmission.acquire(serial:serial)
            try Task.checkCancellation()
            let owner=try ownerReceipt(serial)
            if owner.busy {
                set(serial,owner.receipt?.route ?? route,.shared,"Another DroidBridge host owns this device's audio. Routing is device-wide; changes apply when that owner refreshes.")
                return .shared
            }
            guard outputAvailable() else {throw BridgeError.message("No Mac audio output is available. Select an output in System Settings → Sound, then Retry, or choose Phone.")}
            guard FileManager.default.isExecutableFile(atPath:toolchain.audioClient),FileManager.default.isExecutableFile(atPath:supervisor) else {throw BridgeError.message("The DroidBridge audio client or supervisor is unavailable. Reinstall DroidBridge, or choose Phone.")}
            set(serial,route,.starting,"Connecting device-wide audio…")
            let sdk=try await ProcessRunner.run(toolchain.adb,arguments:["-s",serial,"shell","getprop","ro.build.version.sdk"],environment:toolchain.environment,timeout:5)
            guard let api=Int(sdk.output.trimmingCharacters(in:.whitespacesAndNewlines)),api>=33 else {throw BridgeError.message("Device audio routing requires Android 13 or newer. Choose Phone.")}
            try Task.checkCancellation()
            guard revisions[serial,default:0]==revision else {return .changed}
            let artifactsDirectory=directory
            try await Task.detached {try DeviceAudioArtifacts.prepare(artifactsDirectory)}.value
            try Task.checkCancellation()
            guard revisions[serial,default:0]==revision else {return .changed}
            lease=try ScrcpyPortLease.acquire()
            guard let lease else {throw BridgeError.message("No audio transport port available")}
            try Self.writeReceipt(Receipt(token:token,ownerPID:getpid(),supervisorPID:0,route:route,phase:.starting),receiptURL)
            FileManager.default.createFile(atPath:log.path,contents:nil,attributes:[.posixPermissions:0o600])
            output=try FileHandle(forWritingTo:log)
            let process=Process(); child=process
            process.executableURL=URL(fileURLWithPath:supervisor)
            process.arguments=["--parent",String(getpid())] + (aliasLease?.supervisorArguments ?? []) + ["--owner-lock",lock.path,"--owner-token",token,"--failure-file",failureURL.path,"--failure-tag",failureTag,"--terminal-output","1","--adb",toolchain.adb,"--serial",serial,"--forward","tcp:\(lease.port)","--forward-remote","localabstract:scrcpy_\(scid)","--remote","/data/local/tmp/droidbridge-audio-\(scid).jar","--",toolchain.audioClient]+Self.arguments(serial:serial,route:route,port:lease.port)
            var environment=ProcessInfo.processInfo.environment.merging(toolchain.environment) {$1}
            environment["DROIDBRIDGE_AUDIO_SCID"]=scid
            process.environment=environment
            process.standardInput=lease.inheritedInput; process.standardOutput=output; process.standardError=output
            try process.run()
            try Self.writeReceipt(Receipt(token:token,ownerPID:getpid(),supervisorPID:process.processIdentifier,route:route,phase:.starting),receiptURL)
            let deadline=ProcessInfo.processInfo.systemUptime+startupTimeout
            var ready=false
            while !Task.isCancelled && !closing && active.contains(serial) && connected.contains(serial) && revisions[serial,default:0]==revision {
                let text=try await Self.readLog(log)
                try Task.checkCancellation()
                guard !closing,active.contains(serial),connected.contains(serial),revisions[serial,default:0]==revision else {break}
                if text.contains("\"event\":\"supervisor_failure_latched\"") {throw BridgeError.message("A previous device audio attempt failed. Retry or choose Phone.")}
                if text.contains("\"event\":\"supervisor_owner_busy\"") {
                    let other=(try? ownerReceipt(serial))?.receipt
                    let suffix=other.map {" Current owner requested \($0.route == .macAndPhone ? "Mac + Phone" : "Mac") audio."} ?? ""
                    set(serial,other?.route ?? route,.shared,"Another DroidBridge host owns this device's audio."+suffix+" Route changes apply when that owner refreshes.")
                    outcome = .shared; break
                }
                if !ownReceipt && text.contains("\"event\":\"supervisor_owner_acquired\"") {
                    try Self.writeReceipt(Receipt(token:token,ownerPID:getpid(),supervisorPID:process.processIdentifier,route:route,phase:.starting),receiptURL)
                    ownReceipt=true
                }
                if !ready && ownReceipt && Self.hasInitializedOutput(text) {
                    ready=true
                    try Self.writeReceipt(Receipt(token:token,ownerPID:getpid(),supervisorPID:process.processIdentifier,route:route,phase:.ready),receiptURL)
                    set(serial,route,.ready,route == .mac ? "Mac audio output initialized. Applies to all device audio; audibility depends on Android audio and Mac volume." : "Mac + Phone output initialized. Android apps may refuse playback capture.")
                }
                guard process.isRunning else {throw BridgeError.message(Self.failureMessage(text,route:route))}
                if ready && !outputAvailable() {throw BridgeError.message("Mac audio output disappeared. Select a Sound output and Retry, or choose Phone.")}
                if !ready && ProcessInfo.processInfo.systemUptime>=deadline {throw BridgeError.message("Audio output did not initialize within \(Int(startupTimeout)) seconds. Check Android audio permission/device state and Mac Sound output, then Retry, or choose Phone.")}
                try await Task.sleep(nanoseconds:ready ? 500_000_000 : 100_000_000)
            }
            if outcome != .shared {outcome = .changed}
        } catch {
            if !Task.isCancelled && !closing && revisions[serial,default:0]==revision {
                failureMessage="Audio unavailable: \(error.localizedDescription) Video continues. Retry or choose Phone."
                if let child,child.isRunning {kill(child.processIdentifier,SIGUSR1)}
                outcome = .failed
            } else {outcome = .changed}
        }
        if let child {await Self.drain(child)}
        if let failureMessage {
            let diagnostics=(try? await Self.readLog(log)) ?? ""
            let artifactsDirectory=directory
            var reported=failureMessage
            do {try await Task.detached {try DeviceAudioArtifacts.saveFailure(artifactsDirectory,token:token,text:failureMessage+"\n"+diagnostics)}.value}
            catch {reported += " The diagnostic log could not be retained: \(error.localizedDescription)"}
            if !closing,!Task.isCancelled,revisions[serial,default:0]==revision {set(serial,route,.failed,reported)}
        }
        try? output?.close()
        // Keep the inherited port pinned until the supervisor finishes cleanup.
        withExtendedLifetime(lease) {}
        withExtendedLifetime(aliasLease) {}
        if (try? Self.readReceipt(receiptURL).token)==token {try? FileManager.default.removeItem(at:receiptURL)}
        try? FileManager.default.removeItem(at:log)
        return outcome
    }
    /// The PTY makes stdout timely but the pinned client may prefix a LOGI line
    /// with an OSC window title. Strip only complete terminal control sequences;
    /// initialization still requires an exact complete client INFO line.
    nonisolated static func hasInitializedOutput(_ text:String)->Bool {
        let input=Array(text.utf8)
        guard input.count<=262_144 else {return false}
        var output=[UInt8]();output.reserveCapacity(input.count)
        var index=0
        while index<input.count {
            guard input[index]==0x1b else {output.append(input[index]);index+=1;continue}
            guard index+1<input.count else {return false}
            if input[index+1]==0x5d { // OSC: BEL or ESC backslash terminator
                index+=2
                var complete=false
                while index<input.count {
                    if input[index]==0x07 {index+=1;complete=true;break}
                    if input[index]==0x1b,index+1<input.count,input[index+1]==0x5c {index+=2;complete=true;break}
                    index+=1
                }
                guard complete else {return false}
            } else if input[index+1]==0x5b { // CSI parameters, intermediates, final
                index+=2
                while index<input.count,(0x30...0x3f).contains(input[index]) {index+=1}
                while index<input.count,(0x20...0x2f).contains(input[index]) {index+=1}
                guard index<input.count,(0x40...0x7e).contains(input[index]) else {return false}
                index+=1
            } else {return false}
        }
        let normalized=String(decoding:output,as:UTF8.self)
        return normalized.components(separatedBy:"\n").dropLast().contains {
            $0.trimmingCharacters(in:.whitespacesAndNewlines)=="INFO: DROIDBRIDGE_AUDIO_OUTPUT_READY"
        }
    }
    nonisolated public static func arguments(serial:String,route:DeviceAudioRoute,port:UInt16)->[String] {
        guard route != .phone else {return []}
        var args=["--serial",serial,"--port",String(port),"--force-adb-forward","--no-video","--no-control","--no-window","--no-power-on","--require-audio","--audio-codec=raw"]
        args += route == .macAndPhone ? ["--audio-source=playback","--audio-dup"] : ["--audio-source=output"]
        return args
    }
    private static func readLog(_ url:URL) async throws ->String {
        try await Task.detached {
            let handle=try FileHandle(forReadingFrom:url);defer {try? handle.close()}
            let bytes=try handle.read(upToCount:262_145) ?? Data()
            guard bytes.count<=262_144 else {throw BridgeError.message("Audio diagnostics exceeded the bounded log size. Retry or choose Phone.")}
            return String(decoding:bytes,as:UTF8.self)
        }.value
    }
    private func ownerReceipt(_ serial:String) throws ->(busy:Bool,receipt:Receipt?) {
        _ = try CanonicalAliasAdmission.identity(for:serial)
        let path=directory.appendingPathComponent(deviceKey(serial)+".lock")
        let fd=open(path.path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
        if fd<0 {if errno==ENOENT {return (false,nil)};throw BridgeError.message("Cannot open audio owner lock")}
        defer {close(fd)}
        var metadata=stat()
        guard fstat(fd,&metadata)==0,metadata.st_mode&S_IFMT==S_IFREG,metadata.st_uid==getuid(),metadata.st_mode&0o777==0o600 else {throw BridgeError.message("Invalid audio owner lock")}
        if flock(fd,LOCK_EX|LOCK_NB)==0 {return (false,nil)}
        guard errno==EWOULDBLOCK else {throw BridgeError.message("Cannot inspect audio ownership")}
        var bytes=[UInt8](repeating:0,count:37)
        let count=pread(fd,&bytes,37,0)
        guard count==36,let token=String(bytes:bytes.prefix(36),encoding:.utf8),UUID(uuidString:token) != nil else {return (true,nil)}
        let receipt=try? Self.readReceipt(directory.appendingPathComponent(token+".json"))
        var verify=[UInt8](repeating:0,count:37)
        guard pread(fd,&verify,37,0)==36,bytes==verify else {return (true,nil)}
        return (true,receipt.flatMap {$0.token==token && kill($0.supervisorPID,0)==0 ? $0 : nil})
    }
    private static func readBounded(_ url:URL,limit:Int) throws ->Data {
        let fd=open(url.path,O_RDONLY|O_CLOEXEC|O_NOFOLLOW)
        guard fd>=0 else {throw BridgeError.message("Audio status is unavailable")}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        defer {try? handle.close()}
        var metadata=stat()
        guard fstat(fd,&metadata)==0,metadata.st_mode&S_IFMT==S_IFREG,metadata.st_uid==getuid(),metadata.st_size<=limit else {throw BridgeError.message("Invalid audio status file")}
        let bytes=try handle.read(upToCount:limit+1) ?? Data()
        guard bytes.count<=limit else {throw BridgeError.message("Audio status changed beyond the size limit")}
        return bytes
    }
    private static func readReceipt(_ url:URL) throws ->Receipt {
        let bytes=try readBounded(url,limit:4096)
        return try JSONDecoder().decode(Receipt.self,from:bytes)
    }
    private static func writeReceipt(_ receipt:Receipt,_ url:URL) throws {
        try JSONEncoder().encode(receipt).write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    private static func drain(_ process:Process) async {
        await Task.detached {
            if process.isRunning {process.terminate()}
            let deadline=ProcessInfo.processInfo.systemUptime+20
            while process.isRunning && ProcessInfo.processInfo.systemUptime<deadline {usleep(20_000)}
            if process.isRunning {kill(process.processIdentifier,SIGKILL)}
            process.waitUntilExit()
        }.value
    }
    private static func failureMessage(_ log:String,route:DeviceAudioRoute)->String {
        let diagnostics=log.split(whereSeparator:\.isNewline).filter {$0.contains("ERROR:") || $0.contains("WARN:")}.suffix(3).joined(separator:" ")
        return diagnostics.isEmpty ? "The audio player stopped before or during playback. Check Mac Sound output and Android capture support." : String(diagnostics.suffix(1000))
    }
    private static func defaultSupervisor()->String {
        let optionalCandidates:[String?]=[ProcessInfo.processInfo.environment["DROIDBRIDGE_SUPERVISOR"],Bundle.main.resourceURL?.appendingPathComponent("Runtime/bin/DroidBridgeSupervisor").path,URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("DroidBridgeSupervisor").path,FileManager.default.currentDirectoryPath+"/.build/debug/DroidBridgeSupervisor"]
        let candidates=optionalCandidates.compactMap {$0}
        return candidates.first {FileManager.default.isExecutableFile(atPath:$0)} ?? candidates.last!
    }
    private static func hasOutputDevice()->Bool {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var device=AudioDeviceID(0),size=UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&device)==noErr && device != kAudioObjectUnknown
    }
}
