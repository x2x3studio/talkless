import Foundation
import Combine

/// Dictation trigger key; its interaction is selected independently by RecordingGestureMode.
enum TriggerKey: String, CaseIterable, Identifiable {
    case fn
    case rightOption
    case rightCommand
    case rightControl

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fn: return L10n.tr("Fn / Globe")
        case .rightOption: return L10n.tr("Right Option")
        case .rightCommand: return L10n.tr("Right Command")
        case .rightControl: return L10n.tr("Right Control")
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

enum RecordingGestureMode: String, CaseIterable, Identifiable {
    case hold, toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hold: L10n.tr("Hold to dictate")
        case .toggle: L10n.tr("Tap to dictate")
        }
    }
}

enum AlternateFinishKey: String, CaseIterable, Identifiable {
    case automatic, disabled, fn, rightOption, rightCommand, rightControl

    var id: String { rawValue }

    var triggerKey: TriggerKey? {
        switch self {
        case .automatic, .disabled: nil
        case .fn: .fn
        case .rightOption: .rightOption
        case .rightCommand: .rightCommand
        case .rightControl: .rightControl
        }
    }

    var title: String {
        switch self {
        case .automatic: L10n.tr("Automatic")
        case .disabled: L10n.tr("Disabled")
        case .fn: TriggerKey.fn.title
        case .rightOption: TriggerKey.rightOption.title
        case .rightCommand: TriggerKey.rightCommand.title
        case .rightControl: TriggerKey.rightControl.title
        }
    }

    func resolved(for primary: TriggerKey) -> TriggerKey? {
        if self == .automatic { return primary == .rightOption ? .rightCommand : .rightOption }
        guard let triggerKey, triggerKey != primary else { return nil }
        return triggerKey
    }

    func title(for primary: TriggerKey) -> String {
        guard self == .automatic, let key = resolved(for: primary) else { return title }
        return L10n.format("%@ (%@)", title, key.title)
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
        case .qwen: return L10n.tr("Qwen3-ASR (local, offline)")
        case .apple: return L10n.tr("Apple on-device recognition (offline)")
        case .openAICompatible: return L10n.tr("Cloud Whisper-compatible API")
        }
    }
}

/// Output language after dictation. `.original` preserves the spoken language.
enum OutputLanguage: String, CaseIterable, Identifiable {
    case original, chinese, english, japanese

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return L10n.tr("Keep original language")
        case .chinese: return L10n.tr("Simplified Chinese")
        case .english: return L10n.tr("English")
        case .japanese: return L10n.tr("Japanese")
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

    private let defaults: UserDefaults
    private let credentialStore: any CredentialStoring
    private static let polishSettingsKey = "polishProviderSettings.v1"
    private var providerStates: [String: PolishProviderState]
    private var credentials: [PolishProvider: String] = [:]
    private var credentialErrors: [PolishProvider: String] = [:]
    private var legacyCredentialProvider: PolishProvider?
    private var isLoadingProvider = false

    private static let hudAppearanceKey = "hudAppearance.v1"
    @Published var hudAppearance: HUDAppearance {
        didSet {
            if let data = try? JSONEncoder().encode(hudAppearance) {
                save(data, Self.hudAppearanceKey)
            }
        }
    }

    static let defaultRecordingGestureMode: RecordingGestureMode = .hold
    @Published var recordingGestureMode: RecordingGestureMode {
        didSet { save(recordingGestureMode.rawValue, "recordingGestureMode") }
    }

    static let defaultTriggerKey: TriggerKey = .fn
    static let defaultAlternateFinishKey: AlternateFinishKey = .automatic

    @Published var triggerKey: TriggerKey { didSet { save(triggerKey.rawValue, "triggerKey") } }
    @Published var alternateFinishKey: AlternateFinishKey { didSet { save(alternateFinishKey.rawValue, "alternateFinishKey") } }

    var effectiveAlternateFinishKey: TriggerKey? { alternateFinishKey.resolved(for: triggerKey) }
    var isTriggerKeyDefault: Bool { triggerKey == Self.defaultTriggerKey }
    // Automatic is a preference, not merely today's resolved key.
    var isAlternateFinishKeyDefault: Bool { alternateFinishKey == Self.defaultAlternateFinishKey }
    static let defaultTranslationShortcut: TranslationShortcut = .default
    private static let translationShortcutKey = "translationShortcut.v1"
    @Published var translationShortcut: TranslationShortcut {
        didSet {
            if let data = try? JSONEncoder().encode(translationShortcut) {
                save(data, Self.translationShortcutKey)
            }
        }
    }
    var isTranslationShortcutDefault: Bool { translationShortcut == Self.defaultTranslationShortcut }
    var areRecordingShortcutsDefault: Bool { isTriggerKeyDefault && isAlternateFinishKeyDefault }
    var areShortcutsDefault: Bool { areRecordingShortcutsDefault && isTranslationShortcutDefault }

    func resetTranslationShortcut() {
        if !isTranslationShortcutDefault { translationShortcut = Self.defaultTranslationShortcut }
    }
    var defaultAlternateFinishKeyTitle: String { Self.defaultAlternateFinishKey.title(for: triggerKey) }

    /// A single-row reset must not overwrite or disable the other custom binding.
    func resetTriggerKey() -> String? {
        guard !isTriggerKeyDefault else { return nil }
        guard alternateFinishKey.triggerKey != Self.defaultTriggerKey else {
            return L10n.format("%@ is already the AI polishing shortcut. Change it first, or use Reset recording shortcuts to reset both keys.", Self.defaultTriggerKey.title)
        }
        triggerKey = Self.defaultTriggerKey
        return nil
    }

    func resetAlternateFinishKey() -> String? {
        if !isAlternateFinishKeyDefault { alternateFinishKey = Self.defaultAlternateFinishKey }
        return nil
    }

    func restoreRecordingShortcutDefaults() {
        // Restore Automatic first so an explicit Fn alternate cannot briefly collide.
        _ = resetAlternateFinishKey()
        _ = resetTriggerKey()
    }

    func restoreShortcutDefaults() {
        restoreRecordingShortcutDefaults()
        resetTranslationShortcut()
    }

    /// nil follows System default; explicit UIDs remain selected while disconnected.
    @Published var audioInputDeviceUID: String? {
        didSet { defaults.set(audioInputDeviceUID, forKey: "audioInputDeviceUID") }
    }

    @Published var asrEngine: ASREngine { didSet { save(asrEngine.rawValue, "asrEngine") } }
    @Published var qwenModelDirectory: String { didSet { save(qwenModelDirectory, "qwenModelDirectory") } }

    @Published var useCustomQwenDirectory: Bool { didSet { save(useCustomQwenDirectory, "useCustomQwenDirectory") } }

    static var defaultQwenModelDirectory: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Talkless/Models/Qwen3-ASR-0.6B-4bit", isDirectory: true).path
    }

    func resolvedQwenModelDirectory() throws -> URL {
        if useCustomQwenDirectory {
            let path = (qwenModelDirectory as NSString).expandingTildeInPath
            guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TalklessError.message(L10n.tr("Choose a local model folder in Speech recognition settings."))
            }
            return URL(fileURLWithPath: path)
        }
        let manager = ModelManager.shared
        guard !manager.isChecking else {
            throw TalklessError.message(L10n.tr("Checking downloaded model files. Try again in a moment."))
        }
        guard let directory = manager.installedDirectory(manager.activeModelID) else {
            let name = ModelCatalog.model(id: manager.activeModelID)?.name ?? L10n.tr("the selected model")
            throw TalklessError.message(L10n.format("Download %@ in Speech recognition settings before starting dictation.", name))
        }
        return directory
    }
    /// The locale for on-device recognition, such as zh_CN or en_US.
    @Published var speechLocale: String { didSet { save(speechLocale, "speechLocale") } }

    @Published var asrBaseURL: String { didSet { save(asrBaseURL, "asrBaseURL") } }
    @Published var asrAPIKey: String { didSet { save(asrAPIKey, "asrAPIKey") } }
    @Published var asrModel: String { didSet { save(asrModel, "asrModel") } }

    @Published var polishEnabled: Bool { didSet { save(polishEnabled, "polishEnabled") } }
    @Published private(set) var selectedPolishProvider: PolishProvider
    // These published compatibility bindings always describe the selected provider.
    @Published var llmBaseURL: String { didSet { persistCurrentProvider() } }
    @Published var llmAPIKey: String { didSet { persistCurrentCredential() } }
    @Published var llmModel: String { didSet { persistCurrentProvider() } }
    @Published var llmProtocol: LLMProtocol { didSet { persistCurrentProvider() } }
    @Published var llmAuthMode: LLMAuthMode { didSet { persistCurrentProvider() } }
    @Published private(set) var llmCredentialSaveError: String?

    @Published var outputLanguage: OutputLanguage { didSet { save(outputLanguage.rawValue, "outputLanguage") } }
    /// If text is selected when dictation starts, treat speech as an instruction to edit it.
    @Published var voiceEditEnabled: Bool { didSet { save(voiceEditEnabled, "voiceEditEnabled") } }
    @Published var appToneEnabled: Bool { didSet { save(appToneEnabled, "appToneEnabled") } }
    private static let translationLanguagesKey = "translationLanguages.v1"
    @Published var translationLanguages: TranslationLanguagePreferences {
        didSet {
            if let data = try? JSONEncoder().encode(translationLanguages) {
                save(data, Self.translationLanguagesKey)
            }
        }
    }
    /// Compatibility for integrations using the former free-text target. New UI and
    /// translation requests use translationLanguages and resolve Auto against the text.
    var translateTarget: String {
        get {
            if let name = translationLanguages.target.promptName { return name }
            return TranslationLanguages.resolvedPrimary(preferences: translationLanguages).englishName
        }
        set { translationLanguages.target = TranslationLanguages.selection(legacyValue: newValue) }
    }
    /// One term per line: proper nouns, names, technical terms, etc.
    @Published var dictionary: String { didSet { save(dictionary, "dictionary") } }
    /// Local suggestion mining is opt-in; it never sends history to a service.
    @Published var dictionaryReviewEnabled: Bool { didSet { save(dictionaryReviewEnabled, "dictionaryReviewEnabled") } }
    @Published var customInstructions: String { didSet { save(customInstructions, "customInstructions") } }

    /// Tests supply an isolated defaults suite and in-memory credential store.
    init(defaults: UserDefaults = .standard, credentialStore: any CredentialStoring = CredentialStore()) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        let d = defaults
        hudAppearance = d.data(forKey: Self.hudAppearanceKey)
            .flatMap { try? JSONDecoder().decode(HUDAppearance.self, from: $0) } ?? HUDAppearance()
        let stored = d.data(forKey: Self.polishSettingsKey)
            .flatMap { try? JSONDecoder().decode(StoredPolishSettings.self, from: $0) }
        var states = stored?.providers ?? [:]
        var selected = stored?.selectedProvider ?? .deepSeek
        // Reading only the old polish fields lets an untouched installation use the
        // new recommended provider rather than the old implicit OpenAI defaults.
        let legacyURL = d.string(forKey: "llmBaseURL")
        let legacyModel = d.string(forKey: "llmModel")
        let legacyKey = d.string(forKey: "llmAPIKey")
        if stored == nil, legacyURL != nil || legacyModel != nil || !(legacyKey ?? "").isEmpty {
            let url = legacyURL ?? "https://api.openai.com/v1"
            selected = PolishProvider.matchingLegacyURL(url)
            var state = PolishProviderState(provider: selected)
            state.baseURL = url
            // This is the old implicit default, preserved only for an existing setup.
            state.model = legacyModel ?? "gpt-4.1-mini"
            if selected == .openAI { state.apiProtocol = .chatCompletions }
            states[selected.rawValue] = state
        }
        let state = states[selected.rawValue] ?? PolishProviderState(provider: selected)
        states[selected.rawValue] = state
        providerStates = states
        selectedPolishProvider = selected
        llmBaseURL = state.baseURL
        llmModel = state.model
        llmProtocol = state.apiProtocol
        llmAuthMode = state.authMode
        llmAPIKey = ""
        llmCredentialSaveError = nil
        let storedRecordingMode = RecordingGestureMode(rawValue: d.string(forKey: "recordingGestureMode") ?? "")
        recordingGestureMode = storedRecordingMode ?? Self.defaultRecordingGestureMode
        // Retired Automatic and malformed values migrate to conventional push-to-talk.
        if storedRecordingMode == nil, d.object(forKey: "recordingGestureMode") != nil {
            d.set(Self.defaultRecordingGestureMode.rawValue, forKey: "recordingGestureMode")
        }
        triggerKey = TriggerKey(rawValue: d.string(forKey: "triggerKey") ?? "") ?? Self.defaultTriggerKey
        alternateFinishKey = AlternateFinishKey(rawValue: d.string(forKey: "alternateFinishKey") ?? "") ?? Self.defaultAlternateFinishKey
        let storedTranslationShortcut = d.data(forKey: Self.translationShortcutKey)
            .flatMap { try? JSONDecoder().decode(TranslationShortcut.self, from: $0) }
        translationShortcut = storedTranslationShortcut.flatMap { $0.validationError == nil ? $0 : nil }
            ?? Self.defaultTranslationShortcut
        audioInputDeviceUID = d.string(forKey: "audioInputDeviceUID")
        asrEngine = ASREngine(rawValue: d.string(forKey: "asrEngine") ?? "") ?? .qwen
        qwenModelDirectory = d.string(forKey: "qwenModelDirectory") ?? ""
        useCustomQwenDirectory = d.object(forKey: "useCustomQwenDirectory") as? Bool ?? false
        speechLocale = d.string(forKey: "speechLocale") ?? "zh_CN"
        asrBaseURL = d.string(forKey: "asrBaseURL") ?? "https://api.openai.com/v1"
        asrAPIKey = d.string(forKey: "asrAPIKey") ?? ""
        asrModel = d.string(forKey: "asrModel") ?? "gpt-4o-transcribe"
        polishEnabled = d.object(forKey: "polishEnabled") as? Bool ?? false
        outputLanguage = OutputLanguage(rawValue: d.string(forKey: "outputLanguage") ?? "") ?? .original
        voiceEditEnabled = d.object(forKey: "voiceEditEnabled") as? Bool ?? false
        appToneEnabled = d.object(forKey: "appToneEnabled") as? Bool ?? true
        let storedLanguages = d.data(forKey: Self.translationLanguagesKey)
            .flatMap { try? JSONDecoder().decode(TranslationLanguagePreferences.self, from: $0) }
        var languages = storedLanguages
            ?? TranslationLanguagePreferences.migrated(legacyTarget: d.string(forKey: "translateTarget"))
        languages.normalizePreferredLanguages()
        translationLanguages = languages
        // Do not rewrite an unchanged preference on every launch (JSON key order is
        // unspecified). Persist migration once so the old text cannot reappear.
        if storedLanguages != languages, let data = try? JSONEncoder().encode(languages) {
            d.set(data, forKey: Self.translationLanguagesKey)
        }
        dictionary = d.string(forKey: "dictionary") ?? ""
        dictionaryReviewEnabled = d.object(forKey: "dictionaryReviewEnabled") as? Bool ?? false
        customInstructions = d.string(forKey: "customInstructions") ?? ""

        if let legacyKey, !legacyKey.isEmpty {
            let provider = PolishProvider.matchingLegacyURL(legacyURL ?? "https://api.openai.com/v1")
            legacyCredentialProvider = provider
            migrateLegacyCredential(legacyKey, for: provider)
        }
        isLoadingProvider = true
        llmAPIKey = loadCredential(for: selected)
        llmCredentialSaveError = credentialErrors[selected]
        isLoadingProvider = false
        persistCurrentProvider()
    }

    func selectPolishProvider(_ provider: PolishProvider) {
        guard provider != selectedPolishProvider else { return }
        let state = providerStates[provider.rawValue] ?? PolishProviderState(provider: provider)
        isLoadingProvider = true
        selectedPolishProvider = provider
        llmBaseURL = state.baseURL
        llmModel = state.model
        llmProtocol = state.apiProtocol
        llmAuthMode = state.authMode
        llmAPIKey = loadCredential(for: provider)
        llmCredentialSaveError = credentialErrors[provider]
        isLoadingProvider = false
        persistCurrentProvider()
    }

    private func persistCurrentProvider() {
        guard !isLoadingProvider else { return }
        var state = PolishProviderState(provider: selectedPolishProvider)
        state.baseURL = llmBaseURL
        state.model = llmModel
        state.apiProtocol = llmProtocol
        state.authMode = llmAuthMode
        providerStates[selectedPolishProvider.rawValue] = state
        let stored = StoredPolishSettings(selectedProvider: selectedPolishProvider, providers: providerStates)
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Self.polishSettingsKey)
        }
    }

    private func loadCredential(for provider: PolishProvider) -> String {
        if let cached = credentials[provider] { return cached }
        do {
            let value = try credentialStore.credential(for: provider) ?? ""
            credentials[provider] = value
            credentialErrors[provider] = nil
            return value
        } catch {
            credentialErrors[provider] = credentialErrorMessage(error, saving: false)
            return ""
        }
    }

    private func persistCurrentCredential() {
        guard !isLoadingProvider else { return }
        let provider = selectedPolishProvider
        // A failed save remains usable in this session and survives provider switching.
        credentials[provider] = llmAPIKey
        do {
            try credentialStore.setCredential(llmAPIKey, for: provider)
            credentialErrors[provider] = nil
            if legacyCredentialProvider == provider {
                defaults.removeObject(forKey: "llmAPIKey")
                legacyCredentialProvider = nil
            }
        } catch {
            credentialErrors[provider] = credentialErrorMessage(error, saving: true)
        }
        llmCredentialSaveError = credentialErrors[provider]
    }

    private func migrateLegacyCredential(_ legacyKey: String, for provider: PolishProvider) {
        do {
            // Do not overwrite a newer Keychain value if migration previously completed
            // its write but the application exited before deleting the old default.
            if let existing = try credentialStore.credential(for: provider), !existing.isEmpty {
                credentials[provider] = existing
            } else {
                try credentialStore.setCredential(legacyKey, for: provider)
                credentials[provider] = legacyKey
            }
            defaults.removeObject(forKey: "llmAPIKey")
            legacyCredentialProvider = nil
        } catch {
            // Never delete or rewrite the old plaintext key until Keychain succeeds.
            credentials[provider] = legacyKey
            credentialErrors[provider] = credentialErrorMessage(error, saving: true)
        }
    }

    private func credentialErrorMessage(_ error: Error, saving: Bool) -> String {
        let detail = (error as? CredentialStoreError)?.errorDescription ?? L10n.tr("Check Keychain access for Talkless.")
        return saving
            ? L10n.format("The API key could not be saved to Keychain. It is available for this session only; any previous saved key is unchanged. %@", detail)
            : L10n.format("The API key could not be read from Keychain. The saved key has not been changed. %@", detail)
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    var dictionaryTerms: [String] { DictionaryTerms.terms(in: dictionary) }

    var llmConfigured: Bool {
        // Validation builds a request locally; it never fetches models or sends data.
        // This also permits keyless localhost services without accepting keyless cloud URLs.
        (try? LLMClient.makeRequest(system: "", user: "", config: llmConfig)) != nil
    }

    /// Automatic policy, not a saved preference: request thinking off only when verified.
    var llmThinkingMode: LLMThinkingMode {
        LLMClient.supportsDisablingThinking(config: baseLLMConfig) ? .disabled : .modelDefault
    }

    private var baseLLMConfig: LLMClient.Config {
        LLMClient.Config(baseURL: llmBaseURL, apiKey: llmAPIKey, model: llmModel,
                         apiProtocol: llmProtocol, authMode: llmAuthMode,
                         maxOutputTokens: 4096, thinking: .modelDefault)
    }

    var llmConfig: LLMClient.Config {
        var config = baseLLMConfig
        config.thinking = LLMClient.supportsDisablingThinking(config: config) ? .disabled : .modelDefault
        return config
    }
}
