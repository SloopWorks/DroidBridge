import AppKit
import Carbon

/// Registers only the owned shortcut; it needs no Accessibility permission.
@MainActor final class QuickAccessHotKey {
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var callbackContext: CallbackContext?
    private var generation: UUID?
    private static let signature: OSType = 0x44425141 // DBQA
    private static let identifier: UInt32 = 1

    private final class CallbackContext: @unchecked Sendable {
        let action: @MainActor () -> Void
        init(action: @escaping @MainActor () -> Void) { self.action = action }
    }

    /// Returns an actionable explanation if macOS cannot reserve Command-Shift-D.
    func enable(handler: @escaping @MainActor () -> Void) -> String? {
        disable()
        let token = UUID()
        generation = token
        let context = CallbackContext { [weak self] in
            guard let self, self.generation == token, self.hotKey != nil else { return }
            handler()
        }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identity = EventHotKeyID()
            let read = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identity)
            guard read == noErr, identity.signature == 0x44425141, identity.id == 1 else { return OSStatus(eventNotHandledErr) }
            let context = Unmanaged<CallbackContext>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in context.action() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(context).toOpaque(), &eventHandler)
        guard installed == noErr else {
            disable()
            return "Couldn’t enable Command-Shift-D (macOS error \(installed)). Use the Quick Access menu and try enabling the shortcut again."
        }
        callbackContext = context
        let identity = EventHotKeyID(signature: Self.signature, id: Self.identifier)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(cmdKey | shiftKey), identity, GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            disable()
            if registered == OSStatus(eventHotKeyExistsErr) {
                return "Command-Shift-D is already in use. Change or disable that shortcut in the other app or System Settings, then enable Quick Access again. You can still use the Quick Access menu."
            }
            return "Couldn’t enable Command-Shift-D (macOS error \(registered)). Use the Quick Access menu and try enabling the shortcut again."
        }
        return nil
    }

    func disable() {
        generation = nil
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        callbackContext = nil
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
