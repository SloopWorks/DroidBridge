// Actual Android runtime verification only. Compile against current DEBUG
// Core+Streaming objects with @testable enabled, then run with an exclusively
// owned --companion-qa-root and --serial emulator-5580. The private root must
// contain wireless-owned.json for the one real TLS alias. Pairing links are
// consumed from a private file, never argv/stdout; no shipping auth bypass exists.
import Foundation
import Darwin
import AppKit
@testable import DroidBridgeCore
import DroidBridgeStreaming

@main struct Runtime {
 @MainActor static func main() async {
  var broker:CompanionBrokerEngine?;var sessions:[BridgeSession]=[];var audio:DeviceAudioRouter?;var crashHost:Process?
  do {
   guard let scope=try CompanionQAScope.parse(arguments:CommandLine.arguments) else {throw BridgeError.message("QA scope required")}
   let root=scope.root
   let wireless=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("wireless-owned.json"))) as! [String:Any]
   let alias=wireless["serial"] as! String
   let toolsRoot=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("dist/DroidBridge.app/Contents/Resources/Runtime")
   let toolchain=Toolchain(adb:FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/adb").path,scrcpy:toolsRoot.appendingPathComponent("Player.app/Contents/MacOS/scrcpy").path,server:toolsRoot.appendingPathComponent("share/scrcpy/scrcpy-server").path,audioClient:toolsRoot.appendingPathComponent("bin/DroidBridgeAudioClient").path)
   if CommandLine.arguments.contains("--crash-child") {
    let session=BridgeSession(descriptor:.init(device:.init(serial:scope.serial,model:"QA35"),application:.init(packageName:"dev.droidbridge.companionfixture",name:"M6 crash fixture"),configuration:.init(width:480,height:720,backend:.native)),toolchain:toolchain)
    sessions=[session];session.onFrame={_ in}
    try await session.start();try await until{session.metrics.frames>0}
    try Data("ready".utf8).write(to:root.appendingPathComponent("crash-ready"))
    while true {try await Task.sleep(nanoseconds:1_000_000_000)}
   }
   let engine=CompanionBrokerEngine(directory:scope.brokerDirectory,managedPaths:scope.managedPaths,testingHooks:.init(qaAdditionalSerials:[alias]));broker=engine;await engine.start()
   let owner=CompanionBrokerOwner.live(getpid())!
   func call(_ op:String,_ payload:[String:CompanionJSON]=[:]) async throws -> [String:CompanionJSON] {
    let response=await engine.exchange(.init(operation:op,payload:payload,nonce:"compiled-runtime-harness"),owner:owner)
    if let error=response.error {throw CompanionBoundaryError(error.code,error.message,retryable:error.retryable)};return response.data
   }
   let linkURL=root.appendingPathComponent("private-link")
   try await until(timeout:60){FileManager.default.fileExists(atPath:linkURL.path)}
   let link=String(decoding:try Data(contentsOf:linkURL),as:UTF8.self)
   let q=URLComponents(string:link)!.queryItems!.reduce(into:[String:String]()){$0[$1.name]=$1.value}
   try FileManager.default.removeItem(at:linkURL)
   let id=q["device_id"]!,pin=q["server_pin"]!,secret=q["secret"]!
   let pending=try await call("begin_pair",["serial":.string(scope.serial),"expected_device_id":.string(id),"server_pin":.string(pin),"secret":.string(secret)])
   let pair=pending["pairing_id"]!.string!
   try JSONSerialization.data(withJSONObject:["comparison_code":pending["comparison_code"]!.string!]).write(to:root.appendingPathComponent("engine-pending.json"))
   var approved=false
   for _ in 0..<100 {let response=try await call("poll_pair",["pairing_id":.string(pair)]);if response["status"]?.string=="approved"{approved=true;break};try await Task.sleep(nanoseconds:500_000_000)}
   guard approved else {throw BridgeError.message("Phone approval timeout")}
   let connected=try await call("connect",["serial":.string(alias)]);guard connected["paired"]?.bool==true,connected["device_id"]?.string==id else {throw BridgeError.message("Authenticated alias identity failed")}
   let status=try await call("status"),device=status["devices"]!.array!.compactMap(\.object).first{$0["device_id"]?.string==id}!
   guard Set(device["aliases"]!.array!.compactMap(\.string)) == Set([scope.serial,alias]) else {throw BridgeError.message("Verified aliases not persisted")}
   print("Actual broker authenticated both TLS aliases; private QA catalog committed");fflush(stdout)
   func make(_ serial:String,_ package:String)->BridgeSession {let s=BridgeSession(descriptor:.init(device:.init(serial:serial,model:"QA35"),application:.init(packageName:package,name:"M6 actual runtime"),configuration:.init(width:480,height:720,backend:.native)),toolchain:toolchain);s.onFrame={_ in};sessions.append(s);return s}
   let settings=make(scope.serial,"com.android.settings"),fixture=make(scope.serial,"dev.droidbridge.companionfixture")
   try await settings.start();try await fixture.start();try await until{settings.metrics.frames>0 && fixture.metrics.frames>0}
   let firstCounts=[settings.metrics.frames,fixture.metrics.frames]
   try await refuses(alias:alias)
   settings.resize(width:640,height:800);try await until{settings.metrics.width==640 && settings.metrics.height==800}
   let router=DeviceAudioRouter(toolchain:toolchain,directory:scope.audioDirectory,supervisor:FileManager.default.currentDirectoryPath+"/.build/debug/DroidBridgeSupervisor",outputAvailable:{true},startupTimeout:20);audio=router
   let routes=try DeviceAudioPreferences.setRoute(.mac,for:scope.serial)
   router.reconcile(activeSerials:[scope.serial],connectedSerials:[scope.serial,alias],routes:routes)
   try await until(timeout:25){router.status(for:scope.serial).phase == .ready || router.status(for:scope.serial).phase == .failed}
   guard router.status(for:scope.serial).phase == .ready else {throw BridgeError.message("Actual audio initialization: "+router.status(for:scope.serial).message)}
   await settings.stopAndWait();await fixture.stopAndWait()
   try await refuses(alias:alias) // audio still owns the selected USB alias
   let phoneRoutes=try DeviceAudioPreferences.setRoute(.phone,for:alias)
   guard phoneRoutes[scope.serial] == .phone,phoneRoutes[alias] == .phone else {throw BridgeError.message("Alias route intent diverged")}
   router.reconcile(activeSerials:[scope.serial],connectedSerials:[scope.serial,alias],routes:phoneRoutes)
   try await until(timeout:25){router.status(for:scope.serial).phase == .phone}
   await router.shutdown();audio=nil
   let wifi=make(alias,"dev.droidbridge.companionfixture");try await wifi.start();try await until{wifi.metrics.frames>0}
   try await refuses(alias:scope.serial)
   await wifi.stopAndWait()
   print("Actual concurrent native frames, resize, audio-drain fence and alias switch passed");fflush(stdout)
   let child=Process();child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);child.arguments=["--companion-qa-root",root.path,"--serial",scope.serial,"--crash-child"]
   child.standardOutput=FileHandle.nullDevice;child.standardError=FileHandle.nullDevice;child.environment=ProcessInfo.processInfo.environment
   let marker=root.appendingPathComponent("crash-ready");try? FileManager.default.removeItem(at:marker);try child.run();crashHost=child
   try await until(timeout:30){FileManager.default.fileExists(atPath:marker.path)}
   let crashStart=Date();kill(child.processIdentifier,SIGKILL)
   var refused=0,drained=false
   for _ in 0..<300 {
    do {let lease=try await CanonicalAliasAdmission.acquire(serial:alias);withExtendedLifetime(lease){};drained=true;break}
    catch let error as CompanionBoundaryError where error.code=="transport_in_use" {refused+=1;try await Task.sleep(nanoseconds:20_000_000)}
   }
   let leaseDrainSeconds=Date().timeIntervalSince(crashStart)
   child.waitUntilExit();crashHost=nil;guard drained,refused>0 else {throw BridgeError.message("GUI crash did not demonstrate retained teardown lease")}
   let recovered=make(alias,"dev.droidbridge.companionfixture");try await recovered.start();try await until{recovered.metrics.frames>0};await recovered.stopAndWait()
   let finalStatus=try await call("status"),trust=finalStatus["devices"]!.array!.compactMap(\.object).first{$0["device_id"]?.string==id}!["trust_id"]!.string!
   _ = try await call("revoke",["device_id":.string(id),"trust_id":.string(trust)])
   await engine.shutdown();broker=nil
   let report:[String:Any]=["test":"M6 actual Core/Streaming harness with real Android TLS wireless alias","result":"PASS","installed_gui_acceptance":false,"physical_wifi_verified":false,"real_broker_authenticates_both_aliases":true,"same_alias_concurrent_native_apps":2,"first_frame_counts":firstCounts,"adaptive_resize_verified":true,"audio_initialized":true,"audio_only_blocks_other_alias":true,"phone_intent_shared_across_aliases":true,"wireless_native_frames_verified":true,"gui_sigkill_retained_lease_refusals":refused,"lease_drain_seconds":leaseDrainSeconds,"host_sigkill_to_recovered_stream_and_cleanup_seconds":Date().timeIntervalSince(crashStart),"lease_refusal_poll_interval_seconds":0.02,"post_crash_wireless_capture_verified":true,"scope":"Private QA35 Keychain/catalog/receipts; unchanged shipping pin/identity/authentication and real ADB forwards"]
   try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:FileManager.default.currentDirectoryPath+"/verification/companion/broker/m6-actual-alias-runtime.json"))
   print("PASS actual M6 runtime");fflush(stdout);exit(0)
  } catch {
   if let child=crashHost,child.isRunning {
    child.terminate();let deadline=Date().addingTimeInterval(5)
    while child.isRunning && Date()<deadline {try? await Task.sleep(nanoseconds:20_000_000)}
    if child.isRunning {kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()
   }
   for s in sessions {await s.stopAndWait()};await audio?.shutdown();await broker?.shutdown()
   fputs("FAIL runtime: \(error)\n",stderr);exit(1)
  }
 }
 @MainActor static func until(timeout:Double=20,_ predicate:()->Bool) async throws {
  let deadline=Date().addingTimeInterval(timeout)
  while !predicate() {guard Date()<deadline else {throw BridgeError.message("Actual runtime condition timeout")};try await Task.sleep(nanoseconds:50_000_000)}
 }
 static func refuses(alias:String) async throws {
  do {let lease=try await CanonicalAliasAdmission.acquire(serial:alias);withExtendedLifetime(lease){};throw BridgeError.message("Other alias was incorrectly admitted")}
  catch let error as CompanionBoundaryError where error.code=="transport_in_use" {}
 }
}
