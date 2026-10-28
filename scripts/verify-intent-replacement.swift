import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

@main struct VerifyIntentReplacement {
 @MainActor static func main() {
  let app=NSApplication.shared
  Task { @MainActor in
   do {try await run();print("PASS: explicit Close and task cancellation during delayed readiness cannot lose or resurrect replacement/restore intents");exit(0)}
   catch {fputs("FAIL: \(error)\n",stderr);exit(1)}
  }
  app.run()
 }
 @MainActor static func run() async throws {
  let launcher=LauncherController()
  let device=AndroidDevice(serial:"qa-no-device",model:"Delayed fixture")
  let application=AndroidApplication(packageName:"dev.example.test",name:"Intent")
  let marker=URL(fileURLWithPath:ProcessInfo.processInfo.environment["DROIDBRIDGE_QA_MARKER"]!)
  func original() ->BridgeSession {
   let session=BridgeSession(descriptor:SessionDescriptor(device:device,application:application,configuration:SessionConfiguration()),toolchain:launcher.toolchain)
   launcher.sessions[session.descriptor.id]=session;launcher.sessionStates[session.descriptor.id]="disconnected";launcher.reconnectRetries[session.descriptor.id]=ReconnectRetry()
   return session
  }
  func waitForReadiness() async throws {
   for _ in 0..<300 {if FileManager.default.fileExists(atPath:marker.path){return};try await Task.sleep(for:.milliseconds(5))}
   throw BridgeError.message("Readiness boundary not reached")
  }
  let old=original()
  let replacement=Task {await launcher.launch(device:device,app:application,configuration:old.descriptor.configuration,replacing:old.descriptor.id)}
  try await waitForReadiness();launcher.close(old.descriptor.id)
  guard await replacement.value == nil,launcher.sessions.isEmpty else {throw BridgeError.message("Explicit Close resurrected the old intent")}
  try? FileManager.default.removeItem(at:marker)
  let retained=original()
  let cancelled=Task {await launcher.launch(device:device,app:application,configuration:retained.descriptor.configuration,replacing:retained.descriptor.id)}
  try await waitForReadiness();cancelled.cancel()
  guard await cancelled.value == nil,launcher.sessions[retained.descriptor.id] === retained,launcher.sessionStates[retained.descriptor.id]=="disconnected",launcher.reconnectRetries[retained.descriptor.id]?.failures==0 else {throw BridgeError.message("Cancelled admission lost original intent or consumed retry budget")}
  launcher.close(retained.descriptor.id)
  try? FileManager.default.removeItem(at:marker)
  let saved=SessionDescriptor(device:device,application:application,configuration:SessionConfiguration(showSystemDecorations:false))
  launcher.devices=[device];launcher.pending=[saved];launcher.restoreAction();try await waitForReadiness();launcher.restoreTask?.cancel()
  if let task=launcher.restoreTask {await task.value}
  guard launcher.pending.map(\.id)==[saved.id],launcher.sessions.isEmpty else {throw BridgeError.message("Cancelled restore lost saved intent")}
  launcher.save()
  let bytes=try Data(contentsOf:launcher.persistenceURL),persisted=try JSONDecoder().decode([SessionDescriptor].self,from:bytes)
  guard persisted.map(\.id)==[saved.id],persisted.first?.configuration.showSystemDecorations==false else {throw BridgeError.message("Pending saved intent was not durably preserved")}
  await launcher.shutdownAndWait();launcher.window?.close()
 }
}
