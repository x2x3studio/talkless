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
hotkeys = (ROOT / "Sources/Talkless/Hotkeys.swift").read_text()
hotkeys = hotkeys.split("/// A standard keyboard shortcut", 1)[0]
hotkeys = hotkeys.replace("private func handle(type:", "func handle(type:")


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
for name in ("pressedAt", "tapThreshold"):
    match = re.search(r"^    private (?:var|let) " + name + r"\b[^\n]*", controller, re.M)
    assert match, f"Missing production field: {name}"
    fields.append(match.group().replace("private ", "", 1))
# Keep any additional combo threshold in sync with production too.
fields += [line.replace("private ", "", 1) for line in controller.splitlines()
           if re.match(r"    private let \w*Threshold\b", line) and "tapThreshold" not in line]
error_callback = re.search(
    r"onError: \{ \[weak self\] message in\n(.*?)\n                \}",
    controller, re.S,
)
assert error_callback, "Missing production Qwen error callback"

STUBS = r'''
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
}
@MainActor final class Diagnostics {
    static let shared = Diagnostics()
    func record(event: String, metadata: [String: String] = [:]) {}
}
@MainActor final class FakeHUD {
    enum Phase { case listening(handsFree: Bool), error(String) }
    func show(_ phase: Phase) {}
    func hide() {}
}
@MainActor final class FakeRecorder { func stop() {} }
@MainActor final class FakeSession { func cancel() {} }
@MainActor final class GestureHarness {
    enum State { case idle, recording, processing }
    var state: State = .idle
    var handsFree = false
    var generation = 0
    let hud = FakeHUD()
    let recorder = FakeRecorder()
    var session: FakeSession?
    var processingTask: Task<Void, Never>?
    var startupDelay: TimeInterval = 0
    var starts = 0
    var stops = 0
    var onError: ((String) -> Void)?
    let monitor = HotkeyMonitor()
    init() {
        monitor.onPress = { [weak self] in self?.triggerPressed(at: $0) }
        monitor.onRelease = { [weak self] in self?.triggerReleased(at: $0) }
        monitor.onComboKey = { [weak self] in self?.comboKeyPressed(at: $0) }
    }
    func startRecording() {
        generation += 1
        handsFree = false
        starts += 1
        session = FakeSession()
        let generation = self.generation
        onError = { [weak self] message in
__ERROR_CALLBACK__
        }
        Thread.sleep(forTimeInterval: startupDelay)
        state = .recording
    }
    func stopAndProcess() {
        guard state == .recording else { return }
        stops += 1
        state = .processing
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
        let cold = GestureHarness()
        cold.startupDelay = 0.45
        let began = Date()
        cold.press(base)
        cold.release(base + 100_000_000)
        precondition(Date().timeIntervalSince(began) >= 0.45)
        precondition(cold.state == .recording && cold.handsFree && cold.stops == 0,
                     "100 ms physical tap must survive 450 ms synchronous startup")
        precondition(cold.pressedAt == nil)
        // These events were physically generated before the delayed first handler returned.
        cold.press(base + 180_000_000)
        cold.release(base + 250_000_000)
        precondition(cold.state == .processing && cold.stops == 1 && cold.starts == 1,
                     "Queued double tap must stop exactly once, without starting again")
        print("PASS cold 100 ms tap / 450 ms startup and queued double tap")

        for duration: UInt64 in [100_000_000, 299_000_000, 300_000_000, 400_000_000] {
            let test = GestureHarness()
            test.press(base)
            test.release(base + duration)
            if duration < 300_000_000 {
                precondition(test.state == .recording && test.handsFree && test.stops == 0)
            } else {
                precondition(test.state == .processing && !test.handsFree && test.stops == 1,
                             "Physical long hold must stop even when delivery is immediate")
            }
            precondition(test.pressedAt == nil)
        }
        print("PASS warm tap, 299/300 ms threshold, and 400 ms hold")

        let duplicate = GestureHarness()
        duplicate.press(base)
        duplicate.press(base + 50_000_000)
        duplicate.release(base + 100_000_000)
        duplicate.release(base + 150_000_000)
        precondition(duplicate.starts == 1 && duplicate.stops == 0 && duplicate.handsFree)
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

        let stale = GestureHarness()
        stale.press(base)
        let oldError = stale.onError!
        stale.cancel()
        stale.release(base + 100_000_000)
        stale.press(base + 200_000_000)
        oldError("synthetic stale error")
        precondition(stale.state == .recording,
                     "Cancelled generation's error must not cancel the next recording")
        stale.release(base + 250_000_000)
        precondition(stale.handsFree && stale.starts == 2 && stale.stops == 0)
        stale.onError!("synthetic current error")
        precondition(stale.state == .idle && stale.pressedAt == nil)
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
    }
}
'''

source = (hotkeys + STUBS.replace("__ERROR_CALLBACK__", error_callback.group(1))
          + "\n".join(fields) + "\n"
          + "\n".join(method(name) for name in
                      ("triggerPressed", "triggerReleased", "comboKeyPressed", "toggleFromMenu", "cancel"))
          + TESTS)
with tempfile.TemporaryDirectory(prefix="talkless-hotkey-tests-") as directory:
    path = Path(directory)
    swift = path / "GestureTests.swift"
    binary = path / "gesture-tests"
    swift.write_text(source)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
