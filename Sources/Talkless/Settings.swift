import Foundation
import Combine

/// Dictation trigger key. Hold to talk and release to finish; tap for hands-free mode, then tap again to finish.
enum TriggerKey: String, CaseIterable, Identifiable {
    case fn
    case rightOption
    case rightCommand
    case rightControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fn: return "Fn / 🌐"
        case .rightOption: return "Right Option ⌥"
        case .rightCommand: return "Right Command ⌘"
        case .rightControl: return "Right Control ⌃"
        }
    }

    /// The corresponding virtual key code (kVK_*).
    var keyCode: Int64 {
        switch self {
        case .fn: return 63
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        }
    }
}

enum ASREngine: String, CaseIterable, Identifiable {
    /// Local Qwen3-ASR, running on Apple Silicon through MLX.
    case qwen
    /// On-device SpeechAnalyzer on macOS 26+: free, offline, with live previews.
    case apple
    /// Any service compatible with OpenAI `/audio/transcriptions` (OpenAI, Groq, SiliconFlow, etc.).
    case openAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qwen: return "Qwen3-ASR (local, offline)"
        case .apple: return "Apple on-device recognition (offline)"
        case .openAICompatible: return "Cloud Whisper-compatible API"
        }
    }
}

/// Output language after dictation. `.original` preserves the spoken language.
enum OutputLanguage: String, CaseIterable, Identifiable {
    case original, chinese, english, japanese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return "Keep original language"
        case .chinese: return "Simplified Chinese"
        case .english: return "English"
        case .japanese: return "Japanese"
        }
    }

    /// The language name used in prompts.
    var promptName: String? {
        switch self {
        case .original: return nil
        case .chinese: return "Simplified Chinese"
        case .english: return "English"
        case .japanese: return "Japanese"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var triggerKey: TriggerKey { didSet { save(triggerKey.rawValue, "triggerKey") } }
    @Published var asrEngine: ASREngine { didSet { save(asrEngine.rawValue, "asrEngine") } }
    @Published var qwenModelDirectory: String { didSet { save(qwenModelDirectory, "qwenModelDirectory") } }

    /// Models are user-managed and are never downloaded or bundled by Talkless.
    static var defaultQwenModelDirectory: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Talkless/Models/Qwen3-ASR-1.7B-4bit", isDirectory: true)
        if FileManager.default.fileExists(atPath: support.appendingPathComponent("config.json").path) {
            return support.path
        }
        // Development-only fallback: available only while the original source checkout exists.
        // A distributed app on another machine falls back to Application Support instead.
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let development = project.appendingPathComponent("experiments/qwen-streaming/model", isDirectory: true)
        if FileManager.default.fileExists(atPath: development.appendingPathComponent("config.json").path) {
            return development.path
        }
        return support.path
    }
    /// The locale for on-device recognition, such as zh_CN or en_US.
    @Published var speechLocale: String { didSet { save(speechLocale, "speechLocale") } }

    @Published var asrBaseURL: String { didSet { save(asrBaseURL, "asrBaseURL") } }
    @Published var asrAPIKey: String { didSet { save(asrAPIKey, "asrAPIKey") } }
    @Published var asrModel: String { didSet { save(asrModel, "asrModel") } }

    @Published var polishEnabled: Bool { didSet { save(polishEnabled, "polishEnabled") } }
    @Published var llmBaseURL: String { didSet { save(llmBaseURL, "llmBaseURL") } }
    @Published var llmAPIKey: String { didSet { save(llmAPIKey, "llmAPIKey") } }
    @Published var llmModel: String { didSet { save(llmModel, "llmModel") } }

    @Published var outputLanguage: OutputLanguage { didSet { save(outputLanguage.rawValue, "outputLanguage") } }
    /// If text is selected when dictation starts, treat speech as an instruction to edit it.
    @Published var voiceEditEnabled: Bool { didSet { save(voiceEditEnabled, "voiceEditEnabled") } }
    @Published var appToneEnabled: Bool { didSet { save(appToneEnabled, "appToneEnabled") } }
    @Published var translateTarget: String { didSet { save(translateTarget, "translateTarget") } }
    /// One term per line: proper nouns, names, technical terms, etc.
    @Published var dictionary: String { didSet { save(dictionary, "dictionary") } }
    @Published var customInstructions: String { didSet { save(customInstructions, "customInstructions") } }
    @Published var playSounds: Bool { didSet { save(playSounds, "playSounds") } }

    private init() {
        let d = UserDefaults.standard
        triggerKey = TriggerKey(rawValue: d.string(forKey: "triggerKey") ?? "") ?? .fn
        asrEngine = ASREngine(rawValue: d.string(forKey: "asrEngine") ?? "") ?? .qwen
        qwenModelDirectory = d.string(forKey: "qwenModelDirectory") ?? Self.defaultQwenModelDirectory
        speechLocale = d.string(forKey: "speechLocale") ?? "zh_CN"
        asrBaseURL = d.string(forKey: "asrBaseURL") ?? "https://api.openai.com/v1"
        asrAPIKey = d.string(forKey: "asrAPIKey") ?? ""
        asrModel = d.string(forKey: "asrModel") ?? "gpt-4o-transcribe"
        polishEnabled = d.object(forKey: "polishEnabled") as? Bool ?? false
        llmBaseURL = d.string(forKey: "llmBaseURL") ?? "https://api.openai.com/v1"
        llmAPIKey = d.string(forKey: "llmAPIKey") ?? ""
        llmModel = d.string(forKey: "llmModel") ?? "gpt-4.1-mini"
        outputLanguage = OutputLanguage(rawValue: d.string(forKey: "outputLanguage") ?? "") ?? .original
        voiceEditEnabled = d.object(forKey: "voiceEditEnabled") as? Bool ?? false
        appToneEnabled = d.object(forKey: "appToneEnabled") as? Bool ?? true
        translateTarget = d.string(forKey: "translateTarget") ?? "Simplified Chinese"
        dictionary = d.string(forKey: "dictionary") ?? ""
        customInstructions = d.string(forKey: "customInstructions") ?? ""
        playSounds = d.object(forKey: "playSounds") as? Bool ?? true
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    var dictionaryTerms: [String] {
        dictionary
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var llmConfigured: Bool {
        !llmAPIKey.isEmpty && !llmBaseURL.isEmpty && !llmModel.isEmpty
    }

    var llmConfig: LLMClient.Config {
        LLMClient.Config(baseURL: llmBaseURL, apiKey: llmAPIKey, model: llmModel)
    }
}
