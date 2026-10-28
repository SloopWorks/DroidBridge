import AppKit
import Foundation
import DroidBridgeCore

@main struct VerifyDeviceOnboarding {
 @MainActor static func main() async throws {
  _ = NSApplication.shared
  let host=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/DroidBridge.app")
  let runtime=host.appendingPathComponent("Contents/Resources/Runtime")
  let tools=Toolchain(adb:runtime.appendingPathComponent("bin/adb").path,scrcpy:runtime.appendingPathComponent("Player.app/Contents/MacOS/scrcpy").path,server:runtime.appendingPathComponent("share/scrcpy/scrcpy-server").path)
  let discovery=AndroidDiscovery(toolchain:tools)
  guard let device=try await discovery.devices().first(where:{$0.serial=="emulator-5580" && $0.state=="device"}) else { fatalError("Dedicated emulator absent") }
  let apps=try await discovery.applications(device:device)
  print("DISCOVERY count=\(apps.count)")
  let controller=DeviceOnboardingController(toolchain:tools,hostBundleURL:host)
  controller.onProgress={ print("PROGRESS \($0.summary)") }
  let start=Date()
  try controller.begin(device:device,applications:apps,backend:.native)
  while controller.isRunning && Date().timeIntervalSince(start)<240 { try await Task.sleep(for:.milliseconds(100)) }
  guard !controller.isRunning else { await controller.cancelAndWait(); fatalError("Onboarding timed out") }
  let firstElapsed=Date().timeIntervalSince(start)
  print("FIRST elapsed=\(firstElapsed) created=\(controller.progress.created) failed=\(controller.progress.failed)")
  for failure in controller.failures { print("APP_FAILURE \(failure)") }
  guard controller.progress.completed==apps.count, controller.progress.failed==0 else { fatalError("Cohort incomplete") }
  let build=Bundle(url:host)?.object(forInfoDictionaryKey:"CFBundleVersion") as? String
  let publicationStart=Date()
  while true {
   let records=try ManagedAppCatalog().records().filter{$0.deviceSerial==device.serial}
   if records.count==apps.count && records.allSatisfy({$0.sourceBuild==build && $0.availability == .active && FileManager.default.fileExists(atPath:$0.activeBundleURL.path)}) {break}
   guard Date().timeIntervalSince(publicationStart)<90 else {fatalError("Accepted publications did not finish")}
   try await Task.sleep(for:.milliseconds(200))
  }
  print("PUBLICATION_SECONDS \(Date().timeIntervalSince(publicationStart))")
  let resumed=Date()
  try controller.begin(device:device,applications:apps,backend:.native)
  while controller.isRunning && Date().timeIntervalSince(resumed)<60 { try await Task.sleep(for:.milliseconds(100)) }
  guard !controller.isRunning,controller.progress.current==apps.count,controller.progress.created==0 else { fatalError("Resume did not skip existing apps") }
  let resumeElapsed=Date().timeIntervalSince(resumed)
  var requestedCancel=false
  controller.onProgress={ progress in
   if controller.isRunning && progress.completed>=4 && !requestedCancel {requestedCancel=true;controller.cancel()}
  }
  try controller.begin(device:device,applications:apps,backend:.native)
  while controller.isRunning {try await Task.sleep(for:.milliseconds(20))}
  guard requestedCancel,controller.progress.cancelled,controller.progress.completed<apps.count else {fatalError("Cancellation failed to stop new admission")}
  print("CANCELLATION PASS completed=\(controller.progress.completed) total=\(apps.count)")
  controller.onProgress=nil
  try controller.begin(device:device,applications:apps,backend:.native)
  while controller.isRunning {try await Task.sleep(for:.milliseconds(20))}
  guard controller.progress.current==apps.count,controller.progress.failed==0 else {fatalError("Resume after cancellation failed")}
  let records=try ManagedAppCatalog().records().filter{$0.deviceSerial==device.serial}
  guard records.count==apps.count,records.allSatisfy({$0.sourceBuild==build}) else {fatalError("Accepted wrappers do not match installed build")}
  print("RESULT PASS records=\(records.count) firstSeconds=\(firstElapsed) resumeSeconds=\(resumeElapsed)")
 }
}
