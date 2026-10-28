import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

@main struct ManagedLaunchGateQA {
 @MainActor static func main() {
  NSApplication.shared.setActivationPolicy(.accessory)
  Task { @MainActor in do {try await run();exit(0)} catch {fputs("FAIL managed gates: \(error)\n",stderr);exit(1)} }
  NSApplication.shared.run()
 }
 @MainActor static func run() async throws {
  guard Bundle.main.bundleIdentifier?.hasPrefix("app.droidbridge.managed.")==true else {throw BridgeError.message("Fixture must execute as managed bundle")}
  let root=URL(fileURLWithPath:ProcessInfo.processInfo.environment["DROIDBRIDGE_QA_ROOT"]!)
  let launcher=LauncherController();launcher.managedCatalog=ManagedAppCatalog(paths:ManagedAppsPaths(privateRoot:root.appendingPathComponent("Private.noindex"),activeRoot:root.appendingPathComponent("Devices")))
  let device=AndroidDevice(serial:"qa-managed-gate",model:"No physical device")
  let app=AndroidApplication(packageName:"dev.qa.gate",name:"Managed Gate")
  let configuration=SessionConfiguration(backend:.native)
  launcher.devices=[device];launcher.devicePicker.addItem(withTitle:"Fixture");launcher.devicePicker.selectItem(at:0)
  launcher.applications=[app];launcher.filterApps();launcher.readySerials=[device.serial];launcher.appsDeviceSerial=device.serial
  var results:[[String:Any]]=[]
  var failures:[String]=[]
  func check(_ entry:String,_ enabled:Bool,_ retained:UUID? = nil)throws {
   if Set(launcher.sessions.keys) != Set(retained.map {[$0]} ?? []) {
    if retained != nil { failures.append("\(entry): denied launch lost retained intent (enabled=\(enabled))") } else {throw BridgeError.message("\(entry) bypassed gate")}
   }
   guard !FileManager.default.fileExists(atPath:root.appendingPathComponent("scrcpy-spawned").path) else {throw BridgeError.message("Gate spawned capture process")}
   results.append(["entrypoint":entry,"enabled":enabled,"admitted_sessions":0])
  }
  for enabled in [false,true] {
   try DroidBridgePreferences.update{$0.bulkWrapperOnboardingEnabled=enabled}
   _=await launcher.launch(device:device,app:app,configuration:configuration,readinessChecked:true);try check("central",enabled)
   launcher.launchAction();try await Task.sleep(nanoseconds:200_000_000);try check("Launch App button target",enabled)
   launcher.pending=[SessionDescriptor(device:device,application:app,configuration:configuration)];launcher.restoreAction();try await Task.sleep(nanoseconds:200_000_000);try check("Restore",enabled)
   if launcher.pending.count != 1 {failures.append("Restore: denied launch lost saved intent (enabled=\(enabled))")}
   launcher.pending=[]
   let retry=BridgeSession(descriptor:SessionDescriptor(device:device,application:app,configuration:configuration),toolchain:launcher.toolchain)
   launcher.sessions[retry.descriptor.id]=retry;launcher.retry(retry.descriptor.id);try await Task.sleep(nanoseconds:200_000_000);try check("Retry",enabled,retry.descriptor.id)
   launcher.close(retry.descriptor.id)
   launcher.processedArguments=false;await launcher.launchArgumentsIfNeeded();try check("immutable wrapper launch arguments",enabled)
   let reconnect=BridgeSession(descriptor:SessionDescriptor(device:device,application:app,configuration:configuration),toolchain:launcher.toolchain)
   launcher.sessions[reconnect.descriptor.id]=reconnect;launcher.sessionStates[reconnect.descriptor.id]="disconnected";launcher.reconnect.state = .on
   launcher.refreshDevices();if let task=launcher.refreshTask{await task.value};try check("poll reconnection",enabled,reconnect.descriptor.id)
   if launcher.sessionStates[reconnect.descriptor.id] != "disconnected" {failures.append("poll reconnection: denied launch lost disconnected marker (enabled=\(enabled))")}
   launcher.close(reconnect.descriptor.id)
   launcher.processedArguments=true;launcher.reopen()
   guard !launcher.processedArguments else {throw BridgeError.message("Explicit reopen did not rearm denied immutable identity")}
   if let task=launcher.refreshTask{await task.value};try check("explicit reopen",enabled)
  }
  let interrupted=BridgeSession(descriptor:SessionDescriptor(device:device,application:app,configuration:configuration),toolchain:launcher.toolchain)
  launcher.sessions[interrupted.descriptor.id]=interrupted
  try Data().write(to:root.appendingPathComponent("delay-next-readiness"))
  launcher.retry(interrupted.descriptor.id)
  for _ in 0..<100 {if FileManager.default.fileExists(atPath:root.appendingPathComponent("readiness-delayed").path){break};try await Task.sleep(nanoseconds:10_000_000)}
  guard FileManager.default.fileExists(atPath:root.appendingPathComponent("readiness-delayed").path) else {throw BridgeError.message("Did not reach delayed Retry readiness")}
  launcher.close(interrupted.descriptor.id);try await Task.sleep(nanoseconds:500_000_000)
  try check("explicit close during Retry readiness is terminal",true)
  launcher.pending=[SessionDescriptor(device:device,application:app,configuration:configuration)]
  launcher.restoreAction();await launcher.shutdownAndWait()
  guard launcher.restoreTask==nil,launcher.sessions.isEmpty else {throw BridgeError.message("Shutdown did not drain Restore admission")}
  results.append(["entrypoint":"shutdown drains Restore","admitted_sessions":0]);launcher.window?.close()
  try JSONSerialization.data(withJSONObject:["passed":failures.isEmpty,"failures":failures,"policy_cases":["flag off","enabled but stale/unaccepted generation"],"cases":results],options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("results.json"))
  guard failures.isEmpty else {throw BridgeError.message(failures.joined(separator:"; "))}
  print("PASS16 shipping managed launch gates: flag-off and stale-generation for direct, button, Restore, Retry, arguments, reconnect and reopen")
 }
}
