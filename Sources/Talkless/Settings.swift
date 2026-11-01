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

    /// Held together with the dictation key, it edits the selected text instead of dictating:
    /// Control, or Option when Right Control already is the dictation key.
    var editModifierTitle: String { self == .rightControl ? L10n.tr("Option") : L10n.tr("Control") }

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

enum ASREngine: String, CaseIterable, Identifiable {
    case qwen, doubao
    var id: String { rawValue }
    var title: String {
        switch self {
        case .qwen: L10n.tr("On this Mac")
        case .doubao: L10n.tr("Doubao cloud")
        }
    }
    var detail: String {
        switch self {
        case .qwen: L10n.tr("Free and works offline. Audio never leaves your Mac.")
        case .doubao: L10n.tr("Text appears as you speak. Needs a Doubao account.")
        }
    }
    var symbol: String { self == .qwen ? "laptopcomputer" : "cloud" }
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
        didSet { defaults.setEncoded(hudAppearance, forKey: Self.hudAppearanceKey) }
    }

    static let defaultRecordingGestureMode: RecordingGestureMode = .hold
    @Published var recordingGestureMode: RecordingGestureMode {
        didSet { save(recordingGestureMode.rawValue, "recordingGestureMode") }
    }

    static let defaultTriggerKey: TriggerKey = .fn

    @Published var triggerKey: TriggerKey { didSet { save(triggerKey.rawValue, "triggerKey") } }

    var isTriggerKeyDefault: Bool { triggerKey == Self.defaultTriggerKey }
    static let defaultTranslationShortcut: TranslationShortcut = .default
    private static let translationShortcutKey = "translationShortcut.v1"
    @Published var translationShortcut: TranslationShortcut {
        didSet { defaults.setEncoded(translationShortcut, forKey: Self.translationShortcutKey) }
    }
    var isTranslationShortcutDefault: Bool { translationShortcut == Self.defaultTranslationShortcut }
    var areShortcutsDefault: Bool { isTriggerKeyDefault && isTranslationShortcutDefault }

    func resetTranslationShortcut() {
        if !isTranslationShortcutDefault { translationShortcut = Self.defaultTranslationShortcut }
    }

    /// Returns an error message for the recorder row; resetting the only recording key cannot conflict.
    func resetTriggerKey() -> String? {
        if !isTriggerKeyDefault { triggerKey = Self.defaultTriggerKey }
        return nil
    }

    func restoreShortcutDefaults() {
        _ = resetTriggerKey()
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
    /// Dedicated Speech API key; never shared with AI polishing or retired cloud providers.
    @Published var doubaoAPIKey: String { didSet { persistDoubaoCredential() } }
    @Published private(set) var doubaoCredentialError: String?
    @Published var doubaoResource: DoubaoResource {
        didSet { save(doubaoResource.rawValue, "doubaoResource") }
    }
    var doubaoConfig: DoubaoConfig { .init(apiKey: doubaoAPIKey, resource: doubaoResource) }
    var doubaoConfigured: Bool { doubaoConfig.isConfigured }
    @Published var onlineLocalFallback: Bool { didSet { save(onlineLocalFallback, "onlineLocalFallback") } }
    var needsLocalModel: Bool { asrEngine == .qwen || onlineLocalFallback }


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
        didSet { defaults.setEncoded(translationLanguages, forKey: Self.translationLanguagesKey) }
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
    /// Explicit "heard as" fixes for My terms, applied after recognition.
    @Published var dictionaryReplacements: [DictionaryReplacement] {
        didSet { defaults.setEncoded(dictionaryReplacements, forKey: Self.dictionaryReplacementsKey) }
    }
    private static let dictionaryReplacementsKey = "dictionaryReplacements.v1"
    /// Learn fixes from how dictations get corrected. Local only; on by default.
    @Published var dictionaryLearningEnabled: Bool { didSet { save(dictionaryLearningEnabled, "dictionaryLearningEnabled") } }
    @Published var learnedDictionary: LearnedDictionary {
        didSet { if learnedDictionary != oldValue { defaults.setEncoded(learnedDictionary, forKey: Self.learnedDictionaryKey) } }
    }
    private static let learnedDictionaryKey = "dictionaryLearning.v1"
    /// Spellings dismissed in the former Review list are never learned.
    private let dismissedReviewTerms: Set<String>
    @Published var customInstructions: String { didSet { save(customInstructions, "customInstructions") } }

    /// Tests supply an isolated defaults suite and in-memory credential store.
    init(defaults: UserDefaults = .standard, credentialStore: any CredentialStoring = CredentialStore()) {
        self.defaults = defaults
        self.credentialStore = credentialStore
        let d = defaults
        hudAppearance = d.decoded(HUDAppearance.self, forKey: Self.hudAppearanceKey) ?? HUDAppearance()
        let stored = d.decoded(StoredPolishSettings.self, forKey: Self.polishSettingsKey)
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
        // The per-dictation AI polishing shortcut was retired; drop its stored preference.
        d.removeObject(forKey: "alternateFinishKey")
        let storedTranslationShortcut = d.decoded(TranslationShortcut.self, forKey: Self.translationShortcutKey)
        translationShortcut = storedTranslationShortcut.flatMap { $0.validationError == nil ? $0 : nil }
            ?? Self.defaultTranslationShortcut
        audioInputDeviceUID = d.string(forKey: "audioInputDeviceUID")
        asrEngine = ASREngine(rawValue: d.string(forKey: "asrEngine") ?? "") ?? .qwen
        qwenModelDirectory = d.string(forKey: "qwenModelDirectory") ?? ""
        useCustomQwenDirectory = d.object(forKey: "useCustomQwenDirectory") as? Bool ?? false
        doubaoAPIKey = ""
        doubaoCredentialError = nil
        onlineLocalFallback = d.bool(forKey: "onlineLocalFallback")
        doubaoResource = DoubaoResource(rawValue: d.string(forKey: "doubaoResource") ?? "") ?? .duration
        polishEnabled = d.object(forKey: "polishEnabled") as? Bool ?? false
        outputLanguage = OutputLanguage(rawValue: d.string(forKey: "outputLanguage") ?? "") ?? .original
        voiceEditEnabled = d.object(forKey: "voiceEditEnabled") as? Bool ?? false
        appToneEnabled = d.object(forKey: "appToneEnabled") as? Bool ?? true
        let storedLanguages = d.decoded(TranslationLanguagePreferences.self, forKey: Self.translationLanguagesKey)
        var languages = storedLanguages
            ?? TranslationLanguagePreferences.migrated(legacyTarget: d.string(forKey: "translateTarget"))
        languages.normalizePreferredLanguages()
        translationLanguages = languages
        // Do not rewrite an unchanged preference on every launch (JSON key order is
        // unspecified). Persist migration once so the old text cannot reappear.
        if storedLanguages != languages { d.setEncoded(languages, forKey: Self.translationLanguagesKey) }
        dictionary = d.string(forKey: "dictionary") ?? ""
        dictionaryReplacements = d.decoded([DictionaryReplacement].self, forKey: Self.dictionaryReplacementsKey) ?? []
        dictionaryLearningEnabled = d.object(forKey: "dictionaryLearningEnabled") as? Bool ?? true
        learnedDictionary = d.decoded(LearnedDictionary.self, forKey: Self.learnedDictionaryKey) ?? LearnedDictionary()
        dismissedReviewTerms = d.decoded(Set<String>.self, forKey: "dictionaryReview.dismissed.v1") ?? []
        customInstructions = d.string(forKey: "customInstructions") ?? ""

        if let legacyKey, !legacyKey.isEmpty {
            let provider = PolishProvider.matchingLegacyURL(legacyURL ?? "https://api.openai.com/v1")
            legacyCredentialProvider = provider
            migrateLegacyCredential(legacyKey, for: provider)
        }
        // Retired choices fall back locally; upgrading never enables a new online provider.
        if d.string(forKey: "asrEngine") != asrEngine.rawValue { d.set(asrEngine.rawValue, forKey: "asrEngine") }

        doubaoAPIKey = loadDoubaoCredential()
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
        defaults.setEncoded(stored, forKey: Self.polishSettingsKey)
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

    /// Never reuse a former cloud-provider key for Doubao. The dedicated account is isolated.
    private func loadDoubaoCredential() -> String {
        do { return try credentialStore.doubaoCredential() ?? "" }
        catch { doubaoCredentialError = credentialErrorMessage(error, saving: false); return "" }
    }

    private func persistDoubaoCredential() {
        do {
            try credentialStore.setDoubaoCredential(doubaoAPIKey)
            doubaoCredentialError = nil
        } catch { doubaoCredentialError = credentialErrorMessage(error, saving: true) }
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

    /// Rules whose term is still in My terms; a term removed elsewhere stops its fixes too.
    var activeDictionaryReplacements: [DictionaryReplacement] {
        let terms = Set(dictionaryTerms)
        return dictionaryReplacements.filter { terms.contains($0.term) }
    }

    /// Hand-written fixes first, then learned ones that do not collide with them.
    var recognitionReplacements: [DictionaryReplacement] {
        let manual = activeDictionaryReplacements
        guard dictionaryLearningEnabled else { return manual }
        return manual + DictionaryLearning.replacements(learnedDictionary, manualTerms: dictionaryTerms, manualRules: manual)
    }

    /// Recognition hints and polish context: My terms plus learned terms.
    var recognitionTerms: [String] {
        let terms = dictionaryTerms
        guard dictionaryLearningEnabled else { return terms }
        let known = Set(terms.map(DictionaryLearning.key))
        return terms + DictionaryLearning.terms(learnedDictionary).filter { !known.contains(DictionaryLearning.key($0)) }
    }

    /// Feed one finished, same-language polished dictation into the learned dictionary.
    func learnFromDictation(raw: String, output: String, fired: Set<String>, at date: Date = Date()) {
        guard dictionaryLearningEnabled else { return }
        var state = DictionaryLearning.recordApplied(fired, at: date, in: learnedDictionary)
        if raw != output {
            state = DictionaryLearning.observe(raw: raw, output: output, at: date, in: state,
                                               manualTerms: dictionaryTerms, manualRules: activeDictionaryReplacements,
                                               dismissedTerms: dismissedReviewTerms)
        }
        learnedDictionary = DictionaryLearning.expire(state, now: date)
    }

    /// One-time catch-up from existing local dictations (newest first, as history stores them).
    func seedLearnedDictionary(from entries: [(raw: String, output: String, date: Date)], now: Date = Date()) {
        guard dictionaryLearningEnabled, !learnedDictionary.seeded else { return }
        var state = learnedDictionary
        for entry in entries.reversed() where entry.raw != entry.output {
            state = DictionaryLearning.observe(raw: entry.raw, output: entry.output, at: entry.date, in: state,
                                               manualTerms: dictionaryTerms, manualRules: activeDictionaryReplacements,
                                               dismissedTerms: dismissedReviewTerms)
        }
        state.seeded = true
        learnedDictionary = DictionaryLearning.expire(state, now: now)
    }

    func expireLearnedFixes(now: Date = Date()) {
        learnedDictionary = DictionaryLearning.expire(learnedDictionary, now: now)
    }

    /// Move a learned fix into My terms, where it never retires.
    func keepLearnedFix(_ fix: LearnedFix) {
        if let updated = DictionaryTerms.adding(fix.term, to: dictionary) { dictionary = updated }
        guard let term = dictionaryTerms.first(where: { DictionaryLearning.key($0) == DictionaryLearning.key(fix.term) }) else { return }
        if DictionaryReplacements.problem(heard: fix.heard, term: term, rules: activeDictionaryReplacements, terms: dictionaryTerms) == nil {
            dictionaryReplacements.append(DictionaryReplacement(heard: fix.heard, term: term))
        }
        learnedDictionary.fixes.removeAll { $0.id == fix.id }
    }

    /// Remove a learned fix and never learn the same pair again.
    func removeLearnedFix(_ fix: LearnedFix) {
        learnedDictionary.fixes.removeAll { $0.id == fix.id }
        learnedDictionary.blocked.insert(DictionaryLearning.pairKey(heard: fix.heard, term: fix.term))
    }

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
