import AppKit
import Carbon.HIToolbox
import SwiftUI

private struct RecorderPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard shortcuts").font(.headline)
            ShortcutRecorder(title: "Dictation key", value: "Fn / Globe",
                             defaultValue: "Fn / Globe", isDefault: true,
                             setCaptureActive: { _ in true }, onReset: { nil }) {
                ShortcutRecorderRules.primaryError($0, alternate: .rightCommand)
            }
            Text("Click a shortcut. Press Fn or a right-side modifier. Release to save; Esc cancels. Single keys only.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            ShortcutRecorder(title: "AI polishing shortcut", value: "Right Command ⌘",
                             valueDetail: "Use AI polishing", defaultValue: "Automatic (Right Option ⌥)", isDefault: false,
                             allowsClearing: true, setCaptureActive: { _ in true }, onReset: { nil }) {
                ShortcutRecorderRules.alternateError($0, primary: .fn)
            }
            Text("Click its shortcut and press Delete or Backspace to disable the AI polishing shortcut.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 620, height: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@main
struct ShortcutRecorderTests {
    @MainActor
    static func main() {
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        localization.interfaceLanguage = .english
        defer { withExtendedLifetime(localization) {} }
        var assertions = 0
        func check(_ value: @autoclosure () -> Bool, _ description: String) {
            assertions += 1
            if !value() { fatalError("FAIL: \(description)") }
        }
        let rightOption = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x40)
        let rightCommand = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)
        let rightControl = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue | 0x2000)
        let supported: [(TriggerKey, NSEvent.ModifierFlags)] = [
            (.fn, .function), (.rightOption, rightOption), (.rightCommand, rightCommand), (.rightControl, rightControl)
        ]
        for (key, flags) in supported {
            check(ShortcutCaptureState.key(for: UInt16(key.keyCode)) == key, "physical mapping \(key)")
            var state = ShortcutCaptureState(allowsClearing: false)
            check(state.flagsChanged(keyCode: UInt16(key.keyCode), flags: flags) == .waiting, "no save on press")
            check(state.pendingKey == key && state.message.contains("Release"), "pending key feedback")
            check(state.flagsChanged(keyCode: UInt16(key.keyCode), flags: []) == .record(key), "save on release")
            check(ShortcutRecorderRules.alternateError(key, primary: key) != nil, "reject alternate conflict")
            let alternate = AlternateFinishKey(rawValue: key.rawValue)!
            check(ShortcutRecorderRules.primaryError(key, alternate: alternate)
                  == "\(key.title) is already the AI polishing shortcut. Record a different key.",
                  "Primary conflict identifies the plain stable shortcut label")
            check(ShortcutRecorderRules.primaryError(key, alternate: .automatic) == nil, "automatic fallback stays valid")
        }
        check(AlternateFinishKey.automatic.resolved(for: .rightOption) == .rightCommand, "automatic resolves to real key")
        check(ShortcutRecorderRules.alternateError(.fn, primary: .rightCommand) == nil, "Fn alternate supported")
        check(ShortcutRecorderRules.primaryError(nil, alternate: .disabled) != nil, "primary cannot clear")
        check(ShortcutRecorderRules.alternateError(nil, primary: .fn) == nil, "alternate can clear")

        for (code, flags, name): (UInt16, NSEvent.ModifierFlags, String) in [
            (55, NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x8), "Left Command"),
            (58, NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | 0x20), "Left Option"),
            (59, NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue | 0x1), "Left Control"),
            (56, .shift, "Left Shift"), (60, .shift, "Right Shift")
        ] {
            var state = ShortcutCaptureState(allowsClearing: false)
            _ = state.flagsChanged(keyCode: code, flags: flags)
            check(state.isError && state.pendingKey == nil && state.message.contains(name), "precise unsupported side \(name)")
            check(state.flagsChanged(keyCode: code, flags: []) == .waiting, "unsupported release never saves")
            _ = state.flagsChanged(keyCode: 63, flags: .function)
            check(state.flagsChanged(keyCode: 63, flags: []) == .record(.fn), "retry after unsupported key")
        }
        var state = ShortcutCaptureState(allowsClearing: true)
        _ = state.flagsChanged(keyCode: 57, flags: .capsLock)
        check(state.isError && state.message.contains("Caps Lock"), "unsupported Caps Lock reports an error")
        _ = state.flagsChanged(keyCode: 54, flags: rightCommand)
        _ = state.keyDown(keyCode: 0, flags: rightCommand)
        check(state.isError && state.pendingKey == nil, "reject Command+A chord")
        check(state.flagsChanged(keyCode: 54, flags: []) == .waiting, "chord modifier release does not save")
        _ = state.keyUp(keyCode: 0, flags: [])
        _ = state.flagsChanged(keyCode: 61, flags: rightOption)
        check(state.flagsChanged(keyCode: 61, flags: []) == .record(.rightOption), "valid retry after chord")

        state = ShortcutCaptureState(allowsClearing: false)
        _ = state.flagsChanged(keyCode: 54, flags: rightCommand)
        _ = state.flagsChanged(keyCode: 61, flags: [rightCommand, rightOption])
        check(state.isError && state.pendingKey == nil, "reject two modifiers")
        check(state.flagsChanged(keyCode: 61, flags: rightCommand) == .waiting, "two modifier release does not save")
        check(state.flagsChanged(keyCode: 54, flags: []) == .waiting, "fully releasing chord does not save")

        for escapeFirst in [false, true] {
            state = ShortcutCaptureState(allowsClearing: true)
            _ = state.flagsChanged(keyCode: 54, flags: rightCommand)
            check(state.keyDown(keyCode: 53, flags: rightCommand) == .waiting, "Escape waits for release")
            if escapeFirst {
                check(state.keyUp(keyCode: 53, flags: rightCommand) == .waiting, "Escape release waits for modifier")
                check(state.flagsChanged(keyCode: 54, flags: []) == .cancel, "modifier release completes cancellation")
            } else {
                check(state.flagsChanged(keyCode: 54, flags: []) == .waiting, "modifier release waits for Escape")
                check(state.keyUp(keyCode: 53, flags: []) == .cancel, "Escape release completes cancellation")
            }
        }
        state = ShortcutCaptureState(allowsClearing: true, initialFlags: rightCommand)
        check(state.flagsChanged(keyCode: 54, flags: []) == .waiting && state.pendingKey == nil, "initially held trigger release ignored")
        for code: UInt16 in [51, 117] {
            state = ShortcutCaptureState(allowsClearing: true)
            check(state.keyDown(keyCode: code, flags: []) == .waiting, "clear waits for release")
            check(state.message == "Release Delete to disable the AI polishing shortcut.",
                  "Clear instruction names the shortcut rather than an abstract finish action")
            check(state.keyUp(keyCode: code, flags: []) == .record(nil), "clear alternate on release")
            state = ShortcutCaptureState(allowsClearing: false)
            _ = state.keyDown(keyCode: code, flags: [])
            check(state.isError && state.keyUp(keyCode: code, flags: []) == .waiting, "cannot clear primary")
        }

        for flags: NSEvent.ModifierFlags in [.command, .control, .option, [.command, .shift], [.control, .option]] {
            let shortcut = TranslationShortcut(keyCode: 17, modifiers: TranslationShortcutCapture.modifiers(flags))
            check(shortcut.validationError == nil, "Cmd/Ctrl/Option chords accepted")
            for ordinaryFirst in [true, false] {
                var chord = TranslationShortcutCapture()
                check(chord.keyDown(keyCode: 17, flags: flags) == .waiting, "Chord press never saves")
                check(chord.pendingShortcut == shortcut && chord.message.contains("Release"), "Chord feedback")
                if ordinaryFirst {
                    check(chord.keyUp(keyCode: 17, flags: flags) == .waiting, "Ordinary release waits for modifiers")
                    check(chord.flagsChanged(keyCode: 55, flags: []) == .record(shortcut), "Last modifier release commits")
                } else {
                    check(chord.flagsChanged(keyCode: 55, flags: []) == .waiting, "Modifier release waits for ordinary key")
                    check(chord.keyUp(keyCode: 17, flags: []) == .record(shortcut), "Last ordinary release commits")
                }
            }
        }
        check(TranslationShortcut.default.title == "⌃⌥T", "Default display unchanged")
        for shortcut in [TranslationShortcut(keyCode: 17, modifiers: []),
                         TranslationShortcut(keyCode: 17, modifiers: .shift),
                         TranslationShortcut(keyCode: 63, modifiers: .command),
                         TranslationShortcut(keyCode: 49, modifiers: .command),
                         TranslationShortcut(keyCode: 48, modifiers: .command)] {
            check(shortcut.validationError != nil, "Plain, modifier-only, and reserved keys rejected")
        }
        var chord = TranslationShortcutCapture()
        _ = chord.keyDown(keyCode: 17, flags: [])
        check(chord.isError && chord.keyUp(keyCode: 17, flags: []) == .waiting, "Plain key does not save")
        _ = chord.keyDown(keyCode: 17, flags: [.control, .option])
        _ = chord.keyDown(keyCode: 53, flags: [.control, .option])
        _ = chord.keyUp(keyCode: 17, flags: [.control, .option])
        _ = chord.keyUp(keyCode: 53, flags: [.control, .option])
        check(chord.flagsChanged(keyCode: 59, flags: []) == .cancel, "Escape cancels full chord after release")
        for code: UInt16 in [51, 117] {
            chord = TranslationShortcutCapture()
            check(chord.keyDown(keyCode: code, flags: []) == .waiting, "Clear waits for release")
            check(chord.keyUp(keyCode: code, flags: []) == .record(.disabled), "Backspace and forward Delete disable")
        }
        chord = TranslationShortcutCapture(initialFlags: .command)
        _ = chord.keyDown(keyCode: 17, flags: .command)
        _ = chord.flagsChanged(keyCode: 55, flags: [])
        check(chord.keyUp(keyCode: 17, flags: []) == .waiting, "Held-at-start gesture ignored entirely")
        chord = TranslationShortcutCapture()
        _ = chord.keyDown(keyCode: 17, flags: .command)
        _ = chord.keyDown(keyCode: 9, flags: .command)
        _ = chord.keyUp(keyCode: 17, flags: .command)
        _ = chord.keyUp(keyCode: 9, flags: .command)
        check(chord.flagsChanged(keyCode: 55, flags: []) == .waiting && chord.isError, "Two ordinary keys rejected")

        // Inject every Carbon call, including allocation/failure cleanup; never register a real key.
        let fakeRef = OpaquePointer(bitPattern: 1)!
        var lifecycle: [String] = []
        var registrationStatus: OSStatus = noErr
        var installationStatus: OSStatus = noErr
        var received: [(UInt32, UInt32)] = []
        let api = GlobalHotKey.API(
            install: { _, _, handler in lifecycle.append("install"); handler = fakeRef; return installationStatus },
            register: { code, modifiers, _, ref in
                lifecycle.append("register"); received.append((code, modifiers)); ref = fakeRef; return registrationStatus
            },
            unregister: { _ in lifecycle.append("unregister") },
            remove: { _ in lifecycle.append("remove") }
        )
        var global: GlobalHotKey? = GlobalHotKey(api: api, action: { fatalError("Offline test must not invoke translation") })
        global!.update(.default)
        check(global!.isActive && global!.error == nil && received[0].0 == 17 && received[0].1 == 6144, "Carbon receives default code/mask")
        lifecycle = []
        let custom = TranslationShortcut(keyCode: 9, modifiers: [.command, .option])
        global!.update(custom)
        check(lifecycle == ["unregister", "remove", "install", "register"], "Old registration cleaned before replacement")
        check(received.last!.0 == 9 && received.last!.1 == 2304, "Custom chord forwarded to Carbon")
        registrationStatus = OSStatus(eventHotKeyExistsErr)
        lifecycle = []
        global!.update(.default)
        check(!global!.isActive && global!.error?.contains("inactive") == true, "Registration failure visibly inactive")
        check(lifecycle == ["unregister", "remove", "install", "register", "unregister", "remove"], "Partial failed registration and old key cleaned")
        lifecycle = []
        global!.update(.disabled)
        check(lifecycle.isEmpty && !global!.isActive && global!.error == nil, "Disable clears failure without registering")
        installationStatus = -1
        global!.update(.default)
        check(!global!.isActive && lifecycle == ["install", "remove"] && global!.error != nil, "Handler failure cleaned without registering")
        installationStatus = noErr
        registrationStatus = noErr
        global!.update(.default)
        lifecycle = []
        global!.stop()
        global!.stop()
        check(lifecycle == ["unregister", "remove"] && !global!.isActive, "Capture suspension cleanup is idempotent")
        global!.update(custom)
        lifecycle = []
        global = nil
        check(lifecycle == ["unregister", "remove"], "Deinit unregisters active binding")

        // Native control lifecycle checks use synthetic local events and an unshown window.
        // No real preferences, microphone, Accessibility grant, event tap, or posted key events.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let button = ShortcutRecorderButton(frame: NSRect(x: 20, y: 20, width: 205, height: 28))
        window.contentView!.addSubview(button)
        var transitions: [Bool] = []
        var saved: [TriggerKey?] = []
        var status: String?
        button.currentValue = TriggerKey.fn.title
        button.setCaptureActive = { transitions.append($0); return true }
        button.onStatus = { text, _ in status = text }
        button.onRecord = { key in
            if let error = ShortcutRecorderRules.primaryError(key, alternate: .rightCommand) { return error }
            saved.append(key)
            return nil
        }
        func event(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: "",
                             charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
        }
        button.beginCapture(initialFlags: [])
        check(transitions == [true] && window.firstResponder === button, "click begins suspended first-responder capture")
        button.flagsChanged(with: event(.flagsChanged, 54, rightCommand))
        check(button.title.contains("Right Command") && saved.isEmpty, "native pending feedback without save")
        button.flagsChanged(with: event(.flagsChanged, 54))
        check(button.capture != nil && saved.isEmpty && status?.contains("already") == true, "native conflict remains visible, no save")
        button.flagsChanged(with: event(.flagsChanged, 61, rightOption))
        button.flagsChanged(with: event(.flagsChanged, 61))
        check(saved.count == 1 && saved[0] == .rightOption && transitions == [true, false], "native commit restores monitor exactly once")
        button.beginCapture(initialFlags: [])
        button.keyDown(with: event(.keyDown, 53))
        button.keyUp(with: event(.keyUp, 53))
        check(button.capture == nil && transitions.suffix(2) == [true, false], "native Escape cleanup")
        button.beginCapture(initialFlags: [])
        button.flagsChanged(with: event(.flagsChanged, 54, rightCommand))
        let savedBeforeReset = saved.count
        ShortcutRecorder.cancelCapture()
        check(button.capture == nil && transitions.suffix(2) == [true, false], "reset cancels pending capture synchronously")
        check(saved.count == savedBeforeReset, "reset never commits the pending shortcut")
        let transitionsAfterReset = transitions.count
        ShortcutRecorder.cancelCapture()
        check(transitions.count == transitionsAfterReset, "reset cancellation removes observer and resumes only once")
        button.beginCapture(initialFlags: [])
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        check(button.capture == nil && transitions.suffix(2) == [true, false], "window blur cleanup")
        button.beginCapture(initialFlags: [])
        button.removeFromSuperview()
        check(button.capture == nil && transitions.suffix(2) == [true, false], "view disappearance cleanup")
        let count = transitions.count
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        check(transitions.count == count, "observers removed after capture")
        window.contentView!.addSubview(button)
        button.setCaptureActive = { _ in false }
        button.beginCapture(initialFlags: [])
        check(button.capture == nil && status?.contains("Finish dictation") == true, "idle-only suspension denial")
        button.setCaptureActive = { transitions.append($0); return true }
        var recordedTranslations: [TranslationShortcut] = []
        button.onTranslationRecord = { recordedTranslations.append($0); return nil }
        button.currentValue = TranslationShortcut.default.title
        button.beginCapture(initialFlags: [])
        check(button.performKeyEquivalent(with: event(.keyDown, 17, .command)), "Translation consumes Command key equivalent")
        check(recordedTranslations.isEmpty && button.capture != nil, "Native chord waits for release")
        button.keyUp(with: event(.keyUp, 17, .command))
        check(recordedTranslations.isEmpty, "Native chord waits for last modifier")
        button.flagsChanged(with: event(.flagsChanged, 55))
        check(recordedTranslations == [TranslationShortcut(keyCode: 17, modifiers: .command)] && button.capture == nil,
              "Native chord saves once after all release")
        ApplicationEditMenu.install()
        button.beginCapture(initialFlags: [])
        let pasteKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                       characters: "v", charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9)!
        NSApp.sendEvent(pasteKey)
        check(button.capture != nil && recordedTranslations.count == 1,
              "active recorder consumes Cmd+V before installed Edit menu")
        button.keyUp(with: event(.keyUp, 9, .command))
        button.flagsChanged(with: event(.flagsChanged, 55))
        check(recordedTranslations.last == TranslationShortcut(keyCode: 9, modifiers: .command),
              "Cmd+V records as a shortcut instead of editing while capturing")
        recordedTranslations.removeLast()
        button.beginCapture(initialFlags: [])
        button.keyDown(with: event(.keyDown, 9, .option))
        ShortcutRecorder.cancelCapture()
        check(button.capture == nil && recordedTranslations.count == 1, "Shared reset cancellation discards pending translation")
        button.beginCapture(initialFlags: [])
        button.keyDown(with: event(.keyDown, 51))
        button.keyUp(with: event(.keyUp, 51))
        check(recordedTranslations.last == .disabled && button.capture == nil, "Native translation clear")
        button.beginCapture(initialFlags: [])
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        check(button.capture == nil && transitions.suffix(2) == [true, false], "Native translation blur resumes monitors")
        if CommandLine.arguments.count > 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let preview = NSHostingView(rootView: RecorderPreview())
            preview.frame = NSRect(x: 0, y: 0, width: 620, height: 340)
            let previewWindow = NSWindow(contentRect: preview.frame, styleMask: [.titled], backing: .buffered, defer: false)
            previewWindow.contentView = preview
            previewWindow.appearance = NSAppearance(named: .aqua)
            preview.layoutSubtreeIfNeeded()
            func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); preview.layoutSubtreeIfNeeded() }
            func save(_ name: String) {
                settle()
                let bitmap = preview.bitmapImageRepForCachingDisplay(in: preview.bounds)!
                preview.cacheDisplay(in: preview.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
            }
            func recorder(in view: NSView) -> ShortcutRecorderButton? {
                if let button = view as? ShortcutRecorderButton { return button }
                return view.subviews.lazy.compactMap { recorder(in: $0) }.first
            }
            save("normal")
            let previewButton = recorder(in: preview)!
            previewButton.beginCapture()
            previewButton.flagsChanged(with: event(.flagsChanged, 54, rightCommand))
            save("pending")
            previewButton.flagsChanged(with: event(.flagsChanged, 54))
            save("conflict")
            previewButton.endCapture()
            print("Snapshots: \(directory.path)")
        }
        print("PASS: \(assertions) shortcut recorder checks")
    }
}
