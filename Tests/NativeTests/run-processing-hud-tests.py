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
    func setDictionaryTerms(_ terms: [String]) {}
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

STARTUP_STUBS = r'''
// Execute real startup/cancel code with synthetic recorder, permissions and providers.
// No hardware, network, Accessibility or persisted settings are consulted.
enum L10n {
    static func tr(_ key: String) -> String { key }
    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: key, locale: Locale(identifier: "en"), arguments: args)
    }
}
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()
    func record(event: String, metadata: [String: String] = [:]) {}
}
@MainActor final class FakeSettings {
    enum Engine: String, CaseIterable { case qwen, apple, openAICompatible }
    var asrEngine: Engine = .qwen
    var audioInputDeviceUID: String?
    var terms = ["Talkless", "\u{5317}\u{4EAC}"]
    var termReads = 0
    var dictionaryTerms: [String] { termReads += 1; return terms }
    var voiceEditEnabled = false
    var llmConfigured = true
    var speechLocale = "en-US"
    var asrAPIKey = "synthetic-not-sent"
    var asrBaseURL = "https://unused.invalid"
    var asrModel = "synthetic"
    func resolvedQwenModelDirectory() throws -> URL { URL(fileURLWithPath: "/synthetic/model") }
}
struct AppContext { let name: String; let bundleID: String }
struct FakeApp { let localizedName: String?; let bundleIdentifier: String? }
@MainActor final class FakeWorkspace {
    static let shared = FakeWorkspace()
    let frontmostApplication: FakeApp? = nil
}
@MainActor final class ModelManager {
    static let shared = ModelManager()
    var operationModelID: String?
}
@MainActor enum TextIO {
    static func selectedTextViaAX() -> String? { "Selected sentence" }
}
enum AVCaptureDevice {
    enum Media { case audio }
    static func requestAccess(for media: Media, completion: (Bool) -> Void) { preconditionFailure("No permissions") }
}
@MainActor protocol TranscriptionSession: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    func feed(_ buffer: Int)
    func cancel()
}
@MainActor class FakeSession: TranscriptionSession {
    static var latest: FakeSession?
    static var onCreate: () -> Void = {}
    var onPartial: ((String) -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var terms: [String] = []
    var prompt: String?
    var cancelled = false
    init() { Self.latest = self; Self.onCreate() }
    func feed(_ buffer: Int) {}
    func cancel() { cancelled = true }
}
@MainActor final class QwenTranscriptionSession: FakeSession {
    init(modelDirectory: URL, language: String?, contextualStrings: [String],
         onStatus: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
        super.init(); terms = contextualStrings; self.onStatus = onStatus; self.onError = onError
    }
}
@MainActor final class AppleSpeechSession: FakeSession {
    init(locale: Locale, contextualStrings: [String], onStatus: @escaping (String) -> Void) {
        super.init(); terms = contextualStrings; self.onStatus = onStatus
    }
}
@MainActor final class CloudTranscriptionSession: FakeSession {
    struct Config { let baseURL: String; let apiKey: String; let model: String; let language: String?; let prompt: String? }
    init(config: Config) { super.init(); prompt = config.prompt }
}
@MainActor final class FakeRecorder {
    var onBuffer: ((Int) -> Void)?
    var onError: ((String) -> Void)?
    var fail = false
    func start(deviceUID: String?, operationID: UUID) throws {
        if fail { throw NSError(domain: "Synthetic", code: 1) }
    }
    func stop() {}
}
@MainActor final class FakeHUD {
    let model = HUDModel()
    func show(_ phase: HUDModel.Phase) { model.phase = phase }
    func hide() { model.phase = .hidden; model.preview = ""; model.isEditMode = false }
}
@MainActor final class FakeHotkeys { func armAlternateFinish(_ value: Int?) {} }
@MainActor final class StartupHarness {
    enum State { case idle, recording, processing }
    enum Gesture: String { case hold }
    enum Authorization { case authorized, notDetermined, denied, restricted }
    static var microphoneStatus: Authorization { .authorized }
    var state = State.idle
    var shortcutCaptureActive = false
    var generation = 0
    var recordingGestureMode = Gesture.hold
    var handsFree = false
    private var diagnosticOperation: DictationOperation?
    var changingModel = false
    let settings = FakeSettings()
    let hud = FakeHUD()
    let recorder = FakeRecorder()
    let hotkeys = FakeHotkeys()
    var targetApp: FakeApp?
    var previewText = ""
    var context: AppContext?
    var editSelection: String?
    var session: (any TranscriptionSession)?
    var recordingModelDirectory: URL?
    var recordingPreparationGeneration = 0
    var preparationGeneration = 0
    var pressedAt: UInt64?
    var processingTask: Task<Void, Never>?
    var onModelSetupRequested: (() -> Void)?
    func configureRecordingFinish() {}
    func updateTriggerKey() {}
'''

STARTUP_TESTS = r'''
}
@main struct StartupTests {
    @MainActor static func matched(_ model: HUDModel) -> [String] {
        let attributed = model.attributedDisplayText()
        return attributed.runs.compactMap {
            $0.underlineStyle == nil ? nil : String(attributed.characters[$0.range])
        }
    }
    @MainActor static func main() {
        for engine in FakeSettings.Engine.allCases {
            let test = StartupHarness()
            test.settings.asrEngine = engine
            // Simulate a Settings edit during construction, between snapshot and HUD setup.
            FakeSession.onCreate = { test.settings.terms = ["NextSession"] }
            test.startRecording()
            let old = FakeSession.latest!
            precondition(test.state == .recording && test.settings.termReads == 1)
            precondition(test.hud.model.dictionaryTerms == ["Talkless", "\u{5317}\u{4EAC}"])
            if engine == .openAICompatible {
                precondition(old.prompt == "Talkless, \u{5317}\u{4EAC}")
                precondition(test.hud.model.preview.isEmpty && matched(test.hud.model).isEmpty,
                             "Cloud recognition has no live partial to decorate")
            } else {
                precondition(old.terms == ["Talkless", "\u{5317}\u{4EAC}"])
                old.onPartial?("Talkless \u{5317}\u{4EAC} NextSession")
                precondition(matched(test.hud.model) == ["Talkless", "\u{5317}\u{4EAC}"])
                old.onPartial?("Talkles")
                precondition(matched(test.hud.model).isEmpty, "Replacement partial clears prior matches")
                // Translation can briefly use the shared HUD while recording continues.
                // Presentation reset must not replace the recording-owned term snapshot.
                for dismissError in [false, true] {
                    test.hud.show(.error("Synthetic unrelated translation error"))
                    precondition(test.hud.model.dictionaryTerms.isEmpty)
                    if dismissError { test.hud.hide() }
                    old.onPartial?("Talkless NextSession")
                    precondition(test.hud.model.phase == .listening(handsFree: false))
                    precondition(matched(test.hud.model) == ["Talkless"] && test.settings.termReads == 1,
                                 "Continued recording restores its original snapshot after unrelated error/hide")
                }
                test.state = .processing
                test.hud.show(.recognizing)
                old.onPartial?("Talkless")
                precondition(test.hud.model.phase == .recognizing && matched(test.hud.model).isEmpty)
            }
            test.cancel()
            precondition(test.hud.model.dictionaryTerms.isEmpty)
            old.onPartial?("Talkless")
            old.onStatus?("late")
            old.onError?("late")
            precondition(test.hud.model.phase == .hidden && matched(test.hud.model).isEmpty)
            FakeSession.onCreate = {}
            test.startRecording()
            let current = FakeSession.latest!
            precondition(test.settings.termReads == 2 && test.hud.model.dictionaryTerms == ["NextSession"])
            old.onPartial?("Talkless")
            old.onStatus?("late")
            old.onError?("late")
            precondition(test.state == .recording && test.hud.model.preview.isEmpty,
                         "Previous generation cannot change the new HUD or terminate recording")
            current.onPartial?("Talkless NextSession")
            precondition(matched(test.hud.model) == ["NextSession"])
            test.cancel()
            test.recorder.fail = true
            test.startRecording()
            precondition(test.state == .idle && test.hud.model.dictionaryTerms.isEmpty)
            let failedPhase = test.hud.model.phase
            FakeSession.latest?.onPartial?("NextSession")
            FakeSession.latest?.onStatus?("late")
            FakeSession.latest?.onError?("late")
            precondition(test.hud.model.phase == failedPhase && matched(test.hud.model).isEmpty,
                         "Failed startup callbacks cannot revive HUD highlights")
            test.recorder.fail = false
            test.settings.voiceEditEnabled = true
            test.startRecording()
            FakeSession.latest?.onPartial?("NextSession")
            precondition(test.hud.model.isEditMode && test.hud.model.dictionaryTerms.isEmpty)
            precondition(matched(test.hud.model).isEmpty, "Voice edit instructions never decorate")
            test.hud.show(.error("Synthetic unrelated translation error"))
            test.hud.hide()
            FakeSession.latest?.onPartial?("NextSession")
            precondition(test.hud.model.isEditMode && matched(test.hud.model).isEmpty,
                         "Resuming after hidden error must preserve voice-edit exclusion")
            test.cancel()
        }
        print("PASS production recording snapshots for Qwen/Apple/cloud, dynamic dictionary edits, partial revisions, processing exclusion, cancel/startup failures, stale generations, and voice edit")
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
    overlay_model = (ROOT / "Sources/Talkless/Overlay.swift").read_text().split("/// A nonactivating", 1)[0]
    # Real HUDModel, real startup/cancel methods, only external boundaries substituted.
    startup = overlay_model + "\nprivate struct DictationOperation" + operation + STARTUP_STUBS
    startup += method("startRecording").replace("NSWorkspace", "FakeWorkspace") + "\n" + method("cancel") + STARTUP_TESTS
    swift.write_text(startup)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift),
                    str(ROOT / "Sources/Talkless/HUDAppearance.swift"),
                    str(ROOT / "Sources/Talkless/DictionaryHighlight.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
