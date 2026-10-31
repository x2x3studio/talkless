import Combine
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "LocalizationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

@main
struct LocalizationTests {
    @MainActor
    static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let resources = source.appendingPathComponent("Resources")
        let en = try catalog(at: resources.appendingPathComponent("en.lproj/Localizable.strings"))
        let zh = try catalog(at: resources.appendingPathComponent("zh-Hans.lproj/Localizable.strings"))
        try expect(!en.isEmpty && Set(en.keys) == Set(zh.keys), "English and Simplified Chinese catalog keys must match")
        for (key, value) in en {
            try expect(!value.isEmpty && !(zh[key] ?? "").isEmpty, "Empty translation for \(key)")
            for displayed in [value, zh[key]!] {
                try expect(!displayed.localizedCaseInsensitiveContains("alternate finish")
                           && !displayed.localizedCaseInsensitiveContains("alternate-finish")
                           && !displayed.contains("\u{66FF}\u{4EE3}\u{7ED3}\u{675F}") && !displayed.contains("opposite AI"),
                           "Polishing UI must use plain action wording: \(key)")
            }
            if !key.hasPrefix("interface.language.") {
                try expect(key == value, "English catalog must preserve the English source key: \(key)")
            }
            try expect(tryFormatArguments(value) == tryFormatArguments(zh[key]!), "Format arguments differ for \(key)")
        }
        for language in ["en", "zh-Hans"] {
            let info = try catalog(at: resources.appendingPathComponent("\(language).lproj/InfoPlist.strings"))
            try expect(Set(info.keys) == ["NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"], "Permission descriptions missing")
        }
        try checkSourceKeys(in: source, keys: Set(en.keys))
        try selectionTests()
        try fallbackTests()
        try bundleDetectionTests()
        try controllerTests(chinese: zh)
        print("Localization tests passed (\(en.count) keys, parity, formats, source coverage, language selection, persistence, fallback and notifications).")
    }

    private static func catalog(at url: URL) throws -> [String: String] {
        let data = try Data(contentsOf: url)
        guard let values = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
            throw NSError(domain: "LocalizationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid catalog: \(url.path)"])
        }
        let text = String(decoding: data, as: UTF8.self)
        let entryPattern = try NSRegularExpression(pattern: #"(?m)^\s*\"(?:\\.|[^\"\\])*\"\s*="#)
        try expect(entryPattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == values.count,
                   "Duplicate keys or malformed entries in \(url.path)")
        return values
    }

    /// Compare argument positions and types, allowing a translation to reorder positional arguments.
    private static func tryFormatArguments(_ format: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?[-+#0 ']*(?:\d+|\*)?(?:\.(?:\d+|\*))?(hh|ll|[hlLzjtq])?([@diuoxXfFeEgGaAcCsSp%])"#)
        var sequential = 0
        return regex.matches(in: format, range: NSRange(format.startIndex..., in: format)).compactMap { match in
            let type = (format as NSString).substring(with: match.range(at: 3))
            guard type != "%" else { return nil }
            sequential += 1
            let position = match.range(at: 1).location == NSNotFound ? String(sequential) : (format as NSString).substring(with: match.range(at: 1))
            let length = match.range(at: 2).location == NSNotFound ? "" : (format as NSString).substring(with: match.range(at: 2))
            return "\(position):\(length)\(type)"
        }.sorted()
    }

    private static func checkSourceKeys(in source: URL, keys: Set<String>) throws {
        let regex = try NSRegularExpression(pattern: #"L10n\.(?:tr|format)\(\s*(\"(?:\\.|[^\"\\])*\")"#)
        for url in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let literal = (text as NSString).substring(with: match.range(at: 1))
                guard let key = try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: [.fragmentsAllowed]) as? String else {
                    throw NSError(domain: "LocalizationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Use a static English localization key in \(url.lastPathComponent): \(literal)"])
                }
                try expect(keys.contains(key), "Missing catalog key in \(url.lastPathComponent): \(key)")
            }
        }
    }

    private static func selectionTests() throws {
        for preferences in [["zh-Hans"], ["zh-CN"], ["zh_SG"], ["fr-FR", "zh-Hans-CN"], ["zh-Hans-TW"]] {
            try expect(InterfaceLanguage.system.localization(preferredLanguages: preferences) == "zh-Hans", "Simplified Chinese system selection: \(preferences)")
        }
        for preferences in [["en-US", "zh-Hans"], ["fr-FR"], ["zh-Hant"], ["zh-TW"], ["zh-HK"], [String]()] {
            try expect(InterfaceLanguage.system.localization(preferredLanguages: preferences) == "en", "English system fallback: \(preferences)")
        }
        try expect(InterfaceLanguage.english.localization(preferredLanguages: ["zh-Hans"]) == "en", "Manual English must override system")
        try expect(InterfaceLanguage.simplifiedChinese.localization(preferredLanguages: ["en"]) == "zh-Hans", "Manual Chinese must override system")
    }

    private static func fallbackTests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TalklessLocalization-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: root) }
        let en = root.appendingPathComponent("en.lproj")
        try FileManager.default.createDirectory(at: en, withIntermediateDirectories: true)
        try #""Known key" = "English fallback";"#.write(to: en.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        let catalog = LocalizationCatalog(bundle: Bundle(url: root))
        try expect(catalog.bundle != nil, "Test bundle should load")
        try expect(catalog.string("Known key", localization: "zh-Hans") == "English fallback", "Missing localized resource must use English")
        try expect(catalog.string("Unknown key", localization: "zh-Hans") == "Unknown key", "Missing key must return readable English source")
        try expect(LocalizationCatalog(bundle: nil).string("No bundle", localization: "zh-Hans") == "No bundle", "Missing bundle fallback")
        try expect(LocalizationCatalog(bundle: nil).string("interface.language.english", localization: "en") == "English", "Missing bundle preserves English autonym")
        try expect(LocalizationCatalog(bundle: nil).string("interface.language.simplifiedChinese", localization: "en") == "\u{7B80}\u{4F53}\u{4E2D}\u{6587}", "Missing bundle preserves Chinese autonym")
        try expect(LocalizationCatalog().string("Follow System", localization: "zh-Hans") != "Follow System", "Standalone lookup must find source resources independently of cwd")
    }

    private static func bundleDetectionTests() throws {
        let root = URL(fileURLWithPath: "/")
        for executable: URL? in [nil, root, URL(fileURLWithPath: "/Talkless"), URL(fileURLWithPath: "/tmp/bin/Talkless")] {
            try expect(LocalizationCatalog.applicationURL(bundleURL: root, executableURL: executable) == nil,
                       "CLI/root ancestor traversal must terminate without detecting an app")
        }
        let app = URL(fileURLWithPath: "/tmp/Moved App.app")
        try expect(LocalizationCatalog.applicationURL(bundleURL: app, executableURL: nil) == app, "Recognize app wrapper directly")
        try expect(LocalizationCatalog.applicationURL(bundleURL: root, executableURL: app.appendingPathComponent("Contents/MacOS/Talkless")) == app,
                   "Malformed app must not be mistaken for development CLI")
        var fallbackCalls = 0
        _ = LocalizationCatalog.resolveApplicationBundle(mainBundle: .main) { fallbackCalls += 1; return nil }
        try expect(fallbackCalls == 1, "Standalone resolver invokes development fallback lazily")
    }

    @MainActor
    private static func controllerTests(chinese: [String: String]) throws {
        var preferred = ["en-GB"]
        var regionalLocale = Locale(identifier: "en_GB")
        let settings = LocalizationSettings(defaults: nil, preferredLanguages: { preferred }, currentLocale: { regionalLocale })
        try expect(settings.interfaceLanguage == .system && settings.locale.identifier == "en_GB", "Follow System preserves British regional formatting")
        var notificationCount = 0
        let subscription = NotificationCenter.default.publisher(for: .interfaceLanguageDidChange).sink { _ in notificationCount += 1 }
        defer { subscription.cancel() }
        settings.interfaceLanguage = .simplifiedChinese
        try expect(settings.locale.identifier == "zh-Hans" && L10n.locale.identifier == "zh-Hans", "Manual Chinese updates both locale APIs")
        try expect(L10n.tr("Follow System") == chinese["Follow System"], "Manual Chinese lookup")
        try expect(L10n.format("%d saved entries", 3) == String(format: chinese["%d saved entries"]!, locale: Locale(identifier: "zh-Hans"), arguments: [3]), "Chinese formats preserve numeric arguments")
        try expect(notificationCount == 1, "Language change refreshes menus")
        let chineseAutonym = InterfaceLanguage.simplifiedChinese.displayName
        try expect(InterfaceLanguage.english.displayName == "English", "English autonym remains readable in Chinese interface")
        settings.interfaceLanguage = .english
        try expect(InterfaceLanguage.simplifiedChinese.displayName == chineseAutonym && chineseAutonym == chinese["interface.language.simplifiedChinese"], "Chinese autonym is independent of interface language")
        try expect(L10n.tr("Follow System") == "Follow System", "Manual English lookup")
        preferred = ["zh-Hans-CN"]
        settings.refreshLocale()
        try expect(settings.locale.identifier == "en", "System refresh cannot override manual selection")
        settings.interfaceLanguage = .system
        try expect(settings.locale.identifier == "en_GB" && L10n.tr("Follow System") == chinese["Follow System"], "Chinese system catalog remains separate from British region")
        preferred = ["de-DE", "en-GB"]
        regionalLocale = Locale(identifier: "de_DE")
        settings.refreshLocale()
        try expect(L10n.tr("Follow System") == "Follow System", "Unsupported system language falls back to English catalog")
        try expect(L10n.locale.identifier == "de_DE" && settings.locale.identifier == "de_DE", "English catalog preserves German regional formatting")
        let numericKey = "%.1f"
        try expect(L10n.format(numericKey, 1.5) == "1,5", "System decimal separator uses regional locale, not catalog language")
        preferred = ["en-GB"]
        regionalLocale = Locale(identifier: "en_GB")
        settings.refreshLocale()
        try expect(L10n.locale.identifier == "en_GB" && L10n.tr("Follow System") == "Follow System", "System changes refresh strings and regional format without restarting")
        try expect(L10n.format("Missing format: %@ %d", "value", 7) == "Missing format: value 7", "Unknown English format fallback")

        // Only a random test domain is written; never read or mutate standard preferences.
        let suite = "Talkless.LocalizationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("invalid-future-value", forKey: LocalizationSettings.preferenceKey)
        let persisted = LocalizationSettings(defaults: defaults, preferredLanguages: { ["en"] })
        try expect(persisted.interfaceLanguage == .system, "Unknown saved preference falls back to system")
        persisted.interfaceLanguage = .simplifiedChinese
        try expect(defaults.string(forKey: LocalizationSettings.preferenceKey) == InterfaceLanguage.simplifiedChinese.rawValue, "Language preference persists independently")
        let restored = LocalizationSettings(defaults: defaults, preferredLanguages: { ["en"] })
        try expect(restored.interfaceLanguage == .simplifiedChinese && restored.locale.identifier == "zh-Hans", "Saved language restores")
        restored.interfaceLanguage = .english
    }
}
