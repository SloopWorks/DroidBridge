import Foundation
import CoreGraphics
import DroidBridgeCore

@MainActor
public final class BridgeSession {
    public let descriptor: SessionDescriptor
    public var onFrame: ((CGImage) -> Void)?
    public var onState: ((SessionState,String?) -> Void)?
    public var onMetrics: ((SessionMetrics) -> Void)?
    public private(set) var state: SessionState = .stopped
    public private(set) var metrics = SessionMetrics()
    public private(set) var logURL: URL
    private let toolchain: Toolchain
    private var process: Process?
    private var logHandle: FileHandle?
    private var transport: NativeTransport?
    private var frameMailbox: FrameMailbox?
    var forwardedEndpoint: String? { forward }
    private var forward: String?
    private var remotePath: String?
    private var receiptURL: URL?
    private var generation = UUID()
    private var cleanupTasks: [UUID:Task<Void,Never>] = [:]
    private var startupInFlight = 0
    private var startupWaiters: [CheckedContinuation<Void,Never>] = []
    private var admissionOpen = true
    private var startupTerminalMessage: String?
    public init(descriptor: SessionDescriptor, toolchain: Toolchain) {
        self.descriptor = descriptor; self.toolchain = toolchain
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DroidBridge",isDirectory:true)
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        logURL = directory.appendingPathComponent("session-\(descriptor.id.uuidString).log")
    }
    private func transition(_ value: SessionState, _ message: String? = nil) {
        state = value
        var event: [String:Any] = ["state":value.rawValue]
        if let message { event["message"] = message }
        appendEvent(event)
        onState?(value,message)
    }
    private func appendEvent(_ fields: [String:Any]) {
        var event: [String:Any] = ["timestamp":ISO8601DateFormatter().string(from:Date()),"session":descriptor.id.uuidString,"backend":descriptor.configuration.backend.rawValue,"device":descriptor.device.serial,"package":descriptor.application.packageName]
        fields.forEach { event[$0.key] = $0.value }
        let eventURL = logURL.appendingPathExtension("jsonl")
        if !FileManager.default.fileExists(atPath:eventURL.path) { FileManager.default.createFile(atPath:eventURL.path,contents:Data()) }
        if let data = try? JSONSerialization.data(withJSONObject:event,options:[.sortedKeys]), let handle = try? FileHandle(forWritingTo:eventURL) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf:data+Data([10])); try? handle.close()
        }
    }
    /// Small client lifecycle facts help distinguish a hidden Mac window from
    /// Android transport failure. Never accepts images, text input or app data.
    public func recordClientEvent(_ event: String, details: [String: String]) {
        guard event.range(of: "^[a-z_]{1,64}$", options: .regularExpression) != nil,
              details.count <= 16,
              details.allSatisfy({ $0.key.utf8.count <= 64 && $0.value.utf8.count <= 512 }) else { return }
        appendEvent(["event": event, "details": details])
    }
    public func start() async throws {
        guard admissionOpen else { throw CancellationError() }
        guard state == .stopped || state == .failed else { return }
        guard descriptor.application.packageName.range(of:"^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+$",options:.regularExpression) != nil, descriptor.application.packageName.utf8.count <= 255 else { throw BridgeError.message("Invalid Android package name") }
        guard descriptor.device.serial.range(of:"^[A-Za-z0-9._:-]+$",options:.regularExpression) != nil else { throw BridgeError.message("Invalid Android device serial") }
        let c = descriptor.configuration
        guard (160...4096).contains(c.width), (160...4096).contains(c.height), (72...640).contains(c.density) else { throw BridgeError.message("Display size must be 160–4096 pixels and density 72–640 dpi") }
        startupInFlight += 1
        defer {
            startupInFlight -= 1
            if startupInFlight == 0 { let waiters = startupWaiters; startupWaiters.removeAll(); waiters.forEach { $0.resume() } }
        }
        let token = UUID(); generation = token; transition(.starting)
        do {
            let version = try await ProcessRunner.run(toolchain.scrcpy, arguments:["--version"],environment:toolchain.environment)
            guard version.output.contains("scrcpy 5.0.1") else { throw BridgeError.message("DroidBridge requires the bundled scrcpy 5.0.1 client and server") }
            try check(token)
            let activity = try await adb(["shell","cmd","package","resolve-activity","--brief","-a","android.intent.action.MAIN","-c","android.intent.category.LAUNCHER",descriptor.application.packageName])
            guard !activity.output.contains("No activity found"), activity.output.contains("/") else { throw BridgeError.message("Android application has no launchable activity") }
            try check(token)
            if descriptor.configuration.backend == .scrcpy { try startExternal(token:token) }
            else { try await startNative(token:token) }
        } catch {
            if generation == token { stop(reason: "startup_failure"); transition(.failed,error.localizedDescription) }
            else if state == .failed, let startupTerminalMessage { throw BridgeError.message(startupTerminalMessage) }
            throw error
        }
    }
    private func check(_ token: UUID) throws { if generation != token { throw CancellationError() } }
    private func spawn(_ executable: String, arguments: [String], token: UUID) throws {
        FileManager.default.createFile(atPath:logURL.path,contents:Data())
        let file = try FileHandle(forWritingTo:logURL); logHandle = file
        let sibling = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("DroidBridgeSupervisor").path
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Runtime/bin/DroidBridgeSupervisor").path
        let explicit = ProcessInfo.processInfo.environment["DROIDBRIDGE_SUPERVISOR"]
        let paths = [explicit,bundled,sibling,FileManager.default.currentDirectoryPath + "/.build/debug/DroidBridgeSupervisor",FileManager.default.currentDirectoryPath + "/.build/release/DroidBridgeSupervisor"].compactMap { $0 }
        guard let supervisor = paths.first(where:{ FileManager.default.isExecutableFile(atPath:$0) }) else { throw BridgeError.message("DroidBridgeSupervisor is missing; rebuild or reinstall DroidBridge") }
        var supervised = ["--parent",String(getpid())]
        if descriptor.configuration.backend == .native {
            supervised += ["--adb",toolchain.adb,"--serial",descriptor.device.serial]
            if let forward { supervised += ["--forward",forward] }
            if let remotePath { supervised += ["--remote",remotePath] }
        }
        supervised += ["--",executable] + arguments
        let process = Process(); process.executableURL = URL(fileURLWithPath:supervisor); process.arguments = supervised
        var environment = ProcessInfo.processInfo.environment; toolchain.environment.forEach { environment[$0.key] = $0.value }
        environment["SCRCPY_SERVER_PATH"] = toolchain.server; environment["ADB"] = toolchain.adb
        process.environment = environment; process.standardOutput = file; process.standardError = file
        process.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                guard let self, self.generation == token, self.state == .running || self.state == .starting else { return }
                let code = terminated.terminationStatus
                let reason = terminated.terminationReason == .uncaughtSignal ? "signal \(code)" : "exit status \(code)"
                let beforeFrame = self.state == .starting && self.descriptor.configuration.backend == .native
                let message = beforeFrame
                    ? "Native session process ended before the first decoded video frame (\(reason)). See \(self.logURL.path)"
                    : "Session process exited (\(reason)). See \(self.logURL.path)"
                if beforeFrame { self.startupTerminalMessage = message }
                self.stop(reason: "session_process_exit")
                let clean = code == 0 && terminated.terminationReason == .exit && !beforeFrame
                self.transition(clean ? .stopped : .failed,clean ? nil : message)
            }
        }
        try process.run(); self.process = process
    }
    private func startExternal(token: UUID) throws {
        let config = descriptor.configuration
        let args = ["--serial",descriptor.device.serial,"--no-audio","--new-display=\(config.width)x\(config.height)/\(config.density)","--flex-display","--start-app=\(descriptor.application.packageName)","--window-title=DroidBridge · \(descriptor.application.name)","--max-fps=30","--video-codec=h264"]
        try spawn(toolchain.scrcpy,arguments:args,token:token); transition(.running)
    }
    private func adb(_ arguments: [String]) async throws -> ProcessResult {
        try await ProcessRunner.run(toolchain.adb,arguments:["-s",descriptor.device.serial]+arguments,environment:toolchain.environment)
    }
    private func startNative(token: UUID) async throws {
        let scid = String(format:"%08x",UInt32.random(in:1...0x7fffffff))
        let receipt = SessionReceipt(ownerPID:getpid(),serial:descriptor.device.serial,scid:scid)
        let localReceipt = try receipt.save(); receiptURL = localReceipt
        let remote = receipt.remote; remotePath = remote
        var localForward: String?
        do {
        _ = try await adb(["push",toolchain.server,remote]); try check(token)
        let result = try await adb(["forward","tcp:0","localabstract:scrcpy_\(scid)"])
        guard let port = UInt16(result.output.trimmingCharacters(in:.whitespacesAndNewlines)), port > 0 else { throw BridgeError.message("ADB did not allocate a video port") }
        localForward = "tcp:\(port)"; try check(token); forward = localForward
        let c = descriptor.configuration
        let arguments = ["-s",descriptor.device.serial,"shell","CLASSPATH=\(remote)","app_process","/","com.genymobile.scrcpy.Server","5.0.1","scid=\(scid)","tunnel_forward=true","audio=false","control=true","video_codec=h264","max_fps=30","video_bit_rate=6000000","new_display=\(c.width)x\(c.height)/\(c.density)","flex_display=true","vd_destroy_content=true","clipboard_autosync=false","cleanup=true"]
        try spawn(toolchain.adb,arguments:arguments,token:token)
        let transport = NativeTransport(); self.transport = transport
        let mailbox = FrameMailbox { [weak self] frame in
            guard let self, self.generation == token else { return }
            self.metrics.frames += frame.frames; self.metrics.bytes += frame.bytes
            self.metrics.width = frame.image.width; self.metrics.height = frame.image.height
            if self.state == .starting { self.transition(.running) }
            self.onFrame?(frame.image); self.onMetrics?(self.metrics)
        }
        frameMailbox = mailbox
        transport.onFrame = { [mailbox] image,bytes in mailbox.publish(image,bytes:bytes) }
        transport.onSize = { [weak self] width,height in Task { @MainActor in guard let self,self.generation == token else { return }; self.metrics.width = width; self.metrics.height = height } }
        transport.onDiagnostic = { [weak self] message in Task { @MainActor in
            guard let self, self.generation == token else { return }
            self.appendEvent(["event":"native_decoder_error","message":message])
        } }
        transport.onFailure = { [weak self] error in Task { @MainActor in
            guard let self,self.generation == token else { return }
            let diagnostic = self.transport?.startupDiagnostic ?? "video diagnostics unavailable"
            self.stop(reason: "transport_failure"); self.transition(.failed,"\(error.localizedDescription) (\(diagnostic))")
        } }
        try await transport.start(port:port,package:descriptor.application.packageName)
        try check(token)
        for _ in 0..<150 {
            try check(token)
            if state == .running { return }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        throw BridgeError.message("Android did not produce a decoded video frame within 15 seconds (\(transport.startupDiagnostic))")
        } catch {
            // Cleanup belongs to this start attempt, even if stop() fenced it
            // while ADB was still staging bytes or allocating a forward.
            cleanup(forward:localForward,remote:remote,receipt:localReceipt)
            throw error
        }
    }
    private func cleanup(forward: String?, remote: String?, receipt: URL? = nil) {
        let tools = toolchain; let serial = descriptor.device.serial
        let taskID = UUID()
        cleanupTasks[taskID] = Task.detached(priority:.utility) {
            var complete = true
            if let forward {
                do { _ = try await ProcessRunner.run(tools.adb,arguments:["-s",serial,"forward","--remove",forward],environment:tools.environment,timeout:5) }
                catch {
                    if let list = try? await ProcessRunner.run(tools.adb,arguments:["forward","--list"],environment:tools.environment,timeout:5) {
                        complete = !list.output.components(separatedBy:.newlines).contains { line in let fields = line.split(whereSeparator:{$0.isWhitespace}); return fields.count == 3 && fields[0] == serial && fields[1] == forward }
                    } else { complete = false }
                }
            }
            if let remote {
                do { _ = try await ProcessRunner.run(tools.adb,arguments:["-s",serial,"shell","rm","-f",remote],environment:tools.environment,timeout:5) } catch { complete = false }
            }
            if complete, let receipt { try? FileManager.default.removeItem(at:receipt) }
        }
    }
    public func resize(width: Int, height: Int) { guard state == .running else { return }; transport?.send(ScrcpyControl.resize(width:width,height:height)) }
    public func sendInput(_ event: AndroidInputEvent) { guard state == .running else { return }; transport?.send(ScrcpyControl.encode(event)) }
    /// Defers application termination until supervised processes and exact
    /// ADB resources have completed cleanup, including an earlier window close.
    public func stopAndWait() async {
        stop()
        while startupInFlight > 0 { await withCheckedContinuation { startupWaiters.append($0) } }
        while !cleanupTasks.isEmpty {
            let pending = cleanupTasks
            for (id,task) in pending { await task.value; cleanupTasks.removeValue(forKey:id) }
        }
    }
    public func stop(reason: String = "requested") {
        // Closing an intent is terminal. A reconnect creates a new BridgeSession;
        // a previously queued start must never resurrect a closed window.
        admissionOpen = false
        guard state != .stopped || process != nil || forward != nil || remotePath != nil else { return }
        appendEvent(["event": "session_stop_requested", "reason": String(reason.prefix(128))])
        generation = UUID(); transition(.stopping)
        frameMailbox?.cancel(); frameMailbox = nil
        transport?.stop(); transport = nil
        if let process,process.isRunning {
            process.terminate()
            let taskID = UUID()
            cleanupTasks[taskID] = Task.detached(priority:.utility) {
                let deadline = Date().addingTimeInterval(20)
                while process.isRunning && Date() < deadline { try? await Task.sleep(nanoseconds:50_000_000) }
                if process.isRunning { kill(process.processIdentifier,SIGKILL) }
                process.waitUntilExit()
            }
        }
        process = nil; try? logHandle?.close(); logHandle = nil
        let cleanupForward = forward; let cleanupRemote = remotePath
        let cleanupReceipt = startupInFlight == 0 ? receiptURL : nil
        forward = nil; remotePath = nil; receiptURL = nil
        cleanup(forward:cleanupForward,remote:cleanupRemote,receipt:cleanupReceipt)
        transition(.stopped)
    }
}
