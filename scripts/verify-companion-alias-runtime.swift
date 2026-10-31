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
  var broker:CompanionBrokerEngine?;var sessions:[BridgeSession]=[];var audio:DeviceAudioRouter?;var crashHost:Process?;var ownedPairing:(String,String)?
  do {
   guard let scope=try CompanionQAScope.parse(arguments:CommandLine.arguments) else {throw BridgeError.message("QA scope required")}
   let root=scope.root
   let wireless=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("wireless-owned.json"))) as! [String:Any]
   let alias=wireless["serial"] as! String
   let candidate=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("candidate.json"))) as! [String:Any]
   guard let appPath=candidate["app_path"] as? String,appPath.hasPrefix("/") else {throw BridgeError.message("Exact signed installed candidate required")}
   let toolsRoot=URL(fileURLWithPath:appPath).appendingPathComponent("Contents/Resources/Runtime")
   let packagedSupervisor=toolsRoot.appendingPathComponent("bin/DroidBridgeSupervisor").path
   let toolchain=Toolchain(adb:toolsRoot.appendingPathComponent("bin/adb").path,scrcpy:toolsRoot.appendingPathComponent("Player.app/Contents/MacOS/scrcpy").path,server:toolsRoot.appendingPathComponent("share/scrcpy/scrcpy-server").path,audioClient:toolsRoot.appendingPathComponent("bin/DroidBridgeAudioClient").path)
   if CommandLine.arguments.contains("--crash-child") {
    let session=BridgeSession(descriptor:.init(device:.init(serial:scope.serial,model:"QA35"),application:.init(packageName:"dev.droidbridge.companionfixture",name:"M6 crash fixture"),configuration:.init(width:480,height:720,backend:.native)),toolchain:toolchain)
    sessions=[session];session.onFrame={_ in}
    try await session.start();try await until{session.metrics.frames>0}
    try Data("ready".utf8).write(to:root.appendingPathComponent("crash-ready"))
    while true {try await Task.sleep(nanoseconds:1_000_000_000)}
   }
   let recoveryOnly=CommandLine.arguments.contains("--companion-recovery")
   let engine=CompanionBrokerEngine(directory:scope.brokerDirectory,automaticReconnect:recoveryOnly,managedPaths:scope.managedPaths,testingHooks:.init(qaAdditionalSerials:recoveryOnly ? [] : [alias]));broker=engine;await engine.start()
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
   guard let rawExpiry=q["expires"],let expiry=Double(rawExpiry),expiry.isFinite,expiry.rounded()==expiry else {throw BridgeError.message("Complete phone pairing link expiry required")}
   let pending=try await call("begin_pair",["serial":.string(scope.serial),"expected_device_id":.string(id),"server_pin":.string(pin),"secret":.string(secret),"pairing_expires":.number(expiry)])
   let pair=pending["pairing_id"]!.string!
   try JSONSerialization.data(withJSONObject:["comparison_code":pending["comparison_code"]!.string!]).write(to:root.appendingPathComponent("engine-pending.json"))
   var approved=false
   for _ in 0..<100 {let response=try await call("poll_pair",["pairing_id":.string(pair)]);if response["status"]?.string=="approved"{approved=true;break};try await Task.sleep(nanoseconds:500_000_000)}
   guard approved else {throw BridgeError.message("Phone approval timeout")}
   let admittedStatus=try await call("status")
   if let d=admittedStatus["devices"]?.array?.compactMap(\.object).first(where:{$0["device_id"]?.string==id}),let trust=d["trust_id"]?.string {ownedPairing=(id,trust)}
   if recoveryOnly {
    let before=try await call("status"),oldDevice=before["devices"]!.array!.compactMap(\.object).first{$0["device_id"]?.string==id}!
    let oldTrust=oldDevice["trust_id"]!.string!
    let cached=try await call("connect",["serial":.string(scope.serial)]),oldEpoch=cached["hello"]!.object!["clock_epoch"]!.string!
    let native=BridgeSession(descriptor:.init(device:.init(serial:scope.serial,model:"QA35"),application:.init(packageName:"com.android.settings",name:"Recovery native verification"),configuration:.init(width:480,height:720,backend:.native)),toolchain:toolchain)
    sessions.append(native);native.onFrame={_ in};try await native.start();try await until{native.metrics.frames>0}
    let row:CompanionJSON = .object(["session_id":.string(native.descriptor.id.uuidString),"package_name":.string("com.android.settings"),"label":.string("Recovery native verification"),"backend":.string("native"),"phase":.string("running")])
    let registration:[String:CompanionJSON] = ["device_id":.string(id),"serial":.string(scope.serial),"role":.string("launcher"),"command_protocol":.number(2),"generation":.number(1),"sessions":.array([row])]
    _ = try await call("session_publish",registration)
    let captureBefore=try await captureState(toolchain:toolchain,serial:scope.serial),framesBefore=native.metrics.frames
    _ = try await ProcessRunner.run(toolchain.adb,arguments:["-s",scope.serial,"shell","am","force-stop","dev.droidbridge.companion"],environment:toolchain.environment,timeout:5)
    let downDeadline=Date().addingTimeInterval(45);var disconnected=false
    while Date()<downDeadline {
     let state=try await call("status"),device=state["devices"]!.array!.compactMap(\.object).first{$0["device_id"]?.string==id}!
     if device["connected"]?.bool==false {disconnected=true;break}
     try await Task.sleep(nanoseconds:200_000_000)
    }
    guard disconnected else {throw BridgeError.message("Broker never reported the stopped companion disconnected")}
    native.resize(width:640,height:800)
    try await until{native.metrics.frames>framesBefore && native.metrics.width==640 && native.metrics.height==800}
    let offline=try await captureState(toolchain:toolchain,serial:scope.serial),framesOffline=native.metrics.frames
    guard offline.pid==captureBefore.pid,offline.displays==captureBefore.displays,native.state == .running else {throw BridgeError.message("Companion loss replaced or stopped independent capture")}
    print("Companion force-stop reported disconnected; same Android capture PID produced fresh resized frames");fflush(stdout)
    try Data([1]).write(to:root.appendingPathComponent("recovery-restart-request"))
    let upDeadline=Date().addingTimeInterval(90);var reconnected=false
    while Date()<upDeadline {
     let state=try await call("status"),device=state["devices"]!.array!.compactMap(\.object).first{$0["device_id"]?.string==id}!
     if device["connected"]?.bool==true {guard device["trust_id"]?.string==oldTrust else {throw BridgeError.message("Automatic reconnect replaced trust")};reconnected=true;break}
     try await Task.sleep(nanoseconds:200_000_000)
    }
    guard reconnected else {throw BridgeError.message("Automatic companion reauthentication timed out")}
    // connect here reads the already-connected transport; the status wait above
    // is the automatic-recovery assertion, and never invokes repair itself.
    let after=try await call("connect",["serial":.string(scope.serial)]),newEpoch=after["hello"]!.object!["clock_epoch"]!.string!
    guard newEpoch != oldEpoch,after["device_id"]?.string==id,try CompanionCredentialStore.load(deviceID:id)?.serverPin==pin else {throw BridgeError.message("Reconnect identity/pin/epoch assertions failed")}
    let recovered=try await captureState(toolchain:toolchain,serial:scope.serial)
    guard recovered.pid==captureBefore.pid,recovered.displays==captureBefore.displays else {throw BridgeError.message("Reconnect duplicated capture/display")}
    let registry=try await call("status");guard registry["sessions"]?.array?.count==1 else {throw BridgeError.message("Session registry did not survive companion restart")}
    try Data([1]).write(to:root.appendingPathComponent("recovery-phone-proof-request"))
    try await until(timeout:40){FileManager.default.fileExists(atPath:root.appendingPathComponent("recovery-phone-proof.json").path)}
    let proof=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("recovery-phone-proof.json"))) as! [String:Any]
    guard proof["session_label_count"] as? Int==1,proof["connected"] as? Bool==true else {throw BridgeError.message("Phone did not observe recovered session metadata")}
    await native.stopAndWait();var empty=registration;empty["sessions"] = .array([]);_ = try await call("session_publish",empty)
    _ = try await call("revoke",["device_id":.string(id),"trust_id":.string(oldTrust)]);await engine.shutdown();broker=nil
    let report:[String:Any]=["result":"PASS","boundary":"Actual current Core broker automatic reconnect with signed packaged runtime and owned Android10; not installed GUI acceptance","automatic_reconnect_enabled":true,"discovery_scope":"shipping QA emulator-5580 only","companion_force_stopped_only":true,"disconnected_status_observed":true,"capture_pid_before":captureBefore.pid,"capture_pid_offline":offline.pid,"capture_pid_recovered":recovered.pid,"display_ids_before":captureBefore.displays,"display_ids_offline":offline.displays,"display_ids_recovered":recovered.displays,"decoded_frames_before":framesBefore,"decoded_frames_offline":framesOffline,"live_resize_while_companion_down":true,"same_trust_uuid_pin":true,"new_service_clock_epoch":true,"phone_observed_exactly_one_recovered_session":true,"no_duplicate_capture_or_display":true,"session_command_protocol":2,"own_test_trust_revoked":true]
    try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("recovery-report.json"));print("PASS actual companion-service recovery with independent native capture");fflush(stdout);exit(0)
   }
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
   let router=DeviceAudioRouter(toolchain:toolchain,directory:scope.audioDirectory,supervisor:packagedSupervisor,outputAvailable:{true},startupTimeout:20);audio=router
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
   var cycles:[[String:Any]]=[]
   for index in 0..<5 {
    let serial=index.isMultiple(of:2) ? scope.serial : alias
    let session=make(serial,"dev.droidbridge.companionfixture"),started=Date()
    try await session.start();try await until{session.metrics.frames>0}
    let firstFrameSeconds=Date().timeIntervalSince(started),frames=session.metrics.frames
    let stopped=Date();await session.stopAndWait()
    cycles.append(["cycle":index+1,"alias":serial==scope.serial ? "USB/emulator" : "wireless TLS","decoded_frames":frames,"first_frame_seconds":firstFrameSeconds,"awaited_stop_seconds":Date().timeIntervalSince(stopped)])
   }
   let finalStatus=try await call("status"),trust=finalStatus["devices"]!.array!.compactMap(\.object).first{$0["device_id"]?.string==id}!["trust_id"]!.string!
   _ = try await call("revoke",["device_id":.string(id),"trust_id":.string(trust)])
   await engine.shutdown();broker=nil
   let report:[String:Any]=["test":"Current Core/Streaming with packaged runtimes and actual Android TLS wireless alias","candidate":candidate["candidate"] as? String ?? "unspecified","launch_close_cycles":cycles,"packaged_app_path":appPath,"result":"PASS","installed_gui_acceptance":false,"physical_wifi_verified":false,"real_broker_authenticates_both_aliases":true,"same_alias_concurrent_native_apps":2,"first_frame_counts":firstCounts,"adaptive_resize_verified":true,"audio_initialized":true,"audio_only_blocks_other_alias":true,"phone_intent_shared_across_aliases":true,"wireless_native_frames_verified":true,"gui_sigkill_retained_lease_refusals":refused,"lease_drain_seconds":leaseDrainSeconds,"host_sigkill_to_recovered_stream_and_cleanup_seconds":Date().timeIntervalSince(crashStart),"lease_refusal_poll_interval_seconds":0.02,"post_crash_wireless_capture_verified":true,"scope":"Private QA35 Keychain/catalog/receipts; unchanged shipping pin/identity/authentication and real ADB forwards"]
   try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("runtime-report.json"))
   print("PASS actual M6 runtime");fflush(stdout);exit(0)
  } catch {
   if let child=crashHost,child.isRunning {
    child.terminate();let deadline=Date().addingTimeInterval(5)
    while child.isRunning && Date()<deadline {try? await Task.sleep(nanoseconds:20_000_000)}
    if child.isRunning {kill(child.processIdentifier,SIGKILL)};child.waitUntilExit()
   }
   for s in sessions {await s.stopAndWait()};await audio?.shutdown()
   if let broker,let ownedPairing,let owner=CompanionBrokerOwner.live(getpid()) {
    let revoked=await broker.exchange(.init(operation:"revoke",payload:["device_id":.string(ownedPairing.0),"trust_id":.string(ownedPairing.1)],nonce:"compiled-runtime-cleanup"),owner:owner)
    if revoked.error != nil {
     do {try CompanionCredentialStore.remove(deviceID:ownedPairing.0)}
     catch {fputs("Retained owned QA credential cleanup failure: \(error)\n",stderr)}
    }
   }
   await broker?.shutdown()
   fputs("FAIL runtime: \(error)\n",stderr);exit(1)
  }
 }
 static func captureState(toolchain:Toolchain,serial:String) async throws -> (pid:Int,displays:[Int]) {
  let processes=try await ProcessRunner.run(toolchain.adb,arguments:["-s",serial,"shell","ps","-A","-w","-o","PID,NAME,ARGS"],environment:toolchain.environment,timeout:5)
  let matching=processes.output.split(separator:"\n").filter{line in let fields=line.split(whereSeparator:{$0.isWhitespace});return fields.count>=3 && fields[1]=="app_process" && line.contains("com.genymobile.scrcpy.Server")}
  guard matching.count==1,let first=matching.first?.split(whereSeparator:{$0.isWhitespace}).first,let pid=Int(first) else {throw BridgeError.message("Exactly one actual Android capture process required")}
  let display=try await ProcessRunner.run(toolchain.adb,arguments:["-s",serial,"shell","dumpsys","display"],environment:toolchain.environment,timeout:5)
  let expression=try NSRegularExpression(pattern:"mDisplayId=([0-9]+)")
  let text=display.output as NSString
  let ids=Set(expression.matches(in:display.output,range:NSRange(location:0,length:text.length)).compactMap{Int(text.substring(with:$0.range(at:1)))})
  return(pid,ids.sorted())
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
