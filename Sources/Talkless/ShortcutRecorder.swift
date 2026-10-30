import AppKit
import SwiftUI

/// A single physical modifier recorder. It deliberately does not record arbitrary chords.
struct ShortcutRecorder: View {
    let title: String
    let value: String
    var defaultValue: String? = nil
    var isDefault = true
    var allowsClearing = false
    let setCaptureActive: (Bool) -> Bool
    var onReset: (() -> String?)? = nil
    /// Validate before saving; a returned message keeps recording open without changing preferences.
    let onRecord: (TriggerKey?) -> String?

    @Environment(\.isEnabled) private var isEnabled
    @State private var message: String?
    @State private var isError = false

    static let cancelCaptureNotification = Notification.Name("TalklessCancelShortcutCapture")

    static func cancelCapture() {
        NotificationCenter.default.post(name: cancelCaptureNotification, object: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                ShortcutRecorderRepresentable(
                    value: value, accessibilityLabel: title, allowsClearing: allowsClearing,
                    isEnabled: isEnabled, setCaptureActive: setCaptureActive, onRecord: onRecord,
                    onStatus: { text, error in
                        message = text
                        isError = error
                    }
                )
                .frame(width: 230, height: 28)
                if let onReset {
                    Button("Reset") {
                        Self.cancelCapture()
                        message = onReset()
                        isError = message != nil
                    }
                    .disabled(isDefault)
                    .help("Restore the default for \(title.lowercased())")
                    .accessibilityLabel("Reset \(title)")
                }
            }
            if let defaultValue {
                Text("Default: \(defaultValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(isError ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Validation is independent of preferences so rejected recordings never get persisted.
enum ShortcutRecorderRules {
    static func primaryError(_ key: TriggerKey?, alternate: AlternateFinishKey) -> String? {
        guard let key else { return "The dictation key cannot be cleared. Press Fn or a right-side modifier." }
        if alternate.triggerKey == key {
            return "\(key.title) is already the alternate finish key. Record a different key."
        }
        // Existing Automatic preferences adapt to the new primary key rather than collide.
        return nil
    }

    static func alternateError(_ key: TriggerKey?, primary: TriggerKey) -> String? {
        guard let key else { return nil }
        if key == primary {
            return "\(key.title) is already the dictation key. Record a different key."
        }
        return nil
    }
}

/// Event interpretation is kept separate from AppKit focus and monitor ownership for offline tests.
struct ShortcutCaptureState {
    enum Result: Equatable {
        case waiting, record(TriggerKey?), cancel
    }

    private(set) var pendingKey: TriggerKey?
    private(set) var message = "Press Fn or a right-side modifier. Esc cancels."
    private(set) var isError = false
    private var heldKeys: Set<UInt16> = []
    private var invalidGesture = false
    private var waitingForInitialRelease = false
    private var pendingClear = false
    private var pendingCancel = false
    let allowsClearing: Bool

    init(allowsClearing: Bool, initialFlags: NSEvent.ModifierFlags = []) {
        self.allowsClearing = allowsClearing
        waitingForInitialRelease = Self.heldModifiers(initialFlags) != 0
        if waitingForInitialRelease { message = "Release held keys, then press Fn or a right-side modifier." }
    }

    static func key(for keyCode: UInt16) -> TriggerKey? {
        TriggerKey.allCases.first { $0.keyCode == Int64(keyCode) }
    }

    private static let modifierMask: UInt = NSEvent.ModifierFlags([
        .shift, .control, .option, .command, .function
    ]).rawValue | 0x207F

    private static func heldModifiers(_ flags: NSEvent.ModifierFlags) -> UInt {
        flags.rawValue & modifierMask
    }

    private static func mask(for key: TriggerKey) -> UInt {
        switch key {
        case .fn: NSEvent.ModifierFlags.function.rawValue
        case .rightOption: NSEvent.ModifierFlags.option.rawValue | 0x40
        case .rightCommand: NSEvent.ModifierFlags.command.rawValue | 0x10
        case .rightControl: NSEvent.ModifierFlags.control.rawValue | 0x2000
        }
    }

    private static func isDown(_ key: TriggerKey, flags: NSEvent.ModifierFlags) -> Bool {
        switch key {
        case .fn: flags.contains(.function)
        case .rightOption: flags.rawValue & 0x40 != 0
        case .rightCommand: flags.rawValue & 0x10 != 0
        case .rightControl: flags.rawValue & 0x2000 != 0
        }
    }

    mutating func reject(_ error: String) {
        pendingKey = nil
        pendingClear = false
        message = error
        isError = true
    }

    mutating func flagsChanged(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Result {
        let modifiers = Self.heldModifiers(flags)
        if pendingCancel { return modifiers == 0 && heldKeys.isEmpty ? .cancel : .waiting }
        if waitingForInitialRelease {
            if modifiers == 0 {
                waitingForInitialRelease = false
                message = "Press Fn or a right-side modifier. Esc cancels."
            }
            return .waiting
        }
        if invalidGesture {
            if modifiers == 0 && heldKeys.isEmpty { invalidGesture = false }
            return .waiting
        }
        if let pendingKey {
            if modifiers & ~Self.mask(for: pendingKey) != 0 || !heldKeys.isEmpty {
                invalidGesture = true
                reject("Use one key by itself, not a keyboard combination. Release the keys and try again.")
            } else if keyCode == UInt16(pendingKey.keyCode), !Self.isDown(pendingKey, flags: flags) {
                self.pendingKey = nil
                return .record(pendingKey)
            }
            return .waiting
        }
        if keyCode == 57 {
            reject("Caps Lock is not supported. Press Fn or a right-side modifier.")
            return .waiting
        }
        guard modifiers != 0 else { return .waiting }
        guard let key = Self.key(for: keyCode), Self.isDown(key, flags: flags) else {
            let name: String
            switch keyCode {
            case 55: name = "Left Command ⌘"
            case 58: name = "Left Option ⌥"
            case 59: name = "Left Control ⌃"
            case 56: name = "Left Shift ⇧"
            case 60: name = "Right Shift ⇧"
            default: name = "That key"
            }
            invalidGesture = true
            reject("\(name) is not supported. Press Fn or a right-side Command, Option, or Control key.")
            return .waiting
        }
        guard modifiers & ~Self.mask(for: key) == 0, heldKeys.isEmpty else {
            invalidGesture = true
            reject("Use one key by itself, not a keyboard combination. Release the keys and try again.")
            return .waiting
        }
        pendingKey = key
        isError = false
        message = "Release \(key.title) to save. Esc cancels."
        return .waiting
    }

    mutating func keyDown(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Result {
        heldKeys.insert(keyCode)
        if pendingCancel { return .waiting }
        if keyCode == 53 {
            pendingCancel = true
            pendingKey = nil
            message = "Release Esc to cancel."
            isError = false
        } else if (keyCode == 51 || keyCode == 117), Self.heldModifiers(flags) == 0 {
            pendingKey = nil
            if allowsClearing {
                pendingClear = true
                message = "Release Delete to disable alternate finish."
                isError = false
            } else {
                reject("The dictation key cannot be cleared. Press Fn or a right-side modifier.")
            }
        } else {
            invalidGesture = true
            reject("That key or combination is not supported. Press Fn or a right-side modifier by itself.")
        }
        return .waiting
    }

    mutating func keyUp(keyCode: UInt16, flags: NSEvent.ModifierFlags) -> Result {
        heldKeys.remove(keyCode)
        if pendingCancel {
            return Self.heldModifiers(flags) == 0 && heldKeys.isEmpty ? .cancel : .waiting
        }
        if pendingClear, (keyCode == 51 || keyCode == 117), heldKeys.isEmpty,
           Self.heldModifiers(flags) == 0 {
            pendingClear = false
            return .record(nil)
        }
        if Self.heldModifiers(flags) == 0 && heldKeys.isEmpty { invalidGesture = false }
        return .waiting
    }
}

private struct ShortcutRecorderRepresentable: NSViewRepresentable {
    let value: String
    let accessibilityLabel: String
    let allowsClearing: Bool
    let isEnabled: Bool
    let setCaptureActive: (Bool) -> Bool
    let onRecord: (TriggerKey?) -> String?
    let onStatus: (String?, Bool) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let view = ShortcutRecorderButton()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ShortcutRecorderButton, context: Context) {
        view.currentValue = value
        view.allowsClearing = allowsClearing
        view.isEnabled = isEnabled
        view.setCaptureActive = setCaptureActive
        view.onRecord = onRecord
        view.onStatus = onStatus
        view.setAccessibilityLabel(accessibilityLabel)
        view.refreshTitle()
        if !isEnabled { view.endCapture() }
    }

    static func dismantleNSView(_ view: ShortcutRecorderButton, coordinator: ()) {
        view.endCapture()
    }
}

@MainActor
final class ShortcutRecorderButton: NSButton {
    var currentValue = ""
    var allowsClearing = false
    var setCaptureActive: (Bool) -> Bool = { _ in false }
    var onRecord: (TriggerKey?) -> String? = { _ in nil }
    var onStatus: (String?, Bool) -> Void = { _, _ in }
    private(set) var capture: ShortcutCaptureState?
    private var outsideClickMonitor: Any?
    private var focusObservers: [NSObjectProtocol] = []
    private weak var previousResponder: NSResponder?

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        target = self
        action = #selector(clicked)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func refreshTitle() {
        if let capture {
            title = capture.pendingKey.map { "\($0.title) …" } ?? "Press a key…"
        } else {
            title = currentValue
        }
        toolTip = capture == nil ? "Click, then press a key to change this shortcut." : "Esc cancels.\(allowsClearing ? " Delete disables alternate finish." : "")"
        setAccessibilityValue(title)
    }

    @objc private func clicked() {
        if capture != nil { endCapture() } else { beginCapture() }
    }

    func beginCapture() {
        guard isEnabled, capture == nil, let window else { return }
        // Focus the recorder before asking the controller to suspend its global shortcuts.
        previousResponder = window.firstResponder
        guard window.makeFirstResponder(self) else { return }
        guard setCaptureActive(true) else {
            onStatus("Finish dictation before changing shortcuts.", true)
            window.makeFirstResponder(previousResponder)
            return
        }
        capture = ShortcutCaptureState(allowsClearing: allowsClearing, initialFlags: NSEvent.modifierFlags)
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.window || !self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.endCapture()
                }
            }
            return event
        }
        focusObservers.append(NotificationCenter.default.addObserver(
            forName: ShortcutRecorder.cancelCaptureNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.endCapture() }
        })
        for (name, object) in [(NSWindow.didResignKeyNotification, window as AnyObject),
                               (NSApplication.didResignActiveNotification, NSApp as AnyObject)] {
            focusObservers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.endCapture() }
            })
        }
        publishStatus()
    }

    func endCapture(restoreFocus: Bool = true) {
        guard capture != nil else { return }
        capture = nil
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        focusObservers.removeAll()
        _ = setCaptureActive(false)
        // The controller reconciles physically held keys before restoring its monitor.
        if restoreFocus, window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
        previousResponder = nil
        refreshTitle()
        onStatus(nil, false)
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { endCapture(restoreFocus: false) }
        return result
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { endCapture() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func flagsChanged(with event: NSEvent) {
        guard capture != nil else { super.flagsChanged(with: event); return }
        process(capture!.flagsChanged(keyCode: event.keyCode, flags: event.modifierFlags))
    }

    override func keyDown(with event: NSEvent) {
        guard capture != nil else {
            if event.keyCode == 36 || event.keyCode == 49 { beginCapture() }
            else { super.keyDown(with: event) }
            return
        }
        process(capture!.keyDown(keyCode: event.keyCode, flags: event.modifierFlags))
    }

    override func keyUp(with event: NSEvent) {
        guard capture != nil else { super.keyUp(with: event); return }
        process(capture!.keyUp(keyCode: event.keyCode, flags: event.modifierFlags))
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard capture != nil else { return super.performKeyEquivalent(with: event) }
        // Consume Command-based menu shortcuts instead of letting them escape the first responder.
        if event.type == .keyDown { keyDown(with: event) }
        return true
    }

    private func process(_ result: ShortcutCaptureState.Result) {
        switch result {
        case .waiting: publishStatus()
        case .cancel: endCapture()
        case .record(let key):
            if let error = onRecord(key) {
                capture?.reject(error)
                publishStatus()
            } else {
                endCapture()
            }
        }
    }

    private func publishStatus() {
        refreshTitle()
        if let capture { onStatus(capture.message, capture.isError) }
    }
}
