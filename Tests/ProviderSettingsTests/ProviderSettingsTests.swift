import Foundation
import Combine

// Settings' local-model dependencies are irrelevant to these isolated provider tests.
enum TalklessError: Error { case message(String) }
@MainActor
final class ModelManager {
    static let shared = ModelManager()
    let isChecking = false
    let activeModelID = "test-model"
    func installedDirectory(_ id: String) -> URL? { nil }
}
enum ModelCatalog {
    struct Model { let name: String }
    static func model(id: String) -> Model? { nil }
}

/// Every method used by AppSettings is in-memory. No real defaults domains are read
/// or written; none of the synthetic test credentials ever reaches Keychain.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    var values: [String: Any] = [:]
    init() { super.init(suiteName: "talkless-isolated-tests-\(UUID().uuidString)")! }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

@MainActor
final class MemoryCredentials: CredentialStoring {
    enum Failure: Error { case unavailable }
    var values: [PolishProvider: String] = [:]
    var failReads = false
    var failWrites = false
    func credential(for provider: PolishProvider) throws -> String? {
        if failReads { throw Failure.unavailable }
        return values[provider]
    }
    func setCredential(_ value: String, for provider: PolishProvider) throws {
        if failWrites { throw Failure.unavailable }
        values[provider] = value.isEmpty ? nil : value
    }
}

@main
struct ProviderSettingsTests {
    @MainActor
    static func main() throws {
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            assertions += 1
            guard condition() else { fatalError("FAIL: \(description)") }
        }
        func settings(_ defaults: MemoryDefaults = MemoryDefaults(),
                      _ store: MemoryCredentials = MemoryCredentials()) -> AppSettings {
            AppSettings(defaults: defaults, credentialStore: store)
        }
        assertions += try testHUDAppearance()
        assertions += testAlternateFinishKey()
        assertions += testShortcutDefaults()
        let persistenceKey = "polishProviderSettings.v1"

        // Recording interaction is independent of key bindings and defaults to the legacy dual gesture.
        let gestureDefaults = MemoryDefaults()
        let gestures = settings(gestureDefaults)
        check(gestures.recordingGestureMode == .automatic, "fresh recording mode preserves Automatic")
        check(AppSettings.defaultRecordingGestureMode == .automatic, "recording reset default is Automatic")
        check(RecordingGestureMode.allCases == [.automatic, .hold, .toggle], "all recording interactions are selectable")
        for mode in RecordingGestureMode.allCases {
            check(mode.id == mode.rawValue && !mode.title.isEmpty, "recording interaction has a stable picker identity and title")
            gestures.recordingGestureMode = mode
            check(gestureDefaults.string(forKey: "recordingGestureMode") == mode.rawValue, "recording mode persists its raw value")
            check(settings(gestureDefaults).recordingGestureMode == mode, "recording mode survives relaunch")
        }
        gestureDefaults.values["recordingGestureMode"] = "unknown-mode"
        check(settings(gestureDefaults).recordingGestureMode == .automatic, "unknown recording mode safely falls back")
        gestureDefaults.values["recordingGestureMode"] = 123
        check(settings(gestureDefaults).recordingGestureMode == .automatic, "malformed recording mode safely falls back")
        gestureDefaults.values = ["triggerKey": "rightControl", "alternateFinishKey": "rightOption"]
        let existingGestures = settings(gestureDefaults)
        check(existingGestures.recordingGestureMode == .automatic, "existing installations retain dual gesture")
        existingGestures.recordingGestureMode = .hold
        check(existingGestures.triggerKey == .rightControl && existingGestures.alternateFinishKey == .rightOption,
              "changing interaction leaves custom key bindings untouched")
        existingGestures.recordingGestureMode = AppSettings.defaultRecordingGestureMode
        check(settings(gestureDefaults).recordingGestureMode == .automatic, "reset recording mode persists Automatic")

        let audioDefaults = MemoryDefaults()
        let audioSettings = settings(audioDefaults)
        check(audioSettings.audioInputDeviceUID == nil, "fresh audio input follows the system default")
        audioSettings.audioInputDeviceUID = "synthetic-input-uid"
        check(audioDefaults.string(forKey: "audioInputDeviceUID") == "synthetic-input-uid", "audio input UID is persisted")
        check(settings(audioDefaults).audioInputDeviceUID == "synthetic-input-uid", "audio input selection survives relaunch")
        audioSettings.audioInputDeviceUID = nil
        check(audioDefaults.object(forKey: "audioInputDeviceUID") == nil, "resetting audio input removes the saved UID")
        check(settings(audioDefaults).audioInputDeviceUID == nil, "reset audio input follows system default after relaunch")

        // Dictionary normalization is stable and case-sensitive, without rewriting the editor.
        let dictionaryDefaults = MemoryDefaults()
        let dictionarySettings = settings(dictionaryDefaults)
        check(dictionarySettings.dictionaryTerms.isEmpty, "fresh dictionary has no terms")
        dictionarySettings.dictionary = " \t\n\r\n\u{2028}\u{3000} "
        check(dictionarySettings.dictionaryTerms.isEmpty, "blank lines and whitespace have no terms")
        let rawDictionary = "  Talkless \r\n\tOpenAI\t\nTalkless\n \nopenAI\r\u{7528}\u{6237}ID\u{2028}\u{7528}\u{6237}ID\nMy  Project\n user_ID \nuser_id\n\u{3000}\u{4E2D}\u{6587}\u{672F}\u{8BED}\u{3000}"
        let expectedTerms = ["Talkless", "OpenAI", "openAI", "\u{7528}\u{6237}ID", "My  Project", "user_ID", "user_id", "\u{4E2D}\u{6587}\u{672F}\u{8BED}"]
        dictionarySettings.dictionary = rawDictionary
        check(dictionarySettings.dictionaryTerms == expectedTerms,
              "dictionary trims, removes exact duplicates, and preserves first order, case, and inner spacing")
        check(dictionarySettings.dictionary == rawDictionary, "normalization leaves editor text unchanged")
        check(dictionaryDefaults.string(forKey: "dictionary") == rawDictionary, "saved dictionary retains editor text")
        check(settings(dictionaryDefaults).dictionaryTerms == expectedTerms, "normalized dictionary survives relaunch")
        dictionarySettings.dictionary = "replacement\nreplacement"
        check(dictionarySettings.dictionaryTerms == ["replacement"], "dictionary terms reflect edits immediately")
        dictionarySettings.dictionary = ""
        check(dictionarySettings.dictionaryTerms.isEmpty, "clearing dictionary removes all hints")

        // Fresh state never guesses or silently selects a remotely available model.
        let freshDefaults = MemoryDefaults()
        let freshStore = MemoryCredentials()
        let fresh = settings(freshDefaults, freshStore)
        check(fresh.selectedPolishProvider == .deepSeek, "fresh provider is DeepSeek")
        check(!fresh.llmConfigured, "fresh installation is not configured")
        for provider in PolishProvider.allCases {
            fresh.selectPolishProvider(provider)
            check(fresh.llmModel.isEmpty, "fresh model selection is empty")
            check(fresh.llmAPIKey.isEmpty, "fresh providers have no key")
            check(fresh.llmBaseURL == provider.defaultURL, "fresh endpoint matches provider")
            check(fresh.llmProtocol == provider.defaultProtocol, "fresh protocol matches provider")
        }

        // Endpoint, model, protocol, auth, and key are independent across switches/relaunch.
        let d = MemoryDefaults()
        let keychain = MemoryCredentials()
        let app = settings(d, keychain)
        var changes = 0
        let subscription = app.objectWillChange.sink { changes += 1 }
        app.llmBaseURL = "https://api.deepseek.com/v1"
        app.llmModel = "synthetic-deepseek-model"
        app.llmAPIKey = "synthetic-deepseek-key"
        app.llmAuthMode = .bearer
        app.selectPolishProvider(.openAI)
        check(app.llmAPIKey.isEmpty, "switch never carries another provider's key")
        app.llmBaseURL = "https://api.openai.com/v1"
        app.llmModel = "synthetic-openai-model"
        app.llmAPIKey = "synthetic-openai-key"
        app.llmProtocol = .chatCompletions
        app.llmAuthMode = .apiKey
        app.selectPolishProvider(.deepSeek)
        check(app.llmBaseURL == "https://api.deepseek.com/v1", "endpoint survives switching")
        check(app.llmModel == "synthetic-deepseek-model", "model survives switching")
        check(app.llmAPIKey == "synthetic-deepseek-key", "key survives switching")
        check(app.llmAuthMode == .bearer, "auth survives switching")
        check(app.llmProtocol == .chatCompletions, "protocol survives switching")
        check(changes > 0, "settings emits published changes")
        withExtendedLifetime(subscription) {}
        let restored = settings(d, keychain)
        check(restored.selectedPolishProvider == .deepSeek, "selection survives relaunch")
        restored.selectPolishProvider(.openAI)
        check(restored.llmModel == "synthetic-openai-model", "other model survives relaunch")
        check(restored.llmAPIKey == "synthetic-openai-key", "other key survives relaunch")
        check(restored.llmAuthMode == .apiKey, "other auth survives relaunch")
        check(restored.llmProtocol == .chatCompletions, "other protocol survives relaunch")
        let encoded = String(data: d.data(forKey: persistenceKey)!, encoding: .utf8)!
        check(!encoded.contains("synthetic-deepseek-key"), "JSON excludes DeepSeek secret")
        check(!encoded.contains("synthetic-openai-key"), "JSON excludes OpenAI secret")
        check(d.string(forKey: "llmAPIKey") == nil, "new key never enters plaintext defaults")

        // Existing setup migrates without changing its URL, model, or Chat protocol.
        let legacy = MemoryDefaults()
        legacy.values = ["llmBaseURL": "https://api.openai.com/v1",
                         "llmModel": "previous-model", "llmAPIKey": "synthetic-legacy-key"]
        let migratedStore = MemoryCredentials()
        let migrated = settings(legacy, migratedStore)
        check(migrated.selectedPolishProvider == .openAI, "legacy OpenAI host classified")
        check(migrated.llmProtocol == .chatCompletions, "legacy OpenAI retains Chat")
        check(migrated.llmModel == "previous-model", "legacy model preserved")
        check(migrated.llmAPIKey == "synthetic-legacy-key", "legacy key available")
        check(migratedStore.values[.openAI] == "synthetic-legacy-key", "legacy key saved to mock Keychain")
        check(legacy.string(forKey: "llmAPIKey") == nil, "legacy plaintext removed after success")

        // A failed migration retains the old credential, and switching retains failed edits.
        let failingDefaults = MemoryDefaults()
        failingDefaults.values = ["llmBaseURL": "https://api.deepseek.com",
                                  "llmModel": "previous-model", "llmAPIKey": "synthetic-old-key"]
        let failingStore = MemoryCredentials()
        failingStore.failWrites = true
        let failing = settings(failingDefaults, failingStore)
        check(failingDefaults.string(forKey: "llmAPIKey") == "synthetic-old-key", "failed migration retains plaintext")
        check(failing.llmAPIKey == "synthetic-old-key", "failed migration retains usable in-memory key")
        check(failing.llmCredentialSaveError != nil, "failed migration is visible")
        failing.llmAPIKey = "synthetic-unsaved-key"
        failing.selectPolishProvider(.gemini)
        check(failing.llmAPIKey.isEmpty, "failed key never leaks to another provider")
        failing.selectPolishProvider(.deepSeek)
        check(failing.llmAPIKey == "synthetic-unsaved-key", "unsaved key survives switch back")
        check(failing.llmCredentialSaveError != nil, "save error survives switch back")
        check(failingDefaults.string(forKey: "llmAPIKey") == "synthetic-old-key", "failed new edit never overwrites old plaintext")
        failingStore.failWrites = false
        failing.llmAPIKey = "synthetic-retried-key"
        check(failingDefaults.string(forKey: "llmAPIKey") == nil, "successful retry removes legacy plaintext")
        check(failing.llmCredentialSaveError == nil, "successful retry clears error")
        failing.llmAPIKey = ""
        check(failingStore.values[.deepSeek] == nil, "clearing a key deletes saved credential")

        let unreadableStore = MemoryCredentials()
        unreadableStore.values[.deepSeek] = "synthetic-unreadable-key"
        unreadableStore.failReads = true
        let unreadable = settings(MemoryDefaults(), unreadableStore)
        check(unreadable.llmCredentialSaveError != nil, "read failure visible")
        check(unreadableStore.values[.deepSeek] == "synthetic-unreadable-key", "read failure never deletes key")

        // Legacy Google OpenAI-compatible URLs remain Custom + Chat, never native Gemini.
        let proxyDefaults = MemoryDefaults()
        proxyDefaults.values = ["llmBaseURL": "https://generativelanguage.googleapis.com/v1beta/openai",
                                "llmModel": "existing-model", "llmAPIKey": "synthetic-google-key"]
        let proxy = settings(proxyDefaults, MemoryCredentials())
        check(proxy.selectedPolishProvider == .custom, "Google compatibility endpoint stays custom")
        check(proxy.llmProtocol == .chatCompletions, "Google compatibility endpoint retains Chat")
        check(proxy.llmBaseURL == "https://generativelanguage.googleapis.com/v1beta/openai", "Google compatibility URL preserved")
        check(PolishProvider.matchingLegacyURL("https://api.openai.com.evil.invalid/v1") == .custom,
              "look-alike hostname is not a known provider")
        check(PolishProvider.matchingLegacyURL("https://api.anthropic.com/v1") == .anthropic,
              "Anthropic native host classified")
        check(PolishProvider.matchingLegacyURL("https://generativelanguage.googleapis.com/v1beta") == .gemini,
              "Gemini native host classified")

        // Corrupt nonsecret metadata does not remove any Keychain entry.
        let corruptDefaults = MemoryDefaults()
        corruptDefaults.values[persistenceKey] = Data("not valid JSON".utf8)
        let corruptStore = MemoryCredentials()
        corruptStore.values[.openAI] = "synthetic-existing-key"
        let corrupt = settings(corruptDefaults, corruptStore)
        check(corruptStore.values[.openAI] == "synthetic-existing-key", "corrupt JSON does not erase key")
        corrupt.selectPolishProvider(.openAI)
        check(corrupt.llmAPIKey == "synthetic-existing-key", "key retrievable after corrupt JSON fallback")
        check(corrupt.llmModel.isEmpty, "corrupt JSON does not guess model")

        check(PolishProvider.openAI.protocolOptions == [.responses, .chatCompletions], "OpenAI supports only advertised protocols")
        check(PolishProvider.deepSeek.protocolOptions == [.chatCompletions], "DeepSeek protocol fixed")
        check(PolishProvider.gemini.protocolOptions == [.geminiGenerateContent], "Gemini protocol fixed")
        check(PolishProvider.anthropic.protocolOptions == [.anthropicMessages], "Anthropic protocol fixed")
        check(PolishProvider.custom.protocolOptions.count == 4, "Custom offers all protocols")
        check(PolishProvider.openAI.defaultProtocol == .responses, "fresh OpenAI defaults Responses")

        // Readiness is entirely local and shares the client's real validation path.
        let local = settings()
        local.selectPolishProvider(.custom)
        local.llmBaseURL = "http://localhost:1234/v1"
        local.llmModel = "synthetic-local-model"
        check(local.llmConfigured, "localhost is valid without key")
        local.llmBaseURL = "https://remote.invalid/v1"
        check(!local.llmConfigured, "remote service requires key")
        local.llmAPIKey = "synthetic-key"
        check(local.llmConfigured, "remote service valid with key")
        check(local.llmConfig.maxOutputTokens == 4096, "controller receives bounded token budget")
        check(local.llmThinkingMode == .modelDefault, "unknown model receives no guessed thinking flags")
        local.llmBaseURL = "http://remote.invalid/v1"
        check(!local.llmConfigured, "insecure remote URL rejected")
        local.llmBaseURL = "https://remote.invalid/v1"
        local.llmModel = "   "
        check(!local.llmConfigured, "whitespace model is not configured")

        print("Provider settings tests passed (\(assertions) assertions; in-memory defaults and credentials only).")
    }
}
