import Foundation
import Darwin
import DroidBridgeCore

@main struct DroidBridgeAvailabilityMain {
    static func appendBounded(data: Data, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        if let size = try? fm.attributesOfItem(atPath:url.path)[.size] as? NSNumber, size.intValue > 1_048_576 {
            let prior = url.appendingPathExtension("1"); try? fm.removeItem(at:prior); try? fm.moveItem(at:url,to:prior)
        }
        if !fm.fileExists(atPath:url.path) { fm.createFile(atPath:url.path,contents:nil,attributes:[.posixPermissions:0o600]) }
        if let file = try? FileHandle(forWritingTo:url) { _ = try? file.seekToEnd(); try? file.write(contentsOf:data+Data([10])); try? file.close() }
    }
    static func main() async {
        let args = CommandLine.arguments
        if args.contains("--help") { print("Usage: DroidBridgeAvailability [--once] [--adb PATH] [--private-root PATH] [--active-root PATH] [--preferences PATH] [--log PATH] [--interval SECONDS]"); return }
        if args.contains("--version") { print("DroidBridgeAvailability 0.1.2"); return }
        func option(_ name: String) -> String? { guard let i = args.firstIndex(of: name), args.indices.contains(i+1) else { return nil }; return args[i+1] }
        let paths = ManagedAppsPaths(privateRoot: option("--private-root").map { URL(fileURLWithPath:$0) } ?? ManagedAppsPaths.userDefault.privateRoot, activeRoot: option("--active-root").map { URL(fileURLWithPath:$0) } ?? ManagedAppsPaths.userDefault.activeRoot)
        let preferences = option("--preferences").map { URL(fileURLWithPath:$0) } ?? DroidBridgePreferences.defaultURL
        let adb = option("--adb") ?? URL(fileURLWithPath:args[0]).deletingLastPathComponent().appendingPathComponent("adb").path
        let monitor = ManagedAvailabilityMonitor(toolchain: Toolchain(adb:adb), catalog: ManagedAppCatalog(paths:paths), preferencesURL:preferences)
        let once = args.contains("--once")
        let interval = min(60,max(2,Double(option("--interval") ?? "10") ?? 10))
        let worker = Task {
            var failures = 0
            repeat {
                let result = await monitor.cycle()
                if let data = try? JSONEncoder().encode(result) {
                    print(String(decoding:data,as:UTF8.self)); fflush(stdout)
                    if let path = option("--log") { appendBounded(data: data, to: URL(fileURLWithPath:path)) }
                }
                failures = result.messages.isEmpty ? 0 : min(3,failures+1)
                if once || Task.isCancelled { break }
                // Delay is armed from cycle completion, never from its start.
                let delay = result.pendingRegistrations > 0 && (result.registrations > 0 || result.transitions > 0) ? 0.2 : min(60,interval*pow(2,Double(failures)))
                try? await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))
            } while !Task.isCancelled
        }
        signal(SIGTERM,SIG_IGN); signal(SIGINT,SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal:SIGTERM,queue:.global())
        let interrupt = DispatchSource.makeSignalSource(signal:SIGINT,queue:.global())
        term.setEventHandler { worker.cancel() }; interrupt.setEventHandler { worker.cancel() }
        term.resume(); interrupt.resume()
        await worker.value
        term.cancel(); interrupt.cancel()
    }
}
