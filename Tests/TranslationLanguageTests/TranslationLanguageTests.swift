import Foundation

@main
struct TranslationLanguageTests {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            count += 1
        }
        let defaults = TranslationLanguagePreferences()
        let englishSystem = ["en-GB"]
        check(defaults.source == .auto && defaults.target == .auto, "Fresh source and target are Auto")
        check(defaults.preferredLanguageIDs == ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "ru", "de", "es", "it", "pt", "pl", "ar"], "Exact common defaults")
        check((40...60).contains(TranslationLanguages.all.count), "Curated manageable language list")
        check(Set(TranslationLanguages.all.map(\.id)).count == TranslationLanguages.all.count, "Unique language IDs")
        check(TranslationLanguages.resolvedPrimary(preferences: defaults, systemLanguages: englishSystem).id == "en", "English system resolves primary English")
        check(TranslationLanguages.resolvedSecondary(preferences: defaults, systemLanguages: englishSystem).id == "zh-Hans", "English primary resolves secondary simplified Chinese")
        check(TranslationLanguages.resolvedPrimary(preferences: defaults, systemLanguages: ["xx-ZZ", "ja-JP", "fr"]).id == "ja", "First supported system preference")
        check(TranslationLanguages.resolvedPrimary(preferences: defaults, systemLanguages: ["xx-ZZ"]).id == "en", "Unsupported system falls back English")
        check(TranslationLanguages.resolvedPrimary(preferences: defaults, systemLanguages: []).id == "en", "Empty system preference fallback")
        check(TranslationLanguages.resolvedPrimary(preferences: defaults, systemLanguages: ["zh_TW"]).id == "zh-Hant", "Traditional system locale preserved")
        check(TranslationLanguages.canonicalID("zh-Hans-TW") == "zh-Hans", "Explicit script beats region")
        check(TranslationLanguages.canonicalID("zh-Hant-CN") == "zh-Hant", "Explicit traditional script beats mainland region")
        check(TranslationLanguages.canonicalID("fr_CA") == "fr", "Regional aliases normalize")
        check(TranslationLanguages.canonicalID("no-NO") == "nb", "Norwegian locale alias")

        func target(_ source: String?, _ preferences: TranslationLanguagePreferences = defaults) -> TranslationLanguageSelection {
            TranslationLanguages.resolve(detectedSourceLanguageID: source, preferences: preferences, systemLanguages: englishSystem).target
        }
        check(target("en") == .languageID("zh-Hans"), "Primary source automatically translates to secondary")
        check(target("en-US") == .languageID("zh-Hans"), "Region-independent equality")
        check(target("zh-Hans") == .languageID("en"), "Secondary source translates to primary")
        check(target("fr") == .languageID("en"), "Third language translates to primary")
        check(target(nil) == .languageID("en"), "Unknown uses primary")
        var explicit = defaults
        explicit.source = .languageID("ja")
        explicit.target = .languageID("fr")
        let resolved = TranslationLanguages.resolve(text: "This text should not override an explicit source.", preferences: explicit, systemLanguages: englishSystem)
        check(resolved.sourceLanguageID == "ja" && resolved.detectedSourceLanguageID == nil, "Explicit source bypasses detection")
        check(resolved.sourcePromptName == "Japanese" && resolved.targetPromptName == "French", "Stable English prompt names independent of interface")
        check(!resolved.isSourceAutomatic && resolved.target == .languageID("fr"), "Explicit target survives")
        explicit.source = .languageID("en")
        explicit.target = .auto
        check(target(nil, explicit) == .languageID("zh-Hans"), "Explicit source also drives Auto target")
        explicit.primary = .languageID("fr")
        explicit.secondary = .languageID("fr")
        explicit.source = .auto
        check(target("fr", explicit) == .languageID("en"), "Duplicate French pair predictably falls back English")
        explicit.primary = .languageID("en")
        explicit.secondary = .languageID("en")
        check(target("en", explicit) == .languageID("zh-Hans"), "Duplicate English pair falls back simplified Chinese")
        explicit.primary = .languageID("zh-Hant")
        explicit.secondary = .languageID("zh-Hans")
        check(target("zh-Hant", explicit) == .languageID("en"), "Chinese script variants use alternate language in Auto")
        check(target("zh-Hans", explicit) == .languageID("en"), "Simplified source matches traditional primary family")
        explicit.primary = .languageID("zh-Hans")
        explicit.secondary = .languageID("zh-Hant")
        check(target("zh-Hant", explicit) == .languageID("en"), "Traditional source matches simplified primary and duplicate secondary falls back English")
        explicit.target = .languageID("zh-Hans")
        check(target("zh-Hant", explicit) == .languageID("zh-Hans"), "Explicit Chinese script conversion is preserved")
        check(TranslationLanguages.sameLanguageFamily("zh-Hant", "zh-Hans"), "Chinese scripts share language family")
        check(!TranslationLanguages.sameLanguageFamily(nil, "en"), "Unknown never matches primary family")

        var preferred = defaults
        preferred.preferredLanguageIDs = ["fr", "fr-CA", "xx", "ja"]
        preferred.normalizePreferredLanguages()
        check(preferred.preferredLanguageIDs == ["fr", "ja"], "Preferred IDs canonicalize and deduplicate")
        preferred.primary = .languageID("de")
        preferred.secondary = .languageID("it")
        let menu = TranslationLanguages.menuLanguages(preferences: preferred, selection: .languageID("ar"), systemLanguages: englishSystem)
        check(menu.map(\.id) == ["fr", "ja", "de", "it", "ar"], "Primary, secondary and selected stay selectable outside preferred")
        check(preferred.preferredLanguageIDs == ["fr", "ja"], "Menu never rewrites preferred choices")
        preferred.preferredLanguageIDs = []
        preferred.normalizePreferredLanguages()
        check(preferred.preferredLanguageIDs.isEmpty, "Intentionally empty preferred list stays empty")
        preferred.primary = .languageID("zh-Hans")
        preferred.secondary = .languageID("zh-Hant")
        let duplicatePairMenu = TranslationLanguages.menuLanguages(preferences: preferred, selection: .auto, systemLanguages: englishSystem)
        check(Set(duplicatePairMenu.map(\.id)) == Set(["zh-Hans", "zh-Hant", "en"]), "Explicit same-family secondary remains selectable alongside resolved fallback")

        check(TranslationLanguagePreferences.migrated(legacyTarget: nil).target == .auto, "No legacy preference starts Auto")
        check(TranslationLanguagePreferences.migrated(legacyTarget: "Simplified Chinese").target == .languageID("zh-Hans"), "Persisted former default remains an explicit target")
        check(TranslationLanguagePreferences.migrated(legacyTarget: "French").target == .languageID("fr"), "Named custom target migrates")
        check(TranslationLanguagePreferences.migrated(legacyTarget: "zh-TW").target == .languageID("zh-Hant"), "Legacy identifier migrates")
        check(TranslationLanguagePreferences.migrated(legacyTarget: "\u{7E41}\u{9AD4}\u{4E2D}\u{6587}").target == .languageID("zh-Hant"), "Localized target migrates")
        let custom = "  Scots, informal tone  "
        let migrated = TranslationLanguagePreferences.migrated(legacyTarget: custom)
        check(migrated.target == .custom(custom), "Unknown custom target preserved verbatim")
        check(TranslationLanguages.resolve(text: "Sample text", preferences: migrated).targetPromptName == custom, "Custom target reaches prompt unchanged")
        let encoded = try JSONEncoder().encode(migrated)
        let decoded = try JSONDecoder().decode(TranslationLanguagePreferences.self, from: encoded)
        check(decoded == migrated, "Codable preference round trip")
        var customChoices = migrated
        customChoices.target = .languageID("fr")
        check(customChoices.customTargetName == custom, "Switching target retains custom language")
        customChoices.target = .custom("Scots")
        check(customChoices.customTargetName == "Scots", "Editing custom language updates remembered name")
        customChoices.target = .auto
        let customRoundTrip = try JSONDecoder().decode(TranslationLanguagePreferences.self, from: JSONEncoder().encode(customChoices))
        check(customRoundTrip.customTargetName == "Scots", "Remembered custom target survives relaunch while Auto selected")
        var oldJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        oldJSON.removeValue(forKey: "customTargetName")
        let oldData = try JSONSerialization.data(withJSONObject: oldJSON)
        var oldPreferences = try JSONDecoder().decode(TranslationLanguagePreferences.self, from: oldData)
        oldPreferences.normalizePreferredLanguages()
        check(oldPreferences.target == .custom(custom) && oldPreferences.customTargetName == custom, "Old schema custom target restores remembered name")
        var corrupt = defaults
        corrupt.source = .languageID("en_US")
        corrupt.target = .languageID("xx-invalid")
        corrupt.primary = .languageID("zh_TW")
        corrupt.secondary = .languageID("")
        let corruptData = try JSONEncoder().encode(corrupt)
        var loaded = try JSONDecoder().decode(TranslationLanguagePreferences.self, from: corruptData)
        loaded.normalizePreferredLanguages()
        check(loaded.source == .languageID("en") && loaded.primary == .languageID("zh-Hant"), "Loaded aliases canonicalize")
        check(loaded.target == .auto && loaded.secondary == .auto, "Loaded invalid IDs become Auto")
        loaded.source = .custom(" \n ")
        loaded.target = .custom(" ")
        loaded.normalizePreferredLanguages()
        check(loaded.source == .auto && loaded.target == .auto && loaded.customTargetName == nil, "Loaded blank custom selections become Auto")

        check(TranslationLanguages.detectSourceLanguage(in: "This is a clear English sentence about translating selected text into another language.") == "en", "Local English detection")
        check(TranslationLanguages.detectSourceLanguage(in: "\u{8FD9}\u{662F}\u{4E00}\u{4E2A}\u{7B80}\u{4F53}\u{4E2D}\u{6587}\u{53E5}\u{5B50}，\u{6211}\u{4EEC}\u{5E0C}\u{671B}\u{628A}\u{8FD9}\u{6BB5}\u{8BDD}\u{7FFB}\u{8BD1}\u{6210}\u{5176}\u{4ED6}\u{8BED}\u{8A00}。") == "zh-Hans", "Local simplified Chinese detection")
        check(TranslationLanguages.detectSourceLanguage(in: "\u{9019}\u{662F}\u{4E00}\u{500B}\u{7E41}\u{9AD4}\u{4E2D}\u{6587}\u{53E5}\u{5B50}，\u{6211}\u{5011}\u{5E0C}\u{671B}\u{628A}\u{9019}\u{6BB5}\u{8A71}\u{7FFB}\u{8B6F}\u{6210}\u{5176}\u{4ED6}\u{8A9E}\u{8A00}。") == "zh-Hant", "Local traditional Chinese detection")
        check(TranslationLanguages.detectSourceLanguage(in: "\u{81FA}\u{7063}\u{67D0}\u{5EA7}\u{5EDF}\u{5B87}\u{8DDD}\u{96E2}\u{6B64}\u{8655}\u{50C5}\u{4E09}\u{516C}\u{91CC}。") == "zh-Hant", "Shared distance character does not override traditional detection")
        check(TranslationLanguages.detectSourceLanguage(in: "\u{7687}\u{540E}\u{6628}\u{65E5}\u{62B5}\u{9054}\u{81FA}\u{7063}。") == "zh-Hant", "Shared queen character does not override traditional detection")
        check(TranslationLanguages.detectSourceLanguage(in: "\u{8FD9}\u{662F}\u{4E2D}\u{6587} mixed with an English sentence \u{6211}\u{4EEC}\u{4E00}\u{8D77}\u{6D4B}\u{8BD5}\u{8BED}\u{8A00}\u{68C0}\u{6D4B}") == nil, "Mixed Chinese and English remains unknown")
        check(TranslationLanguages.detectSourceLanguage(in: "OK") == nil, "Short text remains unknown")
        check(TranslationLanguages.detectSourceLanguage(in: "12345 !? —") == nil, "Non-language text remains unknown")
        let unknown = TranslationLanguages.resolve(text: "?!", preferences: defaults, systemLanguages: englishSystem)
        check(unknown.sourceLanguageID == nil && unknown.detectedSourceLanguageID == nil && unknown.target == .languageID("en"), "Unknown detection does not invent source and chooses primary")
        print("PASS: \(count) translation language checks")
    }
}
