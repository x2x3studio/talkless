#!/usr/bin/env python3
"""Exercise production hotkey dispatch and controller gestures without UI or audio.

Run: python3 -I Tests/HotkeyTests/run-tests.py
Synthetic CGEvents are delivered directly, never posted to the system. Only the
recorder/session/HUD dependencies are faked; gesture methods come from production.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
controller = (ROOT / "Sources/Talkless/DictationController.swift").read_text()
settings = (ROOT / "Sources/Talkless/Settings.swift").read_text()
gesture_mode = settings.split("enum RecordingGestureMode:", 1)[1].split("\nenum ", 1)[0]
gesture_mode = "enum RecordingGestureMode:" + gesture_mode
hotkeys = (ROOT / "Sources/Talkless/Hotkeys.swift").read_text()
hotkeys = hotkeys.split("/// A standard keyboard shortcut", 1)[0]
hotkeys = hotkeys.replace("private func handle(type:", "func handle(type:")
# Deterministic physical-state queries for event-tap recovery; never depend on the user's held keys.
hotkeys = hotkeys.replace("CGEventSource.flagsState(.combinedSessionState)", "TestKeyboardState.flags")


def method(name):
    """Copy the complete production method, including nested closures/branches."""
    start = re.search(r"    (?:private )?func " + name + r"\(", controller)
    assert start, f"Missing production method: {name}"
    opening = controller.index("{", start.start())
    depth = 1
    end = opening + 1
    while depth:
        depth += (controller[end] == "{") - (controller[end] == "}")
        end += 1
    return controller[start.start():end].replace("private func ", "func ", 1)


fields = []
for name in ("pressedAt", "recordingGestureMode", "recordingPolishEnabled",
             "shortcutCaptureActive", "resumeHotkeyAfterCapture"):
    match = re.search(r"^    private (?:var|let) " + name + r"\b[^\n]*", controller, re.M)
    assert match, f"Missing production field: {name}"
    fields.append(match.group().replace("private ", "", 1))
error_callback = re.search(
    r"onError: \{ \[weak self\] message in\n(.*?)\n                \}",
    controller, re.S,
)
assert error_callback, "Missing production Qwen error callback"
recorder_error_callback = re.search(
    r"recorder.onError = \{ \[weak self\] message in\n(.*?)\n        \}", controller, re.S,
)
assert recorder_error_callback, "Missing production recorder interruption callback"

STUBS = r'''
// Extracted controller fixtures use deterministic English without preferences or resources.
enum L10n {
    static func tr(_ key: String) -> String { key }
    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: key, locale: Locale(identifier: "en"), arguments: args)
    }
}
@MainActor enum TestKeyboardState {
    static var flags: CGEventFlags = []
}
enum TriggerKey {
    case fn, rightOption, rightCommand, rightControl
    var keyCode: Int64 {
        switch self {
        case .fn: 63
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        }
    }
    var title: String { String(describing: self) }
}
struct Settings {
    var recordingGestureMode: RecordingGestureMode = .hold
    var polishEnabled = true
    var triggerKey: TriggerKey = .fn
}
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()
    var events: [(String, [String: String])] = []
    func record(event: String, metadata: [String: String] = [:]) { events.append((event, metadata)) }
}
@MainActor final class FakeHUD {
    enum Phase { case listening(handsFree: Bool), error(String) }
    var model: FakeHUD { self }
    func setDictionaryTerms(_ terms: [String]) {}
    func show(_ phase: Phase) {}
    func hide() {}
}
@MainActor final class FakeRecorder { func cancel() {} }
@MainActor final class FakeSession { func cancel() {} }
@MainActor final class FakeTranslationHotKey {
    var isActive = false
    var error: String?
    var fail = false
    var updates: [TranslationShortcut] = []
    var stops = 0
    func stop() { stops += 1; isActive = false }
    func update(_ shortcut: TranslationShortcut) {
        updates.append(shortcut)
        isActive = shortcut != .disabled && !fail
        error = fail ? "Synthetic registration failure" : nil
    }
}
@MainActor final class FakeTranslationPanel {
    var isVisible = false
    func close() { isVisible = false }
}
@MainActor final class GestureHarness {
    enum State { case idle, recording, processing }
    var state: State = .idle
    var hotkeyActive = false
    var translateHotKey: FakeTranslationHotKey? = FakeTranslationHotKey()
    var translationShortcutActive = false
    var translationShortcutError: String?
    var configuredTranslationShortcut: TranslationShortcut = .default
    var activationCalls = 0
    @discardableResult func activateHotkey() -> Bool {
        guard !shortcutCaptureActive else { return false }
        activationCalls += 1
        hotkeyActive = true
        return true
    }
    var handsFree = false
    var generation = 0
    var acceptsRecognitionHUDUpdates = false
    private var diagnosticOperation: DictationOperation?
    var recordingModelDirectory: URL?
    let hud = FakeHUD()
    let translationPanel = FakeTranslationPanel()
    let recorder = FakeRecorder()
    var session: FakeSession?
    var processingTask: Task<Void, Never>?
    var startupTask: Task<Void, Never>?
    var onSetup: (() -> Void)?
    var starts = 0
    var stops = 0
    var stoppedPolish: Bool?
    var editSelection: String?
    var settings = Settings()
    var hotkeys: HotkeyMonitor { monitor }
    var onError: ((String) -> Void)?
    var onRecorderError: ((String) -> Void)?
    let monitor = HotkeyMonitor()
    init() {
        monitor.onPress = { [weak self] in self?.triggerPressed(at: $0) }
        monitor.onRelease = { [weak self] in self?.triggerReleased(at: $0) }
        monitor.onComboKey = { [weak self] in self?.comboKeyPressed(at: $0) }
        monitor.onEscape = { [weak self] in self?.escapePressed() ?? false }
    }
    func startRecording() {
        generation += 1
        acceptsRecognitionHUDUpdates = true
        diagnosticOperation = DictationOperation(generation: generation, engine: "qwen",
                                                 recordingMode: recordingGestureMode.rawValue, handsFree: handsFree)
        onSetup?()
        starts += 1
        session = FakeSession()
        let generation = self.generation
        onError = { [weak self] message in
__ERROR_CALLBACK__
        }
        onRecorderError = { [weak self] message in
__RECORDER_ERROR_CALLBACK__
        }
        state = .recording
        recordingPolishEnabled = settings.polishEnabled
    }
    func stopAndProcess() {
        guard state == .recording else { return }
        stops += 1
        stoppedPolish = recordingPolishEnabled
        pressedAt = nil
        state = .processing
    }
    @discardableResult
    func flags(_ timestamp: UInt64, key: CGKeyCode, raw: UInt64) -> Bool {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: raw)
        event.timestamp = timestamp
        return monitor.handle(type: .flagsChanged, event: event)
    }
    func event(_ type: CGEventType, at timestamp: UInt64, down: Bool = false, key: CGKeyCode = 63) {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
        event.type = type
        event.flags = down ? .maskSecondaryFn : []
        event.timestamp = timestamp
        _ = monitor.handle(type: type, event: event)
    }
    func press(_ timestamp: UInt64) { event(.flagsChanged, at: timestamp, down: true) }
    func release(_ timestamp: UInt64) { event(.flagsChanged, at: timestamp) }
    func combo(_ timestamp: UInt64) { event(.keyDown, at: timestamp, down: true, key: 123) }
'''

TESTS = r'''
}
@main struct Tests {
    @MainActor static func main() {
        let base: UInt64 = 10_000_000_000
        for mode in RecordingGestureMode.allCases {
            let cold = GestureHarness()
            cold.settings.recordingGestureMode = mode
            // This gesture-only fixture assumes startup has completed. Real async
            // pending-start races run production code in run-processing-hud-tests.py.
            cold.press(base)
            cold.release(base + 100_000_000)
            precondition(cold.state == (mode == .hold ? .processing : .recording),
                         "Completed startup must preserve the selected release behavior")
            precondition(cold.stops == (mode == .hold ? 1 : 0) && cold.pressedAt == nil)
            // Trailing presses after a completed start finish exactly once.
            cold.press(base + 180_000_000)
            cold.release(base + 250_000_000)
            precondition(cold.state == .processing && cold.stops == 1 && cold.starts == 1,
                         "Queued double tap must stop exactly once, without starting again")
        }
        print("PASS Hold and Toggle after completed startup and queued double tap")

        for mode in RecordingGestureMode.allCases {
            for duration: UInt64 in [0, 100_000_000, 299_000_000, 300_000_000, 400_000_000, 2_000_000_000] {
                let test = GestureHarness()
                test.settings.recordingGestureMode = mode
                test.press(base)
                precondition(test.handsFree == (mode == .toggle), "Toggle starts hands-free immediately")
                test.release(base + duration)
                let stopsOnRelease = mode == .hold
                precondition(test.pressedAt == nil)
                if stopsOnRelease {
                    precondition(test.state == .processing && test.stops == 1 && !test.handsFree,
                                 "Hold always finishes on release, including a zero-duration tap")
                } else {
                    precondition(test.state == .recording && test.stops == 0 && test.handsFree,
                                 "Toggle never finishes on release, even after a long hold")
                    test.press(base + duration + 10)
                    precondition(test.state == .processing && test.stops == 1)
                    test.state = .idle // completion may precede the trailing release
                    test.release(base + duration + 20)
                    precondition(test.starts == 1 && test.stops == 1 && test.state == .idle)
                }
            }
        }
        print("PASS all recording modes, zero/short/long releases, and second-press finish")

        for mode in RecordingGestureMode.allCases {
            for changedMode in RecordingGestureMode.allCases where changedMode != mode {
                for changeDuringSetup in [true, false] {
                    let test = GestureHarness()
                    test.settings.recordingGestureMode = mode
                    if changeDuringSetup {
                        test.onSetup = { [unowned test] in test.settings.recordingGestureMode = changedMode }
                    }
                    test.press(base)
                    test.settings.recordingGestureMode = changedMode
                    test.release(base + 100_000_000)
                    precondition(test.recordingGestureMode == mode,
                                 "Setup and mid-recording changes must not replace the starting snapshot")
                    precondition(test.stops == (mode == .hold ? 1 : 0))
                    precondition(test.handsFree == (mode != .hold))
                    test.cancel()
                    test.onSetup = nil
                    test.press(base + 200_000_000)
                    precondition(test.recordingGestureMode == changedMode,
                                 "The next recording uses the changed setting")
                    test.release(base + 600_000_000)
                    precondition(test.state == (changedMode == .toggle ? .recording : .processing))
                }
            }
        }
        print("PASS recording mode snapshots before setup and settings changes between recordings")

        for mode in RecordingGestureMode.allCases {
            let duplicate = GestureHarness()
            duplicate.settings.recordingGestureMode = mode
            duplicate.press(base)
            duplicate.press(base + 50_000_000)
            duplicate.release(base + 100_000_000)
            duplicate.release(base + 150_000_000)
            precondition(duplicate.starts == 1 && duplicate.stops == (mode == .hold ? 1 : 0))
            precondition(duplicate.handsFree == (mode == .toggle))
        }
        print("PASS duplicate modifier transitions are ignored")

        let malformed = GestureHarness()
        malformed.press(base)
        malformed.release(base - 1)
        precondition(malformed.state == .recording && !malformed.handsFree && malformed.stops == 0,
                     "Out-of-order timestamp must be ignored, not subtract with UInt64 underflow")
        malformed.cancel()
        precondition(malformed.pressedAt == nil && malformed.state == .idle)
        malformed.release(base + 100_000_000)
        precondition(malformed.state == .idle)
        print("PASS out-of-order timestamp and release after cancellation")

        let combo = GestureHarness()
        combo.press(base)
        combo.combo(base + 100_000_000)
        precondition(combo.state == .idle && combo.pressedAt == nil && combo.stops == 0)
        combo.release(base + 150_000_000)
        precondition(combo.state == .idle)
        let lateCombo = GestureHarness()
        lateCombo.press(base)
        lateCombo.combo(base - 1)
        precondition(lateCombo.state == .recording)
        lateCombo.combo(base + 1_000_000_000)
        precondition(lateCombo.state == .recording,
                     "One-second combo window must use event duration, not handler elapsed")
        lateCombo.cancel()
        print("PASS Fn combo cancellation, timestamp ordering, and one-second boundary")

        for mode in RecordingGestureMode.allCases {
            let test = GestureHarness()
            test.settings.recordingGestureMode = mode
            test.press(base)
            test.combo(base + 999_000_000)
            precondition(test.state == .idle && test.pressedAt == nil && test.stops == 0,
                         "Initial primary shortcut must cancel even when toggle starts hands-free")
            test.release(base + 1_000_000_000)
            precondition(test.state == .idle && test.stops == 0)
        }
        print("PASS accidental primary combo cancellation in Hold and Toggle")

        for mode in RecordingGestureMode.allCases {
            let stale = GestureHarness()
            stale.settings.recordingGestureMode = mode
            stale.press(base)
            let oldError = stale.onError!
            stale.cancel()
            stale.release(base + 100_000_000)
            stale.press(base + 200_000_000)
            oldError("synthetic stale error")
            precondition(stale.state == .recording,
                         "Cancelled generation's error must not cancel the next recording")
            if mode == .toggle { stale.release(base + 250_000_000) }
            precondition(stale.handsFree == (mode == .toggle) && stale.starts == 2 && stale.stops == 0)
            stale.onError!("synthetic current error")
            precondition(stale.state == .idle && stale.pressedAt == nil)
            stale.release(base + 300_000_000)
            precondition(stale.state == .idle && stale.stops == 0)
        }
        print("PASS old-generation error suppression and current-generation cancellation")

        let menu = GestureHarness()
        menu.toggleFromMenu()
        precondition(menu.state == .recording && menu.handsFree && menu.pressedAt == nil)
        menu.release(base)
        precondition(menu.state == .recording && menu.handsFree)
        menu.press(base + 100_000_000)
        menu.release(base + 150_000_000)
        precondition(menu.state == .processing && menu.stops == 1)
        print("PASS menu hands-free has no physical press timestamp")

        let fn = CGEventFlags.maskSecondaryFn.rawValue
        let option = CGEventFlags.maskAlternate.rawValue | 0x40
        let command = CGEventFlags.maskCommand.rawValue | 0x10
        let control = CGEventFlags.maskControl.rawValue | 0x2000
        let modifiers: [(TriggerKey, CGKeyCode, UInt64)] = [
            (.rightOption, 61, option), (.rightCommand, 54, command), (.rightControl, 62, control)
        ]
        for mode in RecordingGestureMode.allCases {
            let menu = GestureHarness()
            menu.settings.recordingGestureMode = mode
            menu.toggleFromMenu()
            precondition(menu.state == .recording && menu.handsFree && menu.pressedAt == nil)
            menu.triggerReleased(at: base + 100_000_000)
            precondition(menu.state == .recording, "Menu start never requires a held primary")
            menu.press(base + 200_000_000)
            precondition(menu.stops == 1 && menu.state == .processing,
                         "Primary press finishes menu recordings regardless of selected interaction")
            for releasePrimary in [false, true] {
                // Hold mode finishes on release, so Escape is tested while still held.
                if releasePrimary && mode == .hold { continue }
                let test = GestureHarness()
                test.settings.recordingGestureMode = mode
                test.press(base)
                if releasePrimary { test.release(base + 100_000_000) }
                test.event(.keyDown, at: base + 200_000_000, key: 53)
                precondition(test.state == .idle && test.stops == 0 && test.pressedAt == nil)
                test.release(base + 250_000_000)
                precondition(test.starts == 1 && test.stops == 0, "Trailing primary release cannot act after Escape")
            }
        }
        print("PASS menu starts and Escape for all recording modes")

        // The retired AI polishing shortcut: no other modifier ever finishes or starts a recording.
        for (primary, primaryCode, primaryMask) in [(.fn, CGKeyCode(63), fn)] + modifiers {
            for (other, otherCode, otherMask) in modifiers where other != primary {
                for handsFree in [false, true] {
                    let test = GestureHarness()
                    test.settings.triggerKey = primary
                    test.monitor.triggerKey = primary
                    test.settings.recordingGestureMode = handsFree ? .toggle : .hold
                    test.flags(base, key: primaryCode, raw: primaryMask)
                    if handsFree { test.flags(base + 50_000_000, key: primaryCode, raw: 0) }
                    let held = handsFree ? 0 : primaryMask
                    test.flags(base + 400_000_000, key: otherCode, raw: held | otherMask)
                    test.flags(base + 450_000_000, key: otherCode, raw: held)
                    precondition(test.state == .recording && test.stops == 0,
                                 "\(other) never finishes a \(primary) recording")
                }
            }
        }
        let idle = GestureHarness()
        idle.flags(base, key: 61, raw: option)
        idle.flags(base + 10, key: 61, raw: 0)
        precondition(idle.state == .idle && idle.starts == 0, "Other modifiers never start dictation")
        print("PASS other modifiers are inert for every dictation key and mode")

        for enabled in [true, false] {
            let normal = GestureHarness()
            normal.settings.polishEnabled = enabled
            normal.press(base)
            normal.settings.polishEnabled = !enabled
            normal.settings.recordingGestureMode = .toggle
            normal.release(base + 400_000_000)
            precondition(normal.stoppedPolish == enabled && normal.recordingGestureMode == .hold,
                         "Polishing follows the recording-start snapshot, not changed Settings")
        }
        let changedTrigger = GestureHarness()
        changedTrigger.press(base)
        changedTrigger.settings.triggerKey = .rightControl
        changedTrigger.updateTriggerKey()
        precondition(changedTrigger.monitor.triggerKey == .fn)
        changedTrigger.release(base + 400_000_000)
        precondition(changedTrigger.stops == 1)
        changedTrigger.state = .idle
        changedTrigger.updateTriggerKey()
        precondition(changedTrigger.monitor.triggerKey == .rightControl)
        print("PASS polish snapshot and dictation key changes wait for idle")

        for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
            let recovered = GestureHarness()
            recovered.press(base)
            // The tap missed the release; recovery reads the physical state without acting.
            TestKeyboardState.flags = []
            recovered.event(type, at: base + 10)
            precondition(recovered.state == .recording && recovered.stops == 0,
                         "Event-tap recovery never fabricates a finish")
            recovered.press(base + 20)
            precondition(recovered.state == .recording && recovered.stops == 0, "A fresh hold press does not finish")
            recovered.release(base + 30)
            precondition(recovered.stops == 1, "The next real release finishes normally")
        }
        print("PASS event-tap recovery without fabricated actions")

        let editing = GestureHarness()
        editing.editSelection = "selected text"
        editing.toggleFromMenu()
        editing.flags(base, key: 61, raw: option)
        precondition(editing.stops == 0, "Voice edit ignores other modifiers too")
        editing.toggleFromMenu()
        precondition(editing.stops == 1)
        let escape = GestureHarness()
        escape.toggleFromMenu()
        escape.event(.keyDown, at: base, key: 53)
        escape.flags(base + 10, key: 61, raw: option)
        precondition(escape.state == .idle && escape.stops == 0)
        print("PASS voice edit and Escape cancellation")

        let capture = GestureHarness()
        capture.hotkeyActive = true
        capture.pressedAt = base
        precondition(capture.setShortcutCaptureActive(true))
        precondition(!capture.hotkeyActive && capture.pressedAt == nil)
        capture.press(base + 10)
        capture.flags(base + 20, key: 61, raw: fn | option)
        capture.toggleFromMenu()
        precondition(capture.state == .idle && capture.starts == 0 && capture.stops == 0,
                     "Shortcut capture must never start actual dictation")
        precondition(!capture.activateHotkey() && capture.activationCalls == 0)
        precondition(capture.setShortcutCaptureActive(true)) // idempotent: do not forget previous active state
        precondition(capture.setShortcutCaptureActive(false))
        precondition(capture.hotkeyActive && capture.activationCalls == 1)
        capture.release(base + 30)
        precondition(capture.starts == 0 && capture.stops == 0)
        let inactiveCapture = GestureHarness()
        precondition(inactiveCapture.setShortcutCaptureActive(true))
        precondition(inactiveCapture.setShortcutCaptureActive(false))
        precondition(!inactiveCapture.hotkeyActive && inactiveCapture.activationCalls == 0)
        for state in [GestureHarness.State.recording, .processing] {
            let busy = GestureHarness()
            busy.state = state
            busy.hotkeyActive = true
            precondition(!busy.setShortcutCaptureActive(true))
            precondition(busy.state == state && busy.hotkeyActive)
        }
        print("PASS shortcut capture suspends gestures, restores monitoring, and refuses busy sessions")
        let translation = GestureHarness()
        translation.updateTranslationShortcut(.default)
        precondition(translation.translationShortcutActive && translation.translationShortcutError == nil)
        precondition(translation.setShortcutCaptureActive(true))
        precondition(!translation.translationShortcutActive && translation.translateHotKey!.stops == 1)
        let custom = TranslationShortcut(keyCode: 9, modifiers: [.command, .option])
        translation.updateTranslationShortcut(custom)
        precondition(translation.translateHotKey!.updates == [.default], "No global registration during capture")
        precondition(translation.setShortcutCaptureActive(false))
        precondition(translation.translateHotKey!.updates == [.default, custom] && translation.translationShortcutActive,
                     "Capture resume registers latest emitted preference, not stale settings")
        translation.translateHotKey!.fail = true
        translation.updateTranslationShortcut(.default)
        precondition(!translation.translationShortcutActive && translation.translationShortcutError != nil,
                     "Controller exposes registration failure rather than claiming active")
        translation.translateHotKey!.fail = false
        translation.updateTranslationShortcut(.disabled)
        precondition(!translation.translationShortcutActive && translation.translationShortcutError == nil)
        print("PASS translation capture suspension, emitted-value registration, and failure publication")
        let recorderFailure = GestureHarness()
        recorderFailure.press(base)
        let staleRecorderError = recorderFailure.onRecorderError!
        recorderFailure.cancel()
        recorderFailure.release(base + 10)
        recorderFailure.press(base + 20)
        staleRecorderError("PRIVATE_STALE_RECORDER_ERROR")
        precondition(recorderFailure.state == .recording)
        recorderFailure.onRecorderError!("PRIVATE_RECORDER_ERROR")
        precondition(recorderFailure.state == .idle)
        let cancellations = Diagnostics.shared.events.filter { $0.0 == "dictation_cancel" }
        for reason in ["user", "escape", "combo", "recognition_error", "recorder_interruption"] {
            precondition(cancellations.contains { $0.1["reason"] == reason }, "Missing cancel reason: \(reason)")
        }
        for (_, fields) in cancellations {
            precondition(fields["reason"] != nil && fields["state"] != nil)
            if fields["operation_id"] != nil {
                precondition(UUID(uuidString: fields["operation_id"]!) != nil && fields["generation"] != nil)
                precondition(fields["recording_mode"] != nil && fields["operation_ms"] != nil)
            }
        }
        precondition(!Diagnostics.shared.events.description.contains("synthetic current error") &&
                     !Diagnostics.shared.events.description.contains("PRIVATE_"), "Never log an error description")
        print("PASS precise cancellation reasons and correlated mode/generation/timing without error content")
    }
}
'''

operation = controller.split("private struct DictationOperation", 1)[1].split("/// Core dictation flow", 1)[0]
source = (hotkeys + "private struct DictationOperation" + operation + gesture_mode + STUBS.replace("__ERROR_CALLBACK__", error_callback.group(1)).replace("__RECORDER_ERROR_CALLBACK__", recorder_error_callback.group(1))
          + "\n".join(fields) + "\n"
          + "\n".join(method(name) for name in
                      ("triggerPressed", "triggerReleased",
                       "setShortcutCaptureActive", "updateTranslationShortcut", "updateTriggerKey", "comboKeyPressed", "toggleFromMenu",
                       "escapePressed", "cancel", "isCurrentRecognition"))
          + TESTS)
with tempfile.TemporaryDirectory(prefix="talkless-hotkey-tests-") as directory:
    path = Path(directory)
    swift = path / "GestureTests.swift"
    binary = path / "gesture-tests"
    swift.write_text(source)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    str(swift), str(ROOT / "Sources/Talkless/TranslationShortcut.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
