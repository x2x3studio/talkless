#!/usr/bin/env python3
"""Compile production stopAndProcess/finish against fakes; no device or API access."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
controller = (ROOT / "Sources/Talkless/DictationController.swift").read_text()


def method(name):
    """Extract the whole production method, including nested closures/branches."""
    start = re.search(r"    (?:private )?func " + name + r"\(", controller)
    assert start, f"Missing production method: {name}"
    opening = controller.index("{", start.start())
    depth, end = 1, opening + 1
    while depth:
        depth += (controller[end] == "{") - (controller[end] == "}")
        end += 1
    return controller[start.start():end].replace("private func ", "func ", 1)


STUBS = r'''
import Foundation

enum HUDModel {
    enum Phase: Equatable { case working, recognizing, polishing, editing, hidden, error(String) }
}
@MainActor final class FakeHUD {
    var phases: [HUDModel.Phase] = []
    var model: FakeHUD { self }
    var recordingHint: String?
    func show(_ phase: HUDModel.Phase) { phases.append(phase) }
}
@MainActor final class Diagnostics {
    static let shared = Diagnostics()
    func record(event: String, metadata: [String: String] = [:]) {}
}
struct AudioRecorder {
    static let sampleRate = 16_000.0
    var interruptionError: String?
    func stop() -> [Float] { [0] }
}
@MainActor final class FakeSession {
    var onFinish: () -> Void = {}
    func finish(samples: [Float]) async throws -> String {
        precondition(samples == [0])
        await Task.yield()
        onFinish()
        return "raw transcript"
    }
}
struct Settings {
    var polishEnabled = true
    var llmConfigured = true
    var llmConfig = 0
}
struct Context { var name = "Fake app" }
enum Prompts {
    static func voiceEdit(settings: Settings) -> String { "edit" }
    static func voiceEditInput(selection: String, instruction: String) -> String { instruction }
    static func polish(context: Context?, settings: Settings) -> String { "polish" }
    static func polishInput(_ raw: String) -> String { raw }
}
@MainActor enum LLMClient {
    static var fail = false
    static var calls = 0
    static var onComplete: () -> Void = {}
    static func complete(system: String, user: String, config: Int,
                         timeout: Int = 60) async throws -> String {
        calls += 1
        await Task.yield()
        onComplete()
        if fail { throw NSError(domain: "Synthetic polish failure", code: 1) }
        return "processed transcript"
    }
}
enum PolishValidation {
    static func validate(source: String, output: String) throws -> String { output }
}
@MainActor enum TextIO {
    static var inserted: [String] = []
    static func insert(_ text: String) async { inserted.append(text) }
}
struct HistoryEntry {
    enum Kind { case dictation, edit }
    var kind: Kind
    var app: String
    var raw: String
    var output: String
    var duration: Double
}
@MainActor final class FakeHistory {
    var entries: [HistoryEntry] = []
    func add(_ entry: HistoryEntry) { entries.append(entry) }
}
@MainActor final class FakeHotkeys {
    var armed = true
    func armAlternateFinish(_ key: Int?) { armed = key != nil }
}
@MainActor final class ProcessingHarness {
    enum State { case idle, recording, processing }
    var state: State = .recording
    var generation = 0
    var pressedAt: UInt64? = 123
    var recordingPolishEnabled = true
    let hotkeys = FakeHotkeys()
    func updateTriggerKey() {}
    var editSelection: String?
    var context: Context? = Context()
    var settings = Settings()
    var lastTranscript = ""
    var session: FakeSession? = FakeSession()
    var processingTask: Task<Void, Never>?
    var recorder = AudioRecorder()
    let hud = FakeHUD()
    let history = FakeHistory()
    var cancelled = false
    func cancel() {
        cancelled = true
        generation += 1
        session = nil
        state = .idle
        hud.show(.hidden)
    }
'''

TESTS = r'''
}
@main struct Tests {
    @MainActor static func check(_ name: String, enabled: Bool = true,
                                 configured: Bool = true, editing: Bool = false,
                                 failure: Bool = false, opposite: Bool = false,
                                 changeDefault: Bool = false, phases: [HUDModel.Phase]) async {
        let test = ProcessingHarness()
        test.recordingPolishEnabled = enabled
        test.settings.polishEnabled = changeDefault ? !enabled : enabled
        test.settings.llmConfigured = configured
        test.editSelection = editing ? "selected text" : nil
        test.session!.onFinish = {
            precondition(test.hud.phases == [.recognizing],
                         "Recognition must complete before polishing/editing is shown")
        }
        LLMClient.calls = 0
        LLMClient.fail = failure
        LLMClient.onComplete = {
            precondition(test.hud.phases == [.recognizing, editing ? .editing : .polishing],
                         "The correct processing phase must be visible during the LLM call")
            precondition(TextIO.inserted.isEmpty)
        }
        TextIO.inserted = []
        test.stopAndProcess(useOppositePolish: opposite)
        precondition(test.state == .processing && test.hud.phases == [.recognizing])
        precondition(test.pressedAt == nil && !test.hotkeys.armed,
                     "Stopping must clear the gesture and disarm alternate before awaiting recognition")
        // Changing global Settings during recognition cannot change the captured finish decision either.
        if changeDefault { test.settings.polishEnabled = !enabled }
        guard let task = test.processingTask else { preconditionFailure("Missing processing task") }
        await task.value
        precondition(test.hud.phases == phases, "\(name): unexpected HUD sequence \(test.hud.phases)")
        let usesLLM = editing || ((opposite ? !enabled : enabled) && configured)
        let output = usesLLM && !failure ? "processed transcript" : "raw transcript"
        precondition(LLMClient.calls == (usesLLM ? 1 : 0))
        precondition(TextIO.inserted == [output] && test.lastTranscript == output,
                     "\(name): must insert the result (raw fallback on failure) exactly once")
        precondition(test.history.entries.count == 1)
        let entry = test.history.entries[0]
        precondition(entry.raw == "raw transcript" && entry.output == output)
        precondition(entry.kind == (editing ? .edit : .dictation))
        precondition(test.state == .idle && test.session == nil && test.processingTask == nil,
                     "Production finish must clear processing state")
        LLMClient.onComplete = {}
        print("PASS \(name)")
    }
    @MainActor static func main() async {
        let interrupted = ProcessingHarness()
        interrupted.recorder.interruptionError = "Microphone disconnected"
        TextIO.inserted = []
        LLMClient.calls = 0
        interrupted.stopAndProcess()
        precondition(interrupted.cancelled && interrupted.processingTask == nil)
        precondition(interrupted.hud.phases == [.hidden, .error("Microphone disconnected")])
        precondition(TextIO.inserted.isEmpty && LLMClient.calls == 0 && interrupted.history.entries.isEmpty)
        print("PASS interrupted recording never processes or pastes a partial transcript")
        await check("configured polish", phases: [.recognizing, .polishing, .hidden])
        await check("disabled polish", enabled: false, phases: [.recognizing, .hidden])
        await check("unconfigured polish", configured: false, phases: [.recognizing, .hidden])
        await check("disabled and unconfigured", enabled: false, configured: false,
                    phases: [.recognizing, .hidden])
        await check("editing is distinct from polishing", editing: true,
                    phases: [.recognizing, .editing, .hidden])
        await check("editing does not require polish enabled", enabled: false, editing: true,
                    phases: [.recognizing, .editing, .hidden])
        await check("failed polish preserves raw transcript and error", failure: true,
                    phases: [.recognizing, .polishing,
                             .error("Polishing failed; using the original transcript.")])
        await check("opposite bypasses configured default AI", opposite: true,
                    phases: [.recognizing, .hidden])
        await check("opposite requests AI when default disabled", enabled: false, opposite: true,
                    phases: [.recognizing, .polishing, .hidden])
        await check("opposite AI without configuration preserves raw with useful error", enabled: false,
                    configured: false, opposite: true,
                    phases: [.recognizing,
                             .error("Configure an AI service in Settings to polish. Using the original transcript.")])
        await check("opposite AI failure preserves raw", enabled: false, failure: true, opposite: true,
                    phases: [.recognizing, .polishing,
                             .error("Polishing failed; using the original transcript.")])
        await check("editing cannot be bypassed defensively", editing: true, opposite: true,
                    phases: [.recognizing, .editing, .hidden])
        for enabled in [true, false] {
            for opposite in [true, false] {
                let polish = opposite ? !enabled : enabled
                await check("snapshot default=\(enabled) opposite=\(opposite)", enabled: enabled,
                            opposite: opposite, changeDefault: true,
                            phases: polish ? [.recognizing, .polishing, .hidden] : [.recognizing, .hidden])
            }
        }
    }
}
'''

source = STUBS + "\n".join(method(name) for name in ("stopAndProcess", "finish")) + TESTS
with tempfile.TemporaryDirectory(prefix="talkless-processing-hud-tests-") as directory:
    path = Path(directory)
    swift = path / "ProcessingHUDTests.swift"
    binary = path / "processing-hud-tests"
    swift.write_text(source)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
