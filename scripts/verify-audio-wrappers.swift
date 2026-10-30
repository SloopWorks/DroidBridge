import AppKit
import Foundation
import DroidBridgeCore

/// Test-only production factory entry point. No catalog mutation or fake icons.
@main struct AudioWrapperFactory {
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                let arguments=CommandLine.arguments
                if arguments.count==4,arguments[1]=="--inspect",let pid=Int32(arguments[2]),let running=NSRunningApplication(processIdentifier:pid) {
                    let receipt:[String:Any]=["pid":pid,"bundle":running.bundleURL?.path ?? "","bundle_identifier":running.bundleIdentifier ?? "","activation_policy":running.activationPolicy.rawValue,"terminated":running.isTerminated]
                    try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:arguments[3]),options:.atomic)
                    exit(0)
                }
                guard arguments.count==6 else {throw BridgeError.message("Usage: verify-audio-wrappers HOST SERIAL PACKAGE DESTINATION OUTPUT")}
                let host=URL(fileURLWithPath:arguments[1]),serial=arguments[2],package=arguments[3]
                try AndroidDiscovery.validateSerial(serial);try AndroidDiscovery.validatePackage(package)
                let destination=URL(fileURLWithPath:arguments[4]),output=URL(fileURLWithPath:arguments[5])
                guard destination.path.hasPrefix(NSHomeDirectory()+"/Applications/DroidBridge Audio QA/") else {throw BridgeError.message("Wrapper test destination must be its owned QA Applications subtree")}
                let runtime=host.appendingPathComponent("Contents/Resources/Runtime")
                let tools=Toolchain(adb:runtime.appendingPathComponent("bin/adb").path,scrcpy:runtime.appendingPathComponent("Player.app/Contents/MacOS/scrcpy").path,server:runtime.appendingPathComponent("share/scrcpy/scrcpy-server").path)
                let device=AndroidDevice(serial:serial,model:"DroidBridge audio QA")
                let application=AndroidApplication(packageName:package,name:"DroidBridge Audio QA")
                let provider=AndroidIconProvider(toolchain:tools,helperPath:runtime.appendingPathComponent("share/droidbridge/icon-helper.jar").path)
                let png=try await provider.icon(device:device,application:application)
                let bundle=try await MacAppWrapper.create(application:application,device:device,backend:.native,iconPNG:png,hostBundleURL:host,destinationRoot:destination)
                _=try await ProcessRunner.run("/usr/bin/codesign",arguments:["--verify","--deep","--strict",bundle.path])
                let info=try PropertyListSerialization.propertyList(from:Data(contentsOf:bundle.appendingPathComponent("Contents/Info.plist")),format:nil) as? [String:Any]
                let receipt:[String:Any]=["passed":true,"bundle":bundle.path,"bundle_identifier":info?["CFBundleIdentifier"] as? String ?? "","package":package,"serial":serial,"backend":"native","icon_bytes":png.count,"factory":"MacAppWrapper.create","signed_and_verified":true]
                try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
                exit(0)
            } catch {fputs("FAIL audio wrapper factory: \(error)\n",stderr);exit(1)}
        }
        app.run()
    }
}
