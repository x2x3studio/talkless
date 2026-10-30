import AppKit
import SwiftUI

private struct RecorderPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard shortcuts").font(.headline)
            ShortcutRecorder(title: "Dictation key", value: "Fn / Globe", setCaptureActive: { _ in true }) {
                ShortcutRecorderRules.primaryError($0, alternate: .rightCommand)
            }
            Text("Click a shortcut. Press Fn or a right-side modifier. Release to save; Esc cancels. Single keys only.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            ShortcutRecorder(title: "Alternate finish key", value: "Right Command ⌘", allowsClearing: true, setCaptureActive: { _ in true }) {
                ShortcutRecorderRules.alternateError($0, primary: .fn)
            }
            Text("Click its shortcut and press Delete or Backspace to disable alternate finish.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 620, height: 270)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@main
struct ShortcutRecorderTests {
    @MainActor
    static func main() {
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
            check(ShortcutRecorderRules.primaryError(key, alternate: alternate) != nil, "reject primary conflict")
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
            check(state.keyUp(keyCode: code, flags: []) == .record(nil), "clear alternate on release")
            state = ShortcutCaptureState(allowsClearing: false)
            _ = state.keyDown(keyCode: code, flags: [])
            check(state.isError && state.keyUp(keyCode: code, flags: []) == .waiting, "cannot clear primary")
        }

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
        button.beginCapture()
        check(transitions == [true] && window.firstResponder === button, "click begins suspended first-responder capture")
        button.flagsChanged(with: event(.flagsChanged, 54, rightCommand))
        check(button.title.contains("Right Command") && saved.isEmpty, "native pending feedback without save")
        button.flagsChanged(with: event(.flagsChanged, 54))
        check(button.capture != nil && saved.isEmpty && status?.contains("already") == true, "native conflict remains visible, no save")
        button.flagsChanged(with: event(.flagsChanged, 61, rightOption))
        button.flagsChanged(with: event(.flagsChanged, 61))
        check(saved.count == 1 && saved[0] == .rightOption && transitions == [true, false], "native commit restores monitor exactly once")
        button.beginCapture()
        button.keyDown(with: event(.keyDown, 53))
        button.keyUp(with: event(.keyUp, 53))
        check(button.capture == nil && transitions.suffix(2) == [true, false], "native Escape cleanup")
        button.beginCapture()
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        check(button.capture == nil && transitions.suffix(2) == [true, false], "window blur cleanup")
        button.beginCapture()
        button.removeFromSuperview()
        check(button.capture == nil && transitions.suffix(2) == [true, false], "view disappearance cleanup")
        let count = transitions.count
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        check(transitions.count == count, "observers removed after capture")
        window.contentView!.addSubview(button)
        button.setCaptureActive = { _ in false }
        button.beginCapture()
        check(button.capture == nil && status?.contains("Finish dictation") == true, "idle-only suspension denial")
        if CommandLine.arguments.count > 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let preview = NSHostingView(rootView: RecorderPreview())
            preview.frame = NSRect(x: 0, y: 0, width: 620, height: 270)
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
