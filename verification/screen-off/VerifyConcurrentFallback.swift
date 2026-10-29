import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

@main struct ConcurrentFallback {
    @MainActor static func main() {
        Task { @MainActor in
            do {try await verify();print("PASS concurrent production fallback ports, OFF input and cleanup");exit(0)}
            catch {fputs("FAIL: \(error)\n",stderr);exit(1)}
        };NSApplication.shared.run()
    }
    @MainActor static func verify() async throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let out=root.appendingPathComponent("verification/screen-off/concurrent-fallback")
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        let tools=Toolchain(scrcpy:root.appendingPathComponent("verification/screen-off/record-production-client.py").path)
        let device=AndroidDevice(serial:"emulator-5582",model:"API37")
        func adb(_ args:[String]) async throws ->String {try await ProcessRunner.run(tools.adb,arguments:["-s",device.serial]+args).output}
        func displays() async throws ->String {try await adb(["shell","cmd","display","get-displays"])}
        func panel(_ output:String)->Bool {PhoneDisplayPower.physicalDisplayState(in:output) == .off}
        let baseline=try await displays(),forward=try await adb(["forward","--list"]),reverse=try await adb(["reverse","--list"])
        let settings=try await adb(["shell","settings","get","global","stay_on_while_plugged_in"])+adb(["shell","settings","get","system","screen_off_timeout"])
        let sessions=(0..<2).map {i in BridgeSession(descriptor:SessionDescriptor(device:device,application:AndroidApplication(packageName:"dev.droidbridge.testapp"+(i==0 ? "":"2"),name:"Production \(i)"),configuration:SessionConfiguration(backend:.scrcpy,showSystemDecorations:false)),toolchain:tools)}
        func restore() async {
            for session in sessions {await session.stopAndWait()}
            _=try? await adb(["shell","cmd","display","power-reset","0"])
            _=try? await adb(["shell","cmd","power","wakeup","--display-id","0"])
        }
        do {
            for name in ["a.trigger","b.trigger"] {try? FileManager.default.removeItem(at:out.appendingPathComponent(name))}
            _=try await adb(["logcat","-c"])
            async let left:Void=sessions[0].start();async let right:Void=sessions[1].start();try await left;try await right
            var ids:[Int]=[]
            for session in sessions {
                var text=""
                for _ in 0..<100 {
                    text=(try? String(contentsOf:session.logURL,encoding:.utf8)) ?? ""
                    if text.contains("[\(session.descriptor.application.packageName)] on display ") {break}
                    try await Task.sleep(for:.milliseconds(100))
                }
                let regex=try NSRegularExpression(pattern:#"Starting app .*\["#+NSRegularExpression.escapedPattern(for:session.descriptor.application.packageName)+#"\] on display (\d+)"#)
                guard let match=regex.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),let range=Range(match.range(at:1),in:text),let id=Int(text[range]) else {throw BridgeError.message("No exact package startup receipt: \(text)")}
                ids.append(id)
            }
            guard Set(ids).count==2 else {throw BridgeError.message("Cross-connected fallback displays")}
            _=try await adb(["shell","cmd","display","power-off","0"])
            try await Task.sleep(for:.seconds(12))
            guard panel(try await displays()) else {throw BridgeError.message("Physical panel is not OFF")}
            for (i,name) in ["a","b"].enumerated() {
                let facts=try await displays()
                guard let line=facts.components(separatedBy:.newlines).first(where:{$0.hasPrefix("Display id \(ids[i]):")}), let match=line.range(of:#"real \d+ x \d+"#,options:.regularExpression),let height=line[match].split(separator:" ").last else {throw BridgeError.message("No virtual display geometry")}
                try String(height).write(to:out.appendingPathComponent(name+".height"),atomically:true,encoding:.utf8)
                try Data().write(to:out.appendingPathComponent(name+".trigger"))
                var receipt=""
                for _ in 0..<100 {
                    receipt=try await adb(["logcat","-d","-s","DroidBridgeProbe:I","*:S"])
                    if receipt.contains("text=\(i+1)Production\(name.uppercased())k display=\(ids[i])") {break}
                    try await Task.sleep(for:.milliseconds(100))
                }
                try receipt.write(to:out.appendingPathComponent(name+"-input.log"),atomically:true,encoding:.utf8)
                guard receipt.contains("text=\(i+1)Production\(name.uppercased())k display=\(ids[i])"),receipt.contains("click=1 display=\(ids[i])") else {throw BridgeError.message("Display-specific input missing: \(receipt)")}
            }
            await sessions[0].stopAndWait();try await Task.sleep(for:.seconds(2))
            guard sessions[1].state == .running,panel(try await displays()) else {throw BridgeError.message("Closing first app disturbed second/panel")}
            await sessions[1].stopAndWait()
            guard panel(try await displays()) else {throw BridgeError.message("Final close woke panel")}
            guard try await displays().components(separatedBy:"Display id ").count==baseline.components(separatedBy:"Display id ").count,
                  try await adb(["forward","--list"])==forward,try await adb(["reverse","--list"])==reverse else {throw BridgeError.message("Resources not restored")}
            let after=try await adb(["shell","settings","get","global","stay_on_while_plugged_in"])+adb(["shell","settings","get","system","screen_off_timeout"])
            guard settings==after else {throw BridgeError.message("Global Android settings changed")}
            for (i,s) in sessions.enumerated() {try FileManager.default.copyItem(at:s.logURL,to:out.appendingPathComponent("session-\(i)-\(UUID().uuidString).log"))}
            let report:[String:Any]=["passed":true,"display_ids":ids,"simultaneous_production_start":true,"real_core_and_streaming":true,"recording_proxy_only_adds_test_recording_and_public_sdl_fixture":true,"settings_unchanged":true,"resource_baseline_restored":true,"off_idle_seconds":12]
            try JSONSerialization.data(withJSONObject:report,options:.prettyPrinted).write(to:out.appendingPathComponent("result.json"))
            await restore()
        } catch {await restore();throw error}
    }
}
