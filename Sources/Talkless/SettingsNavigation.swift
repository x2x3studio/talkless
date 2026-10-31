import Foundation

/// Settings sidebar pages. Kept free of view dependencies so the app delegate, setup guide
/// and focused tests can route to a page without compiling the whole Settings window.
enum SettingsSection: String, CaseIterable, Identifiable {
    case dictation, translation, models, aiService, dictionary, overlay, history, system, about

    var id: Self { self }

    var title: String {
        switch self {
        case .dictation: L10n.tr("Dictation")
        case .translation: L10n.tr("Translation")
        case .models: L10n.tr("Speech recognition")
        case .aiService: L10n.tr("AI service")
        case .dictionary: L10n.tr("Dictionary")
        case .overlay: L10n.tr("Overlay")
        case .history: L10n.tr("History")
        case .system: L10n.tr("System")
        case .about: L10n.tr("About")
        }
    }

    var symbol: String {
        switch self {
        case .dictation: "mic"
        case .translation: "character.bubble"
        case .models: "waveform"
        case .aiService: "network"
        case .dictionary: "character.book.closed"
        case .overlay: "rectangle.on.rectangle"
        case .history: "clock"
        case .system: "gearshape"
        case .about: "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .dictation: L10n.tr("Choose how you record and how your words are processed.")
        case .translation: L10n.tr("Translate selected text, independently of dictation.")
        case .models: L10n.tr("Choose how audio becomes text.")
        case .aiService: L10n.tr("One AI connection for polishing, translation, and voice editing.")
        case .dictionary: L10n.tr("Review and manage preferred spellings.")
        case .overlay: L10n.tr("Preview and customize recording feedback.")
        case .history: L10n.tr("Your recent dictations, edits, and translations.")
        case .system: L10n.tr("Permissions, language, startup, and troubleshooting.")
        case .about: L10n.tr("Version, updates, and project information.")
        }
    }
}

extension Notification.Name {
    /// Posted with a `SettingsSection` object to select that page in an open Settings window.
    static let showSettingsSection = Notification.Name("Talkless.showSettingsSection")
}
