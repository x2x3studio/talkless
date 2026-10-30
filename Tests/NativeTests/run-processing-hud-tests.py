#!/usr/bin/env python3
"""Compile production stopAndProcess/finish against fakes; no device or API access."""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
controller = (ROOT / "Sources/Talkless/DictationController.swift").read_text()
# Readiness relies on successful Qwen finish (even empty speech) proving assets loaded.
# Guard that production worker contract without loading models or making API calls.
qwen = (ROOT / "Sources/Talkless/QwenTranscription.swift").read_text()
qwen_run = qwen.split("    func run(", 1)[1]
qwen_before_prepare = qwen_run.split("try await QwenModelRuntime.shared.prepare(", 1)[0]
assert "return" not in qwen_before_prepare, "Qwen must not return empty success before preparing assets"
assert "for await" not in qwen_before_prepare, "Qwen must prepare assets before consuming/finishing audio"
qwen_finish = qwen.split("    func finish(samples:", 1)[1].split("    func cancel()", 1)[0]
assert "completion.resolve(await worker.result)" in qwen_finish
assert "return try await withTaskCancellationHandler" in qwen_finish


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

// Extracted controller fixtures use deterministic English without preferences or resources.
enum L10n {
    static func tr(_ key: String) -> String { key }
    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: key, locale: Locale(identifier: "en"), arguments: args)
    }
}

enum HUDModel {
    enum Phase: Equatable { case working, recognizing, polishing, editing, hidden, error(String) }
}
@MainActor final class FakeHUD {
    var phases: [HUDModel.Phase] = []
    var model: FakeHUD { self }
    var recordingHint: String?
    func show(_ phase: HUDModel.Phase) { phases.append(phase) }
}
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()
    var events: [(String, [String: String])] = []
    func record(event: String, metadata: [String: String] = [:]) { events.append((event, metadata)) }
}
struct AudioRecorder {
    static let sampleRate = 16_000.0
    var interruptionError: String?
    var samples: [Float] = [0]
    func stop() -> [Float] { samples }
}
@MainActor final class FakeSession {
    var onFinish: () -> Void = {}
    var result = "raw transcript"
    var failure: Error?
    func finish(samples: [Float]) async throws -> String {
        precondition(samples == [0] || samples.isEmpty)
        await Task.yield()
        onFinish()
        if let failure { throw failure }
        return result
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
    var recordingModelDirectory: URL?
    var recordingPreparationGeneration = 0
    var preparationGeneration = 0
    var modelPreparationTask: Task<Void, Never>?
    var preparedModelDirectory: URL?
    var preparingModelDirectory: URL?
    var failedModelDirectory: URL?
    var modelPreparationStatusKey: String?
    enum ModelPreparationState { case unprepared, preparing, ready, failed }
    private var diagnosticOperation: DictationOperation? = DictationOperation(generation: 0, engine: "qwen", recordingMode: "hold", handsFree: false)
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
    func cancel(reason: String = "user") {
        diagnosticOperation?.record("dictation_cancel", ["reason": reason])
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
        Diagnostics.shared.events = []
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
        let diagnostics = Diagnostics.shared.events
        let ids = Set(diagnostics.compactMap { $0.1["operation_id"] })
        precondition(ids.count == 1 && UUID(uuidString: ids.first!) != nil, "Operation correlation lost")
        for (event, fields) in diagnostics {
            precondition(fields["generation"] == "0" && fields["recording_mode"] == "hold" && fields["operation_ms"] != nil)
            if ["recognition_complete", "paste_returned", "processing_complete"].contains(event) {
                precondition(fields["duration_ms"] != nil, "Missing stage timing")
            }
        }
        precondition(diagnostics.last?.0 == "processing_complete")
        precondition(diagnostics.contains { $0.0 == "paste_attempt" } && diagnostics.contains { $0.0 == "paste_returned" })
        if failure { precondition(diagnostics.contains { $0.0 == "polish_error" && $0.1["fallback"] == "true" }) }
        precondition(!diagnostics.description.contains("transcript") && !diagnostics.description.contains("Synthetic polish failure"),
                     "Never log transcript/error content")
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
        precondition(Diagnostics.shared.events.contains { $0.0 == "dictation_cancel" && $0.1["reason"] == "stop_interruption" })
        print("PASS interrupted recording never processes or pastes a partial transcript")
        for failure in [nil, NSError(domain: "PRIVATE_ERROR_DESCRIPTION", code: 72), CancellationError()] as [Error?] {
            Diagnostics.shared.events = []
            let test = ProcessingHarness()
            test.recorder.samples = []
            test.session!.result = ""
            test.session!.failure = failure
            TextIO.inserted = []
            test.stopAndProcess()
            await test.processingTask?.value
            let logs = Diagnostics.shared.events
            precondition(logs.contains { $0.0 == "recording_empty" && $0.1["reason"] == "empty_audio" })
            precondition(TextIO.inserted.isEmpty && test.state == .idle)
            if failure is CancellationError {
                precondition(logs.contains { $0.0 == "processing_cancelled" })
            } else if failure != nil {
                precondition(logs.contains { $0.0 == "recognition_error" && $0.1["error_code"] == "72" })
                precondition(logs.last?.0 == "processing_error")
            } else {
                precondition(logs.contains { $0.0 == "recognition_empty" })
                precondition(logs.contains { $0.0 == "paste_skipped" && $0.1["reason"] == "empty_result" })
                precondition(logs.last?.0 == "processing_complete")
            }
            precondition(!logs.description.contains("PRIVATE_ERROR_DESCRIPTION"))
        }
        print("PASS empty audio/result, recognition failure, and cancellation diagnostics")
        let modelA = URL(fileURLWithPath: "/synthetic/models/a")
        let modelB = URL(fileURLWithPath: "/synthetic/models/b")
        for outcome in ["success", "empty", "failure", "cancelled", "stale", "new_preparation", "non_qwen"] {
            let test = ProcessingHarness()
            test.failedModelDirectory = modelA
            test.modelPreparationStatusKey = "Model preparation failed. Check Speech recognition settings."
            test.recordingModelDirectory = outcome == "non_qwen" ? nil : modelA.appendingPathComponent("../a")
            test.recordingPolishEnabled = false
            if outcome == "empty" { test.session!.result = "" }
            if outcome == "failure" { test.session!.failure = NSError(domain: "synthetic", code: 1) }
            if outcome == "cancelled" { test.session!.failure = CancellationError() }
            test.session!.onFinish = {
                if outcome == "stale" { test.generation += 1 }
                if outcome == "new_preparation" {
                    test.preparationGeneration += 1
                    test.preparingModelDirectory = modelB
                }
            }
            precondition(test.modelPreparationState(for: modelA) == .failed)
            test.stopAndProcess()
            await test.processingTask?.value
            if outcome == "success" || outcome == "empty" {
                precondition(test.modelPreparationState(for: modelA) == .ready,
                             "Successful Qwen finish must replace stale failed prewarm readiness")
                precondition(test.failedModelDirectory == nil && test.modelPreparationStatusKey == "Ready · kept in memory")
                precondition(test.modelPreparationState(for: modelB) == .unprepared,
                             "Success for captured model A cannot report selected model B ready")
            } else {
                precondition(test.modelPreparationState(for: modelA) == .failed,
                             "Failure/cancellation/stale/non-Qwen finish cannot claim model readiness")
                if outcome == "new_preparation" {
                    precondition(test.modelPreparationState(for: modelB) == .preparing,
                                 "Older recognition cannot overwrite a newer preparation")
                }
            }
        }
        print("PASS successful Qwen finish repairs failed prewarm readiness with directory/generation isolation")
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

operation = controller.split("private struct DictationOperation", 1)[1].split("/// Core dictation flow", 1)[0]
source = "import Foundation\nprivate struct DictationOperation" + operation + STUBS + "\n".join(method(name) for name in ("stopAndProcess", "finish", "markModelReadyAfterRecognition", "modelPreparationState")) + TESTS
with tempfile.TemporaryDirectory(prefix="talkless-processing-hud-tests-") as directory:
    path = Path(directory)
    swift = path / "ProcessingHUDTests.swift"
    binary = path / "processing-hud-tests"
    swift.write_text(source)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
