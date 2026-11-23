import AppKit
import AnonymousUsage
import DroidBridgeCore

/// The control app and independently running native wrappers contribute through
/// a shared aggregate. Only the control app exposes the consent setting.
@MainActor
final class DesktopUsage {
    static let shared = DesktopUsage()
    private(set) var meter: UsageMeter?
    private(set) var isLocalVerification = false
    private var clock: Task<Void, Never>?
    private var windowObservers: [NSObjectProtocol] = []
    private var consentObserver: NSObjectProtocol?
    private var generation = 0
    private var measuringForeground = false
    private static let consentChanged = Notification.Name("app.droidbridge.desktop.usage-consent-changed")
    private var observers: [NSObjectProtocol] = []
    private(set) var wrapperArguments: [String] = []
    private var isWrapper = false
    private var sleeping = false
    private var screensAsleep = false

    func start(isWrapper: Bool) {
        let args = ProcessInfo.processInfo.arguments
        let flags = args.indices.filter { args[$0] == "--usage-loopback-port" }
        guard meter == nil else { return }
        self.isWrapper = isWrapper
        if CompanionQAScope.current != nil || !flags.isEmpty {
            guard flags.count == 1, let flag = flags.first, args.indices.contains(flag + 1),
                  let port = UInt16(args[flag + 1]), port > 0,
                  let scope = CompanionQAScope.current, scope.serial == "emulator-5580" else { return }
            meter = UsageMeter(directory: scope.root.appendingPathComponent("AnonymousUsage"), transport: LoopbackUsageTransport(port: port), consentScope: "loopback-\(port)", canChangeConsent: !isWrapper)
            wrapperArguments = ["--usage-loopback-port", String(port)]
            isLocalVerification = true
        } else {
            guard (isWrapper || Bundle.main.bundleIdentifier == "app.droidbridge.desktop"),
                  Bundle.main.object(forInfoDictionaryKey: "DroidBridgeUsageLane") as? String == "production-v1",
                  let raw = Bundle.main.object(forInfoDictionaryKey: "DroidBridgeUsageEndpoint") as? String,
                  let url = URL(string: raw), let transport = ProductionUsageTransport(approvedEndpoint: url) else { return }
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            meter = UsageMeter(directory: base.appendingPathComponent("DroidBridge/AnonymousUsage"), transport: transport, consentScope: raw, canChangeConsent: !isWrapper)
        }
        observe(NSWorkspace.willSleepNotification) { $0.sleeping = true }
        observe(NSWorkspace.didWakeNotification) { $0.sleeping = false }
        observe(NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.updateForeground() }
            })
        }
        consentObserver = DistributedNotificationCenter.default().addObserver(forName: Self.consentChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateForeground() }
        }
        updateForeground()
    }

    private func observe(_ name: Notification.Name, change: @escaping @MainActor (DesktopUsage) -> Void) {
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.updateForeground()
            }
        })
    }

    func updateForeground() {
        guard let meter else { return }
        let window = NSApp.keyWindow
        let native = window?.windowController as? NativeWindowController
        let showingVideo = native?.video.frameImage != nil && native?.session?.state == .running
            && window?.occlusionState.contains(.visible) == true && window?.isMiniaturized == false
        let visible = window?.isVisible == true && window?.occlusionState.contains(.visible) == true
            && window?.isMiniaturized == false
        generation &+= 1
        let expectedGeneration = generation
        guard NSApp.isActive, !sleeping, !screensAsleep, visible, !isWrapper || showingVideo else {
            clock?.cancel()
            clock = nil
            if measuringForeground { meter.setForeground(false) }
            measuringForeground = false
            return
        }
        meter.refreshConsent { [weak self] enabled in
            guard let self, self.generation == expectedGeneration else { return }
            meter.setForeground(enabled)
            self.measuringForeground = enabled
            guard enabled else {
                self.clock?.cancel()
                self.clock = nil
                return
            }
            guard self.clock == nil else { return }
            self.clock = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    meter.tick()
                }
            }
        }
    }

    func setConsent(_ enabled: Bool, completion: @escaping (UsageConsentResult) -> Void) {
        guard !isWrapper, let meter else { return }
        clock?.cancel()
        clock = nil
        generation &+= 1
        meter.setConsent(enabled) { [weak self] result in
            completion(result)
            self?.updateForeground()
            // A wakeup carries no consent value or identity. Every process checks
            // its own scope against the ledger before collection or transmission.
            DistributedNotificationCenter.default().postNotificationName(Self.consentChanged, object: nil, userInfo: nil, deliverImmediately: true)
        }
    }

    func stop() {
        generation &+= 1
        if measuringForeground { meter?.setForeground(false) }
        measuringForeground = false
        clock?.cancel()
        clock = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers.removeAll()
        if let consentObserver { DistributedNotificationCenter.default().removeObserver(consentObserver) }
        consentObserver = nil
        meter = nil
    }
}
