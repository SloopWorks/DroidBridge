import AppKit
import Foundation
import DroidBridgeCore
import DroidBridgeStreaming

/// Shipping AppKit composition, deterministic catalogs and inert session objects.
/// Explicit false tools prohibit Android access. This is not physical focus proof.
@MainActor final class QAMenuContextWindow:NSWindow {
    var fixtureKey=false
    override var isKeyWindow:Bool {fixtureKey}
}
@main struct VerifyLauncherRedesign {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.finishLaunching()
        Task { @MainActor in
            do { try await run(); print("PASS: launcher redesign layout, search, control wiring and scroll reachability"); fflush(stdout); exit(0) }
            catch { fputs("FAIL: launcher redesign \(error)\n",stderr); exit(1) }
        }
        NSApplication.shared.run()
    }
    @MainActor static func require(_ condition:Bool,_ message:String) throws {
        guard condition else {throw BridgeError.message(message)}
    }
    @MainActor static func descendants(_ view:NSView)->[NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor static func capture(_ view:NSView,_ url:URL) throws {
        view.layoutSubtreeIfNeeded()
        for child in descendants(view) {child.needsDisplay=true}
        view.displayIfNeeded()
        guard let bitmap=view.bitmapImageRepForCachingDisplay(in:view.bounds) else {throw BridgeError.message("Cannot capture AppKit view")}
        view.cacheDisplay(in:view.bounds,to:bitmap)
        guard let png=bitmap.representation(using:.png,properties:[:]) else {throw BridgeError.message("Cannot encode AppKit view")}
        try png.write(to:url)
    }
    @MainActor static func run() async throws {
        let output=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("verification/launcher-redesign/qa")
        let launcher=LauncherController(),window=launcher.window!,content=launcher.window!.contentView!
        launcher.onboardingPending=true // Never launch icon fixture work while rendering 1000 rows.
        launcher.timer?.invalidate();launcher.pending=[]
        window.orderFrontRegardless()
        let d=AndroidDevice(serial:"qa-layout-only",model:"QA Device With A Long Readable Name")
        launcher.devices=[d,AndroidDevice(serial:"qa-unauthorized",model:"Unauthorized fixture",state:"unauthorized")]
        launcher.devicePicker.removeAllItems();launcher.devicePicker.addItems(withTitles:[d.model,"Unauthorized fixture"]);launcher.devicePicker.selectItem(at:0)
        launcher.readySerials=[d.serial];launcher.appsDeviceSerial=d.serial
        launcher.applications=(0..<1000).map {AndroidApplication(packageName:"dev.droidbridge.fixture.app\($0)",name:$0 == 17 ? "Distinct Search Label" : "Android Application \($0)")}
        launcher.filterApps()
        try require(launcher.filtered.count==1000 && launcher.table.numberOfRows==1000,"1000-app catalog not represented")
        launcher.search.stringValue="dIsTiNcT sEaRcH";launcher.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:launcher.search))
        try require(launcher.filtered.count==1 && launcher.filtered.first?.packageName=="dev.droidbridge.fixture.app17","Case-insensitive label search regressed")
        launcher.search.stringValue="dev.droidbridge.fixture.app42";launcher.filterApps()
        try require(!launcher.filtered.isEmpty && launcher.filtered.allSatisfy {$0.packageName.contains("app42")},"Package-name search regressed")
        launcher.search.stringValue="no-match-qa";launcher.filterApps()
        try require(launcher.filtered.isEmpty && launcher.selectedApp == nil,"No-match query retained a launch selection")
        launcher.search.stringValue="";launcher.filterApps();launcher.table.selectRowIndexes(IndexSet(integer:17),byExtendingSelection:false)
        launcher.backendPicker.selectItem(at:1)
        let selection=launcher.selectedApp!.packageName
        var ownedLogs:[URL]=[]
        defer {for url in ownedLogs {try? FileManager.default.removeItem(at:url)};window.orderOut(nil)}
        for i in 0..<40 {
            let descriptor=SessionDescriptor(device:d,application:AndroidApplication(packageName:"dev.droidbridge.session.app\(i)",name:i == 0 ? String(repeating:"Long Android App Name ",count:12) : "Session \(i)"),configuration:SessionConfiguration(backend:i%2 == 0 ? .native : .scrcpy))
            let session=BridgeSession(descriptor:descriptor,toolchain:launcher.toolchain)
            launcher.sessions[descriptor.id]=session;launcher.sessionStates[descriptor.id]=i%3 == 0 ? "disconnected" : "starting"
            ownedLogs += [session.logURL,URL(fileURLWithPath:session.logURL.path+".jsonl")]
        }
        launcher.updateSessions()
        launcher.onboardingStatus.stringValue=String(repeating:"Long app progress and warning summary. ",count:50)
        launcher.status.stringValue=String(repeating:"Connection diagnostic must stay bounded. ",count:20)
        let wired:[(String,NSControl,Selector)]=[
            ("device",launcher.devicePicker,#selector(LauncherController.deviceChanged)),
            ("phone",launcher.phoneScreenPreference,#selector(LauncherController.phoneScreenPreferenceChanged(_:))),
            ("bulk",launcher.bulkPreference,#selector(LauncherController.sharedPreferenceChanged(_:))),
            ("decorations",launcher.decorationsPreference,#selector(LauncherController.sharedPreferenceChanged(_:))),
            ("onboard",launcher.onboardingButton,#selector(LauncherController.onboardDeviceApps)),
            ("cancel",launcher.onboardingCancel,#selector(LauncherController.cancelOnboarding))]
        for (name,control,action) in wired {try require(control.target === launcher && control.action==action,"Target/action disconnected: \(name)")}
        let expectedSelectors=["launchAction","refreshAction","createWrapper","restoreAction","openDiagnostics","showOnboardingDetails"]
        let buttons=descendants(content).compactMap {$0 as? NSButton}
        for action in expectedSelectors {try require(buttons.contains {$0.action==NSSelectorFromString(action) && $0.target === launcher},"Missing workflow button: \(action)")}
        guard let ui=launcher.launcherUI else {throw BridgeError.message("Missing launcher composition")}
        launcher.updateLauncherPresentation()
        try require(ui.launch.isEnabled && window.defaultButtonCell == nil && ui.launch.keyEquivalent.isEmpty,"Ready action/default Return policy incorrect")
        launcher.filterApps()
        try require(launcher.selectedApp?.packageName==selection,"Unchanged filter lost selected app identity")
        launcher.readySerials=[];launcher.updateLauncherPresentation()
        try require(!ui.launch.isEnabled && !ui.create.isEnabled,"Booting device permits launch/create")
        let noSessionIDs=Set(launcher.sessions.keys)
        let enter=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        launcher.table.keyDown(with:enter)
        try require(launcher.control(launcher.search,textView:NSTextView(),doCommandBy:#selector(NSResponder.insertNewline(_:))),"Search Return no longer handled")
        try require(!launcher.control(launcher.backendPicker,textView:NSTextView(),doCommandBy:#selector(NSResponder.insertNewline(_:))),"Sidebar Return captured app launch handler")
        try require(!window.performKeyEquivalent(with:enter),"Global Return launches from unrelated focus context")
        try await Task.sleep(for:.milliseconds(30))
        try require(Set(launcher.sessions.keys)==noSessionIDs,"Return admitted session while not ready")
        launcher.readySerials=[d.serial];launcher.appsDeviceSerial="different-device";launcher.updateLauncherPresentation()
        try require(!ui.launch.isEnabled,"Stale other-device catalog permits launch")
        launcher.appsDeviceSerial=d.serial
        let catalog=launcher.applications
        launcher.applications=[];launcher.filterApps();launcher.devicePicker.selectItem(at:1);launcher.updateLauncherPresentation()
        try require(!ui.launch.isEnabled && ui.emptyTitle.stringValue.contains("Authorize"),"Unauthorized state missing truthful action guidance")
        try require(!ui.count.stringValue.contains("0 of 0"),"Unavailable discovery reported as zero installed applications")
        launcher.devicePicker.selectItem(at:0);launcher.appsDeviceSerial=nil;launcher.updateLauncherPresentation()
        try require(ui.emptyTitle.stringValue.localizedCaseInsensitiveContains("loading") || ui.emptyTitle.stringValue.localizedCaseInsensitiveContains("reading"),"Unloaded ready catalog misrepresented as empty completion")
        launcher.appsError=(d.serial,String(repeating:"Explicit app discovery failure. ",count:30));launcher.updateLauncherPresentation()
        try require(ui.emptyTitle.stringValue.contains("load applications") && ui.count.stringValue.contains("unavailable"),"Discovery failure incorrectly appears as loading/empty success")
        try require(ui.emptyDetail.toolTip==launcher.appsError?.message,"Discovery failure lost complete diagnostic detail")
        launcher.appsError=nil
        launcher.devices=[];launcher.devicePicker.removeAllItems();launcher.updateLauncherPresentation()
        try require(!ui.launch.isEnabled && ui.emptyTitle.stringValue.contains("Connect"),"Missing-device state lost setup guidance")
        launcher.devices=[d,AndroidDevice(serial:"qa-unauthorized",model:"Unauthorized fixture",state:"unauthorized")]
        launcher.devicePicker.addItems(withTitles:[d.model,"Unauthorized fixture"]);launcher.devicePicker.selectItem(at:0)
        launcher.applications=catalog;launcher.appsDeviceSerial=d.serial;launcher.filterApps();launcher.table.selectRowIndexes(IndexSet(integer:17),byExtendingSelection:false)
        let oldBulk=launcher.sharedPreferences.bulkWrapperOnboardingEnabled
        launcher.onboardingPending=false;launcher.sharedPreferences.bulkWrapperOnboardingEnabled=true;launcher.updateLauncherPresentation()
        try require(launcher.canOnboardSelectedDevice && launcher.onboardingButton.isEnabled,"Ready full catalog cannot onboard")
        launcher.sharedPreferences.bulkWrapperOnboardingEnabled=false;launcher.updateLauncherPresentation()
        try require(!launcher.canOnboardSelectedDevice && !launcher.onboardingButton.isEnabled,"Feature-off still permits onboarding")
        launcher.sharedPreferences.bulkWrapperOnboardingEnabled=oldBulk;launcher.onboardingPending=true;launcher.updateLauncherPresentation()
        launcher.focusAppSearch()
        try require(window.firstResponder === launcher.search || (window.firstResponder as? NSTextView)?.delegate === launcher.search,"Search-focus action does not focus search")
        let details=buttons.first {$0.action==#selector(LauncherController.showOnboardingDetails)}!
        details.performClick(nil)
        try await Task.sleep(for:.milliseconds(60))
        try require(window.attachedSheet != nil,"Details action did not open its real AppKit sheet")
        if let sheet=window.attachedSheet {window.endSheet(sheet);sheet.orderOut(nil)}
        let controls:[(String,NSView)]=[("device",launcher.devicePicker),("backend",launcher.backendPicker),("search",launcher.search),("applications",launcher.table.enclosingScrollView!),("sessions",launcher.sessionList.enclosingScrollView!),("phone",launcher.phoneScreenPreference),("bulk",launcher.bulkPreference),("decorations",launcher.decorationsPreference),("onboard",launcher.onboardingButton),("cancel",launcher.onboardingCancel),("onboarding_status",launcher.onboardingStatus),("status",launcher.status)]
        var cases:[[String:Any]]=[]
        for appearance in [NSAppearance.Name.aqua,.darkAqua] {
            window.appearance=NSAppearance(named:appearance)
            for size in [NSSize(width:1160,height:780),NSSize(width:920,height:640)] {
                window.setContentSize(size);content.layoutSubtreeIfNeeded();try await Task.sleep(for:.milliseconds(80))
                let tag="\(appearance.rawValue)-\(Int(size.width))x\(Int(size.height))"
                try require(launcher.selectedDevice?.serial==d.serial && launcher.backend == .scrcpy && launcher.selectedApp?.packageName==selection,"Layout rebuild changed selection/backend/device")
                var frames:[[String:Any]]=[]
                for (name,view) in controls {
                    view.scrollToVisible(view.bounds);content.layoutSubtreeIfNeeded()
                    let frame=view.convert(view.bounds,to:content),visible=view.visibleRect
                    frames.append(["name":name,"frame":[frame.minX,frame.minY,frame.width,frame.height],"visible_rect":[visible.minX,visible.minY,visible.width,visible.height],"hidden":view.isHiddenOrHasHiddenAncestor])
                    try require(!view.isHiddenOrHasHiddenAncestor,"Essential control hidden: \(tag) \(name)")
                    try require(frame.width>0 && frame.height>0 && visible.width>0 && visible.height>0,"Essential control unreachable: \(tag) \(name) \(frame)")
                    try require(frame.minX >= -1 && frame.maxX<=content.bounds.maxX+1,"Horizontal clipping: \(tag) \(name) \(frame)")
                }
                var reachedButtons=0
                for button in descendants(content).compactMap({$0 as? NSButton}) where !button.isHiddenOrHasHiddenAncestor {
                    button.scrollToVisible(button.bounds);content.layoutSubtreeIfNeeded()
                    let frame=button.convert(button.bounds,to:content)
                    try require(frame.width>0 && button.visibleRect.width>0 && button.visibleRect.height>0,"Unreachable button: \(tag) \(button.title)")
                    try require(frame.minX >= -1 && frame.maxX<=content.bounds.maxX+1,"Button clipped horizontally: \(tag) \(button.title) \(frame)")
                    reachedButtons += 1
                }
                try capture(content,output.appendingPathComponent(tag+"-scrolled.png"))
                for scroll in descendants(content).compactMap({$0 as? NSScrollView}) {scroll.documentView?.scrollToVisible(NSRect(x:0,y:0,width:1,height:1))}
                try capture(content,output.appendingPathComponent(tag+".png"))
                cases.append(["appearance":appearance.rawValue,"content_size":[size.width,size.height],"reachable_buttons":reachedButtons,"frames":frames])
            }
        }
        let sessionScroll=launcher.sessionList.enclosingScrollView!
        launcher.sessionList.scrollToVisible(NSRect(x:0,y:max(0,launcher.sessionList.bounds.height-1),width:1,height:1))
        try require(launcher.sessionList.frame.height>sessionScroll.contentView.bounds.height,"40-session list cannot scroll")
        try require(launcher.devicePicker.accessibilityLabel()?.isEmpty==false && launcher.search.accessibilityLabel()?.isEmpty==false && launcher.table.accessibilityLabel()?.isEmpty==false,"Core accessibility label missing")
        let existingCards=launcher.sessionList.arrangedSubviews
        let focusButton=descendants(existingCards[0]).compactMap {$0 as? NSButton}.first {$0.isEnabled}!
        window.makeFirstResponder(focusButton)
        let responder=window.firstResponder
        launcher.updateSessions()
        try require(zip(existingCards,launcher.sessionList.arrangedSubviews).allSatisfy {$0 === $1},"Unchanged session refresh recreated recovery controls")
        try require(window.firstResponder === responder,"Unchanged session refresh destroyed keyboard focus")
        let delegate=AppDelegate();delegate.launcher=launcher
        let findItem=NSMenuItem(title:"Find App…",action:#selector(AppDelegate.findApp),keyEquivalent:"f")
        // Locked WindowServer cannot grant key status to this test process.
        // Inject only the public key-state predicate; execute the actual delegate.
        let menuWindow=QAMenuContextWindow(contentRect:.zero,styleMask:.titled,backing:.buffered,defer:false)
        launcher.window=menuWindow;menuWindow.fixtureKey=true
        try require(delegate.validateMenuItem(findItem),"Find shortcut disabled for launcher key predicate")
        menuWindow.fixtureKey=false
        try require(!delegate.validateMenuItem(findItem),"Find shortcut captures non-launcher key context")
        let unchangedResponder=window.firstResponder
        delegate.findApp()
        try require(launcher.window === menuWindow && window.firstResponder === unchangedResponder,"Find action bypassed its context guard")
        launcher.window=window
        let appOffset=launcher.table.enclosingScrollView!.contentView.bounds.origin
        let sessionOffset=sessionScroll.contentView.bounds.origin
        launcher.updateSessions();launcher.updateLauncherPresentation();content.layoutSubtreeIfNeeded()
        try require(abs(sessionScroll.contentView.bounds.origin.y-sessionOffset.y)<1,"Session refresh resets recovery scroll position")
        try require(abs(launcher.table.enclosingScrollView!.contentView.bounds.origin.y-appOffset.y)<1,"Presentation refresh resets application scroll position")
        try require(launcher.selectedApp?.packageName==selection,"Session refresh resets selected app")
        let restored=SessionDescriptor(device:d,application:AndroidApplication(packageName:"dev.droidbridge.restoreqa",name:"Restore QA"),configuration:SessionConfiguration(backend:.native,showSystemDecorations:false))
        launcher.pending=[restored];launcher.updateLauncherPresentation()
        try require(ui.restore.isEnabled,"Saved-session restore action not enabled")
        ui.restore.performClick(nil)
        if let task=launcher.restoreTask {await task.value}
        try require(launcher.pending.map(\.id)==[restored.id] && Set(launcher.sessions.keys)==noSessionIDs,"Unavailable Restore removed saved intent or admitted a duplicate")
        let firstID=launcher.sessions.sorted { $0.value.descriptor.application.name.localizedStandardCompare($1.value.descriptor.application.name) == .orderedAscending }.first!.key
        let close=descendants(launcher.sessionList.arrangedSubviews.first!).compactMap {$0 as? NSButton}.first {$0.title=="Close"}!
        close.performClick(nil)
        for _ in 0..<50 {if launcher.retiring.isEmpty {break};try await Task.sleep(for:.milliseconds(10))}
        try require(launcher.sessions[firstID]==nil && launcher.sessions.count==39 && launcher.retiring.isEmpty,"Session Close removed wrong row or failed cleanup")
        var selectionDrained=Set<UUID>()
        for index in 0..<2 {
            let id=UUID()
            let task=Task { @MainActor in
                defer {launcher.deviceSelectionTasks.removeValue(forKey:id)}
                // Model detached, bounded ProcessRunner I/O that does not stop
                // merely because its publication task has been canceled.
                await Task.detached {try? await Task.sleep(for:.milliseconds(index == 0 ? 180 : 120))}.value
                selectionDrained.insert(id)
            }
            launcher.deviceSelectionTasks[id]=task
            if index==0 {task.cancel()}
        }
        await launcher.shutdownAndWait()
        try require(selectionDrained.count==2 && launcher.deviceSelectionTasks.isEmpty,"Shutdown failed to drain superseded and current selection I/O")
        let result:[String:Any]=["passed":true,"scope":"shipping AppKit no-device catalog/layout/control-wiring fixture","physical_focus_verified":false,"actual_android_launch_verified":false,"application_fixture_count":1000,"session_fixture_count":40,"restore_unavailable_preserves_intent":true,"exact_close_action":true,"unchanged_session_controls_preserved":true,"find_menu_context_predicate_guard":true,"menu_key_state_fixture":true,"superseded_selection_task_shutdown_drained":true,"typed_discovery_error_verified":true,"onboarding_admission_readiness_verified":true,"cases":cases]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("results.json"))
    }
}
