import AppKit
import DroidBridgeCore
@main struct MakeWrapper {
 @MainActor static func main() async throws {
  let host=URL(fileURLWithPath:CommandLine.arguments[1]),root=URL(fileURLWithPath:CommandLine.arguments[2])
  let tools=Toolchain(adb:host.appendingPathComponent("Contents/Resources/Runtime/bin/adb").path,server:host.appendingPathComponent("Contents/Resources/Runtime/share/scrcpy/scrcpy-server").path)
  let device=AndroidDevice(serial:"emulator-5580",model:"QA")
  let app=AndroidApplication(packageName:"dev.droidbridge.testapp",name:"Launch UX Probe")
  let provider=AndroidIconProvider(toolchain:tools,helperPath:host.appendingPathComponent("Contents/Resources/Runtime/share/droidbridge/icon-helper.jar").path)
  let png=try await provider.icon(device:device,application:app)
  let url=try await MacAppWrapper.create(application:app,device:device,backend:.native,iconPNG:png,hostBundleURL:host,destinationRoot:root)
  print(url.path)
 }
}
