import Foundation
import NaturalLanguage

/// Interface language and translation choices are deliberately independent.
enum TranslationLanguageSelection: Codable, Hashable, Sendable {
    case auto
    case languageID(String)
    /// A legacy free-form target is kept verbatim rather than silently discarded.
    case custom(String)

    var displayName: String {
        switch self {
        case .auto: L10n.tr("Auto")
        case .languageID(let id): TranslationLanguages.language(id: id)?.displayName ?? id
        case .custom(let name): name
        }
    }

    var promptName: String? {
        switch self {
        case .auto: nil
        case .languageID(let id): TranslationLanguages.language(id: id)?.englishName ?? id
        case .custom(let name): name
        }
    }
}

struct TranslationLanguage: Identifiable, Hashable, Sendable {
    let id: String
    let englishName: String
    var displayName: String { L10n.tr(englishName) }
}

struct TranslationLanguagePreferences: Codable, Equatable, Sendable {
    var source: TranslationLanguageSelection = .auto
    var target: TranslationLanguageSelection = .auto {
        didSet {
            if case .custom(let name) = target { customTargetName = name }
            else if case .custom(let name) = oldValue { customTargetName = name }
        }
    }
    /// Keep a custom language available after temporarily choosing another target.
    var customTargetName: String? = nil
    var primary: TranslationLanguageSelection = .auto
    var secondary: TranslationLanguageSelection = .auto
    var preferredLanguageIDs: [String] = TranslationLanguages.commonLanguageIDs

    static func migrated(legacyTarget: String?) -> Self {
        var result = Self()
        guard let legacyTarget else { return result }
        let value = legacyTarget.trimmingCharacters(in: .whitespacesAndNewlines)
        // Any persisted nonempty target is user data, including the former default.
        guard !value.isEmpty else { return result }
        result.target = TranslationLanguages.selection(legacyValue: legacyTarget)
        return result
    }

    /// Normalizes loaded selections and removes invalid/duplicate menu IDs without
    /// adding back deliberately hidden languages or discarding a custom target.
    mutating func normalizePreferredLanguages() {
        func normalized(_ selection: TranslationLanguageSelection) -> TranslationLanguageSelection {
            switch selection {
            case .auto: return .auto
            case .languageID(let id):
                return TranslationLanguages.canonicalID(id).map(TranslationLanguageSelection.languageID) ?? .auto
            case .custom(let name):
                return name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .auto : .custom(name)
            }
        }
        source = normalized(source)
        target = normalized(target)
        primary = normalized(primary)
        secondary = normalized(secondary)
        if customTargetName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            customTargetName = nil
        }
        var seen = Set<String>()
        preferredLanguageIDs = preferredLanguageIDs.compactMap { TranslationLanguages.canonicalID($0) }
            .filter { seen.insert($0).inserted }
    }
}

struct TranslationLanguageResolution: Equatable, Sendable {
    let sourceLanguageID: String?
    let detectedSourceLanguageID: String?
    let sourcePromptName: String?
    let target: TranslationLanguageSelection
    let targetPromptName: String
    let isSourceAutomatic: Bool
}

enum TranslationLanguages {
    /// A useful menu, not a claim about a provider's language capabilities.
    static let commonLanguageIDs = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "ru", "de", "es", "it", "pt", "pl", "ar"]
    static let all: [TranslationLanguage] = [
        .init(id: "en", englishName: "English"),
        .init(id: "zh-Hans", englishName: "Simplified Chinese"),
        .init(id: "zh-Hant", englishName: "Traditional Chinese"),
        .init(id: "ja", englishName: "Japanese"),
        .init(id: "ko", englishName: "Korean"),
        .init(id: "fr", englishName: "French"),
        .init(id: "ru", englishName: "Russian"),
        .init(id: "de", englishName: "German"),
        .init(id: "es", englishName: "Spanish"),
        .init(id: "it", englishName: "Italian"),
        .init(id: "pt", englishName: "Portuguese"),
        .init(id: "pl", englishName: "Polish"),
        .init(id: "ar", englishName: "Arabic"),
        .init(id: "bg", englishName: "Bulgarian"),
        .init(id: "ca", englishName: "Catalan"),
        .init(id: "hr", englishName: "Croatian"),
        .init(id: "cs", englishName: "Czech"),
        .init(id: "da", englishName: "Danish"),
        .init(id: "nl", englishName: "Dutch"),
        .init(id: "et", englishName: "Estonian"),
        .init(id: "fi", englishName: "Finnish"),
        .init(id: "el", englishName: "Greek"),
        .init(id: "he", englishName: "Hebrew"),
        .init(id: "hi", englishName: "Hindi"),
        .init(id: "hu", englishName: "Hungarian"),
        .init(id: "id", englishName: "Indonesian"),
        .init(id: "lv", englishName: "Latvian"),
        .init(id: "lt", englishName: "Lithuanian"),
        .init(id: "ms", englishName: "Malay"),
        .init(id: "nb", englishName: "Norwegian Bokmål"),
        .init(id: "fa", englishName: "Persian"),
        .init(id: "ro", englishName: "Romanian"),
        .init(id: "sr", englishName: "Serbian"),
        .init(id: "sk", englishName: "Slovak"),
        .init(id: "sl", englishName: "Slovenian"),
        .init(id: "sv", englishName: "Swedish"),
        .init(id: "th", englishName: "Thai"),
        .init(id: "tr", englishName: "Turkish"),
        .init(id: "uk", englishName: "Ukrainian"),
        .init(id: "vi", englishName: "Vietnamese"),
        .init(id: "bn", englishName: "Bengali"),
        .init(id: "ta", englishName: "Tamil"),
        .init(id: "te", englishName: "Telugu"),
        .init(id: "ur", englishName: "Urdu"),
        .init(id: "fil", englishName: "Filipino"),
        .init(id: "sw", englishName: "Swahili"),
        .init(id: "af", englishName: "Afrikaans"),
        .init(id: "is", englishName: "Icelandic"),
        .init(id: "ga", englishName: "Irish"),
        .init(id: "mt", englishName: "Maltese"),
    ]

    static func canonicalID(_ raw: String) -> String? {
        let parts = raw.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
        guard let base = parts.first else { return nil }
        if base == "zh" {
            if parts.contains("hant") { return "zh-Hant" }
            if parts.contains("hans") { return "zh-Hans" }
            return parts.contains(where: { ["tw", "hk", "mo"].contains($0) }) ? "zh-Hant" : "zh-Hans"
        }
        let alias = ["no": "nb", "tl": "fil", "iw": "he", "in": "id"]
        let id = alias[String(base)] ?? String(base)
        return all.contains { $0.id == id } ? id : nil
    }

    static func language(id: String) -> TranslationLanguage? {
        guard let canonical = canonicalID(id) else { return nil }
        return all.first { $0.id == canonical }
    }

    static func selection(legacyValue: String) -> TranslationLanguageSelection {
        let value = legacyValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return .auto }
        if value.caseInsensitiveCompare("auto") == .orderedSame { return .auto }
        if let id = canonicalID(value) { return .languageID(id) }
        if let language = all.first(where: { $0.englishName.caseInsensitiveCompare(value) == .orderedSame }) {
            return .languageID(language.id)
        }
        // Recognize localized names too without depending on the current interface locale.
        for locale in [Locale(identifier: "en"), Locale(identifier: "zh-Hans"), Locale(identifier: "zh-Hant")] {
            if let language = all.first(where: {
                locale.localizedString(forIdentifier: $0.id)?.caseInsensitiveCompare(value) == .orderedSame
            }) { return .languageID(language.id) }
        }
        let chineseAliases = ["\u{7B80}\u{4F53}\u{4E2D}\u{6587}": "zh-Hans", "\u{7B80}\u{4F53}\u{6C49}\u{8BED}": "zh-Hans", "\u{7E41}\u{9AD4}\u{4E2D}\u{6587}": "zh-Hant", "\u{7E41}\u{4F53}\u{4E2D}\u{6587}": "zh-Hant", "\u{4E2D}\u{6587}": "zh-Hans", "\u{82F1}\u{8BED}": "en", "\u{82F1}\u{6587}": "en", "\u{65E5}\u{8BED}": "ja"]
        if let id = chineseAliases[value] { return .languageID(id) }
        return .custom(legacyValue)
    }

    static func resolvedPrimary(preferences: TranslationLanguagePreferences,
                                systemLanguages: [String] = Locale.preferredLanguages) -> TranslationLanguage {
        if case .languageID(let id) = preferences.primary, let language = language(id: id) { return language }
        return systemLanguages.lazy.compactMap { language(id: $0) }.first ?? language(id: "en")!
    }

    /// Auto direction treats script variants as one language; explicit target choices
    /// keep the full identifier so script conversion remains available.
    static func sameLanguageFamily(_ first: String?, _ second: String?) -> Bool {
        guard let first, let second,
              let lhs = canonicalID(first), let rhs = canonicalID(second) else { return false }
        return lhs.split(separator: "-").first == rhs.split(separator: "-").first
    }

    static func resolvedSecondary(preferences: TranslationLanguagePreferences,
                                  systemLanguages: [String] = Locale.preferredLanguages) -> TranslationLanguage {
        let primary = resolvedPrimary(preferences: preferences, systemLanguages: systemLanguages)
        if case .languageID(let id) = preferences.secondary,
           let language = language(id: id), !sameLanguageFamily(language.id, primary.id) { return language }
        // An explicitly duplicated pair must not make Auto translate to the source again.
        return language(id: primary.id == "en" ? "zh-Hans" : "en")!
    }

    static func menuLanguages(preferences: TranslationLanguagePreferences,
                              selection: TranslationLanguageSelection,
                              systemLanguages: [String] = Locale.preferredLanguages) -> [TranslationLanguage] {
        var ids = preferences.preferredLanguageIDs
        ids += [resolvedPrimary(preferences: preferences, systemLanguages: systemLanguages).id,
                resolvedSecondary(preferences: preferences, systemLanguages: systemLanguages).id]
        for choice in [preferences.primary, preferences.secondary, selection] {
            if case .languageID(let id) = choice { ids.append(id) }
        }
        var seen = Set<String>()
        return ids.compactMap { language(id: $0) }.filter { seen.insert($0.id).inserted }
    }

    static func resolve(text: String, preferences: TranslationLanguagePreferences,
                        systemLanguages: [String] = Locale.preferredLanguages) -> TranslationLanguageResolution {
        let detected = preferences.source == .auto ? detectSourceLanguage(in: text) : nil
        return resolve(detectedSourceLanguageID: detected, preferences: preferences, systemLanguages: systemLanguages)
    }

    /// Separate deterministic policy from local detection for repeatable direction tests.
    static func resolve(detectedSourceLanguageID: String?, preferences: TranslationLanguagePreferences,
                        systemLanguages: [String] = Locale.preferredLanguages) -> TranslationLanguageResolution {
        let sourceID: String?
        let sourceName: String?
        switch preferences.source {
        case .auto:
            sourceID = detectedSourceLanguageID.flatMap(canonicalID)
            sourceName = sourceID.flatMap { language(id: $0)?.englishName }
        case .languageID(let id):
            sourceID = canonicalID(id)
            sourceName = preferences.source.promptName
        case .custom(let name):
            sourceID = nil
            sourceName = name
        }
        let target: TranslationLanguageSelection
        if preferences.target == .auto {
            let primary = resolvedPrimary(preferences: preferences, systemLanguages: systemLanguages)
            let secondary = resolvedSecondary(preferences: preferences, systemLanguages: systemLanguages)
            target = .languageID(sameLanguageFamily(sourceID, primary.id) ? secondary.id : primary.id)
        } else {
            target = preferences.target
        }
        return .init(sourceLanguageID: sourceID,
                     detectedSourceLanguageID: preferences.source == .auto ? sourceID : nil,
                     sourcePromptName: sourceName, target: target,
                     targetPromptName: target.promptName ?? "English", isSourceAutomatic: preferences.source == .auto)
    }

    /// Conservative on-device detection. Mixed or tiny samples remain unknown rather than
    /// showing a confident language label or issuing another network request.
    static func detectSourceLanguage(in text: String) -> String? {
        let sample = String(text.prefix(8_000))
        let letters = sample.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 4 else { return nil }
        let han = letters.filter { (0x3400...0x9FFF).contains($0.value) }.count
        let latin = letters.filter { (0x0041...0x024F).contains($0.value) }.count
        let kana = letters.filter { (0x3040...0x30FF).contains($0.value) }.count
        if kana == 0, han >= 3, latin >= 3,
           Double(min(han, latin)) / Double(han + latin) >= 0.18 { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 2).sorted { $0.value > $1.value }
        guard let best = hypotheses.first, best.value >= 0.65,
              hypotheses.count < 2 || best.value - hypotheses[1].value >= 0.15,
              let id = canonicalID(best.key.rawValue) else { return nil }
        return id
    }
}
