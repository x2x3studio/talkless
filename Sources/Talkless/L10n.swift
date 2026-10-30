import Combine
import Foundation
import Synchronization

enum InterfaceLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english
    case simplifiedChinese

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: L10n.tr("Follow System")
        case .english: L10n.tr("interface.language.english")
        case .simplifiedChinese: L10n.tr("interface.language.simplifiedChinese")
        }
    }

    func localization(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .english: return "en"
        case .simplifiedChinese: return "zh-Hans"
        case .system:
            for preference in preferredLanguages {
                let parts = preference.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
                guard let language = parts.first else { continue }
                if language == "en" { return "en" }
                if language == "zh" {
                    // Do not mistake a Traditional Chinese preference for Simplified Chinese.
                    if parts.contains("hant") { continue }
                    if parts.contains("hans") { return "zh-Hans" }
                    if parts.contains("tw") || parts.contains("hk") || parts.contains("mo") { continue }
                    return "zh-Hans"
                }
            }
            return "en"
        }
    }
}

extension Notification.Name {
    static let interfaceLanguageDidChange = Notification.Name("Talkless.interfaceLanguageDidChange")
}

/// Looks up a specific language rather than relying on Bundle's process-wide preferred localization.
/// A separate catalog also lets standalone tests inject resources without touching user preferences.
struct LocalizationCatalog: Sendable {
    let bundle: Bundle?

    init(bundle: Bundle? = Self.applicationBundle) {
        self.bundle = bundle
    }

    func string(_ englishKey: String, localization: String) -> String {
        if let translated = lookup(englishKey, localization: localization) { return translated }
        if localization != "en", let english = lookup(englishKey, localization: "en") { return english }
        return englishKey
    }

    private func lookup(_ key: String, localization: String) -> String? {
        // SwiftPM normalizes localization folder names to lowercase when packaging.
        guard let path = bundle?.path(forResource: localization, ofType: "lproj")
                ?? bundle?.path(forResource: localization.lowercased(), ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else { return nil }
        let missing = "\u{1F}Talkless.missing:\(key)"
        let value = localizedBundle.localizedString(forKey: key, value: missing, table: "Localizable")
        return value == missing ? nil : value
    }

    static let applicationBundle: Bundle? = {
        #if SWIFT_PACKAGE
        return Bundle.module
        #else
        // Standalone swiftc tests do not generate Bundle.module. Prefer a packaged
        // bundle, then find source resources relative to this file (not the cwd).
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Talkless_Talkless.bundle"),
            Bundle.main.bundleURL.appendingPathComponent("Talkless_Talkless.bundle"),
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources"),
        ]
        return candidates.compactMap { $0.flatMap { Bundle(url: $0) } }.first
        #endif
    }()
}

/// Explicit lookup is necessary: SwiftUI's environment locale does not select Bundle.module strings.
enum L10n {
    private struct State: Sendable {
        var localization: String
        var locale: Locale
        var catalog = LocalizationCatalog()
    }

    private static let state = Mutex(State(localization: InterfaceLanguage.system.localization(), locale: .current))

    static var locale: Locale {
        state.withLock { $0.locale }
    }

    static func tr(_ englishKey: String) -> String {
        state.withLock { $0.catalog.string(englishKey, localization: $0.localization) }
    }

    static func format(_ key: String, _ args: CVarArg...) -> String {
        state.withLock {
            String(format: $0.catalog.string(key, localization: $0.localization),
                   locale: $0.locale, arguments: args)
        }
    }

    fileprivate static func select(_ localization: String, locale: Locale) {
        state.withLock {
            $0.localization = localization
            $0.locale = locale
        }
    }
}

/// Interface preferences are independent of speech, translation and provider settings.
@MainActor
final class LocalizationSettings: ObservableObject {
    static let shared = LocalizationSettings()
    nonisolated static let preferenceKey = "interfaceLanguage"

    @Published var interfaceLanguage: InterfaceLanguage {
        didSet {
            guard oldValue != interfaceLanguage else { return }
            defaults?.set(interfaceLanguage.rawValue, forKey: Self.preferenceKey)
            refreshLocale()
        }
    }
    @Published private(set) var locale: Locale

    private let defaults: UserDefaults?
    private let preferredLanguages: () -> [String]
    private let currentLocale: () -> Locale
    private var localeObserver: NSObjectProtocol?

    /// Pass nil defaults and explicit language/locale providers in tests to avoid real preferences.
    init(
        defaults: UserDefaults? = .standard,
        preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages },
        currentLocale: @escaping () -> Locale = { .current }
    ) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        self.currentLocale = currentLocale
        let selection = InterfaceLanguage(rawValue: defaults?.string(forKey: Self.preferenceKey) ?? "") ?? .system
        interfaceLanguage = selection
        let localization = selection.localization(preferredLanguages: preferredLanguages())
        let formattingLocale = selection == .system ? currentLocale() : Locale(identifier: localization)
        locale = formattingLocale
        L10n.select(localization, locale: formattingLocale)
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshLocale() }
        }
    }

    isolated deinit {
        if let localeObserver { NotificationCenter.default.removeObserver(localeObserver) }
    }

    func refreshLocale() {
        let localization = interfaceLanguage.localization(preferredLanguages: preferredLanguages())
        // Follow System keeps regional formatting separate from the supported UI catalog.
        let formattingLocale = interfaceLanguage == .system ? currentLocale() : Locale(identifier: localization)
        // Update the lookup before publishing a locale change that redraws views.
        L10n.select(localization, locale: formattingLocale)
        locale = formattingLocale
        NotificationCenter.default.post(name: .interfaceLanguageDidChange, object: self)
    }
}
