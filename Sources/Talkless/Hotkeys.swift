import AppKit
import Carbon.HIToolbox

/// Monitor a single modifier key (Fn, Right Option, etc.) with CGEventTap. Requires Accessibility permission.
@MainActor
final class HotkeyMonitor {
    var triggerKey: TriggerKey = .fn {
        didSet { if triggerKey != oldValue { triggerDown = false } }
    }
    var onPress: (CGEventTimestamp) -> Void = { _ in }
    var onRelease: (CGEventTimestamp) -> Void = { _ in }
    /// Another key was pressed while holding the trigger (a keyboard shortcut, not dictation).
    var onComboKey: (CGEventTimestamp) -> Void = { _ in }
    /// Return true to consume this Escape key event.
    var onEscape: () -> Bool = { false }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var triggerDown = false

    var isRunning: Bool { tap != nil }

    func start() -> Bool {
        if tap != nil { return true }
        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let keep = MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
            return keep ? Unmanaged.passUnretained(event) : nil
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        reconcilePhysicalState()
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        triggerDown = false
    }

    /// Startup/recovery may miss presses as well as releases. Rebuild without firing actions.
    private func reconcilePhysicalState() {
        triggerDown = isDown(triggerKey, flags: CGEventSource.flagsState(.combinedSessionState))
    }

    /// Return false to consume the event.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            reconcilePhysicalState()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true

        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keyCode == triggerKey.keyCode else { return true }
            let down = isDown(triggerKey, flags: event.flags)
            if down && !triggerDown {
                triggerDown = true
                onPress(event.timestamp)
            } else if !down && triggerDown {
                triggerDown = false
                onRelease(event.timestamp)
            }
            return true

        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if keyCode == Int64(kVK_Escape) {
                return !onEscape()
            }
            if triggerDown { onComboKey(event.timestamp) }
            return true

        default:
            return true
        }
    }

    /// Use device-specific flags to distinguish left and right modifier keys.
    private func isDown(_ key: TriggerKey, flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        switch key {
        case .fn: return flags.contains(.maskSecondaryFn)
        case .rightOption: return raw & 0x40 != 0      // NX_DEVICERALTKEYMASK
        case .rightCommand: return raw & 0x10 != 0     // NX_DEVICERCMDKEYMASK
        case .rightControl: return raw & 0x2000 != 0   // NX_DEVICERCTLKEYMASK
        }
    }
}

/// A standard keyboard shortcut (no permission required) for translating selected text.
@MainActor
final class GlobalHotKey {
    /// Injectable Carbon boundary; tests use fake opaque references, never real global shortcuts.
    struct API {
        var install: (EventHandlerUPP, UnsafeMutableRawPointer, inout EventHandlerRef?) -> OSStatus
        var register: (UInt32, UInt32, EventHotKeyID, inout EventHotKeyRef?) -> OSStatus
        var unregister: (EventHotKeyRef) -> Void
        var remove: (EventHandlerRef) -> Void

        @MainActor static let carbon = API(
            install: { callback, context, handler in
                var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
                return InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, context, &handler)
            },
            register: { key, modifiers, id, ref in
                RegisterEventHotKey(key, modifiers, id, GetApplicationEventTarget(), 0, &ref)
            },
            unregister: { _ = UnregisterEventHotKey($0) },
            remove: { _ = RemoveEventHandler($0) }
        )
    }

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let api: API
    private let action: @MainActor @Sendable () -> Void
    private var registrationID: UInt32 = 0
    private static var nextID: UInt32 = 0
    private(set) var error: String?
    var isActive: Bool { ref != nil && handler != nil }

    init(api: API = .carbon, action: @escaping @MainActor @Sendable () -> Void) {
        self.api = api
        self.action = action
    }

    /// Replace rather than silently retain an old binding if registration fails.
    func update(_ shortcut: TranslationShortcut) {
        stop()
        error = nil
        if let validationError = shortcut.validationError {
            error = L10n.format("Translation shortcut is inactive. %@", validationError)
            return
        }
        guard let keyCode = shortcut.keyCode else { return }
        Self.nextID &+= 1
        registrationID = Self.nextID
        let status = api.install({ _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == OSType(0x544C_4B53) else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            return MainActor.assumeIsolated {
                guard hotKey.isActive, hotKey.registrationID == id.id else { return OSStatus(eventNotHandledErr) }
                let registrationID = id.id
                Task { @MainActor [weak hotKey] in
                    guard let hotKey, hotKey.isActive, hotKey.registrationID == registrationID else { return }
                    hotKey.action()
                }
                return noErr
            }
        }, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr, handler != nil else { fail(status); return }
        let id = EventHotKeyID(signature: OSType(0x544C_4B53), id: registrationID)
        let registrationStatus = api.register(UInt32(keyCode), shortcut.modifiers.rawValue, id, &ref)
        guard registrationStatus == noErr, ref != nil else { fail(registrationStatus); return }
    }

    private func fail(_ status: OSStatus) {
        stop()
        error = L10n.format("Translation shortcut is inactive: macOS could not register it (error %d). It may be used by another app. Record a different shortcut.", status)
    }

    func stop() {
        if let ref { api.unregister(ref) }
        if let handler { api.remove(handler) }
        ref = nil
        handler = nil
    }

    isolated deinit {
        if let ref { api.unregister(ref) }
        if let handler { api.remove(handler) }
    }
}
