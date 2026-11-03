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
    var onShow: (HUDModel.Phase) -> Void = { _ in }
    func show(_ phase: HUDModel.Phase) {
        onShow(phase)
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
    var finalizing = false
    func beginFinalization() -> Bool { finalizing = true; return true }
    func stop() async throws -> [Float] {
        stops += 1
        if suspendStop { return try await withCheckedThrowingContinuation { pendingStop = $0 } }
        if let interruptionError { throw NSError(domain: "Synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: interruptionError]) }
        return samples
    }
    func cancel() {}
}
@MainActor class FakeSession {
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
enum TalklessError: Error { case message(String) }
@MainActor final class EnhancedFailureRelay { weak var session: EnhancedTranscriptionSession? }
@MainActor final class EnhancedTranscriptionSession: FakeSession {
    func onlineFailed(_ error: Error) { online.cancel() }
    func localFailed(_ error: Error) { local.cancel() }
    var secondaryTranscript: String?
    let online: FakeSession
    let local: FakeSession
    init(online: FakeSession, local: FakeSession) { self.online = online; self.local = local; super.init() }
}
enum OutputLanguage { case original, english }
struct Settings {
    var enhancedRecognition = false
    var sentenceCandidates = false
    var candidateWaitSeconds = 5
    var doubaoConfigured = true
    var polishEnabled = true
    var llmConfigured = true
    var llmConfig = 0
    var outputLanguage = OutputLanguage.original
    var punctuationStyle = PunctuationStyle.keepAll
    var latinSpacing = LatinSpacing.none
    var learned: [(raw: String, output: String)] = []
    mutating func learnFromDictation(raw: String, output: String, fired: Set<String>) { learned.append((raw, output)) }
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
@MainActor enum EnhancedPolish {
    static var choices = ["processed transcript"]
    static var inputs: [(primary: String, secondary: String?)] = []
    static func run(primary: String, secondary: String?, context: Context?, settings: Settings, alternatives: Bool = true) async throws -> [String] {
        inputs.append((primary, secondary))
        await Task.yield()
        return choices
    }
}
@MainActor final class SentenceCandidatesPanel {
    struct Selection {
        let text: String
        let explicit: Bool
    }
    var requests: [(candidates: [String], timeout: TimeInterval)] = []
    var selection: Selection?
    var suspendChoice = false
    var pendingChoice: CheckedContinuation<Selection?, Never>?
    var cancels = 0
    func choose(candidates: [String], timeout: TimeInterval) async -> Selection? {
        requests.append((candidates, timeout))
        if suspendChoice { return await withCheckedContinuation { pendingChoice = $0 } }
        await Task.yield()
        return selection
    }
    func cancel() {
        cancels += 1
        pendingChoice?.resume(returning: nil)
        pendingChoice = nil
    }
}
enum PolishValidation {
    static func validate(source: String, output: String) throws -> String { output }
}
extension Int { var processIdentifier: Int32 { Int32(self) } }
@MainActor enum TextIO {
    static func insertionContext() -> [String: String] { ["globe_action": "none", "input_method": "false"] }
    static var inserted: [String] = []
    static var onInsert: (String) -> Void = { _ in }
    static var outcome = PasteOutcome.submitted
    static func insert(_ text: String, targetPID: Int32? = nil) async -> PasteOutcome {
        onInsert(text)
        await Task.yield()
        inserted.append(text)
        return outcome
    }
    static var copied: [String] = []
    static func copyToClipboard(_ text: String) { copied.append(text) }
    static var copiedSelection: String?
    static var copyReads = 0
    static func selectedTextViaCopy() async -> String? { copyReads += 1; await Task.yield(); return copiedSelection }
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
@MainActor final class FakeHotkeys {}
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
    var recordingCandidatesEnabled = false
    var recordingCandidateWait: TimeInterval = 5
    let sentencePanel = SentenceCandidatesPanel()
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
    var targetApp: Int? = 1
    var selectionTask: Task<Void, Never>?
    var aiInProgress = false
    var recordingReplacements: [DictionaryReplacement] = []
    var appChanged = false
    var accessibilityMissing = false
    enum PermissionPane { case accessibility, microphone }
    var openedPanes: [PermissionPane] = []
    func openPermissionSettings(_ pane: PermissionPane) { openedPanes.append(pane) }
    func insertionBlocker(for app: Int?) -> (reason: String, message: String)? {
        precondition(app == 1)
        if accessibilityMissing { return ("permission", "Accessibility needed. Result saved in History.") }
        return appChanged ? ("target_changed", "The app changed. Result saved in History.") : nil
    }
    func cancel(reason: String = "user") {
        sentencePanel.cancel()
        aiInProgress = false
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
                                 failure: Bool = false,
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
            precondition(test.aiInProgress, "The menu bar shows AI work for the whole polish/edit call")
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
        test.stopAndProcess()
        precondition(test.state == .processing && test.hud.phases == [.recognizing])
        precondition(test.hud.model.phase.accessibilityLabel == dictatingLabel,
                     "Engine capture/recognition phases share one continuous user-facing activity")
        precondition(test.pressedAt == nil, "Stopping must clear the gesture before awaiting recognition")
        // Changing global Settings during recognition cannot change the captured finish decision either.
        if changeDefault { test.settings.polishEnabled = !enabled }
        guard let task = test.processingTask else { preconditionFailure("Missing processing task") }
        await task.value
        precondition(test.hud.phases == phases, "\(name): unexpected HUD sequence \(test.hud.phases)")
        let usesLLM = editing || (enabled && configured)
        let output = usesLLM && !failure ? "processed transcript" : "raw transcript"
        precondition(LLMClient.calls == (usesLLM ? 1 : 0))
        precondition(TextIO.inserted == [output] && test.lastTranscript == output,
                     "\(name): must insert the result (raw fallback on failure) exactly once")
        precondition(test.history.entries.count == 1)
        let entry = test.history.entries[0]
        precondition(entry.raw == "raw transcript" && entry.output == output)
        precondition(entry.kind == (editing ? .edit : .dictation))
        // Only same-language polish output is learning evidence; edits never are.
        let learnedOutput = enabled && configured && !failure ? "processed transcript" : "raw transcript"
        precondition(editing ? test.settings.learned.isEmpty
                     : test.settings.learned.count == 1 && test.settings.learned[0] == ("raw transcript", learnedOutput),
                     "\(name): unexpected dictionary learning input")
        precondition(test.state == .idle && test.session == nil && test.processingTask == nil,
                     "Production finish must clear processing state")
        precondition(!test.aiInProgress, "Finishing clears the AI indicator")
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
        for (editing, missingAccessibility) in [(false, false), (true, false), (false, true), (true, true)] {
            let switched = ProcessingHarness()
            switched.editSelection = editing ? "selected text" : nil
            switched.appChanged = !missingAccessibility
            switched.accessibilityMissing = missingAccessibility
            TextIO.inserted = []
            TextIO.copied = []
            switched.stopAndProcess()
            await switched.processingTask?.value
            precondition(TextIO.inserted.isEmpty, "A changed frontmost app must never receive the paste")
            precondition(TextIO.copied.isEmpty && switched.history.entries.count == 1, "Automatic fallback must not overwrite an unresolved clipboard transaction")
            guard case .error(let message) = switched.hud.model.phase, message.contains("History") else {
                preconditionFailure("Switching apps must explain where the result was saved")
            }
            precondition(switched.state == .idle)
            let reason = missingAccessibility ? "permission" : "target_changed"
            precondition(switched.openedPanes == (missingAccessibility ? [.accessibility] : []),
                         "Missing Accessibility opens its System Settings pane; a changed app does not")
            precondition(Diagnostics.shared.events.contains { $0.0 == "paste_skipped" && $0.1["reason"] == reason })
        }
        for outcome in [PasteOutcome.unconfirmed, .blocked, .clipboardChanged, .targetChanged, .writeFailed] {
            let failedPaste = ProcessingHarness()
            TextIO.outcome = outcome
            TextIO.copied = []
            Diagnostics.shared.events = []
            failedPaste.stopAndProcess()
            await failedPaste.processingTask?.value
            precondition(failedPaste.state == .idle && failedPaste.history.entries.count == 1)
            precondition(TextIO.copied.isEmpty, "Failed paste must preserve unresolved clipboard contents")
            if outcome == .unconfirmed || outcome == .blocked {
                precondition(failedPaste.hud.model.phase == .hidden, "Uncertain paste outcomes close quietly")
            } else {
                precondition(failedPaste.hud.model.phase == .error(outcome.message))
            }
            precondition(Diagnostics.shared.events.contains { $0.0 == "paste_skipped" && $0.1["reason"] == outcome.diagnosticReason })
            precondition(!Diagnostics.shared.events.contains { $0.0 == "paste_returned" })
        }
        TextIO.outcome = .submitted
        TextIO.copied = []
        for polish in [false, true] {
            Diagnostics.shared.events = []
            let fixedTest = ProcessingHarness()
            fixedTest.recordingPolishEnabled = polish
            fixedTest.recordingReplacements = [DictionaryReplacement(heard: "TRANSCRIPT", term: "Transcript™")]
            TextIO.inserted = []
            fixedTest.stopAndProcess()
            await fixedTest.processingTask?.value
            let expected = polish ? "processed transcript" : "raw Transcript™"
            precondition(TextIO.inserted == [expected], "Dictionary fixes apply before polish and without it")
            precondition(fixedTest.history.entries.first?.raw == "raw Transcript™", "History keeps the fixed transcript")
            precondition(fixedTest.hud.model.revisionOriginal == "raw transcript", "HUD compares against the recognizer's words")
            precondition(Diagnostics.shared.events.contains { $0.0 == "recognition_complete" && $0.1["replacement_count"] == "1" })
        }
        print("PASS explicit dictionary fixes run after recognition, before polish, and are visible against recognized words")
        let late = ProcessingHarness()
        late.recordingPolishEnabled = false
        var selectionReady: CheckedContinuation<Void, Never>?
        late.selectionTask = Task { @MainActor in
            await withCheckedContinuation { selectionReady = $0 }
            late.editSelection = "selected text"
        }
        late.hud.onShow = { phase in
            if phase == .recognizing {
                precondition(late.recorder.finalizing, "Capture must close before showing the processing HUD")
            }
        }
        LLMClient.calls = 0
        late.stopAndProcess()
        precondition(late.recorder.finalizing && late.recorder.stops == 0)
        while selectionReady == nil { await Task.yield() }
        precondition(late.recorder.finalizing && late.recorder.stops == 0,
                     "Pending selection must not extend capture")
        selectionReady!.resume()
        await late.processingTask?.value
        precondition(late.history.entries.first?.kind == .edit && LLMClient.calls == 1,
                     "A selection copied after recording started still makes this a voice edit")
        print("PASS stop waits for a pending selection read before choosing edit or dictation")
        print("PASS failed or blocked pastes keep history without replacing the clipboard and explain their outcome")
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
        for explicit in [false, true] {
            for translated in [false, true] {
                let test = ProcessingHarness()
                test.recordingCandidatesEnabled = true
                test.recordingCandidateWait = 7
                test.settings.outputLanguage = translated ? .english : .original
                EnhancedPolish.choices = ["first candidate", "chosen candidate"]
                EnhancedPolish.inputs = []
                let selected = explicit ? "chosen candidate" : "first candidate"
                test.sentencePanel.selection = .init(text: selected, explicit: explicit)
                TextIO.inserted = []
                LLMClient.calls = 0
                test.stopAndProcess()
                // Mid-processing preferences affect only the next recording.
                test.settings.sentenceCandidates = false
                test.settings.candidateWaitSeconds = 15
                await test.processingTask?.value
                precondition(EnhancedPolish.inputs.count == 1 && EnhancedPolish.inputs[0].primary == "raw transcript"
                             && EnhancedPolish.inputs[0].secondary == nil && LLMClient.calls == 0)
                precondition(test.sentencePanel.requests.count == 1
                             && test.sentencePanel.requests[0].candidates == EnhancedPolish.choices
                             && test.sentencePanel.requests[0].timeout == 7)
                precondition(TextIO.inserted == [selected] && test.lastTranscript == selected)
                precondition(test.history.entries.count == 1 && test.history.entries[0].output == selected)
                let learning = explicit && !translated ? selected : "raw transcript"
                precondition(test.settings.learned.count == 1
                             && test.settings.learned[0] == ("raw transcript", learning),
                             "Only an explicit same-language candidate is correction evidence; timeout only refreshes raw words")
                precondition(test.hud.phases == [.recognizing, .polishing, .hidden, .inserting, .completed])
                precondition(test.state == .idle && test.processingTask == nil && !test.aiInProgress)
            }
        }
        print("PASS multiple candidates insert explicit choice or timeout default; only explicit same-language choices teach corrections")
        for enhanced in [false, true] {
            let test = ProcessingHarness()
            test.recordingCandidatesEnabled = !enhanced
            if enhanced {
                let session = EnhancedTranscriptionSession(online: FakeSession(), local: FakeSession())
                session.secondaryTranscript = "local transcript"
                test.session = session
            }
            // Single-result candidate mode and enhanced recognition with review off both bypass the panel.
            EnhancedPolish.choices = enhanced ? ["merged transcript", "unused alternative"] : ["only candidate"]
            EnhancedPolish.inputs = []
            TextIO.inserted = []
            LLMClient.calls = 0
            test.stopAndProcess()
            await test.processingTask?.value
            let expected = EnhancedPolish.choices[0]
            precondition(test.sentencePanel.requests.isEmpty && TextIO.inserted == [expected])
            precondition(EnhancedPolish.inputs.count == 1 && EnhancedPolish.inputs[0].primary == "raw transcript"
                         && EnhancedPolish.inputs[0].secondary == (enhanced ? "local transcript" : nil))
            precondition(LLMClient.calls == 0 && test.history.entries.count == 1)
            precondition(test.settings.learned.count == 1 && test.settings.learned[0] == ("raw transcript", expected))
            precondition(test.hud.phases == [.recognizing, .polishing, .inserting, .completed])
        }
        print("PASS a single candidate never opens the panel; enhanced recognition forwards secondary text and works without review")
        for controllerCancel in [false, true] {
            let test = ProcessingHarness()
            test.recordingCandidatesEnabled = true
            test.sentencePanel.suspendChoice = controllerCancel
            EnhancedPolish.choices = ["first candidate", "second candidate"]
            TextIO.inserted = []
            Diagnostics.shared.events = []
            test.stopAndProcess()
            let task = test.processingTask!
            if controllerCancel {
                for _ in 0..<1000 {
                    if test.sentencePanel.pendingChoice != nil { break }
                    try? await Task.sleep(for: .milliseconds(1))
                }
                precondition(test.sentencePanel.pendingChoice != nil, "Candidate review must be pending before cancellation")
                test.cancel()
            }
            await task.value
            precondition(test.sentencePanel.requests.count == 1 && TextIO.inserted.isEmpty)
            precondition(test.history.entries.isEmpty && test.settings.learned.isEmpty && test.lastTranscript.isEmpty,
                         "Cancelling candidates must not insert, learn, or save an unchosen result")
            precondition(test.state == .idle && test.processingTask == nil && !test.aiInProgress
                         && test.hud.model.phase == .hidden)
            precondition(Diagnostics.shared.events.contains { $0.0 == "processing_cancelled" })
        }
        EnhancedPolish.choices = ["processed transcript"]
        print("PASS panel dismissal and controller cancellation never insert, learn, or save an unchosen candidate")
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
        await check("disabled polish skips AI even when configured", enabled: false,
                    phases: [.recognizing, .inserting, .completed])
        for enabled in [true, false] {
            await check("snapshot default=\(enabled)", enabled: enabled, changeDefault: true,
                        phases: enabled ? [.recognizing, .polishing, .inserting, .completed] : [.recognizing, .inserting, .completed])
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
    func recordAsync(event: String, metadata: [String: String] = [:]) {}
}
@MainActor enum LLMAPITransport {
    static var preconnects: [String] = []
    static func preconnect(baseURL: String, apiProtocol: String) { preconnects.append(baseURL) }
}
@MainActor final class FakeSettings {
    enum Engine: String, CaseIterable { case qwen, doubao }
    var asrEngine: Engine = .qwen
    var enhancedRecognition = false
    var sentenceCandidates = false
    var candidateWaitSeconds = 5
    var doubaoConfigured = true
    var audioInputDeviceUID: String?
    var polishEnabled = true
    var llmConfig = 0
    var llmBaseURL = "https://synthetic.invalid"
    var llmProtocol = "responses"
    var recordingGestureMode = StartupHarness.Gesture.hold
    var terms = ["Talkless", "\u{5317}\u{4EAC}"]
    var termReads = 0
    var dictionaryTerms: [String] { termReads += 1; return terms }
    var voiceEditEnabled = false
    var llmConfigured = true
    var recognitionReplacements: [DictionaryReplacement] = []
    var recognitionTerms: [String] { dictionaryTerms }
    func expireLearnedFixes() {}
    enum Language { case original, english }
    var outputLanguage = Language.original
    var punctuationStyle = PunctuationStyle.keepAll
    var latinSpacing = LatinSpacing.none
    func learnFromDictation(raw: String, output: String, fired: Set<String>) {}
    var doubaoConfig = "synthetic-config"
    var onlineLocalFallback = false
    var needsLocalModel: Bool { asrEngine == .qwen || onlineLocalFallback || enhancedRecognition }
    var modelInstalled = true
    func resolvedQwenModelDirectory() throws -> URL {
        guard modelInstalled else { throw NSError(domain: "Synthetic", code: 2) }
        return URL(fileURLWithPath: "/synthetic/model")
    }
}
struct AppContext { let name: String; let bundleID: String }
struct FakeApp { let localizedName: String?; let bundleIdentifier: String?; var processIdentifier: Int32 { 1 } }
@MainActor final class FakeWorkspace {
    static let shared = FakeWorkspace()
    let frontmostApplication: FakeApp? = nil
}
@MainActor final class ModelManager {
    static let shared = ModelManager()
    var operationModelID: String?
    var isBusy: Bool { operationModelID != nil }
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
    static var preparationCalls = 0
    static var unloadCalls = 0
    static func prepareAssets(modelDirectory: URL) async throws { preparationCalls += 1 }
    static func unloadModel() async { unloadCalls += 1; await Task.yield() }
    init(modelDirectory: URL, language: String?, contextualStrings: [String],
         onStatus: @escaping (String) -> Void = { _ in }, onError: @escaping (String) -> Void = { _ in }) {
        super.init(); terms = contextualStrings; self.onStatus = onStatus; self.onError = onError
    }
}
@MainActor final class FallbackTranscriptionSession: FakeSession {
    init(online: any TranscriptionSession, makeLocal: () -> any TranscriptionSession, onFallback: () -> Void) {
        super.init()
    }
}
enum TalklessError: Error { case message(String) }
@MainActor final class EnhancedFailureRelay { weak var session: EnhancedTranscriptionSession? }
@MainActor final class EnhancedTranscriptionSession: FakeSession {
    func onlineFailed(_ error: Error) { online.cancel() }
    func localFailed(_ error: Error) { local.cancel() }
    var secondaryTranscript: String?
    let online: any TranscriptionSession
    let local: any TranscriptionSession
    init(online: any TranscriptionSession, local: any TranscriptionSession, operationID: String = "", diagnostics: @escaping ([String: String]) -> Void = { _ in }) {
        self.online = online; self.local = local
        super.init()
    }
}
@MainActor final class DoubaoTranscriptionSession: FakeSession {
    static var notConfigured = false
    init(config: String, onError: @escaping (String) -> Void = { _ in }) throws {
        if Self.notConfigured { throw NSError(domain: "Synthetic", code: 3) }
        super.init(); self.onError = onError
    }
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
    var active = false
    var finalizing = false
    var finalizations = 0
    func beginFinalization() -> Bool {
        guard active else { return false }
        finalizing = true
        finalizations += 1
        return true
    }
    func start(deviceUID: String?, operationID: UUID) async throws {
        active = true
        finalizing = false
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
    func cancel() { cancelCalls += 1; active = false }
}
typealias AudioRecorder = FakeRecorder
@MainActor final class FakeHUD {
    let model = HUDModel()
    var onShow: (HUDModel.Phase) -> Void = { _ in }
    func show(_ phase: HUDModel.Phase) { onShow(phase); model.phase = phase }
    func hide() { model.phase = .hidden; model.preview = ""; model.isEditMode = false }
}
@MainActor final class FakeHotkeys { var editModifierHeld = false }
@MainActor final class StartupHarness {
    var editIntent = false
    enum State { case idle, recording, processing }
    enum Gesture: String { case hold, toggle }
    enum Authorization { case authorized, notDetermined, denied, restricted }
    static var microphoneStatus: Authorization = .authorized
    var state = State.idle
    var shortcutCaptureActive = false
    var generation = 0
    var acceptsRecognitionHUDUpdates = true
    var recordingGestureMode = Gesture.hold
    var handsFree = false
    private var diagnosticOperation: DictationOperation?
    var changingModel = false
    var preparedModelDirectory: URL?
    var preparingModelDirectory: URL?
    var failedModelDirectory: URL?
    var modelPreparationStatusKey: String?
    var modelPreparationTask: Task<Void, Never>?
    let settings = FakeSettings()
    let hud = FakeHUD()
    let recorder = FakeRecorder()
    let hotkeys = FakeHotkeys()
    var targetApp: FakeApp?
    var selectionTask: Task<Void, Never>?
    var acquiringTranslationSelection = false
    var aiInProgress = false
    var recordingReplacements: [DictionaryReplacement] = []
    func insertionBlocker(for app: FakeApp?) -> (reason: String, message: String)? { nil }
    enum PermissionPane { case accessibility, microphone }
    var openedPanes: [PermissionPane] = []
    func openPermissionSettings(_ pane: PermissionPane) { openedPanes.append(pane) }
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
    var recordingCandidatesEnabled = false
    var recordingCandidateWait: TimeInterval = 5
    let sentencePanel = SentenceCandidatesPanel()
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
        do {
            let fixing = StartupHarness()
            fixing.settings.recognitionReplacements = [DictionaryReplacement(heard: "talk less", term: "Talkless")]
            fixing.startRecording()
            await fixing.startupTask?.value
            // A Settings edit mid-recording must not change this recording's fixes.
            fixing.settings.recognitionReplacements = []
            FakeSession.latest?.onPartial?("open talk less")
            precondition(fixing.hud.model.preview == "open Talkless" && fixing.previewText == "open Talkless",
                         "Live preview shows the recording's dictionary fixes")
            precondition(matched(fixing.hud.model) == ["Talkless"], "Fixed terms are highlighted live")
            fixing.cancel()
        }
        print("PASS live preview applies the recording's dictionary fixes")
        do {
            QwenTranscriptionSession.preparationCalls = 0
            QwenTranscriptionSession.unloadCalls = 0
            let residency = StartupHarness()
            residency.settings.asrEngine = .doubao
            residency.prepareSelectedModel()
            precondition(residency.modelPreparationTask == nil, "Online alone never loads Qwen")
            residency.settings.onlineLocalFallback = true
            residency.prepareSelectedModel()
            await residency.modelPreparationTask?.value
            precondition(QwenTranscriptionSession.preparationCalls == 1 && residency.preparedModelDirectory != nil,
                         "Enabling fallback preloads the local model")
            residency.prepareSelectedModel()
            precondition(QwenTranscriptionSession.preparationCalls == 1, "A warmed standby is reused")
            residency.state = .recording
            residency.settings.onlineLocalFallback = false
            residency.prepareSelectedModel()
            precondition(QwenTranscriptionSession.unloadCalls == 0, "Never unload during recording")
            residency.state = .idle
            residency.prepareSelectedModel()
            precondition(residency.changingModel, "Unload is fenced against new recordings")
            await residency.modelPreparationTask?.value
            precondition(QwenTranscriptionSession.unloadCalls == 1 && residency.preparedModelDirectory == nil && !residency.changingModel)
            residency.settings.asrEngine = .qwen
            residency.prepareSelectedModel()
            await residency.modelPreparationTask?.value
            precondition(QwenTranscriptionSession.preparationCalls == 2, "Returning to local reloads the model")
        }
        print("PASS local model residency follows the selected engine and fallback switch, deferred until idle")
        do {
            let noModel = StartupHarness()
            noModel.settings.asrEngine = .doubao
            noModel.settings.onlineLocalFallback = true
            noModel.settings.modelInstalled = false
            noModel.startRecording()
            await noModel.startupTask?.value
            precondition(noModel.state == .recording && noModel.session is DoubaoTranscriptionSession,
                         "A missing local model never blocks online recognition")
            noModel.cancel()

            DoubaoTranscriptionSession.notConfigured = true
            defer { DoubaoTranscriptionSession.notConfigured = false }
            let unset = StartupHarness()
            unset.settings.asrEngine = .doubao
            unset.settings.onlineLocalFallback = true
            unset.startRecording()
            await unset.startupTask?.value
            precondition(unset.state == .recording && unset.session is QwenTranscriptionSession
                         && unset.hud.model.notice != nil, "Online that cannot start falls back to local")
            unset.cancel()

            let blocked = StartupHarness()
            blocked.settings.asrEngine = .doubao
            blocked.startRecording()
            precondition(blocked.state == .idle && blocked.session == nil, "Without the switch, online setup errors still block")
        }
        print("PASS fallback is a safety net: no model keeps online, unset online uses local only when enabled")
        for missing in ["doubao", "llm", "model"] {
            let blocked = StartupHarness()
            blocked.settings.asrEngine = .doubao
            blocked.settings.enhancedRecognition = true
            blocked.settings.onlineLocalFallback = true
            blocked.settings.doubaoConfigured = missing != "doubao"
            blocked.settings.llmConfigured = missing != "llm"
            blocked.settings.modelInstalled = missing != "model"
            FakeSession.latest = nil
            LLMAPITransport.preconnects = []
            TextIO.inserted = []
            blocked.startRecording()
            precondition(blocked.state == .idle && blocked.session == nil && blocked.startupTask == nil)
            precondition(blocked.recorder.startCalls == 0 && FakeSession.latest == nil
                         && LLMAPITransport.preconnects.isEmpty && TextIO.inserted.isEmpty,
                         "Enhanced recognition requires every provider; fallback must not silently downgrade it")
            guard case .error = blocked.hud.model.phase else { preconditionFailure("Missing enhanced setup must be actionable") }
        }
        print("PASS missing Doubao/AI/local model blocks enhanced recognition before capture, session creation, or preconnect")
        for waitSeconds in [1, 5, 20] {
            let enhanced = StartupHarness()
            enhanced.settings.asrEngine = .doubao
            enhanced.settings.enhancedRecognition = true
            enhanced.settings.polishEnabled = false
            enhanced.settings.sentenceCandidates = true
            enhanced.settings.candidateWaitSeconds = waitSeconds
            enhanced.startRecording()
            await enhanced.startupTask?.value
            guard let session = enhanced.session as? EnhancedTranscriptionSession else {
                preconditionFailure("Enhanced startup must construct both recognizers")
            }
            precondition(session.online is DoubaoTranscriptionSession && session.local is QwenTranscriptionSession)
            precondition(enhanced.recordingPolishEnabled && enhanced.recordingCandidatesEnabled
                         && enhanced.recordingCandidateWait == TimeInterval(min(15, max(2, waitSeconds))))
            precondition(enhanced.recordingModelDirectory == nil, "Online success cannot certify local readiness")
            (session.online as! DoubaoTranscriptionSession).onError?("Synthetic online timeout")
            precondition((session.online as! FakeSession).cancelled && !(session.local as! FakeSession).cancelled
                         && enhanced.state == .recording, "Online timeout cancels only the failed route")
            enhanced.settings.sentenceCandidates = false
            enhanced.settings.candidateWaitSeconds = 3
            precondition(enhanced.recordingCandidatesEnabled
                         && enhanced.recordingCandidateWait == TimeInterval(min(15, max(2, waitSeconds))),
                         "Recording captures candidate settings before asynchronous startup")
            enhanced.cancel()
        }
        print("PASS enhanced startup constructs both engines, forces polish, and snapshots/clamps candidate wait")

        TextIO.axSelection = nil // An app that does not expose its selection through Accessibility.
        for voiceEdit in [false, true] {
            TextIO.copiedSelection = "Copied paragraph"
            TextIO.copyReads = 0
            let copied = StartupHarness()
            copied.settings.voiceEditEnabled = voiceEdit
            copied.editIntent = true
            copied.startRecording()
            await copied.selectionTask?.value
            precondition(TextIO.copyReads == (voiceEdit ? 1 : 0), "The ⌘C fallback runs only when voice editing is on")
            precondition(copied.hud.model.isEditMode == voiceEdit, "A copied selection switches the overlay to voice editing")
            precondition(!copied.acquiringTranslationSelection, "The clipboard is released after the fallback")
            copied.cancel()
        }
        TextIO.copiedSelection = nil
        let nothingSelected = StartupHarness()
        nothingSelected.settings.voiceEditEnabled = true
        nothingSelected.editIntent = true
        nothingSelected.startRecording()
        await nothingSelected.selectionTask?.value
        precondition(!nothingSelected.hud.model.isEditMode && nothingSelected.hud.model.notice != nil,
                     "No copied text keeps ordinary dictation and says so")
        nothingSelected.cancel()
        // An address bar selects its URL on focus: the dictation key alone must never read or edit it.
        TextIO.axSelection = "https://example.com/selected-on-focus"
        TextIO.axReads = 0
        TextIO.copyReads = 0
        let plain = StartupHarness()
        plain.settings.voiceEditEnabled = true
        plain.startRecording()
        precondition(TextIO.axReads == 0 && TextIO.copyReads == 0 && !plain.hud.model.isEditMode && plain.editSelection == nil,
                     "Plain dictation never reads the selection")
        plain.editModifierPressed()
        precondition(TextIO.axReads == 1 && plain.hud.model.isEditMode && plain.editSelection == "https://example.com/selected-on-focus",
                     "Pressing the edit modifier during recording switches to voice editing")
        plain.cancel()
        TextIO.axSelection = "Selected sentence"
        print("PASS voice editing needs the edit gesture, falls back to the app's Copy, and switches only when text was copied")
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
            do {
                if engine == .qwen {
                    precondition(old.terms == ["Talkless", "\u{5317}\u{4EAC}"])
                }
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
            test.editIntent = true
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
        print("PASS production recording snapshots for Qwen/Doubao, dynamic dictionary edits, partial revisions, processing exclusion, cancel/startup failures, stale generations, and voice edit")

        for status in [StartupHarness.Authorization.denied, .restricted] {
            StartupHarness.microphoneStatus = status
            let blocked = StartupHarness()
            blocked.startRecording()
            precondition(blocked.state == .idle && blocked.recorder.startCalls == 0)
            precondition(blocked.openedPanes == (status == .denied ? [.microphone] : []),
                         "Denied microphone opens its pane; a managed restriction does not")
        }
        StartupHarness.microphoneStatus = .authorized
        print("PASS denied microphone opens System Settings; restricted does not")

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

        for action in ["toggle", "menu"] {
            let test = StartupHarness()
            test.settings.recordingGestureMode = .toggle
            test.triggerPressed(at: timestamp)
            let startup = test.startupTask!
            let session = FakeSession.latest!
            if action == "toggle" { test.triggerPressed(at: timestamp + 1) }
            else { test.toggleFromMenu() }
            await startup.value
            precondition(test.state == .idle && test.recorder.startCalls == 0 && test.recorder.stopCalls == 0)
            precondition(test.processingTask == nil && session.cancelled && session.finishes == 0,
                         "Explicit finish before startup must not open capture or finish a stale recorder")
        }
        print("PASS explicit toggle/menu finish before startup never opens capture or submits audio")

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

        for action in ["toggle", "menu"] {
            for enabled in [false, true] {
                let test = StartupHarness()
                test.settings.recordingGestureMode = .toggle
                test.settings.polishEnabled = enabled
                test.settings.audioInputDeviceUID = "captured-input"
                test.recorder.suspendStart = true
                LLMAPITransport.preconnects = []
                test.triggerPressed(at: timestamp)
                // Only a recording that will polish warms the AI connection, once, at start.
                precondition(LLMAPITransport.preconnects == (enabled ? ["https://synthetic.invalid"] : []))
                let session = FakeSession.latest!
                // Changes before the scheduled task runs still belong to the next input.
                test.settings.audioInputDeviceUID = "next-input"
                test.settings.polishEnabled = !enabled
                test.settings.recordingGestureMode = .hold
                await wait { test.recorder.starts.count == 1 }
                test.triggerReleased(at: timestamp + 10)
                precondition(test.state == .recording && test.handsFree)
                test.hud.onShow = { phase in
                    if phase == .recognizing { precondition(test.recorder.finalizing) }
                }
                switch action {
                case "toggle": test.triggerPressed(at: timestamp + 20)
                default: test.toggleFromMenu()
                }
                let task = test.processingTask!
                precondition(test.state == .processing && test.recorder.stopCalls == 0)
                precondition(test.recorder.finalizing && test.recorder.finalizations == 1,
                             "Explicit finish must close capture while startup is still pending")
                test.triggerPressed(at: timestamp + 30)
                test.triggerReleased(at: timestamp + 40)
                test.toggleFromMenu()
                TextIO.inserted = []
                LLMClient.calls = 0
                test.recorder.starts[0].resume()
                await task.value
                let polish = enabled
                precondition(test.recorder.selectedDevice == "captured-input")
                precondition(test.recorder.startCalls == 1 && test.recorder.stopCalls == 1 && session.finishes == 1)
                precondition(LLMClient.calls == (polish ? 1 : 0) && TextIO.inserted.count == 1)
                precondition(test.state == .idle && test.history.entries.count == 1)
            }
        }
        print("PASS pending toggle/menu finish exactly once, input/default snapshots, and trailing-event suppression")

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
        precondition(!queued.recorder.finalizing && queued.recorder.finalizations == 1,
                     "Cancelled finish must not close the next recording's gate")
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
                    str(ROOT / "Sources/Talkless/TextRevisionHighlight.swift"),
                    str(ROOT / "Sources/Talkless/DictionaryTerms.swift"),
                    str(ROOT / "Sources/Talkless/TextFormatting.swift"), str(ROOT / "Sources/Talkless/PasteOutcome.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
    overlay_model = (ROOT / "Sources/Talkless/Overlay.swift").read_text().split("/// A nonactivating", 1)[0]
    # Real HUDModel, real startup/cancel methods, only external boundaries substituted.
    shared_processing = STUBS.split("enum Prompts {", 1)[1].split("@MainActor final class FakeHotkeys", 1)[0]
    shared_processing = "enum Prompts {" + shared_processing
    shared_processing += '''
    typealias Settings = FakeSettings
    typealias Context = AppContext
    extension TextIO {
        enum SelectionReading: Equatable { case text(String), empty, unavailable }
        static var axSelection: String? = "Selected sentence"
        static var axReads = 0
        static func selectionViaAX() -> SelectionReading { axReads += 1; return axSelection.map { .text($0) } ?? .unavailable }
    }
    @MainActor final class FakeTranslationPanel {
        var isVisible = false
        func close() { isVisible = false }
    }
    '''
    startup = overlay_model + "\nprivate struct DictationOperation" + operation + shared_processing + STARTUP_STUBS
    startup += "\n".join(method(name).replace("NSWorkspace", "FakeWorkspace") for name in
                         ("prepareSelectedModel", "startRecording", "isCurrentRecognition", "adoptEditSelection", "captureEditSelection", "editModifierPressed", "stopAndProcess", "finish", "cancel", "triggerPressed", "triggerReleased",
                          "comboKeyPressed", "escapePressed", "toggleFromMenu")) + STARTUP_TESTS
    swift.write_text(startup)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift),
                    str(ROOT / "Sources/Talkless/HUDAppearance.swift"),
                    str(ROOT / "Sources/Talkless/DictionaryHighlight.swift"),
                    str(ROOT / "Sources/Talkless/TextRevisionHighlight.swift"),
                    str(ROOT / "Sources/Talkless/DictionaryTerms.swift"),
                    str(ROOT / "Sources/Talkless/TextFormatting.swift"), str(ROOT / "Sources/Talkless/PasteOutcome.swift"), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
    diagnostic = (ROOT / "Sources/Talkless/MicrophoneDiagnostic.swift").read_text().replace("import AVFoundation\n", "")
    swift.write_text(diagnostic + MICROPHONE_STUBS)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library", str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
