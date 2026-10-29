import AppKit
import Foundation

@main struct OnboardingUILayoutQA {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fputs("FAIL UI: \(error)\n",stderr); exit(1) }
        }
        NSApplication.shared.run()
    }
    @MainActor static func run() async throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("verification/screen-off/qa")
        let launcher=LauncherController();let window=launcher.window!;window.orderFrontRegardless()
        launcher.onboardingStatus.stringValue="481/1000 · 475 added · 4 current · 0 running/skipped · 2 errors. Working: Android Settings, A very long application name to test progress readability."
        launcher.status.stringValue="1000 launchable apps · Authorized test device · Video remains on this Mac."
        var results:[[String:Any]]=[]
        for index in 0..<3 {
            let minimum = index != 0
            if index == 2 { launcher.onboardingStatus.stringValue = String(repeating:"A very long Android app / failure summary; ",count:50) }
            if minimum { window.setFrame(NSRect(origin:window.frame.origin,size:NSSize(width:900,height:720)),display:true) }
            else { window.setContentSize(NSSize(width:1000,height:800)) }
            try await Task.sleep(nanoseconds:150_000_000)
            let content=window.contentView!;content.layoutSubtreeIfNeeded();content.displayIfNeeded()
            let controls:[(String,NSView)]=[("device",launcher.devicePicker),("backend",launcher.backendPicker),("search",launcher.search),("app_table",launcher.table.enclosingScrollView!),("phone_screen",launcher.phoneScreenPreference),("bulk_flag",launcher.bulkPreference),("decorations_flag",launcher.decorationsPreference),("add_all",launcher.onboardingButton),("cancel",launcher.onboardingCancel),("progress",launcher.onboardingProgress),("progress_status",launcher.onboardingStatus),("reconnect",launcher.reconnect),("sessions",launcher.sessionList.enclosingScrollView!),("footer_status",launcher.status)]
            var rows:[[String:Any]]=[]
            for (name,view) in controls {
                let f=view.convert(view.bounds,to:content)
                rows.append(["name":name,"frame":[f.origin.x,f.origin.y,f.width,f.height],"within_content":content.bounds.insetBy(dx:-1,dy:-1).contains(f),"hidden":view.isHiddenOrHasHiddenAncestor])
            }
            let name=index == 2 ? "ui-minimum-long-status" : (minimum ? "ui-minimum-frame900x720" : "ui-default-content1000x800")
            guard let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) else { throw NSError(domain:"UIBitmap",code:1) }
            content.cacheDisplay(in:content.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent(name+".png"))
            results.append(["name":name,"window_frame":[window.frame.width,window.frame.height],"content_size":[content.bounds.width,content.bounds.height],"rows":rows])
        }
        try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("ui-layout.json"))
        window.close();print("Captured shipping AppKit launcher layout and control bounds")
    }
}
