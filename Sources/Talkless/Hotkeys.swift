import AppKit
import Carbon.HIToolbox

/// Monitor a single modifier key (Fn, Right Option, etc.) with CGEventTap. Requires Accessibility permission.
@MainActor
final class HotkeyMonitor {
    var triggerKey: TriggerKey = .fn
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
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
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

    /// Return false to consume the event.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true

        case .flagsChanged:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard keyCode == triggerKey.keyCode else { return true }
            let down = isTriggerDown(event.flags)
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
    private func isTriggerDown(_ flags: CGEventFlags) -> Bool {
        let raw = flags.rawValue
        switch triggerKey {
        case .fn: return flags.contains(.maskSecondaryFn)
        case .rightOption: return raw & 0x40 != 0      // NX_DEVICERALTKEYMASK
        case .rightCommand: return raw & 0x10 != 0     // NX_DEVICERCMDKEYMASK
        case .rightControl: return raw & 0x2000 != 0   // NX_DEVICERCTLKEYMASK
        }
    }
}

/// A standard keyboard shortcut (no permission required) for translating selected text.
final class GlobalHotKey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: @MainActor @Sendable () -> Void

    /// Defaults to ⌃⌥T.
    init(keyCode: Int = kVK_ANSI_T, modifiers: Int = controlKey | optionKey, action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            let action = hotKey.action
            DispatchQueue.main.async { action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)

        let id = EventHotKeyID(signature: OSType(0x544C_4B53), id: 1) // 'TLKS'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handler { RemoveEventHandler(handler) }
    }
}
