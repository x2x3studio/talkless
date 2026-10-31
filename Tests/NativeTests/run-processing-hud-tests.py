#!/usr/bin/env python3
"""Compile production async startup/stop/gestures/HUD and diagnostics against fakes; no device or API access."""
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

@MainActor final class FakeHUD {
    var phases: [HUDModel.Phase] = []
    let model = HUDModel()
    func show(_ phase: HUDModel.Phase) {
        phases.append(phase)
        model.phase = phase
        if phase == .hidden { model.preview = "" }
    }
    func hide() { show(.hidden) }
}
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()
    var events: [(String, [String: String])] = []
    func record(event: String, metadata: [String: String] = [:]) { events.append((event, metadata)) }
}
@MainActor final class AudioRecorder {
    static let sampleRate = 16_000.0
    var interruptionError: String?
    var samples: [Float] = [0]
    var stops = 0
    var pendingStop: CheckedContinuation<[Float], Error>?
    var suspendStop = false
    func stop() async throws -> [Float] {
        stops += 1
        if suspendStop { return try await withCheckedThrowingContinuation { pendingStop = $0 } }
        if let interruptionError { throw NSError(domain: "Synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: interruptionError]) }
        return samples
    }
    func cancel() {}
}
@MainActor final class FakeSession {
    var onFinish: () -> Void = {}
    var result = "raw transcript"
    var failure: Error?
    var cancelled = false
    var finishes = 0
    func cancel() { cancelled = true }
    func finish(samples: [Float]) async throws -> String {
        finishes += 1
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
    static var onInsert: (String) -> Void = { _ in }
    static func insert(_ text: String) async {
        onInsert(text)
        await Task.yield()
        inserted.append(text)
    }
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
    var acceptsRecognitionHUDUpdates = true
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
    var startupTask: Task<Void, Never>?
    var processingTask: Task<Void, Never>?
    var recorder = AudioRecorder()
    let hud = FakeHUD()
    let history = FakeHistory()
    var cancelled = false
    func cancel(reason: String = "user") {
        diagnosticOperation?.record("dictation_cancel", ["reason": reason])
        cancelled = true
        acceptsRecognitionHUDUpdates = false
        startupTask?.cancel()
        startupTask = nil
        processingTask?.cancel()
        processingTask = nil
        generation += 1
        recorder.cancel()
        session?.cancel()
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
        test.hud.model.phase = .listening(handsFree: false)
        let dictatingLabel = test.hud.model.phase.accessibilityLabel
        precondition(dictatingLabel == "Dictating")
        test.hud.model.preview = "partial transcript"
        test.hud.model.isEditMode = editing
        test.hud.model.setDictionaryTerms(editing ? [] : ["transcript"])
        test.session!.onFinish = {
            precondition(test.hud.model.displayText == "partial transcript",
                         "Recognition keeps the last live transcript, not a status label")
            test.hud.model.preview = "revised partial transcript"
            precondition(test.hud.model.displayText == "revised partial transcript")
            precondition(test.hud.phases == [.recognizing],
                         "Recognition must complete before polishing/editing is shown")
        }
        LLMClient.calls = 0
        LLMClient.fail = failure
        LLMClient.onComplete = {
            precondition(test.hud.phases == [.recognizing, editing ? .editing : .polishing],
                         "The correct processing phase must be visible during the LLM call")
            precondition(test.hud.model.displayText == "raw transcript",
                         "Final recognition replaces partial words while polishing/editing runs")
            precondition(!test.acceptsRecognitionHUDUpdates, "Late ASR callbacks cannot replace final raw words")
            precondition(TextIO.inserted.isEmpty)
        }
        TextIO.onInsert = { output in
            precondition(test.hud.model.phase == .inserting && test.hud.model.displayText == output,
                         "Final output must be visible during the real insertion await")
            precondition(!test.acceptsRecognitionHUDUpdates)
            precondition(test.hud.model.revisionOriginal == (editing ? nil : "raw transcript"))
            let attributed = test.hud.model.attributedDisplayText()
            let dictionary = attributed.runs.filter { $0.underlineStyle != nil }.map { String(attributed.characters[$0.range]) }.joined()
            precondition(dictionary == (editing ? "" : "transcript"))
        }
        TextIO.inserted = []
        test.stopAndProcess(useOppositePolish: opposite)
        precondition(test.state == .processing && test.hud.phases == [.recognizing])
        precondition(test.hud.model.phase.accessibilityLabel == dictatingLabel,
                     "Engine capture/recognition phases share one continuous user-facing activity")
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
        precondition(diagnostics.contains { $0.0 == "recognition_complete" },
                     "Merged HUD presentation must preserve technical recognition diagnostics")
        precondition(diagnostics.contains { $0.0 == "paste_attempt" } && diagnostics.contains { $0.0 == "paste_returned" })
        if failure { precondition(diagnostics.contains { $0.0 == "polish_error" && $0.1["fallback"] == "true" }) }
        precondition(!diagnostics.description.contains("transcript") && !diagnostics.description.contains("Synthetic polish failure"),
                     "Never log transcript/error content")
        if case .error(let message) = phases.last! {
            precondition(test.hud.model.displayText == message, "Actionable errors may replace transcript")
        } else {
            precondition(test.hud.model.phase == .completed && test.hud.model.displayText == output,
                         "Completion keeps final words for nonblocking review; controller is already idle")
        }
        LLMClient.onComplete = {}
        TextIO.onInsert = { _ in }
        print("PASS \(name)")
    }
    @MainActor static func main() async {
        let interrupted = ProcessingHarness()
        interrupted.recorder.interruptionError = "Microphone disconnected"
        TextIO.inserted = []
        LLMClient.calls = 0
        let interruptedSession = interrupted.session!
        interrupted.stopAndProcess()
        precondition(interrupted.state == .processing && interrupted.recorder.stops == 0)
        await interrupted.processingTask?.value
        precondition(interrupted.cancelled && interrupted.processingTask == nil && interruptedSession.cancelled)
        precondition(interrupted.hud.phases == [.recognizing, .hidden, .error("Microphone disconnected")])
        precondition(TextIO.inserted.isEmpty && LLMClient.calls == 0 && interrupted.history.entries.isEmpty)
        precondition(Diagnostics.shared.events.contains { $0.0 == "dictation_cancel" && $0.1["reason"] == "stop_interruption" })
        print("PASS interrupted recording never processes or pastes a partial transcript")
        for outcome in ["timeout", "cancel_success", "cancel_error", "cancel_before_launch"] {
            let test = ProcessingHarness()
            test.recorder.suspendStop = true
            let session = test.session!
            test.hud.model.preview = "partial words"
            TextIO.inserted = []
            LLMClient.calls = 0
            test.stopAndProcess()
            let task = test.processingTask!
            precondition(test.state == .processing && test.recorder.stops == 0)
            if outcome == "cancel_before_launch" {
                test.cancel()
                await task.value
                precondition(test.recorder.stops == 0 && session.finishes == 0)
                continue
            }
            for _ in 0..<1000 {
                if test.recorder.pendingStop != nil { break }
                try? await Task.sleep(for: .milliseconds(1))
            }
            precondition(test.recorder.pendingStop != nil)
            test.stopAndProcess()
            precondition(test.recorder.stops == 1, "Only one stop may own teardown")
            if outcome != "timeout" {
                test.cancel()
                test.state = .recording // a new recording is now active
                test.session = FakeSession()
                test.acceptsRecognitionHUDUpdates = true
                test.hud.show(.listening(handsFree: true))
                test.hud.model.preview = "new recording"
            }
            if outcome == "cancel_success" {
                test.recorder.pendingStop!.resume(returning: [0])
            } else {
                test.recorder.pendingStop!.resume(throwing: NSError(domain: "Synthetic", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Microphone stop timed out"]))
            }
            await task.value
            precondition(session.cancelled && session.finishes == 0)
            precondition(TextIO.inserted.isEmpty && LLMClient.calls == 0 && test.history.entries.isEmpty)
            if outcome == "timeout" {
                precondition(test.state == .idle && test.hud.model.phase == .error("Microphone stop timed out"))
            } else {
                precondition(test.state == .recording && test.hud.model.preview == "new recording")
                precondition(test.session?.cancelled == false)
            }
        }
        print("PASS pending stop returns immediately, timeout never pastes partial, cancellation/new-start rejects stale stop success/error")
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
        for cancelStage in ["recognition", "polishing", "editing", "insertion"] {
            let test = ProcessingHarness()
            test.hud.model.preview = "partial words"
            test.editSelection = cancelStage == "editing" ? "selected text" : nil
            LLMClient.fail = false
            TextIO.inserted = []
            test.session!.onFinish = { if cancelStage == "recognition" { test.cancel() } }
            LLMClient.onComplete = {
                if cancelStage == "polishing" || cancelStage == "editing" { test.cancel() }
            }
            TextIO.onInsert = { _ in if cancelStage == "insertion" { test.cancel() } }
            test.stopAndProcess()
            let task = test.processingTask!
            await task.value
            precondition(test.hud.model.phase == .hidden && test.hud.model.preview.isEmpty,
                         "Cancelled work cannot reveal late output at \(cancelStage)")
            precondition(test.history.entries.isEmpty)
            if cancelStage != "insertion" { precondition(TextIO.inserted.isEmpty) }
        }
        LLMClient.onComplete = {}
        TextIO.onInsert = { _ in }
        let failedEdit = ProcessingHarness()
        failedEdit.editSelection = "selected text"
        failedEdit.hud.model.preview = "partial edit instruction"
        LLMClient.fail = true
        TextIO.inserted = []
        failedEdit.stopAndProcess()
        await failedEdit.processingTask?.value
        if case .error(let message) = failedEdit.hud.model.phase {
            precondition(failedEdit.hud.model.displayText == message)
        } else { preconditionFailure("Edit failure must show its actionable error") }
        precondition(TextIO.inserted.isEmpty && failedEdit.history.entries.isEmpty)
        LLMClient.fail = false
        print("PASS cancellation across all awaits prevents late preview/history; edit errors stay actionable")
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
        await check("configured polish", phases: [.recognizing, .polishing, .inserting, .completed])
        await check("disabled polish", enabled: false, phases: [.recognizing, .inserting, .completed])
        await check("unconfigured polish", configured: false, phases: [.recognizing, .inserting, .completed])
        await check("disabled and unconfigured", enabled: false, configured: false,
                    phases: [.recognizing, .inserting, .completed])
        await check("editing is distinct from polishing", editing: true,
                    phases: [.recognizing, .editing, .inserting, .completed])
        await check("editing does not require polish enabled", enabled: false, editing: true,
                    phases: [.recognizing, .editing, .inserting, .completed])
        await check("failed polish preserves raw transcript and error", failure: true,
                    phases: [.recognizing, .polishing, .inserting,
                             .error("Polishing failed; using the original transcript.")])
        await check("opposite bypasses configured default AI", opposite: true,
                    phases: [.recognizing, .inserting, .completed])
        await check("opposite requests AI when default disabled", enabled: false, opposite: true,
                    phases: [.recognizing, .polishing, .inserting, .completed])
        await check("opposite AI without configuration preserves raw with useful error", enabled: false,
                    configured: false, opposite: true,
                    phases: [.recognizing, .inserting,
                             .error("Configure an AI service in Settings to polish. Using the original transcript.")])
        await check("opposite AI failure preserves raw", enabled: false, failure: true, opposite: true,
                    phases: [.recognizing, .polishing, .inserting,
                             .error("Polishing failed; using the original transcript.")])
        await check("editing cannot be bypassed defensively", editing: true, opposite: true,
                    phases: [.recognizing, .editing, .inserting, .completed])
        for enabled in [true, false] {
            for opposite in [true, false] {
                let polish = opposite ? !enabled : enabled
                await check("snapshot default=\(enabled) opposite=\(opposite)", enabled: enabled,
                            opposite: opposite, changeDefault: true,
                            phases: polish ? [.recognizing, .polishing, .inserting, .completed] : [.recognizing, .inserting, .completed])
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
    var polishEnabled = true
    var llmConfig = 0
    var recordingGestureMode = StartupHarness.Gesture.hold
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
enum AVCaptureDevice {
    enum Media { case audio }
    static func requestAccess(for media: Media, completion: (Bool) -> Void) { preconditionFailure("No permissions") }
}
@MainActor protocol TranscriptionSession: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    func feed(_ buffer: Int)
    func cancel()
    func finish(samples: [Float]) async throws -> String
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
    var finishes = 0
    func feed(_ buffer: Int) {}
    func cancel() { cancelled = true }
    func finish(samples: [Float]) async throws -> String { finishes += 1; return "raw transcript" }
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
    static let sampleRate = 16_000.0
    var onBuffer: ((Int) -> Void)?
    var onError: ((String) -> Void)?
    var fail = false
    var suspendStart = false
    var starts: [CheckedContinuation<Void, Error>] = []
    var startCalls = 0
    var stopCalls = 0
    var cancelCalls = 0
    var stopFailure: Error?
    var selectedDevice: String?
    func start(deviceUID: String?, operationID: UUID) async throws {
        startCalls += 1
        selectedDevice = deviceUID
        if suspendStart { try await withCheckedThrowingContinuation { starts.append($0) } }
        if fail { throw NSError(domain: "Synthetic", code: 1) }
    }
    func stop() async throws -> [Float] {
        stopCalls += 1
        if let stopFailure { throw stopFailure }
        return [0]
    }
    // Deliberately don't resume pending continuations: simulate callbacks from
    // a native operation that returns after cancellation and a newer start.
    func cancel() { cancelCalls += 1 }
}
typealias AudioRecorder = FakeRecorder
@MainActor final class FakeHUD {
    let model = HUDModel()
    func show(_ phase: HUDModel.Phase) { model.phase = phase }
    func hide() { model.phase = .hidden; model.preview = ""; model.isEditMode = false }
}
@MainActor final class FakeHotkeys { func armAlternateFinish(_ value: Int?) {} }
@MainActor final class StartupHarness {
    enum State { case idle, recording, processing }
    enum Gesture: String { case hold, toggle }
    enum Authorization { case authorized, notDetermined, denied, restricted }
    static var microphoneStatus: Authorization { .authorized }
    var state = State.idle
    var shortcutCaptureActive = false
    var generation = 0
    var acceptsRecognitionHUDUpdates = true
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
    var startupTask: Task<Void, Never>?
    var processingTask: Task<Void, Never>?
    var onModelSetupRequested: (() -> Void)?
    var recordingPolishEnabled = true
    var lastTranscript = ""
    let history = FakeHistory()
    let translationPanel = FakeTranslationPanel()
    func configureRecordingFinish() { recordingPolishEnabled = settings.polishEnabled }
    func updateTriggerKey() {}
    func markModelReadyAfterRecognition(directory: URL?, generation: Int, preparation: Int) {}
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
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        preconditionFailure("Timed out waiting for fake lifecycle")
    }
    @MainActor static func main() async {
        for engine in FakeSettings.Engine.allCases {
            let test = StartupHarness()
            test.settings.asrEngine = engine
            // Simulate a Settings edit during construction, between snapshot and HUD setup.
            FakeSession.onCreate = { test.settings.terms = ["NextSession"] }
            test.startRecording()
            precondition(test.recorder.startCalls == 0, "Event handler only schedules native startup")
            await test.startupTask?.value
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
                precondition(test.hud.model.phase == .recognizing && matched(test.hud.model) == ["Talkless"])
                precondition(test.hud.model.displayText == "Talkless")
                test.acceptsRecognitionHUDUpdates = false
                for phase in [HUDModel.Phase.polishing, .editing, .inserting, .completed] {
                    test.hud.model.preview = "finalized words"
                    test.hud.show(phase)
                    old.onPartial?("late partial")
                    old.onStatus?("late status")
                    old.onError?("late error")
                    precondition(test.hud.model.phase == phase && test.hud.model.displayText == "finalized words",
                                 "Late callbacks cannot replace final raw or output after recognition completes")
                }
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
            await test.startupTask?.value
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

        FakeSession.onCreate = {}
        LLMClient.onComplete = {}
        TextIO.onInsert = { _ in }
        let timestamp: UInt64 = 10_000_000_000
        // Cancellation can happen synchronously in the next event, before Task runs.
        let neverOpened = StartupHarness()
        neverOpened.triggerPressed(at: timestamp)
        let neverOpenedTask = neverOpened.startupTask!
        neverOpened.triggerReleased(at: timestamp + 1)
        precondition(neverOpened.state == .idle && neverOpened.startupTask == nil)
        await neverOpenedTask.value
        precondition(neverOpened.recorder.startCalls == 0 && neverOpened.recorder.stopCalls == 0)
        print("PASS hold release before task launch never opens or uploads audio")

        for action in ["hold_release", "escape", "combo", "user"] {
            for staleFailure in [false, true] {
                let test = StartupHarness()
                test.recorder.suspendStart = true
                test.triggerPressed(at: timestamp)
                let oldTask = test.startupTask!
                let oldSession = FakeSession.latest!
                await wait { test.recorder.starts.count == 1 }
                switch action {
                case "hold_release": test.triggerReleased(at: timestamp + 10)
                case "escape": precondition(test.escapePressed())
                case "combo": test.comboKeyPressed(at: timestamp + 10)
                default: test.cancel()
                }
                precondition(test.state == .idle && oldSession.cancelled && test.recorder.cancelCalls == 1)
                precondition(test.startupTask == nil && test.processingTask == nil)
                test.triggerReleased(at: timestamp + 20)
                precondition(test.state == .idle && test.recorder.stopCalls == 0)
                test.triggerPressed(at: timestamp + 30)
                let currentTask = test.startupTask!
                let currentSession = FakeSession.latest!
                await wait { test.recorder.starts.count == 2 }
                if staleFailure {
                    test.recorder.starts[0].resume(throwing: NSError(domain: "Old start timeout", code: 1))
                } else {
                    test.recorder.starts[0].resume()
                }
                await oldTask.value
                oldSession.onPartial?("stale words")
                oldSession.onStatus?("stale status")
                oldSession.onError?("stale failure")
                precondition(test.state == .recording && test.startupTask != nil && !currentSession.cancelled)
                precondition(test.hud.model.preview.isEmpty && test.recorder.cancelCalls == 1)
                test.recorder.starts[1].resume()
                await currentTask.value
                precondition(test.startupTask == nil && test.state == .recording && test.recorder.stopCalls == 0)
                test.cancel()
            }
        }
        print("PASS pending start release/Escape/combo/cancel, immediate next start, and stale success/error fencing")

        for action in ["toggle", "menu", "alternate"] {
            for enabled in [false, true] {
                let test = StartupHarness()
                test.settings.recordingGestureMode = .toggle
                test.settings.polishEnabled = enabled
                test.settings.audioInputDeviceUID = "captured-input"
                test.recorder.suspendStart = true
                test.triggerPressed(at: timestamp)
                let session = FakeSession.latest!
                // Changes before the scheduled task runs still belong to the next input.
                test.settings.audioInputDeviceUID = "next-input"
                test.settings.polishEnabled = !enabled
                test.settings.recordingGestureMode = .hold
                await wait { test.recorder.starts.count == 1 }
                test.triggerReleased(at: timestamp + 10)
                precondition(test.state == .recording && test.handsFree)
                switch action {
                case "toggle": test.triggerPressed(at: timestamp + 20)
                case "menu": test.toggleFromMenu()
                default: test.alternateFinishPressed(at: timestamp + 20)
                }
                let task = test.processingTask!
                precondition(test.state == .processing && test.recorder.stopCalls == 0)
                test.triggerPressed(at: timestamp + 30)
                test.triggerReleased(at: timestamp + 40)
                test.alternateFinishPressed(at: timestamp + 50)
                test.toggleFromMenu()
                TextIO.inserted = []
                LLMClient.calls = 0
                test.recorder.starts[0].resume()
                await task.value
                let polish = action == "alternate" ? !enabled : enabled
                precondition(test.recorder.selectedDevice == "captured-input")
                precondition(test.recorder.startCalls == 1 && test.recorder.stopCalls == 1 && session.finishes == 1)
                precondition(LLMClient.calls == (polish ? 1 : 0) && TextIO.inserted.count == 1)
                precondition(test.state == .idle && test.history.entries.count == 1)
            }
        }
        print("PASS pending toggle/menu/alternate finish exactly once, input/default snapshots, and trailing-event suppression")

        let queued = StartupHarness()
        queued.recorder.suspendStart = true
        queued.toggleFromMenu()
        let staleSession = FakeSession.latest!
        await wait { queued.recorder.starts.count == 1 }
        queued.toggleFromMenu()
        let staleProcessing = queued.processingTask!
        precondition(queued.state == .processing)
        queued.cancel()
        queued.toggleFromMenu()
        let currentStartup = queued.startupTask!
        await wait { queued.recorder.starts.count == 2 }
        queued.recorder.starts[0].resume()
        await staleProcessing.value
        precondition(queued.state == .recording && queued.recorder.stopCalls == 0 && staleSession.finishes == 0)
        queued.recorder.starts[1].resume()
        await currentStartup.value
        precondition(queued.state == .recording && queued.startupTask == nil && queued.recorder.stopCalls == 0)
        queued.cancel()
        print("PASS cancelled queued finish cannot stop a newer recording after old startup returns")

        for queueFinish in [false, true] {
            let test = StartupHarness()
            test.recorder.suspendStart = true
            test.toggleFromMenu()
            let task = test.startupTask!
            let session = FakeSession.latest!
            await wait { test.recorder.starts.count == 1 }
            if queueFinish { test.toggleFromMenu() }
            let processing = test.processingTask
            TextIO.inserted = []
            LLMClient.calls = 0
            test.recorder.starts[0].resume(throwing: NSError(domain: "Synthetic", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone start timed out"]))
            await task.value
            await processing?.value
            precondition(test.state == .idle && test.startupTask == nil && test.processingTask == nil && session.cancelled)
            precondition(test.hud.model.phase == .error("Cannot start recording: Microphone start timed out"))
            precondition(test.recorder.stopCalls == 0 && session.finishes == 0 && LLMClient.calls == 0 && TextIO.inserted.isEmpty)
        }
        print("PASS start timeout surfaces actionable error and cancels queued finish without recognition/upload")
    }
}
'''

MICROPHONE_STUBS = r'''
import Foundation
struct FakeBuffer: Sendable { let frameLength: UInt32 }
enum TalklessError: Error { case message(String) }
@MainActor enum AVCaptureDevice {
    enum Media { case audio }
    enum Authorization { case authorized, denied }
    static var permission = Authorization.authorized
    static func authorizationStatus(for media: Media) -> Authorization { permission }
}
@MainActor final class AudioRecorder {
    static var instances = 0
    static var starts: [String?] = []
    static var stops = 0
    static var cancels = 0
    static var startFailure = false
    static var stopFailure = false
    static var noBuffers = false
    var onBuffer: (@Sendable (FakeBuffer) -> Void)?
    init() { Self.instances += 1 }
    func start(deviceUID: String?) async throws {
        Self.starts.append(deviceUID)
        if Self.startFailure { throw TalklessError.message("start timeout") }
        let callback = onBuffer
        let noBuffers = Self.noBuffers
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                if !noBuffers { callback?(FakeBuffer(frameLength: 800)) }
                continuation.resume()
            }
        }
    }
    func stop() async throws -> [Float] {
        Self.stops += 1
        if Self.stopFailure { throw TalklessError.message("stop timeout") }
        return [0]
    }
    func cancel() { Self.cancels += 1 }
    static func reset() {
        instances = 0; starts = []; stops = 0; cancels = 0
        startFailure = false; stopFailure = false; noBuffers = false
    }
}
@main struct MicrophoneTests {
    @MainActor static func main() async throws {
        for selected in [nil, "synthetic-device"] as [String?] {
            AudioRecorder.reset()
            let buffers = try await MicrophoneDiagnostic.run(seconds: 0.0001, repetitions: 20, deviceUID: selected)
            precondition(buffers == 20 && AudioRecorder.instances == 1)
            precondition(AudioRecorder.starts.count == 20 && AudioRecorder.starts.allSatisfy { $0 == selected })
            precondition(AudioRecorder.stops == 20 && AudioRecorder.cancels == 1)
        }
        for repetitions in [0, 31] {
            AudioRecorder.reset()
            do {
                _ = try await MicrophoneDiagnostic.run(repetitions: repetitions)
                preconditionFailure("Invalid repetitions must fail before opening the device")
            } catch {}
            precondition(AudioRecorder.instances == 0)
        }
        for seconds in [Double.nan, .infinity, 0, -1, 31] {
            AudioRecorder.reset()
            do {
                _ = try await MicrophoneDiagnostic.run(seconds: seconds)
                preconditionFailure("Invalid duration must fail before opening the device")
            } catch {}
            precondition(AudioRecorder.instances == 0)
        }
        for fault in ["permission", "start", "stop", "empty"] {
            AudioRecorder.reset()
            AVCaptureDevice.permission = fault == "permission" ? .denied : .authorized
            AudioRecorder.startFailure = fault == "start"
            AudioRecorder.stopFailure = fault == "stop"
            AudioRecorder.noBuffers = fault == "empty"
            do {
                _ = try await MicrophoneDiagnostic.run(seconds: 0.0001, repetitions: 20)
                preconditionFailure("Fault must fail explicitly and stop repetition")
            } catch {}
            precondition(AudioRecorder.instances == (fault == "permission" ? 0 : 1))
            precondition(AudioRecorder.cancels == (fault == "permission" ? 0 : 1))
            precondition(AudioRecorder.starts.count <= 1 && AudioRecorder.stops <= 1)
        }
        print("PASS repeated microphone diagnostic reuses one recorder, preserves system/selected input, totals off-main buffers, validates arguments, and cancels on failure")
    }
}
'''

operation = controller.split("private struct DictationOperation", 1)[1].split("/// Core dictation flow", 1)[0]
overlay_model = (ROOT / "Sources/Talkless/Overlay.swift").read_text().split("/// A nonactivating", 1)[0]
source = overlay_model + "\nprivate struct DictationOperation" + operation + STUBS + "\n".join(method(name) for name in ("stopAndProcess", "finish", "markModelReadyAfterRecognition", "modelPreparationState")) + TESTS
with tempfile.TemporaryDirectory(prefix="talkless-processing-hud-tests-") as directory:
    path = Path(directory)
    swift = path / "ProcessingHUDTests.swift"
    binary = path / "processing-hud-tests"
    swift.write_text(source)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    str(swift), str(ROOT / "Sources/Talkless/HUDAppearance.swift"),
                    str(ROOT / "Sources/Talkless/DictionaryHighlight.swift"),
                    str(ROOT / "Sources/Talkless/TextRevisionHighlight.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
    overlay_model = (ROOT / "Sources/Talkless/Overlay.swift").read_text().split("/// A nonactivating", 1)[0]
    # Real HUDModel, real startup/cancel methods, only external boundaries substituted.
    shared_processing = STUBS.split("enum Prompts {", 1)[1].split("@MainActor final class FakeHotkeys", 1)[0]
    shared_processing = "enum Prompts {" + shared_processing
    shared_processing += '''
    typealias Settings = FakeSettings
    typealias Context = AppContext
    extension TextIO { static func selectedTextViaAX() -> String? { "Selected sentence" } }
    @MainActor final class FakeTranslationPanel {
        var isVisible = false
        func close() { isVisible = false }
    }
    '''
    startup = overlay_model + "\nprivate struct DictationOperation" + operation + shared_processing + STARTUP_STUBS
    startup += "\n".join(method(name).replace("NSWorkspace", "FakeWorkspace") for name in
                         ("startRecording", "stopAndProcess", "finish", "cancel", "triggerPressed", "triggerReleased",
                          "alternateFinishPressed", "comboKeyPressed", "escapePressed", "toggleFromMenu")) + STARTUP_TESTS
    swift.write_text(startup)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift),
                    str(ROOT / "Sources/Talkless/HUDAppearance.swift"),
                    str(ROOT / "Sources/Talkless/DictionaryHighlight.swift"),
                    str(ROOT / "Sources/Talkless/TextRevisionHighlight.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
    diagnostic = (ROOT / "Sources/Talkless/MicrophoneDiagnostic.swift").read_text().replace("import AVFoundation\n", "")
    swift.write_text(diagnostic + MICROPHONE_STUBS)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
