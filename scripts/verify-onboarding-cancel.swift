import AppKit
import DroidBridgeCore

@main struct VerifyOnboardingCancel {
 @MainActor static func main() {
  let app=NSApplication.shared
  Task { @MainActor in
   do {
    let launcher=LauncherController()
    let device=AndroidDevice(serial:"qa-no-device",model:"Synthetic readiness")
    launcher.devices=[device];launcher.devicePicker.removeAllItems();launcher.devicePicker.addItem(withTitle:device.model);launcher.devicePicker.selectItem(at:0)
    launcher.applications=[AndroidApplication(packageName:"dev.example.test",name:"Never admitted")];launcher.appsDeviceSerial=device.serial
    launcher.onboardDeviceApps()
    let marker=ProcessInfo.processInfo.environment["DROIDBRIDGE_QA_MARKER"]!
    for _ in 0..<200 {if FileManager.default.fileExists(atPath:marker){break};try await Task.sleep(for:.milliseconds(5))}
    guard FileManager.default.fileExists(atPath:marker) else {throw BridgeError.message("Did not reach readiness await")}
    launcher.cancelOnboarding()
    if let task=launcher.onboardingAdmissionTask {await task.value}
    guard !launcher.onboarding.isRunning,launcher.onboarding.capturedSerial == nil,launcher.onboarding.progress.total==0 else {throw BridgeError.message("Cancelled readiness admitted a new cohort")}
    launcher.window?.close()
    print("PASS: cancel during readiness never admits onboarding or installs an agent")
    exit(0)
   } catch {fputs("FAIL: \(error)\n",stderr);exit(1)}
  }
  app.run()
 }
}
