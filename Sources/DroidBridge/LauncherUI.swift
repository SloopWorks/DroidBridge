import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

/// Presentation only. Reuses the controller's discovery, preferences and session
/// actions; layout refreshes never perform device, catalog or filesystem work.
@MainActor final class LauncherUI {
    weak var controller: LauncherController?
    let sidebarScroll=NSScrollView(), appsScroll=NSScrollView(), sessionsScroll=NSScrollView()
    let count=NSTextField(labelWithString:""),connection=NSTextField(wrappingLabelWithString:"")
    let selectedName=NSTextField(labelWithString:"Select an app"),selectedPackage=NSTextField(labelWithString:"")
    let selectedIcon=NSImageView(), sessionCount=NSTextField(labelWithString:"")
    let launch=NSButton(title:"Launch App",target:nil,action:nil)
    let create=NSButton(title:"Create / Update Mac App…",target:nil,action:nil)
    let restore=NSButton(title:"Restore Previous Sessions",target:nil,action:nil)
    let empty=NSStackView(), emptyTitle=NSTextField(labelWithString:""),emptyDetail=NSTextField(wrappingLabelWithString:"")
    let emptyAction=NSButton(title:"Refresh Devices",target:nil,action:nil)
    let root=LauncherBackground()
    init(controller:LauncherController) {self.controller=controller}
    static func label(_ text:String,size:CGFloat=12,weight:NSFont.Weight = .regular,secondary:Bool=false)->NSTextField {
        let label=NSTextField(wrappingLabelWithString:text);label.font = .systemFont(ofSize:size,weight:weight)
        label.textColor=secondary ? .secondaryLabelColor : .labelColor
        label.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        return label
    }
    static func column(_ views:[NSView],spacing:CGFloat=10)->NSStackView {
        let stack=NSStackView(views:views);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=spacing
        stack.translatesAutoresizingMaskIntoConstraints=false
        for view in views {view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
        return stack
    }
    static func pin(_ view:NSView,in parent:NSView,inset:CGFloat=0) {
        view.translatesAutoresizingMaskIntoConstraints=false;parent.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:parent.leadingAnchor,constant:inset),view.trailingAnchor.constraint(equalTo:parent.trailingAnchor,constant:-inset),view.topAnchor.constraint(equalTo:parent.topAnchor,constant:inset),view.bottomAnchor.constraint(equalTo:parent.bottomAnchor,constant:-inset)])
    }
    static func document(_ view:NSView,in scroll:NSScrollView,padding:CGFloat=0) {
        let document=LauncherDocumentView();document.translatesAutoresizingMaskIntoConstraints=false
        scroll.documentView=document;scroll.hasVerticalScroller=true;scroll.autohidesScrollers=true;scroll.drawsBackground=false
        pin(view,in:document,inset:padding)
        document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor).isActive=true
    }
    static func card(_ content:NSView)->NSView {let card=LauncherSurface();pin(content,in:card,inset:14);return card}
    static func group(_ title:String,_ views:[NSView])->NSView {
        let heading=label(title,size:11,weight:.semibold,secondary:true)
        return column([heading,card(column(views,spacing:10))],spacing:8)
    }
    static func wrapCheckbox(_ button:NSButton,height:CGFloat=38) {
        button.cell?.wraps=true;button.cell?.isScrollable=false;button.cell?.usesSingleLineMode=false;button.cell?.lineBreakMode = .byWordWrapping
        button.font = .systemFont(ofSize:12);button.heightAnchor.constraint(greaterThanOrEqualToConstant:height).isActive=true
        button.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
    }
    func build() {
        guard let c=controller,let content=c.window?.contentView else {return}
        Self.pin(root,in:content)
        let sidebar=NSVisualEffectView();sidebar.material = .sidebar;sidebar.blendingMode = .behindWindow;sidebar.state = .followsWindowActiveState
        sidebar.identifier=NSUserInterfaceItemIdentifier("launcher.sidebar")
        sidebar.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(sidebar)
        let workspace=LauncherBackground();workspace.identifier=NSUserInterfaceItemIdentifier("launcher.workspace");workspace.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(workspace)
        NSLayoutConstraint.activate([sidebar.leadingAnchor.constraint(equalTo:root.leadingAnchor),sidebar.topAnchor.constraint(equalTo:root.topAnchor),sidebar.bottomAnchor.constraint(equalTo:root.bottomAnchor),sidebar.widthAnchor.constraint(equalToConstant:240),workspace.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor),workspace.trailingAnchor.constraint(equalTo:root.trailingAnchor),workspace.topAnchor.constraint(equalTo:root.topAnchor),workspace.bottomAnchor.constraint(equalTo:root.bottomAnchor)])
        Self.pin(sidebarScroll,in:sidebar)
        let branding=Self.column([Self.label("DroidBridge",size:21,weight:.bold),Self.label("Android apps on your Mac",size:11,secondary:true)],spacing:4)
        c.devicePicker.target=c;c.devicePicker.action=#selector(c.deviceChanged);c.devicePicker.setAccessibilityLabel("Android device")
        c.devicePicker.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        connection.font = .systemFont(ofSize:11);connection.maximumNumberOfLines=3;connection.textColor = .secondaryLabelColor
        let refresh=c.button("Refresh Devices",#selector(c.refreshAction));refresh.image=NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:nil);refresh.imagePosition = .imageLeading
        c.backendPicker.addItems(withTitles:["Native AppKit","scrcpy fallback"]);c.backendPicker.setAccessibilityLabel("Rendering backend")
        for button in [c.bulkPreference,c.decorationsPreference] {button.target=c;button.action=#selector(c.sharedPreferenceChanged(_:))}
        c.bulkPreference.state=c.sharedPreferences.bulkWrapperOnboardingEnabled ? .on : .off
        c.decorationsPreference.state=c.sharedPreferences.showAndroidSystemDecorations ? .on : .off
        c.phoneScreenPreference.target=c;c.phoneScreenPreference.action=#selector(c.phoneScreenPreferenceChanged(_:));c.phoneScreenPreference.isEnabled=false
        c.phoneScreenPreference.toolTip="Applies to the selected device during Mac sessions. Use the Phone menu to turn its screen back on."
        c.decorationsPreference.toolTip="Applies to new Android app windows; app-drawn controls are unchanged. The Android software keyboard stays hidden."
        c.reconnect.state = .on
        for button in [c.phoneScreenPreference,c.decorationsPreference,c.bulkPreference,c.reconnect] {Self.wrapCheckbox(button)}
        Self.wrapCheckbox(c.reconnect,height:48)
        c.onboardingButton.target=c;c.onboardingButton.action=#selector(c.onboardDeviceApps);c.onboardingButton.isEnabled=c.sharedPreferences.bulkWrapperOnboardingEnabled
        c.onboardingButton.title="Add Device Apps…";c.onboardingButton.setAccessibilityLabel("Add All Device Apps to Spotlight");c.onboardingButton.toolTip="Add all launchable apps from the selected device to Spotlight";c.onboardingButton.bezelStyle = .rounded;c.onboardingButton.font = .systemFont(ofSize:12);c.onboardingButton.cell?.wraps=true;c.onboardingButton.cell?.usesSingleLineMode=false;c.onboardingButton.heightAnchor.constraint(equalToConstant:44).isActive=true;c.onboardingButton.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        c.onboardingCancel.target=c;c.onboardingCancel.action=#selector(c.cancelOnboarding);c.onboardingCancel.isEnabled=false;c.onboardingCancel.bezelStyle = .rounded
        let details=c.button("Details…",#selector(c.showOnboardingDetails));details.setAccessibilityLabel("Onboarding Details")
        let onboardingActions=NSStackView(views:[c.onboardingCancel,details]);onboardingActions.distribution = .fillEqually;onboardingActions.spacing=8
        c.onboardingProgress.isIndeterminate=false;c.onboardingProgress.minValue=0;c.onboardingProgress.maxValue=1;c.onboardingProgress.setAccessibilityLabel("Spotlight setup progress")
        c.onboardingStatus.font = .systemFont(ofSize:11);c.onboardingStatus.textColor = .secondaryLabelColor;c.onboardingStatus.maximumNumberOfLines=4;c.onboardingStatus.lineBreakMode = .byTruncatingTail;c.onboardingStatus.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        c.audioRoutePicker.addItems(withTitles:["Mac","Phone","Mac + Phone"])
        for (index,route) in [DeviceAudioRoute.mac,.phone,.macAndPhone].enumerated() {c.audioRoutePicker.item(at:index)?.representedObject=route.rawValue}
        c.audioRoutePicker.autoenablesItems=false;c.audioRoutePicker.setAccessibilityLabel("Device audio route")
        c.audioRoutePicker.target=c;c.audioRoutePicker.action=#selector(c.audioRouteChanged(_:))
        c.audioRoutePicker.toolTip="Device-wide audio: Mac silences phone playback; Mac + Phone depends on the Android app allowing capture."
        c.audioStatus.font = .systemFont(ofSize:11);c.audioStatus.textColor = .secondaryLabelColor;c.audioStatus.maximumNumberOfLines=5;c.audioStatus.lineBreakMode = .byWordWrapping;c.audioStatus.isSelectable=true
        c.audioStatus.setAccessibilityLabel("Device audio status");c.audioStatus.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        c.audioRetry.bezelStyle = .rounded;c.audioRetry.target=c;c.audioRetry.action=#selector(c.retrySelectedAudio)
        c.audioUsePhone.bezelStyle = .rounded;c.audioUsePhone.target=c;c.audioUsePhone.action=#selector(c.usePhoneAudio)
        let audioActions=NSStackView(views:[c.audioRetry,c.audioUsePhone]);audioActions.spacing=6;audioActions.distribution = .fillEqually
        let audioGroup=Self.group("AUDIO",[c.audioRoutePicker,Self.label("Device-wide Android audio, including apps outside DroidBridge. Mac routing silences phone playback.",size:11,secondary:true),c.audioStatus,audioActions])
        audioGroup.identifier=NSUserInterfaceItemIdentifier("launcher.audio")
        let sidebarContent=Self.column([branding,Self.group("DEVICE",[c.devicePicker,connection,refresh]),Self.group("RENDERING",[c.backendPicker,Self.label("Used for new app windows.",size:11,secondary:true),c.phoneScreenPreference,c.decorationsPreference,c.reconnect]),audioGroup,Self.group("SPOTLIGHT",[c.bulkPreference,Self.label("Add this device’s apps to Spotlight and the Dock. They’re available while the device is connected.",size:11,secondary:true),c.onboardingButton,c.onboardingProgress,c.onboardingStatus,onboardingActions])],spacing:22)
        Self.document(sidebarContent,in:sidebarScroll,padding:16)

        let title=Self.label("Applications",size:25,weight:.bold)
        count.font = .systemFont(ofSize:12);count.textColor = .secondaryLabelColor;count.lineBreakMode = .byTruncatingTail;count.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let header=Self.column([title,count],spacing:4)
        c.search.placeholderString="Search apps or package names";c.search.delegate=c;c.search.setAccessibilityLabel("Search Android apps")
        c.search.sendsSearchStringImmediately=true;c.search.controlSize = .large
        let name=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("name"));name.title="Application";name.width=330;name.minWidth=160
        let package=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("package"));package.title="Android package";package.width=250;package.minWidth=140
        c.table.addTableColumn(name);c.table.addTableColumn(package);c.table.rowHeight=50;c.table.intercellSpacing=NSSize(width:12,height:4);c.table.usesAlternatingRowBackgroundColors=false;c.table.style = .fullWidth;c.table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle;c.table.delegate=c;c.table.dataSource=c;c.table.target=c;c.table.doubleAction=#selector(c.launchAction);c.table.setAccessibilityLabel("Installed Android applications")
        c.table.openSelection={ [weak c] in guard let c,c.canLaunchSelectedApp else {return};c.launchAction() }
        appsScroll.documentView=c.table;appsScroll.hasVerticalScroller=true;appsScroll.autohidesScrollers=true;appsScroll.borderType = .noBorder;appsScroll.drawsBackground=false
        let browser=LauncherSurface();Self.pin(appsScroll,in:browser,inset:1);browser.heightAnchor.constraint(greaterThanOrEqualToConstant:170).isActive=true
        let emptySymbol=NSImageView(image:NSImage(systemSymbolName:"iphone.and.arrow.forward",accessibilityDescription:nil) ?? NSImage());emptySymbol.contentTintColor = .secondaryLabelColor;emptySymbol.widthAnchor.constraint(equalToConstant:44).isActive=true;emptySymbol.heightAnchor.constraint(equalToConstant:44).isActive=true
        emptyTitle.font = .systemFont(ofSize:17,weight:.semibold);emptyTitle.alignment = .center
        emptyDetail.font = .systemFont(ofSize:12);emptyDetail.textColor = .secondaryLabelColor;emptyDetail.alignment = .center;emptyDetail.maximumNumberOfLines=4
        emptyAction.bezelStyle = .rounded;emptyAction.target=c;emptyAction.action=#selector(c.refreshAction)
        empty.orientation = .vertical;empty.alignment = .centerX;empty.spacing=10
        for v in [emptySymbol,emptyTitle,emptyDetail,emptyAction] {empty.addArrangedSubview(v)}
        empty.translatesAutoresizingMaskIntoConstraints=false;browser.addSubview(empty)
        NSLayoutConstraint.activate([empty.centerXAnchor.constraint(equalTo:browser.centerXAnchor),empty.centerYAnchor.constraint(equalTo:browser.centerYAnchor,constant:10),empty.widthAnchor.constraint(lessThanOrEqualTo:browser.widthAnchor,constant:-40),empty.widthAnchor.constraint(lessThanOrEqualToConstant:380),emptyDetail.widthAnchor.constraint(equalTo:empty.widthAnchor)])

        selectedIcon.imageScaling = .scaleProportionallyUpOrDown;selectedIcon.widthAnchor.constraint(equalToConstant:36).isActive=true;selectedIcon.heightAnchor.constraint(equalToConstant:36).isActive=true
        selectedName.font = .systemFont(ofSize:13,weight:.semibold);selectedName.lineBreakMode = .byTruncatingTail
        selectedPackage.font = .systemFont(ofSize:11);selectedPackage.textColor = .secondaryLabelColor;selectedPackage.lineBreakMode = .byTruncatingMiddle
        let selectionLabels=Self.column([selectedName,selectedPackage],spacing:3)
        for v in [selectedName,selectedPackage,selectionLabels] {v.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)}
        launch.bezelStyle = .rounded;launch.controlSize = .large;launch.bezelColor = .controlAccentColor;launch.target=c;launch.action=#selector(c.launchAction);launch.setAccessibilityLabel("Launch App");launch.toolTip="Double-click an application, or press Return in the app list or search field."
        create.bezelStyle = .rounded;create.target=c;create.action=#selector(c.createWrapper)
        let selectedRow=NSStackView(views:[selectedIcon,selectionLabels,launch,create]);selectedRow.spacing=12;selectedRow.alignment = .centerY
        let selectedCard=Self.card(selectedRow);selectedCard.identifier=NSUserInterfaceItemIdentifier("launcher.app-actions")
        let sessionsTitle=Self.label("Sessions",size:15,weight:.semibold)
        sessionCount.font = .systemFont(ofSize:11);sessionCount.textColor = .secondaryLabelColor
        restore.bezelStyle = .rounded;restore.target=c;restore.action=#selector(c.restoreAction)
        let spacer=NSView();spacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let sessionHeader=NSStackView(views:[sessionsTitle,sessionCount,spacer,restore]);sessionHeader.spacing=8
        c.sessionList.orientation = .vertical;c.sessionList.alignment = .leading;c.sessionList.spacing=8
        Self.document(c.sessionList,in:sessionsScroll,padding:2)
        sessionsScroll.identifier=NSUserInterfaceItemIdentifier("launcher.sessions");sessionsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:100).isActive=true;sessionsScroll.heightAnchor.constraint(lessThanOrEqualToConstant:180).isActive=true
        let sessionHeight=sessionsScroll.heightAnchor.constraint(equalToConstant:145);sessionHeight.priority = .defaultHigh;sessionHeight.isActive=true
        let separator=NSBox();separator.boxType = .separator
        c.status.font = .systemFont(ofSize:11);c.status.textColor = .secondaryLabelColor;c.status.maximumNumberOfLines=2;c.status.lineBreakMode = .byTruncatingTail;c.status.isSelectable=true;c.status.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let diagnostics=c.button("Diagnostics…",#selector(c.openDiagnostics));diagnostics.setAccessibilityLabel("Open Diagnostics")
        let footer=NSStackView(views:[c.status,diagnostics]);footer.spacing=12;footer.alignment = .centerY
        let main=Self.column([header,c.search,browser,selectedCard,sessionHeader,sessionsScroll,separator,footer],spacing:12)
        Self.pin(main,in:workspace,inset:24)
        self.refresh()
    }
    func refresh() {
        guard let c=controller else {return}
        let device=c.selectedDevice
        let ready=device.map {c.readySerials.contains($0.serial)} ?? false
        if let device {
            connection.stringValue=(device.state == "device" ? (ready ? "Connected and ready" : "Waiting for Android to finish starting") : device.state == "unauthorized" ? "Unlock the phone and allow USB debugging" : "Device unavailable: \(device.state)") + "\n" + device.serial
            connection.toolTip="\(device.model)\n\(device.serial)\n\(device.state)"
        } else {connection.stringValue="Connect a phone with USB debugging enabled, or start an emulator."}
        let catalogLoaded=device.map {$0.state == "device" && ready && c.appsDeviceSerial == $0.serial} ?? false
        if let device {
            let model=device.model.replacingOccurrences(of:"_",with:" ")
            count.stringValue=c.appsError?.serial==device.serial ? "\(model) · Applications unavailable" : catalogLoaded ? "\(c.filtered.count) of \(c.applications.count) apps · \(model)" : "\(model) · \(ready ? "Reading applications…" : device.state == "unauthorized" ? "Authorization required" : "Waiting for device…")"
        } else {count.stringValue="Connect a device to see its applications."}
        count.toolTip=count.stringValue
        c.onboardingButton.isEnabled=c.canOnboardSelectedDevice
        launch.isEnabled=c.canLaunchSelectedApp
        create.isEnabled=c.canLaunchSelectedApp && !c.creatingWrapper && !c.onboardingPending && !c.onboarding.isRunning && c.managedNameRepair?.isRunning != true
        restore.isEnabled = !c.pending.isEmpty && c.restoreTask == nil && !c.quitting
        if let app=c.selectedApp,let device {
            selectedName.stringValue=app.name;selectedPackage.stringValue=app.packageName
            selectedName.toolTip=app.name;selectedPackage.toolTip=app.packageName
            selectedIcon.image=c.icons[c.iconKey(device,app)] ?? NSImage(systemSymbolName:"app",accessibilityDescription:nil)
        } else {selectedName.stringValue="Select an app";selectedPackage.stringValue="Launch it here or create a Mac app for Spotlight.";selectedIcon.image=NSImage(systemSymbolName:"app",accessibilityDescription:nil)}
        empty.isHidden = !c.filtered.isEmpty
        appsScroll.isHidden=c.filtered.isEmpty
        if c.filtered.isEmpty {
            emptyDetail.toolTip=nil
            let query=c.search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            let searching=catalogLoaded && !query.isEmpty
            emptyAction.title=searching ? "Clear Search" : "Refresh Devices";emptyAction.action=searching ? #selector(c.clearAppSearch) : #selector(c.refreshAction)
            if device == nil {emptyTitle.stringValue="Connect your Android device";emptyDetail.stringValue="Enable USB debugging and connect over USB, or start an Android emulator."}
            else if device?.state == "unauthorized" {emptyTitle.stringValue="Authorize this Mac";emptyDetail.stringValue="Unlock your phone and allow USB debugging, then refresh."}
            else if !ready {emptyTitle.stringValue="Getting your device ready";emptyDetail.stringValue="Applications will appear once Android is connected and has finished starting."}
            else if c.appsError?.serial==device?.serial {emptyTitle.stringValue="Couldn’t load applications";emptyDetail.stringValue=String((c.appsError?.message ?? "Refresh to try again.").prefix(220));emptyDetail.toolTip=c.appsError?.message}
            else if !catalogLoaded {emptyTitle.stringValue="Loading applications…";emptyDetail.stringValue="Reading the launchable apps on this device."}
            else if !query.isEmpty {emptyTitle.stringValue="No matching applications";emptyDetail.stringValue="Try another app name or Android package."}
            else {emptyTitle.stringValue=c.refreshing ? "Loading applications…" : "No applications found";emptyDetail.stringValue="Refresh to read the launchable apps on this device."}
        }
        sessionCount.stringValue=c.sessions.isEmpty ? "" : "\(c.sessions.count) sessions"
        c.status.toolTip=c.status.stringValue
    }
    static func sessionEmptyLabel()->NSView {
        let label=Self.label("No active sessions. Launch an app to open its own Mac window.",size:12,secondary:true)
        return label
    }
    static func sessionCard(controller c:LauncherController,id:UUID,session:BridgeSession)->NSView {
        let descriptor=session.descriptor
        let name=label(descriptor.application.name,size:13,weight:.semibold);name.maximumNumberOfLines=1;name.lineBreakMode = .byTruncatingTail;name.toolTip=descriptor.application.name
        let state=c.sessionStates[id] ?? "starting"
        let stateLabel=label(state.capitalized,size:11,weight:.medium,secondary:true);stateLabel.setContentCompressionResistancePriority(.required,for:.horizontal)
        if state == "running" {stateLabel.textColor = .systemGreen} else if state == "failed" || state == "disconnected" {stateLabel.textColor = .systemOrange}
        let top=NSStackView(views:[name,stateLabel]);top.spacing=12
        let detail=label("\(descriptor.device.model.replacingOccurrences(of:"_",with:" ")) · \(descriptor.configuration.backend == .native ? "Native AppKit" : "scrcpy")",size:11,secondary:true);detail.maximumNumberOfLines=1;detail.lineBreakMode = .byTruncatingTail
        let focus=ClosureButton(title:"Focus") { [weak c] in c?.focusSession(id) }
        focus.isEnabled=descriptor.configuration.backend == .native ? (c.hosts[id] != nil && (session.state == .starting || session.state == .running)) : session.externalApplicationPID != nil
        var controls:[NSView]=[focus]
        if session.state == .failed || session.state == .stopped {
            controls += [ClosureButton(title:"Retry") { [weak c] in c?.retry(id) },ClosureButton(title:descriptor.configuration.backend == .native ? "Try scrcpy" : "Try Native") { [weak c] in c?.retry(id,backend:descriptor.configuration.backend == .native ? .scrcpy : .native) }]
        }
        controls += [ClosureButton(title:"Log") {NSWorkspace.shared.open(session.logURL)},ClosureButton(title:"Close") { [weak c] in c?.close(id) }]
        let actions=NSStackView(views:controls);actions.spacing=8
        var rows:[NSView]=[top,detail]
        if let reason=c.sessionErrors[id] {
            let error=label(String(reason.prefix(360)),size:11,secondary:true);error.maximumNumberOfLines=2;error.lineBreakMode = .byTruncatingTail
            rows.append(error)
        }
        rows.append(actions)
        let card=Self.card(column(rows,spacing:6));card.toolTip=c.sessionErrors[id]
        card.setAccessibilityLabel("\(descriptor.application.name), \(state), \(descriptor.device.model)")
        return card
    }
}

@MainActor final class LauncherAppTable:NSTableView {
    var openSelection:(()->Void)?
    override func keyDown(with event:NSEvent) {
        if [36,76].contains(event.keyCode),event.modifierFlags.intersection([.command,.option,.control]).isEmpty {openSelection?();return}
        super.keyDown(with:event)
    }
}
@MainActor final class LauncherStatusField:NSTextField {
    var onChange:(()->Void)?
    override var stringValue:String {didSet {onChange?()}}
}
@MainActor final class LauncherAppCell:NSTableCellView {
    private let icon=NSImageView(),name=NSTextField(labelWithString:"")
    override init(frame:NSRect) {
        super.init(frame:frame)
        icon.imageScaling = .scaleProportionallyUpOrDown
        name.font = .systemFont(ofSize:13,weight:.medium);name.lineBreakMode = .byTruncatingTail;name.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let row=NSStackView(views:[icon,name]);row.spacing=12;row.alignment = .centerY
        LauncherUI.pin(row,in:self,inset:6)
        icon.widthAnchor.constraint(equalToConstant:34).isActive=true;icon.heightAnchor.constraint(equalToConstant:34).isActive=true
    }
    convenience init() {self.init(frame:.zero)}
    required init?(coder:NSCoder) {fatalError("init(coder:) unavailable")}
    func configure(name:String,icon:NSImage?,hint:String?) {
        self.name.stringValue=name;self.icon.image=icon ?? NSImage(systemSymbolName:"app.dashed",accessibilityDescription:nil)
        toolTip=hint.map {"Android icon unavailable: "+$0} ?? name
        setAccessibilityLabel(name)
    }
}
@MainActor final class LauncherDocumentView:NSView {override var isFlipped:Bool {true}}
@MainActor final class LauncherSurface:NSView {
    override func draw(_ dirtyRect:NSRect) {
        let path=NSBezierPath(roundedRect:bounds.insetBy(dx:0.5,dy:0.5),xRadius:10,yRadius:10)
        NSColor.controlBackgroundColor.setFill();path.fill();NSColor.separatorColor.setStroke();path.lineWidth=1;path.stroke()
    }
    override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();needsDisplay=true}
}

@MainActor final class LauncherBackground:NSView {
    override var isOpaque:Bool {true}
    override func draw(_ dirtyRect:NSRect) {NSColor.windowBackgroundColor.setFill();bounds.fill()}
    override func viewDidChangeEffectiveAppearance() {super.viewDidChangeEffectiveAppearance();needsDisplay=true}
}

@MainActor final class LauncherPackageCell:NSTableCellView {
    let label=NSTextField(labelWithString:"")
    override init(frame:NSRect) {
        super.init(frame:frame)
        label.lineBreakMode = .byTruncatingMiddle;label.textColor = .secondaryLabelColor;label.font = .monospacedSystemFont(ofSize:11,weight:.regular)
        label.setContentCompressionResistancePriority(.defaultLow,for:.horizontal);label.translatesAutoresizingMaskIntoConstraints=false;addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo:leadingAnchor,constant:6),label.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-6),label.centerYAnchor.constraint(equalTo:centerYAnchor)])
    }
    convenience init() {self.init(frame:.zero)}
    required init?(coder:NSCoder) {fatalError("init(coder:) unavailable")}
}

struct LauncherSessionPresentation:Equatable {
    let id:UUID,name:String,device:String,backend:String,state:String,error:String?
    let retry:Bool,focus:Bool
    @MainActor init(controller:LauncherController,session:BridgeSession) {
        let descriptor=session.descriptor
        id=descriptor.id;name=descriptor.application.name;device=descriptor.device.model;backend=descriptor.configuration.backend.rawValue
        state=controller.sessionStates[id] ?? "starting";error=controller.sessionErrors[id]
        retry=session.state == .failed || session.state == .stopped
        focus=descriptor.configuration.backend == .native ? (controller.hosts[id] != nil && (session.state == .starting || session.state == .running)) : session.externalApplicationPID != nil
    }
}
