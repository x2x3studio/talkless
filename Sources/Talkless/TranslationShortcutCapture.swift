import AppKit

/// A chord is committed only after its ordinary key and every modifier are released.
struct TranslationShortcutCapture {
    enum Result: Equatable { case waiting, record(TranslationShortcut), cancel }
    private(set) var pendingShortcut: TranslationShortcut?
    private(set) var message = L10n.tr("Press a shortcut with Command, Control, or Option. Esc cancels; Delete clears.")
    private(set) var isError = false
    private var heldKeys: Set<UInt16> = []
    private var waitingForRelease: Bool
    private var invalidGesture = false
    private var cancelling = false

    init(initialFlags: NSEvent.ModifierFlags = []) {
        waitingForRelease = Self.hasModifiers(initialFlags)
        if waitingForRelease { message = L10n.tr("Release held keys, then press a shortcut.") }
    }

    private static func hasModifiers(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.rawValue & (NSEvent.ModifierFlags([.command, .control, .option, .shift, .function]).rawValue | 0x207F) != 0
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> TranslationShortcut.Modifiers {
        var result: TranslationShortcut.Modifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }

    mutating func reject(_ error: String) {
        pendingShortcut = nil
        message = error
        isError = true
    }

    mutating func flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Result {
        if let pendingShortcut, !Self.modifiers(flags).subtracting(pendingShortcut.modifiers).isEmpty || flags.contains(.function) {
            invalidGesture = true
            reject(L10n.tr("The combination changed. Release all keys and try again."))
        }
        return finishIfReleased(flags)
    }

    mutating func keyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Result {
        let isRepeat = !heldKeys.insert(keyCode).inserted
        if keyCode == 53 {
            cancelling = true
            pendingShortcut = nil
            message = L10n.tr("Release all keys to cancel.")
            isError = false
            return .waiting
        }
        guard !cancelling, !waitingForRelease, !invalidGesture, !isRepeat else { return .waiting }
        guard heldKeys.count == 1 else {
            invalidGesture = true
            reject(L10n.tr("Use one non-modifier key with modifiers. Release all keys and try again."))
            return .waiting
        }
        let shortcut: TranslationShortcut
        if (keyCode == 51 || keyCode == 117), !Self.hasModifiers(flags) {
            shortcut = .disabled
        } else {
            shortcut = TranslationShortcut(keyCode: keyCode, modifiers: Self.modifiers(flags))
        }
        if flags.contains(.function) {
            invalidGesture = true
            reject(L10n.tr("Fn combinations are not supported. Use Command, Control, or Option."))
        } else if let error = shortcut.validationError {
            invalidGesture = true
            reject(error)
        } else {
            pendingShortcut = shortcut
            message = shortcut == .disabled ? L10n.tr("Release Delete to disable translation shortcut.") : L10n.format("Release %@ to save. Esc cancels.", shortcut.title)
            isError = false
        }
        return .waiting
    }

    mutating func keyUp(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Result {
        heldKeys.remove(keyCode)
        return finishIfReleased(flags)
    }

    private mutating func finishIfReleased(_ flags: NSEvent.ModifierFlags) -> Result {
        guard heldKeys.isEmpty, !Self.hasModifiers(flags) else { return .waiting }
        if cancelling { return .cancel }
        if waitingForRelease { waitingForRelease = false; return .waiting }
        if invalidGesture { invalidGesture = false; return .waiting }
        guard let pendingShortcut else { return .waiting }
        self.pendingShortcut = nil
        return .record(pendingShortcut)
    }
}

/// Both recorders share exactly the same focus, local event consumption, and suspension lifecycle.
enum RecorderCapture {
    enum Result { case waiting, record(TriggerKey?), translation(TranslationShortcut), cancel }
    case modifier(ShortcutCaptureState)
    case translation(TranslationShortcutCapture)

    var pendingTitle: String? {
        switch self {
        case .modifier(let state): state.pendingKey?.title
        case .translation(let state): state.pendingShortcut?.title
        }
    }
    var message: String {
        switch self { case .modifier(let state): state.message; case .translation(let state): state.message }
    }
    var isError: Bool {
        switch self { case .modifier(let state): state.isError; case .translation(let state): state.isError }
    }
    mutating func reject(_ error: String) {
        switch self {
        case .modifier(var state): state.reject(error); self = .modifier(state)
        case .translation(var state): state.reject(error); self = .translation(state)
        }
    }
    mutating func handle(_ type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Result {
        switch self {
        case .modifier(var state):
            let result: ShortcutCaptureState.Result
            switch type {
            case .flagsChanged: result = state.flagsChanged(keyCode: keyCode, flags: flags)
            case .keyDown: result = state.keyDown(keyCode: keyCode, flags: flags)
            default: result = state.keyUp(keyCode: keyCode, flags: flags)
            }
            self = .modifier(state)
            switch result { case .waiting: return .waiting; case .cancel: return .cancel; case .record(let key): return .record(key) }
        case .translation(var state):
            let result: TranslationShortcutCapture.Result
            switch type {
            case .flagsChanged: result = state.flagsChanged(keyCode: keyCode, flags: flags)
            case .keyDown: result = state.keyDown(keyCode: keyCode, flags: flags)
            default: result = state.keyUp(keyCode: keyCode, flags: flags)
            }
            self = .translation(state)
            switch result { case .waiting: return .waiting; case .cancel: return .cancel; case .record(let key): return .translation(key) }
        }
    }
}
