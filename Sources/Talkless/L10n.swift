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
        // These two catalog identifiers are not English source keys. Keep the
        // language picker readable even when the entire resource bundle is absent.
        switch englishKey {
        case "interface.language.english": return "English"
        case "interface.language.simplifiedChinese": return "\u{7B80}\u{4F53}\u{4E2D}\u{6587}"
        default: return englishKey
        }
    }

    private func lookup(_ key: String, localization: String) -> String? {
        // SwiftPM normalizes localization folder names to lowercase when packaging.
        guard let bundle,
              let path = bundle.path(forResource: localization, ofType: "lproj")
                ?? bundle.path(forResource: localization.lowercased(), ofType: "lproj") else { return nil }
        let folder = URL(fileURLWithPath: path)
        // Checking only the outer bundle is insufficient: a nested lproj or string
        // table symlink could otherwise escape to development/user resources.
        guard Self.isContained(folder, in: bundle.bundleURL),
              Self.isContained(folder.appendingPathComponent("Localizable.strings"), in: bundle.bundleURL),
              Self.isContained(folder.appendingPathComponent("Localizable.stringsdict"), in: bundle.bundleURL),
              let localizedBundle = Bundle(url: folder) else { return nil }
        let missing = "\u{1F}Talkless.missing:\(key)"
        let value = localizedBundle.localizedString(forKey: key, value: missing, table: "Localizable")
        return value == missing ? nil : value
    }

    static let resourceBundleName = "Talkless_Talkless.bundle"

    static let applicationBundle: Bundle? = resolveApplicationBundle(mainBundle: .main) {
        #if SWIFT_PACKAGE
        // SwiftPM's generated accessor traps when neither of its paths exists.
        // Only command-line development builds may evaluate it, never a shipped app.
        return Bundle.module
        #else
        // Standalone swiftc tests have no generated accessor. This development-only
        // fallback must not hide a missing resource bundle in a packaged application.
        return Bundle(url: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources"))
        #endif
    }

    /// Keep the fallback lazy: even referring to Bundle.module initializes a fatal
    /// static accessor. Missing packaged resources must instead return English keys.
    static func resolveApplicationBundle(mainBundle: Bundle, developmentFallback: () -> Bundle?) -> Bundle? {
        guard let appURL = applicationURL(for: mainBundle) else { return developmentFallback() }
        let candidates = [
            mainBundle.resourceURL?.appendingPathComponent(resourceBundleName),
            appURL.appendingPathComponent(resourceBundleName), // Older SwiftPM root layout / relative alias.
        ]
        return candidates.compactMap { candidate -> Bundle? in
            guard let candidate, isContained(candidate, in: appURL) else { return nil }
            return Bundle(url: candidate)
        }.first
    }

    static func applicationURL(for bundle: Bundle) -> URL? {
        applicationURL(bundleURL: bundle.bundleURL, executableURL: bundle.executableURL)
    }

    static func applicationURL(bundleURL: URL, executableURL: URL?) -> URL? {
        if bundleURL.pathExtension.lowercased() == "app" { return bundleURL }
        // A malformed app can make Foundation treat its executable as a plain CLI.
        // Still forbid development fallback if it lives inside an .app wrapper.
        var path = executableURL?.standardizedFileURL.path ?? ""
        while !path.isEmpty && path != "/" {
            if (path as NSString).pathExtension.lowercased() == "app" { return URL(fileURLWithPath: path) }
            let parent = (path as NSString).deletingLastPathComponent
            guard parent != path else { break }
            path = parent
        }
        return nil
    }

    static func isContained(_ url: URL, in directory: URL) -> Bool {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root)
    }
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
