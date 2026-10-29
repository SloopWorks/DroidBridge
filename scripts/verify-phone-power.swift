import Foundation
import DroidBridgeCore

/// Real shipping Core command path for isolated cross-process integration tests.
/// Preferences/locks must be in a test-owned directory; never uses default state.
@main struct PhonePowerVerification {
    static func main() async {
        let args=CommandLine.arguments
        guard args.count==6, ["on","off"].contains(args[1]), args[3].hasSuffix(".noindex") else {
            fputs("Usage: verify-phone-power on|off SERIAL TEST_ROOT.noindex ADB_PATH MODEL\n",stderr);exit(2)
        }
        let root=URL(fileURLWithPath:args[3]),serial=args[2]
        do {
            try AndroidDiscovery.validateSerial(serial)
            guard ["emulator-5580","emulator-5582"].contains(serial) else {throw BridgeError.message("Only dedicated task emulators are permitted")}
            let off=args[1]=="off",prefs=root.appendingPathComponent("preferences.json")
            try DroidBridgePreferences.update(url:prefs) { value in
                if off {value.screenOffDeviceSerials.insert(serial)} else {value.screenOffDeviceSerials.remove(serial)}
            }
            let power=PhoneDisplayPower(toolchain:Toolchain(adb:args[4]),preferencesURL:prefs,lockDirectory:root.appendingPathComponent("locks"))
            let device=AndroidDevice(serial:serial,model:args[5])
            let result=try await (off ? power.setScreenOffIfRequested(device:device) : power.turnScreenOn(device:device))
            let bytes=try JSONSerialization.data(withJSONObject:["pid":getpid(),"serial":serial,"requested":args[1],"result":String(describing:result)],options:.sortedKeys)
            print(String(decoding:bytes,as:UTF8.self))
        } catch {fputs("FAIL: \(error)\n",stderr);exit(1)}
    }
}
