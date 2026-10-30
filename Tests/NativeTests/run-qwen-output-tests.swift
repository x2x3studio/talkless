#!/usr/bin/env swift
import Foundation

// Run: swift Tests/NativeTests/run-qwen-output-tests.swift
// Compiles production parsing/state code and the pinned vendor parser without MLX,
// weights, network, or a GPU. All non-English fixtures use Unicode escapes.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
func read(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}
func section(_ source: String, from start: String, to end: String? = nil) -> String {
    guard let range = source.range(of: start) else { fatalError("Missing production marker: \(start)") }
    let remainder = source[range.lowerBound...]
    guard let end else { return String(remainder) }
    guard let endRange = remainder.range(of: end) else { fatalError("Missing production marker: \(end)") }
    return String(remainder[..<endRange.lowerBound])
}
let parser = try read("Sources/Talkless/QwenOutputParser.swift")
let session = try read("Sources/Talkless/QwenTranscription.swift")
let vendor = try read(".build/checkouts/mlx-audio-swift/Sources/MLXAudioSTT/Models/Qwen3ASR/Qwen3ASR.swift")
let vendorParser = section(vendor, from: "    private func extractLanguage(", to: "    static func mergeLanguages(")
let aliases = section(vendor, from: "private let qwen3ASRLanguageAliases:", to: "func getFeatExtractOutputLengths(")
let stub = #"""
// Extracted parser/state fixtures use deterministic English, never application preferences.
private enum L10n {
    static func tr(_ key: String) -> String { key }
    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: key, locale: Locale(identifier: "en"), arguments: args)
    }
}
private enum TalklessError: Error { case message(String) }
private struct VendorConfig { let supportLanguages = ["Chinese", "English", "Japanese"] }
private struct PinnedVendorParser {
    let config = VendorConfig()
"""# + "\n" + vendorParser + "\n}\n" + aliases + #"""
private actor QwenModelRuntime {
    static let shared = QwenModelRuntime()
    var results: [QwenDecodedOutput] = []
    var calls = 0
    func prepare(modelDirectory: URL, onLoading: @escaping @MainActor @Sendable () -> Void = {}) async throws {}
    func decode(samples: [Float], modelDirectory: URL, language: String?, context: String) async throws -> QwenDecodedOutput {
        calls += 1
        precondition(!results.isEmpty, "Unexpected extra decode")
        return results.removeFirst()
    }
    func reset(_ values: [QwenDecodedOutput]) { results = values; calls = 0 }
}
"""#
let tests = #"""
@main struct Tests {
    @MainActor static func main() async throws {
        let chinese = "\u{4F60}\u{597D}\u{FF0C}\u{4E16}\u{754C}\u{3002}"
        let japanese = "\u{3053}\u{3093}\u{306B}\u{3061}\u{306F}"
        let arabic = "\u{645}\u{631}\u{62D}\u{628}\u{627}"
        let vendor = PinnedVendorParser()
        let leaked = vendor.parseGeneratedChunk("language Chinese", forcedLanguage: nil)
        precondition(leaked.text == "language Chinese" && leaked.language == "English")
        let stripped = vendor.parseGeneratedChunk("language English<asr_text>language English", forcedLanguage: nil)
        precondition(stripped.text == "language English" && stripped.language == "English")
        print("PASS pinned vendor reproduces header leak and indistinguishable parsed speech")

        let golden: [(String, String)] = [
            ("language Chinese<asr_text>" + chinese, chinese),
            ("language English<asr_text>Hello world.", "Hello world."),
            ("language Japanese<asr_text>" + japanese, japanese),
            ("language Arabic<asr_text>" + arabic, arabic),
            ("language Chinese<asr_text>" + chinese + " language English " + japanese, chinese + " language English " + japanese),
            ("language English<asr_text>language English", "language English"),
            ("language English<asr_text>language Chinese<asr_text>quoted", "language Chinese<asr_text>quoted"),
            ("language English<asr_text>Please change the language English setting.", "Please change the language English setting."),
            ("language None<asr_text>", ""),
            ("language Chinese<asr_text>", ""),
            ("  language Chinese<asr_text> " + chinese + " \n", chinese),
            ("<|im_start|>assistant\nlanguage Chinese<asr_text>" + chinese, chinese),
            ("Hello, language English is literal.", "Hello, language English is literal."),
            ("language learning is fun.", "language learning is fun."),
            ("language Englishness is a coined term.", "language Englishness is a coined term."),
            ("I said language Chinese<asr_text> literally.", "I said language Chinese<asr_text> literally."),
            ("", "")
        ]
        for (raw, expected) in golden {
            let result = QwenOutputParser.parse(rawText: raw, languageWasForced: false)
            precondition(result == .transcript(expected), "Golden mismatch: \(raw.debugDescription) -> \(result)")
            let final = try result.finalText()
            precondition(final == expected && result.previewText == expected)
        }
        print("PASS \(golden.count) boundary, multilingual, empty-audio, and literal-speech golden cases")

        for raw in ["language", "language ", "language Ch", "language Chinese", "language Chinese<asr_", "<|im_start|>assistant\n"] {
            let result = QwenOutputParser.parse(rawText: raw, languageWasForced: false)
            precondition(result == .incompleteHeader, raw)
            precondition(result.previewText.isEmpty)
            do { _ = try result.finalText(); fatalError("Incomplete final must fail") }
            catch QwenOutputError.invalidHeader {}
        }
        for raw in ["language Klingon<asr_text>hello", "language <asr_text>hello", "language Chinese broken", "language Chinese<asr_text", "language English and French<asr_text>hello", "<asr_text>hello", "<|im_start|>user\nhello"] {
            let result = QwenOutputParser.parse(rawText: raw, languageWasForced: false)
            // A proper prefix of the marker is incomplete rather than malformed.
            precondition(result == (raw == "language Chinese<asr_text" ? .incompleteHeader : .malformedHeader), raw)
            precondition(result.previewText.isEmpty)
            do { _ = try result.finalText(); fatalError("Malformed final must fail") }
            catch QwenOutputError.invalidHeader {}
        }
        for literal in ["language", "language English", "language Chinese", "language English<asr_text>quoted", "I study language."] {
            let result = QwenOutputParser.parse(rawText: literal, languageWasForced: true)
            precondition(result == .transcript(literal), literal)
        }
        let configured = QwenOutputParser.parse(rawText: "language Welsh<asr_text>Hello", languageWasForced: false, supportedLanguages: ["Welsh"])
        precondition(configured == .transcript("Hello"))
        print("PASS incomplete/malformed headers fail closed; explicit-language speech is untouched")

        let runtime = QwenModelRuntime.shared
        let directory = URL(fileURLWithPath: "/unused")
        let audio = [Float](repeating: 1, count: 32000)
        await runtime.reset([.incompleteHeader])
        let state = QwenCaptureState()
        var previews: [String] = []
        state.onPartial = { previews.append($0) }
        let task = Task { try await state.run(modelDirectory: directory, language: nil, context: "", onStatus: { _ in fatalError("Cached preparation must not overwrite HUD status") }) }
        state.enqueue(audio)
        try await Task.sleep(for: .milliseconds(100))
        precondition(previews == [""], "Control-only preview must never show metadata")
        state.close(samples: audio)
        do { _ = try await task.value; fatalError("Reusing incomplete preview for final must fail") }
        catch QwenOutputError.invalidHeader {}
        let calls = await runtime.calls
        precondition(calls == 1, "No redundant decode if final samples match preview")
        print("PASS short preview suppresses header and cached final fails without metadata paste")

        await runtime.reset([.incompleteHeader, .transcript(chinese)])
        let recovery = QwenCaptureState()
        var recoveredPreviews: [String] = []
        recovery.onPartial = { recoveredPreviews.append($0) }
        let recoveryTask = Task { try await recovery.run(modelDirectory: directory, language: nil, context: "", onStatus: { _ in }) }
        recovery.enqueue(audio)
        try await Task.sleep(for: .milliseconds(100))
        recovery.enqueue([1])
        recovery.close(samples: audio + [1])
        let recovered = try await recoveryTask.value
        precondition(recovered == chinese && recoveredPreviews == ["", chinese])
        print("PASS longer final replaces header-only preview with actual speech")

        await runtime.reset([.malformedHeader])
        let short = QwenCaptureState()
        short.enqueue([1])
        short.close(samples: [1])
        do { _ = try await short.run(modelDirectory: directory, language: nil, context: "", onStatus: { _ in }); fatalError("Short malformed final must fail") }
        catch QwenOutputError.invalidHeader {}
        print("PASS sub-two-second malformed final fails safely")

        await runtime.reset([.incompleteHeader])
        let committed = QwenCaptureState()
        let fullWindow = [Float](repeating: 1, count: 480000)
        committed.enqueue(fullWindow)
        committed.close(samples: fullWindow)
        do { _ = try await committed.run(modelDirectory: directory, language: nil, context: "", onStatus: { _ in }); fatalError("Commit must not silently discard incomplete speech") }
        catch QwenOutputError.invalidHeader {}
        print("PASS completed-window control header fails instead of silently dropping audio")
    }
}
"""#
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("talkless-qwen-output-tests-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let swiftFile = directory.appendingPathComponent("OutputTests.swift")
let binary = directory.appendingPathComponent("output-tests")
try (parser + "\n" + stub + "\n" + section(session, from: "private final class QwenCaptureState:") + "\n" + tests)
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
