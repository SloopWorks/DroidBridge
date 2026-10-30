import AppKit
import Foundation
import DroidBridgeCore
import DroidBridgeStreaming

/// Shipping UI/Core/Streaming with explicit bounded fake tools; no Android or
/// physical OS focus claim. A real H264 packet is decoded by production code.
@main struct VerifyLaunchUX {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
        Task { @MainActor in
            do {try await run();print("PASS: launch UX synchronous preview, restored geometry, same window through decoded video, input fence, reopen reuse, and close/admission fences");fflush(stdout);exit(0)}
            catch {fputs("FAIL: launch UX \(error)\n",stderr);exit(1)}
        }
        NSApplication.shared.run()
    }
    @MainActor static func require(_ condition:Bool,_ message:String) throws {if !condition {throw BridgeError.message(message)}}
    @MainActor static func wait(_ label:String,_ condition:()->Bool) async throws {
        for _ in 0..<400 {if condition(){return};try await Task.sleep(for:.milliseconds(20))}
        throw BridgeError.message("Timed out: \(label)")
    }
    @MainActor static func capture(_ view:NSView,_ url:URL) throws {
        view.layoutSubtreeIfNeeded();view.displayIfNeeded()
        guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds),let _=view.window else {throw BridgeError.message("No drawable view")}
        view.cacheDisplay(in:view.bounds,to:bitmap)
        try require(bitmap.pixelsWide>0 && bitmap.pixelsHigh>0,"Empty native view bitmap")
        try bitmap.representation(using:.png,properties:[:])!.write(to:url)
    }
    @MainActor static func input(_ view:AndroidVideoView) throws {
        let window=view.window!
        let point=view.convert(NSPoint(x:view.bounds.midX,y:view.bounds.midY),to:nil)
        for kind in [NSEvent.EventType.leftMouseDown,.leftMouseUp,.rightMouseDown] {
            let event=NSEvent.mouseEvent(with:kind,location:point,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
            if kind == .leftMouseDown {view.mouseDown(with:event)} else if kind == .leftMouseUp {view.mouseUp(with:event)} else {view.rightMouseDown(with:event)}
        }
        let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"LaunchUxQa",charactersIgnoringModifiers:"LaunchUxQa",isARepeat:false,keyCode:0)!
        view.keyDown(with:event)
    }
    @MainActor static func run() async throws {
        let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("verification/launch-ux/qa")
        let mode=URL(fileURLWithPath:ProcessInfo.processInfo.environment["DROIDBRIDGE_QA_MODE"]!)
        func marker(_ name:String)->URL {URL(fileURLWithPath:mode.path+"."+name)}
        let device=AndroidDevice(serial:"qa-no-device",model:"Explicit no-device fixture")
        let app=AndroidApplication(packageName:"dev.droidbridge.testapp",name:"Launch UX Probe")
        var results:[[String:Any]]=[]
        let seed=NativeWindowController(deviceSerial:device.serial,application:app,configuration:SessionConfiguration())
        let key="NSWindow Frame "+seed.frameName,old=UserDefaults.standard.object(forKey:key)
        defer {if let old {UserDefaults.standard.set(old,forKey:key)} else {UserDefaults.standard.removeObject(forKey:key)};UserDefaults.standard.synchronize()}
        let visible=NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1200,height:900)
        let saved=NSRect(x:visible.minX+40,y:visible.minY+40,width:450,height:420)
        seed.window!.setFrame(saved,display:false);seed.window!.saveFrame(usingName:seed.frameName);seed.close()
        let launcher=LauncherController();launcher.showWindow(nil)
        let before=ProcessInfo.processInfo.systemUptime
        try require(launcher.prepareWrapperLaunch(),"Wrapper did not prepare a preview")
        let elapsed=ProcessInfo.processInfo.systemUptime-before
        guard let preview=launcher.launchPreview,let window=preview.window else {throw BridgeError.message("Missing synchronous preview")}
        let initialNumber=window.windowNumber
        try require(elapsed<0.75,"Local preview blocked on external work")
        try require(window.isVisible && launcher.window?.isVisible==false,"Preview not visible or launcher flashed alongside it")
        try require(preview.session == nil && preview.video.frameImage == nil,"Preview created a session or video before admission")
        try require(window.title==app.name && preview.video.applicationName==app.name,"Preview lost local application branding")
        try require(abs(window.frame.minX-saved.minX)<1 && abs(window.frame.minY-saved.minY)<1 && abs(window.frame.width-saved.width)<1 && abs(window.frame.height-saved.height)<1,"Saved frame did not restore: \(window.frame)")
        try require(!FileManager.default.fileExists(atPath:marker("calls").path),"Preparing local preview performed tool I/O")
        launcher.argumentLaunchInFlight=true
        window.orderOut(nil);launcher.reopen();launcher.argumentLaunchInFlight=false
        try require(launcher.launchPreview === preview && preview.window === window && window.isVisible,"Reopen replaced/failed to reveal loading preview")
        try capture(preview.video,output.appendingPathComponent("loading.png"))
        results.append(["case":"synchronous_branded_preview_and_reopen","passed":true,"seconds":elapsed,"window_number":initialNumber,"frame":[window.frame.minX,window.frame.minY,window.frame.width,window.frame.height]])
        try await Task.sleep(for:.milliseconds(200))
        let minimizeDiagnostics:[String:Any]=["visible":window.isVisible,"style_mask":window.styleMask.rawValue,"application_running":NSApp.isRunning,"application_active":NSApp.isActive,"mini_button_enabled":window.standardWindowButton(.miniaturizeButton)?.isEnabled ?? false]
        try JSONSerialization.data(withJSONObject:minimizeDiagnostics,options:.prettyPrinted).write(to:output.appendingPathComponent("minimize-observation.json"))
        window.miniaturize(nil)
        try await wait("deliberate pre-admission minimize") {window.isMiniaturized}
        let start=Task {await launcher.launch(device:device,app:app,configuration:SessionConfiguration(backend:.native),readinessChecked:true)}
        try await wait("native handshake before first frame") {FileManager.default.fileExists(atPath:marker("handshake").path)}
        guard let attached=launcher.sessions.values.first else {throw BridgeError.message("Missing admitted session")}
        try require(launcher.launchPreview == nil && launcher.hosts[attached.descriptor.id] === preview && preview.window === window,"Attach replaced preview NSWindow")
        try require(window.isMiniaturized,"Attaching preview reversed deliberate pre-admission minimize")
        try require(attached.state == .starting && attached.metrics.frames==0 && preview.video.frameImage==nil,"Fixture did not hold first decoded frame")
        var expectedStart=Data([16,UInt8(app.packageName.utf8.count)]);expectedStart.append(Data(app.packageName.utf8))
        try await wait("canonical startup control message") {(try? Data(contentsOf:marker("controls"))) == expectedStart}
        try input(preview.video)
        try await Task.sleep(for:.milliseconds(150))
        let preframe=try Data(contentsOf:marker("controls"))
        try require(preframe==expectedStart,"Loading window routed user input beyond the canonical app-launch control packet")
        try require(window.isMiniaturized,"Startup lost deliberate minimize before releasing first frame")
        try Data().write(to:marker("allow-frame"))
        try await wait("actual decoded initial black frame") {attached.metrics.frames>0}
        try require(preview.video.frameImage == nil && preview.window === window,"Black first frame erased/replaced the loading preview")
        try require(preview.video.accessibilityLabel()?.hasPrefix("Loading ")==true,"Held black frame lost loading accessibility state")
        try input(preview.video)
        try await Task.sleep(for:.milliseconds(150))
        let heldBlackControl=try Data(contentsOf:marker("controls"))
        try require(heldBlackControl==expectedStart,"Held black loading preview leaked user input")
        try capture(preview.video,output.appendingPathComponent("black-held.png"))
        try Data().write(to:marker("allow-visible"))
        try await wait("visible red frame") {preview.video.frameImage != nil}
        guard let session=await start.value else {throw BridgeError.message("Native session was not admitted")}
        try require(session === attached && session.state == .running && session.metrics.frames>0,"Production transport/decoder did not deliver real first frame")
        try require(launcher.hosts[session.descriptor.id] === preview && preview.window === window && window.windowNumber==initialNumber,"First frame replaced loading window")
        try require(preview.video.frameImage?.width==64 && preview.video.frameImage?.height==64,"Fixture decoded unexpected image size")
        try require(window.isMiniaturized,"First decoded frame reversed a deliberate startup minimize")
        try capture(preview.video,output.appendingPathComponent("decoded.png"))
        let stableIDs=Set(launcher.sessions.keys)
        window.orderOut(nil);launcher.reopen()
        try require(window.isVisible && !window.isMiniaturized && Set(launcher.sessions.keys)==stableIDs,"Running Reopen replaced or duplicated session")
        try input(preview.video)
        try await wait("post-frame control routing") {(try? Data(contentsOf:marker("controls")))?.range(of:ScrcpyControl.encode(.text("LaunchUxQa"))) != nil}
        results.append(["case":"same_window_real_first_frame_input_fence","passed":true,"window_number":window.windowNumber,"decoded_frames":session.metrics.frames,"preframe_user_input_bytes":preframe.count-expectedStart.count,"deliberate_minimize_preserved_until_reopen":true,"decoded_black_held_before_visible_video":true,"canonical_startup_control_bytes":expectedStart.count,"postframe_control_bytes":try Data(contentsOf:marker("controls")).count])
        for source in [session.logURL,session.logURL.appendingPathExtension("jsonl")] {let target=output.appendingPathComponent("decoded-session."+source.pathExtension);try? FileManager.default.removeItem(at:target);try FileManager.default.copyItem(at:source,to:target)}
        await launcher.shutdownAndWait();window.close();launcher.window?.close()

        try "delayed-readiness".write(to:mode,atomically:true,encoding:.utf8)
        let delayed=LauncherController();try require(delayed.prepareWrapperLaunch(),"Missing delayed preview")
        let pending=Task {await delayed.launch(device:device,app:app,configuration:SessionConfiguration())}
        try await wait("delayed readiness") {FileManager.default.fileExists(atPath:marker("readiness").path)}
        delayed.launchPreview!.window!.performClose(nil)
        let denied=await pending.value
        try require(denied==nil && delayed.sessions.isEmpty && delayed.hosts.isEmpty && delayed.launchPreview==nil && delayed.wrapperLaunchCancelled,"Closed preview resurrected after readiness")
        await delayed.launchArgumentsIfNeeded()
        let deniedAgain=await delayed.launch(device:device,app:app,configuration:SessionConfiguration(),readinessChecked:true)
        try require(deniedAgain==nil && delayed.sessions.isEmpty,"Closed wrapper admitted a later entry-point launch")
        await delayed.shutdownAndWait();delayed.window?.close()
        results.append(["case":"close_during_delayed_admission_is_terminal","passed":true])

        // Close after attachment but before a decoded frame: a late frame or
        // startup completion must not recreate a window/session/error panel.
        try await Task.sleep(for:.milliseconds(250))
        for suffix in ["handshake","allow-frame","allow-visible","black-sent","port","controls"] {try? FileManager.default.removeItem(at:marker(suffix))}
        try "native-present".write(to:mode,atomically:true,encoding:.utf8)
        let closing=LauncherController();closing.processedArguments=true;try require(closing.prepareWrapperLaunch(),"Missing attached-close preview")
        let late=Task {await closing.launch(device:device,app:app,configuration:SessionConfiguration(),readinessChecked:true)}
        try await wait("attached startup") {FileManager.default.fileExists(atPath:marker("handshake").path)}
        let closingHost=closing.hosts.values.first!,closingWindow=closingHost.window!,closed=closingHost.session!
        closingWindow.performClose(nil);try Data().write(to:marker("allow-frame"));_=await late.value
        try await Task.sleep(for:.milliseconds(250))
        try require(closing.sessions.isEmpty && closing.hosts.isEmpty && !closingWindow.isVisible && closed.metrics.frames==0,"Late startup/frame resurrected closed native host")
        await closing.shutdownAndWait();closing.window?.close()
        results.append(["case":"close_after_attach_before_first_frame_is_terminal","passed":true])
        // Dark/sparse real apps must have an explicit escape from the startup
        // blank heuristic. Exercise the shipping button after the real timer.
        for suffix in ["handshake","allow-frame","allow-visible","black-sent","port","controls"] {try? FileManager.default.removeItem(at:marker(suffix))}
        let dark=LauncherController();dark.processedArguments=true;try require(dark.prepareWrapperLaunch(),"Missing dark preview")
        let darkWindow=dark.launchPreview!.window!
        darkWindow.setContentSize(NSSize(width:240,height:208))
        let darkStart=Task {await dark.launch(device:device,app:app,configuration:SessionConfiguration(),readinessChecked:true)}
        try await wait("dark handshake") {FileManager.default.fileExists(atPath:marker("handshake").path)}
        try Data().write(to:marker("allow-frame"))
        _=await darkStart.value
        guard let darkHost=dark.hosts.values.first else {throw BridgeError.message("Missing admitted dark host")}
        try await wait("five-second blank diagnostic/reveal button") {darkHost.video.canRevealVideo && !darkHost.video.revealVideoButton.isHidden}
        try require(darkHost.video.frameImage==nil && darkHost.video.statusMessage?.contains("blank")==true,"Blank timeout did not retain explanatory splash")
        try capture(darkHost.video,output.appendingPathComponent("blank-notice-minimum.png"))
        let controlsBefore=try Data(contentsOf:marker("controls"))
        try input(darkHost.video);try await Task.sleep(for:.milliseconds(100))
        let afterBlockedInput=try Data(contentsOf:marker("controls"))
        try require(afterBlockedInput==controlsBefore,"Blank notice leaked covered user input")
        darkHost.video.revealVideoButton.performClick(nil)
        try require(darkHost.window === darkWindow && darkHost.video.frameImage != nil && darkHost.video.statusMessage==nil && darkHost.video.acceptsAndroidInput,"Public reveal action did not expose same actual frame/enable input")
        try input(darkHost.video)
        try await wait("manual reveal enables text routing") {(try? Data(contentsOf:marker("controls")))?.range(of:ScrcpyControl.encode(.text("LaunchUxQa"))) != nil}
        try Data().write(to:marker("allow-visible"))
        try await wait("visible recovery after manual reveal") {darkHost.session.metrics.frames>=2}
        try require(darkHost.video.canRevealVideo==false && darkHost.window === darkWindow,"Later visible frame retained stale reveal overlay or changed window")
        await dark.shutdownAndWait();darkWindow.close();dark.window?.close()
        results.append(["case":"prolonged_black_notice_public_reveal_and_recovery","passed":true,"same_window":true])
        try JSONSerialization.data(withJSONObject:["passed":true,"cases":results,"actual_android_device":false,"physical_os_focus_verified":false,"shipping_ui_sources":true,"real_h264_decoder_fixture":true],options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("results.json"))
    }
}
