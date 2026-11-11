import AppKit
import DroidBridgeCore
import DroidBridgeStreaming

/// Presentation only. Reuses the controller's discovery, preferences and session
/// actions; layout refreshes never perform device, catalog or filesystem work.
@MainActor final class LauncherUI: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate {
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
    let appLaunchSpinner = NSProgressIndicator()
    let appLaunchLabel = NSTextField(wrappingLabelWithString: "")
    let appLaunchCancel = NSButton(title: "Cancel", target: nil, action: nil)
    let appLaunchDismiss = NSButton(title: "Dismiss", target: nil, action: nil)
    let appLaunchBanner = NSStackView()
    init(controller:LauncherController) {self.controller=controller;super.init()}
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
    private let splitController = NSSplitViewController()
    private let detailHost = NSView(), appsPage = NSView(), sessionsPage = NSView(), independentSessionsHost = NSView()
    private let navigationTable = NSTableView()
    private let favorite = NSButton(title: "Favorite", target: nil, action: nil)
    private let retryExport = NSButton(title: "Retry Mac App", target: nil, action: nil)
    private let export = NSButton(checkboxWithTitle: "Available in Spotlight", target: nil, action: nil)
    private let companionAppStatus = NSTextField(wrappingLabelWithString: "Pair the Android app in Devices for favorites, sharing and notification controls.")
    private let deviceControls = NSView()
    private weak var configuredCompanion: CompanionWindowController?
    private var lastEmbeddedContext: String?
    private var refreshingPresentation = false
    private var selectingNavigation = false
    private var presentedFavorites = Set<String>()
    private var localSessionsHeight: NSLayoutConstraint?
    private(set) var currentSection: DesktopWorkspaceSection = .apps
    private let sidebarSections = DesktopWorkspaceSection.primary

    func build() {
        guard let c=controller,let window=c.window else {return}
        c.devicePicker.target=c;c.devicePicker.action=#selector(c.deviceChanged);c.devicePicker.setAccessibilityLabel("Android device")
        c.devicePicker.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        c.devicePicker.widthAnchor.constraint(greaterThanOrEqualToConstant:190).isActive=true
        c.devicePicker.widthAnchor.constraint(lessThanOrEqualToConstant:360).isActive=true
        if c.backendPicker.numberOfItems == 0 {c.backendPicker.addItems(withTitles:["Native AppKit","scrcpy fallback"])}
        c.backendPicker.setAccessibilityLabel("Rendering backend")
        for button in [c.bulkPreference,c.decorationsPreference] {button.target=c;button.action=#selector(c.sharedPreferenceChanged(_:))}
        c.bulkPreference.state=c.sharedPreferences.bulkWrapperOnboardingEnabled ? .on : .off
        c.decorationsPreference.state=c.sharedPreferences.showAndroidSystemDecorations ? .on : .off
        c.phoneScreenPreference.target=c;c.phoneScreenPreference.action=#selector(c.phoneScreenPreferenceChanged(_:));c.phoneScreenPreference.isEnabled=false
        c.phoneScreenPreference.toolTip="Applies to the selected device during Mac sessions. Closing a session leaves its phone screen off; use Turn Phone Screen On explicitly."
        c.decorationsPreference.toolTip="Applies to new Android app windows. Android app-drawn controls remain unchanged."
        for button in [c.phoneScreenPreference,c.decorationsPreference,c.bulkPreference,c.reconnect] {Self.wrapCheckbox(button,height:32)}
        DesktopSettingsWindowController.applyDefaults(to:c)
        c.onboardingButton.target=c;c.onboardingButton.action=#selector(c.onboardDeviceApps)
        c.onboardingButton.title="Add All Device Apps…";c.onboardingButton.setAccessibilityLabel("Add All Device Apps to Spotlight");c.onboardingButton.bezelStyle = .rounded
        c.onboardingCancel.target=c;c.onboardingCancel.action=#selector(c.cancelOnboarding);c.onboardingCancel.isEnabled=false;c.onboardingCancel.bezelStyle = .rounded
        c.onboardingProgress.isIndeterminate=false;c.onboardingProgress.minValue=0;c.onboardingProgress.maxValue=1;c.onboardingProgress.setAccessibilityLabel("Spotlight setup progress")
        c.audioRoutePicker.removeAllItems()
        for (name,route) in [("Mac",DeviceAudioRoute.mac),("Phone",.phone),("Mac + Phone",.macAndPhone)] {c.audioRoutePicker.addItem(withTitle:name);c.audioRoutePicker.lastItem?.representedObject=route.rawValue}
        c.audioRoutePicker.target=c;c.audioRoutePicker.action=#selector(c.audioRouteChanged(_:));c.audioRoutePicker.setAccessibilityLabel("Selected device audio output")
        c.audioStatus.font = .systemFont(ofSize:12);c.audioStatus.maximumNumberOfLines=5;c.audioStatus.isSelectable=true
        c.audioRetry.target=c;c.audioRetry.action=#selector(c.retrySelectedAudio)
        c.audioUsePhone.target=c;c.audioUsePhone.action=#selector(c.usePhoneAudio)
        let screenActions=NSStackView(views:[c.button("Turn Phone Screen Off",#selector(c.turnPhoneScreenOff)),c.button("Turn Phone Screen On",#selector(c.turnPhoneScreenOn))]);screenActions.spacing=8
        let audioActions=NSStackView(views:[c.audioRetry,c.audioUsePhone]);audioActions.spacing=8
        let onboardingActions=NSStackView(views:[c.onboardingCancel,c.button("Results…",#selector(c.showOnboardingDetails))]);onboardingActions.spacing=8
        c.onboardingStatus.font = .systemFont(ofSize:12);c.onboardingStatus.maximumNumberOfLines=4
        Self.pin(Self.column([Self.label("Audio and phone screen",size:17,weight:.semibold),Self.label("These controls apply to the selected device and all its Android app windows.",secondary:true),c.audioRoutePicker,c.audioStatus,audioActions,c.phoneScreenPreference,screenActions,Self.label("Mac app launchers",size:17,weight:.semibold),Self.label("Create managed Mac apps for every launchable app on this device. Enable Spotlight integration in Settings first, or choose individual paired apps in Apps.",secondary:true),c.onboardingButton,c.onboardingProgress,c.onboardingStatus,onboardingActions],spacing:10),in:deviceControls)

        let sidebar=NSViewController();let sidebarBackground=NSVisualEffectView();sidebarBackground.material = .sidebar;sidebarBackground.blendingMode = .behindWindow;sidebarBackground.state = .followsWindowActiveState;sidebar.view=sidebarBackground
        navigationTable.addTableColumn(NSTableColumn(identifier:.init("section")));navigationTable.headerView=nil;navigationTable.style = .sourceList;navigationTable.rowHeight=36;navigationTable.delegate=self;navigationTable.dataSource=self;navigationTable.setAccessibilityLabel("Workspace sections")
        navigationTable.target=self;navigationTable.action=#selector(selectNavigationRow)
        sidebarScroll.documentView=navigationTable;sidebarScroll.hasVerticalScroller=true;sidebarScroll.drawsBackground=false;sidebarScroll.borderType = .noBorder
        let settings=ClosureButton(title:"Settings…") { [weak c] in c?.showLauncherSettings() };settings.image=NSImage(systemSymbolName:"gearshape",accessibilityDescription:nil);settings.imagePosition = .imageLeading
        let sidebarStack=Self.column([sidebarScroll,settings],spacing:12);Self.pin(sidebarStack,in:sidebarBackground,inset:12)
        let detail=NSViewController();detail.view=root
        c.status.font = .systemFont(ofSize:11);c.status.textColor = .secondaryLabelColor;c.status.maximumNumberOfLines=2;c.status.lineBreakMode = .byTruncatingTail;c.status.isSelectable=true
        let separator=NSBox();separator.boxType = .separator
        let footer=Self.column([separator,c.status],spacing:8)
        connection.font = .systemFont(ofSize:12);connection.textColor = .secondaryLabelColor;connection.maximumNumberOfLines=3;connection.isSelectable=true
        let connectionAction=ClosureButton(title:"Connection…") { [weak c] in c?.showWorkspace(.devices) }
        let sharedContext=NSStackView(views:[connection,connectionAction]);sharedContext.spacing=12;sharedContext.alignment = .centerY
        appLaunchSpinner.style = .spinning;appLaunchSpinner.controlSize = .small;appLaunchSpinner.isIndeterminate = true
        appLaunchSpinner.widthAnchor.constraint(equalToConstant:18).isActive = true
        appLaunchSpinner.heightAnchor.constraint(equalToConstant:18).isActive = true
        appLaunchSpinner.setAccessibilityLabel("Opening Android app")
        appLaunchLabel.font = .systemFont(ofSize:12,weight:.medium);appLaunchLabel.maximumNumberOfLines = 3;appLaunchLabel.isSelectable = true
        appLaunchLabel.setAccessibilityIdentifier("launcher.app-launch-progress")
        appLaunchCancel.target=c;appLaunchCancel.action=#selector(c.cancelAppLaunch)
        appLaunchCancel.setAccessibilityLabel("Cancel opening app")
        appLaunchDismiss.target=c;appLaunchDismiss.action=#selector(c.dismissAppLaunchProgress)
        appLaunchBanner.orientation = .horizontal;appLaunchBanner.alignment = .centerY;appLaunchBanner.spacing = 10
        for view in [appLaunchSpinner,appLaunchLabel,appLaunchCancel,appLaunchDismiss] {appLaunchBanner.addArrangedSubview(view)}
        appLaunchLabel.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let body=Self.column([sharedContext,appLaunchBanner,detailHost,footer],spacing:10);Self.pin(body,in:root,inset:20)
        detailHost.setContentHuggingPriority(.defaultLow,for:.vertical);detailHost.heightAnchor.constraint(greaterThanOrEqualToConstant:300).isActive=true
        let sideItem=NSSplitViewItem(sidebarWithViewController:sidebar);sideItem.minimumThickness=190;sideItem.maximumThickness=250;sideItem.canCollapse=true
        splitController.addSplitViewItem(sideItem);splitController.addSplitViewItem(NSSplitViewItem(viewController:detail))
        window.contentViewController=splitController
        let toolbar=NSToolbar(identifier:"DroidBridge.workspace");toolbar.delegate=self;toolbar.displayMode = .iconOnly;toolbar.allowsUserCustomization=false;window.toolbar=toolbar;window.toolbarStyle = .unified
        let workspace=appsPage
        let title=Self.label("Apps",size:25,weight:.bold)
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

        favorite.bezelStyle = .rounded;favorite.target=self;favorite.action=#selector(toggleFavorite);favorite.setAccessibilityLabel("Favorite selected Android app")
        export.target=self;export.action=#selector(changeExport);export.setAccessibilityLabel("Selected Android app available in Spotlight")
        companionAppStatus.font = .systemFont(ofSize:11);companionAppStatus.textColor = .secondaryLabelColor;companionAppStatus.maximumNumberOfLines=3
        retryExport.target=self;retryExport.action=#selector(retrySelectedExport);retryExport.bezelStyle = .rounded;retryExport.isHidden=true
        let selectionOptions=NSStackView(views:[favorite,export,retryExport]);selectionOptions.spacing=16
        let appBody=Self.column([header,c.search,browser,selectedCard,selectionOptions,companionAppStatus],spacing:12);Self.pin(appBody,in:workspace)
        let sessionHeader=NSStackView(views:[Self.label("Sessions",size:25,weight:.bold),sessionCount,NSView(),restore]);sessionHeader.spacing=10
        restore.bezelStyle = .rounded;restore.target=c;restore.action=#selector(c.restoreAction)
        sessionCount.font = .systemFont(ofSize:11);sessionCount.textColor = .secondaryLabelColor
        c.sessionList.orientation = .vertical;c.sessionList.alignment = .leading;c.sessionList.spacing=8
        Self.document(c.sessionList,in:sessionsScroll,padding:2);sessionsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant:60).isActive=true
        let localHeight=sessionsScroll.heightAnchor.constraint(equalToConstant:60);localHeight.priority = .defaultHigh;localHeight.isActive=true;localSessionsHeight=localHeight
        let sessionsBody=Self.column([sessionHeader,Self.label("App windows for the selected device",secondary:true),sessionsScroll,Self.label("Independent Android app launchers",size:15,weight:.semibold),independentSessionsHost],spacing:10)
        independentSessionsHost.heightAnchor.constraint(greaterThanOrEqualToConstant:180).isActive=true;Self.pin(sessionsBody,in:sessionsPage)
        navigationTable.reloadData();navigationTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false)
        show(.apps)
        refresh()
    }
    func show(_ section:DesktopWorkspaceSection) {
        guard let c=controller else {return}
        currentSection=section
        let selected=sidebarSections.firstIndex(of:section == .deviceSettings ? .devices : section)
        if let selected,navigationTable.selectedRow != selected {selectingNavigation=true;navigationTable.selectRowIndexes(IndexSet(integer:selected),byExtendingSelection:false);selectingNavigation=false}
        else if selected == nil {selectingNavigation=true;navigationTable.deselectAll(nil);selectingNavigation=false}
        detailHost.subviews.forEach {$0.removeFromSuperview()}
        switch section {
        case .apps: Self.pin(appsPage,in:detailHost)
        case .sessions:
            let panel=prepareCompanion();let view=panel.embeddedView(for:.sessions);view.removeFromSuperview();Self.pin(view,in:independentSessionsHost);Self.pin(sessionsPage,in:detailHost)
        default:
            let panel=prepareCompanion();let view=panel.embeddedView(for:section.companionPage);view.removeFromSuperview();Self.pin(view,in:detailHost)
        }
        c.window?.title=section.title
        updateEmbeddedContext()
        if section == .apps {c.window?.makeFirstResponder(c.search)}
        else {c.window?.makeFirstResponder(navigationTable)}
        c.companion.catalogVisibilityChanged()
    }
    private func prepareCompanion()->CompanionWindowController {
        let panel=controller!.companion.ensureEmbeddedController()
        if configuredCompanion !== panel {
            configuredCompanion=panel;lastEmbeddedContext=nil
            panel.setDeviceSettingsHeader(deviceControls)
            panel.onCatalogChange={ [weak self,weak panel] in
                guard let self,let panel,let controller=self.controller else {return}
                let favorites=panel.favoriteAppPackages
                if favorites != self.presentedFavorites {self.presentedFavorites=favorites;controller.filterApps()}
                else {controller.updateLauncherPresentation()}
            }
        }
        return panel
    }
    private func updateEmbeddedContext() {
        guard let c=controller else {return}
        let phone=c.selectedDevice.flatMap {c.companion.device(for:$0.serial)}
        if configuredCompanion == nil,phone != nil {_ = prepareCompanion()}
        guard let panel=configuredCompanion else {return}
        let page=currentSection.companionPage
        let key="\(currentSection.rawValue)|\(c.selectedDevice?.serial ?? "")|\(phone?.id ?? "")|\(phone?.trustID ?? "")|\(c.window?.isVisible == true)|\(c.window?.isMiniaturized == true)"
        guard key != lastEmbeddedContext else {return};lastEmbeddedContext=key
        panel.setHostContext(window:c.window,activePage:page,selectedSerial:c.selectedDevice?.serial)
    }
    func hostWindowClosed() {lastEmbeddedContext=nil;configuredCompanion?.hostWindowClosed();controller?.companion.catalogVisibilityChanged()}
    @objc private func toggleFavorite() {if let package=controller?.selectedApp?.packageName {configuredCompanion?.toggleAppFavorite(package:package)}}
    @objc private func changeExport() {if let package=controller?.selectedApp?.packageName {configuredCompanion?.setAppExport(package:package,selected:export.state == .on)}}
    @objc private func retrySelectedExport() {if let package=controller?.selectedApp?.packageName {configuredCompanion?.setAppExport(package:package,selected:true)}}
    @objc private func connectDevice() {controller?.showWorkspace(.devices)}
    @objc private func selectNavigationRow() {tableViewSelectionDidChange(Notification(name:NSTableView.selectionDidChangeNotification))}
    func numberOfRows(in tableView:NSTableView)->Int {sidebarSections.count}
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int)->NSView? {
        guard sidebarSections.indices.contains(row) else {return nil}
        let section=sidebarSections[row],cell=NSTableCellView();let text=NSTextField(labelWithString:section.title),image=NSImageView(image:NSImage(systemSymbolName:section.symbol,accessibilityDescription:nil) ?? NSImage())
        text.font = .systemFont(ofSize:13);text.translatesAutoresizingMaskIntoConstraints=false;image.translatesAutoresizingMaskIntoConstraints=false;cell.addSubview(image);cell.addSubview(text);cell.textField=text;cell.imageView=image
        NSLayoutConstraint.activate([image.leadingAnchor.constraint(equalTo:cell.leadingAnchor,constant:8),image.centerYAnchor.constraint(equalTo:cell.centerYAnchor),image.widthAnchor.constraint(equalToConstant:20),image.heightAnchor.constraint(equalToConstant:18),text.leadingAnchor.constraint(equalTo:image.trailingAnchor,constant:8),text.trailingAnchor.constraint(equalTo:cell.trailingAnchor,constant:-8),text.centerYAnchor.constraint(equalTo:cell.centerYAnchor)])
        cell.setAccessibilityLabel(section.title);return cell
    }
    func tableViewSelectionDidChange(_ notification:Notification) {guard !selectingNavigation,sidebarSections.indices.contains(navigationTable.selectedRow) else {return};let section=sidebarSections[navigationTable.selectedRow];if currentSection != section {show(section)}}
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] {[.toggleSidebar,.init("device"),.init("refresh"),.flexibleSpace,.init("device-settings")]}
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] {[.toggleSidebar,.init("device"),.init("refresh"),.flexibleSpace,.init("device-settings")]}
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag:Bool)->NSToolbarItem? {
        guard let c=controller else {return nil};let item=NSToolbarItem(itemIdentifier:id)
        if id.rawValue == "device" {item.label="Android Device";item.view=c.devicePicker}
        else if id.rawValue == "refresh" {item.label="Refresh Devices";item.image=NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:"Refresh Devices");item.target=c;item.action=#selector(c.refreshAction)}
        else if id.rawValue == "device-settings" {item.label="Device Settings";item.image=NSImage(systemSymbolName:"slider.horizontal.3",accessibilityDescription:"Device Settings");item.target=c;item.action=#selector(c.showDeviceSettings)}
        else {return nil};return item
    }
    func refresh() {
        guard let c=controller,!refreshingPresentation else {return}
        refreshingPresentation=true;defer {refreshingPresentation=false}
        updateEmbeddedContext()
        let device=c.selectedDevice
        let ready=device.map {c.readySerials.contains($0.serial)} ?? false
        if let device {
            connection.stringValue=(device.state == "device" ? (ready ? "Connected and ready" : "Waiting for Android to finish starting") : device.state == "unauthorized" ? "Unlock the phone and allow USB debugging" : "Device unavailable: \(device.state)") + "\n" + device.serial
            connection.toolTip="\(device.model)\n\(device.serial)\n\(device.state)"
            let phone=c.companion.device(for:device.serial)
            connection.stringValue += phone?.paired == true ? (phone?.connected == true ? " · Android app paired and connected" : " · Android app paired, disconnected") : " · Android app not paired"
        } else {connection.stringValue="Connect a phone with USB debugging enabled, or start an emulator."}
        let catalogLoaded=device.map {$0.state == "device" && ready && c.appsDeviceSerial == $0.serial} ?? false
        if let device {
            let model=device.model.replacingOccurrences(of:"_",with:" ")
            count.stringValue=c.appsError?.serial==device.serial ? "\(model) · Applications unavailable" : catalogLoaded ? "\(c.filtered.count) of \(c.applications.count) apps · \(model)" : "\(model) · \(ready ? "Reading applications…" : device.state == "unauthorized" ? "Authorization required" : "Waiting for device…")"
        } else {count.stringValue="Connect a device to see its applications."}
        count.toolTip=count.stringValue
        c.onboardingButton.isEnabled=c.canOnboardSelectedDevice
        launch.isEnabled=c.canLaunchSelectedApp
        launch.title=c.appLaunchProgress?.busy == true ? "Opening…" : "Launch App"
        appLaunchBanner.isHidden=c.appLaunchProgress == nil
        if let progress=c.appLaunchProgress {
            appLaunchLabel.stringValue="\(progress.name) — \(progress.message)"
            appLaunchLabel.toolTip=appLaunchLabel.stringValue
            appLaunchSpinner.isHidden = !progress.busy
            if progress.busy {appLaunchSpinner.startAnimation(nil)} else {appLaunchSpinner.stopAnimation(nil)}
            appLaunchCancel.isHidden = !progress.busy;appLaunchCancel.isEnabled=progress.canCancel
            appLaunchDismiss.isHidden = progress.busy
        } else {appLaunchSpinner.stopAnimation(nil)}
        create.isEnabled=c.canLaunchSelectedApp && !c.creatingWrapper && !c.onboardingPending && !c.onboarding.isRunning && c.managedNameRepair?.isRunning != true
        restore.isEnabled = !c.restorableSessions.isEmpty && c.restoreTask == nil && !c.quitting
        restore.title=c.selectedDevice == nil ? "Restore Sessions for All Devices" : "Restore Previous Sessions"
        if let app=c.selectedApp,let device {
            selectedName.stringValue=app.name;selectedPackage.stringValue=app.packageName
            selectedName.toolTip=app.name;selectedPackage.toolTip=app.packageName
            selectedIcon.image=c.icons[c.iconKey(device,app)] ?? NSImage(systemSymbolName:"app",accessibilityDescription:nil)
        } else {selectedName.stringValue="Select an app";selectedPackage.stringValue="Open it in its own Mac app window.";selectedIcon.image=NSImage(systemSymbolName:"app",accessibilityDescription:nil)}
        empty.isHidden = !c.filtered.isEmpty
        appsScroll.isHidden=c.filtered.isEmpty
        if c.filtered.isEmpty {
            emptyDetail.toolTip=nil
            let query=c.search.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            let searching=catalogLoaded && !query.isEmpty
            emptyAction.title=searching ? "Clear Search" : device == nil ? "Connect Device…" : "Refresh Devices"
            emptyAction.target=device == nil ? self : c
            emptyAction.action=searching ? #selector(c.clearAppSearch) : device == nil ? #selector(connectDevice) : #selector(c.refreshAction)
            if device == nil {emptyTitle.stringValue="Connect your Android device";emptyDetail.stringValue="Enable USB debugging and connect over USB, or start an Android emulator."}
            else if device?.state == "unauthorized" {emptyTitle.stringValue="Authorize this Mac";emptyDetail.stringValue="Unlock your phone and allow USB debugging, then refresh."}
            else if !ready {emptyTitle.stringValue="Getting your device ready";emptyDetail.stringValue="Applications will appear once Android is connected and has finished starting."}
            else if c.appsError?.serial==device?.serial {emptyTitle.stringValue="Couldn’t load applications";emptyDetail.stringValue=String((c.appsError?.message ?? "Refresh to try again.").prefix(220));emptyDetail.toolTip=c.appsError?.message}
            else if !catalogLoaded {emptyTitle.stringValue="Loading applications…";emptyDetail.stringValue="Reading the launchable apps on this device."}
            else if !query.isEmpty {emptyTitle.stringValue="No matching applications";emptyDetail.stringValue="Try another app name or Android package."}
            else {emptyTitle.stringValue=c.refreshing ? "Loading applications…" : "No applications found";emptyDetail.stringValue="Refresh to read the launchable apps on this device."}
        }
        if let package=c.selectedApp?.packageName,let state=configuredCompanion?.appPresentation(package:package) {
            favorite.isEnabled=true;favorite.title=state.favorite ? "Remove Favorite" : "Favorite"
            favorite.setAccessibilityLabel(state.favorite ? "Remove selected Android app from favorites" : "Favorite selected Android app")
            export.isEnabled = !state.pending;export.state=state.exported ? .on : .off
            retryExport.isHidden = !state.pending
            companionAppStatus.stringValue=state.pending ? "Spotlight selection is saved; Mac app creation is pending." : "Favorites are saved on this Mac. Spotlight availability follows the paired phone’s selection."
        } else {
            favorite.isEnabled=false;export.isEnabled=false;export.state = .off
            retryExport.isHidden=true
            companionAppStatus.stringValue="Pair the Android app in Devices to manage favorites and per-app Spotlight availability. Launching apps does not require pairing."
        }
        let sessionTotal=c.visibleSessions.count+c.visibleLaunchedApps.count
        sessionCount.stringValue=sessionTotal == 0 ? "" : "\(sessionTotal) app windows"
        localSessionsHeight?.constant=sessionTotal == 0 ? 60 : min(320,max(110,CGFloat(sessionTotal)*100))
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
        if state == "disconnected" {stateLabel.stringValue = "Waiting to reconnect"}
        if let display = session.appMovedToDisplay {stateLabel.stringValue = display == 0 ? "On phone" : "On another display"}
        if state == "running" {stateLabel.textColor = .systemGreen} else if state == "failed" || state == "disconnected" {stateLabel.textColor = .systemOrange}
        let top=NSStackView(views:[name,stateLabel]);top.spacing=12
        let detail=label("\(descriptor.device.model.replacingOccurrences(of:"_",with:" ")) · \(descriptor.configuration.backend == .native ? "Native AppKit" : "scrcpy")",size:11,secondary:true);detail.maximumNumberOfLines=1;detail.lineBreakMode = .byTruncatingTail
        let focus=ClosureButton(title:"Focus") { [weak c] in c?.focusSession(id) }
        focus.isEnabled=session.appMovedToDisplay != nil || (descriptor.configuration.backend == .native ? (c.hosts[id] != nil && (session.state == .starting || session.state == .running)) : session.externalApplicationPID != nil)
        var controls:[NSView]=[focus]
        if session.appMovedToDisplay != nil {
            controls.append(ClosureButton(title:"Move to Mac") { [weak c] in c?.retry(id) })
        } else if session.state == .failed || session.state == .stopped {
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
        card.setAccessibilityLabel("\(descriptor.application.name), \(stateLabel.stringValue), \(descriptor.device.model)")
        return card
    }
    static func launchedAppCard(controller c:LauncherController,app:LaunchedDesktopApp)->NSView {
        let name=label(app.app.name,size:13,weight:.semibold)
        let phase=label(app.phase,size:11,secondary:true)
        if app.phase == "Running" {phase.textColor = .systemGreen}
        let detail=label("\(app.device.model.replacingOccurrences(of:"_",with:" ")) · \(app.actualBackend == .native ? "Native AppKit" : "scrcpy")",size:11,secondary:true)
        let focus=ClosureButton(title:"Open App") { [weak c] in c?.focusLaunchedApp(app.process.owner.pid) }
        let close=ClosureButton(title:"Close App") { [weak c] in c?.closeLaunchedApp(app.process.owner.pid) }
        let actions=NSStackView(views:[focus,close]);actions.spacing=8
        let content=column([name,phase,detail,actions],spacing:6)
        return card(content)
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
        focus=session.appMovedToDisplay != nil || (descriptor.configuration.backend == .native ? (controller.hosts[id] != nil && (session.state == .starting || session.state == .running)) : session.externalApplicationPID != nil)
    }
}
