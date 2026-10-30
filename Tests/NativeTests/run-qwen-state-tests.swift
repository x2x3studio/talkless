#!/usr/bin/env swift
import Foundation

// Run: swift Tests/NativeTests/run-qwen-state-tests.swift
// Compiles the current production state machine with a fake runtime: no model/GPU/network.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let source = try String(contentsOf: root.appendingPathComponent("Sources/Talkless/QwenTranscription.swift"), encoding: .utf8)
func section(from start: String, to end: String? = nil) -> String {
    guard let startRange = source.range(of: start) else { fatalError("Production marker missing: \(start)") }
    let remainder = source[startRange.lowerBound...]
    if let end {
        guard let endRange = remainder.range(of: end) else { fatalError("Production marker missing: \(end)") }
        return String(remainder[..<endRange.lowerBound])
    }
    return String(remainder)
}
// Both app entry points must opt in; the session's default is deliberately empty.
let controller = try String(contentsOf: root.appendingPathComponent("Sources/Talkless/DictationController.swift"), encoding: .utf8)
let qwenInitializers = controller.components(separatedBy: "QwenTranscriptionSession(").dropFirst()
precondition(qwenInitializers.count == 2, "Check normal dictation and runAudioTest Qwen wiring")
for initializer in qwenInitializers {
    let arguments = initializer.components(separatedBy: "onStatus:")[0]
    precondition(arguments.contains("contextualStrings: settings.dictionaryTerms"),
                 "Every controller Qwen session must receive the dictionary")
}
print("PASS dictionary wiring in normal dictation and audio test")
let transcription = try String(contentsOf: root.appendingPathComponent("Sources/Talkless/Transcription.swift"), encoding: .utf8)
let sessionProtocol = transcription.components(separatedBy: "// MARK: - On-device SpeechAnalyzer")[0]
let stub = #"""
import AVFoundation
import Foundation
// Extracted state-machine fixtures use deterministic English, never application preferences.
private enum L10n {
    static func tr(_ key: String) -> String { key }
    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: key, locale: Locale(identifier: "en"), arguments: args)
    }
}
private enum TalklessError: Error { case message(String) }
private actor QwenModelRuntime {
    static let shared = QwenModelRuntime()
    var calls: [[Float]] = []
    var contexts: [String] = []
    func prepare(modelDirectory: URL, onLoading: @escaping @MainActor @Sendable () -> Void = {}) async throws {}
    func unload() {}
    func decode(samples: [Float], modelDirectory: URL, language: String?, context: String) async throws -> QwenDecodedOutput {
        calls.append(samples)
        contexts.append(context)
        try await Task.sleep(for: .milliseconds(2))
        return .transcript("[\(Int(samples.first ?? -1))..\(Int(samples.last ?? -1))]")
    }
    func reset() { calls = []; contexts = [] }
}
"""#
let tests = #"""
@main struct Tests {
    static func main() async throws {
        let runtime = QwenModelRuntime.shared
        let directory = URL(fileURLWithPath: "/unused")
        let state = QwenCaptureState()
        let all = (0..<520000).map { Float($0 + 1) }

        let dictionarySession = QwenTranscriptionSession(
            modelDirectory: directory,
            contextualStrings: ["Talkless", "user_ID", "user_id", "\u{4E2D}\u{6587}\u{672F}\u{8BED}"]
        )
        _ = try await dictionarySession.finish(samples: all)
        let dictionaryContexts = await runtime.contexts
        precondition(dictionaryContexts == Array(repeating: "Talkless, user_ID, user_id, \u{4E2D}\u{6587}\u{672F}\u{8BED}", count: 2),
                     "Session must forward the same case-preserving dictionary to every decode window")
        print("PASS session dictionary context reaches all decode windows")

        await runtime.reset()
        let emptyDictionarySession = QwenTranscriptionSession(modelDirectory: directory)
        _ = try await emptyDictionarySession.finish(samples: Array(all.prefix(32000)))
        let emptyContexts = await runtime.contexts
        precondition(emptyContexts == [""], "Default dictionary must not add context")
        print("PASS empty dictionary sends no context")

        await runtime.reset()
        for start in stride(from: 0, to: 500000, by: 800) {
            state.enqueue(Array(all[start..<min(start + 800, 500000)]))
        }
        state.close(samples: all)
        let text = try await state.run(modelDirectory: directory, language: nil, context: "", onStatus: { _ in })
        let calls = await runtime.calls
        precondition(calls.count == 2)
        precondition(calls.flatMap { $0 } == all, "Nonoverlapping commits must cover every sample")
        precondition(text == "[1..480000] [480001..520000]", text)
        print("PASS full-window commit, backlog, and missing-tail recovery")

        await runtime.reset()
        let preview = QwenCaptureState()
        let task = Task { try await preview.run(modelDirectory: directory, language: nil, context: "", onStatus: { _ in }) }
        preview.enqueue(Array(all.prefix(32000)))
        try await Task.sleep(for: .milliseconds(100))
        preview.enqueue(Array(all[32000..<40000]))
        preview.close(samples: Array(all.prefix(40000)))
        let final = try await task.value
        let previews = await runtime.calls
        precondition(previews.map { $0.count } == [32000, 40000])
        precondition(final == "[1..40000]", final)
        print("PASS replaceable preview and final active-window decode")

        await runtime.reset()
        let cancelled = QwenCaptureState()
        cancelled.enqueue(Array(all.prefix(32000)))
        cancelled.cancel()
        do {
            _ = try await cancelled.run(modelDirectory: directory, language: nil, context: "", onStatus: { _ in })
            fatalError("Cancel must throw")
        } catch is CancellationError {}
        let afterCancel = await runtime.calls
        precondition(afterCancel.isEmpty)
        cancelled.reportError("stale error", to: { _ in fatalError("Cancelled session must not report errors") })
        print("PASS cancellation before decoding and suppression of stale errors")

        let overflow = QwenCaptureState()
        overflow.enqueue([Float](repeating: 1, count: 120 * 16000 + 1))
        do {
            _ = try await overflow.run(modelDirectory: directory, language: nil, context: "", onStatus: { _ in })
            fatalError("Overflow must fail, not return truncated text")
        } catch is TalklessError {}
        print("PASS bounded pending audio fails explicitly")

        let race = QwenFinishCompletion()
        let waiting = Task { try await race.value() }
        race.resolve(.success("first"))
        race.resolve(.success("second"))
        let answer = try await waiting.value
        precondition(answer == "first")
        let cancelledRace = QwenFinishCompletion()
        cancelledRace.resolve(.failure(CancellationError()))
        do { _ = try await cancelledRace.value(); fatalError("Must cancel") }
        catch is CancellationError {}
        print("PASS finish race resolves once, before or after registration")

        await runtime.reset()
        let cutState = QwenCaptureState()
        var withPause = [Float](repeating: 1, count: 500000)
        withPause.replaceSubrange(456000..<460000, with: repeatElement(Float(0), count: 4000))
        cutState.enqueue(withPause)
        cutState.close(samples: withPause)
        _ = try await cutState.run(modelDirectory: directory, language: nil, context: "", onStatus: { _ in })
        let cutCalls = await runtime.calls
        precondition(cutCalls.count == 2)
        precondition((456000..<460000).contains(cutCalls[0].count))
        precondition(cutCalls.flatMap { $0 } == withPause)
        print("PASS low-energy commit moves boundary but preserves all samples")

        // The latest safe pause can precede the final two seconds; hard-cutting instead
        // splits a word even when the captured window already contains a usable boundary.
        for pauseStart in [25.5, 27.6] {
            await runtime.reset()
            let earlierPauseState = QwenCaptureState()
            var speech = [Float](repeating: 1, count: 500000)
            let start = Int(pauseStart * 16000)
            let end = start + 3200
            speech.replaceSubrange(start..<end, with: repeatElement(Float(0), count: end - start))
            earlierPauseState.enqueue(speech)
            earlierPauseState.close(samples: speech)
            _ = try await earlierPauseState.run(modelDirectory: directory, language: nil, context: "", onStatus: { _ in })
            let decoded = await runtime.calls
            precondition(decoded.count == 2)
            precondition((start..<end).contains(decoded[0].count), "Must use a pause in the five-second lookback")
            precondition(decoded.flatMap { $0 } == speech)
        }
        print("PASS five-second lookback finds earlier pauses without losing audio")

        await runtime.reset()
        let latestPauseState = QwenCaptureState()
        var twoPauses = [Float](repeating: 1, count: 500000)
        for start in [26 * 16000, 28 * 16000] {
            twoPauses.replaceSubrange(start..<(start + 3200), with: repeatElement(Float(0), count: 3200))
        }
        latestPauseState.enqueue(twoPauses)
        latestPauseState.close(samples: twoPauses)
        _ = try await latestPauseState.run(modelDirectory: directory, language: nil, context: "", onStatus: { _ in })
        let latestCalls = await runtime.calls
        precondition(((28 * 16000)..<(28 * 16000 + 3200)).contains(latestCalls[0].count))
        precondition(latestCalls.flatMap { $0 } == twoPauses)
        print("PASS commit selects the latest usable pause, not the first")

        await runtime.reset()
        let weakSpeechState = QwenCaptureState()
        var weakSpeech = [Float](repeating: 1, count: 500000)
        weakSpeech.replaceSubrange(448000..<451200, with: repeatElement(Float(0), count: 3200))
        weakSpeech.replaceSubrange(472000..<475200, with: repeatElement(Float(0.2), count: 3200))
        weakSpeechState.enqueue(weakSpeech)
        weakSpeechState.close(samples: weakSpeech)
        _ = try await weakSpeechState.run(modelDirectory: directory, language: nil, context: "", onStatus: { _ in })
        let weakCalls = await runtime.calls
        precondition((448000..<451200).contains(weakCalls[0].count))
        precondition(weakCalls.flatMap { $0 } == weakSpeech)
        print("PASS word-internal weak audio does not replace a deeper pause boundary")
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("talkless-qwen-tests-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let swiftFile = directory.appendingPathComponent("StateTests.swift")
let binary = directory.appendingPathComponent("state-tests")
let parser = try String(contentsOf: root.appendingPathComponent("Sources/Talkless/QwenOutputParser.swift"), encoding: .utf8)
try (stub + "\n" + sessionProtocol + "\n" + parser + "\n"
    + section(from: "final class QwenTranscriptionSession:", to: "/// Sole MLX owner.")
    + section(from: "private final class QwenCaptureState:") + "\n" + tests)
    .write(to: swiftFile, atomically: true, encoding: .utf8)
func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
}
try run("/usr/bin/xcrun", ["swiftc", "-swift-version", "6", "-parse-as-library", swiftFile.path, "-o", binary.path])
try run(binary.path, [])
