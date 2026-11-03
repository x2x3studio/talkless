import Foundation

/// Settings sidebar pages. Kept free of view dependencies so the app delegate, setup guide
/// and focused tests can route to a page without compiling the whole Settings window.
enum SettingsSection: String, CaseIterable, Identifiable {
    // Voice input comes first; translation is a secondary tool.
    case dictation, aiService, formatting, dictionary, overlay, history, translation, system, labs, about

    /// Existing speech-setup entry points now open the combined voice-input page.
    static var models: Self { .dictation }

    /// Sidebar groups, in display order.
    static let groups: [(title: String, sections: [SettingsSection])] = [
        ("Voice input", [.dictation, .aiService, .formatting, .dictionary, .overlay]),
        ("Tools", [.history, .translation]),
        ("General", [.system, .labs, .about]),
    ]

    var id: Self { self }

    var title: String {
        switch self {
        case .dictation: L10n.tr("Voice input")
        case .translation: L10n.tr("Translation")
        case .aiService: L10n.tr("AI polishing")
        case .formatting: L10n.tr("Text formatting")
        case .dictionary: L10n.tr("Dictionary")
        case .overlay: L10n.tr("Overlay")
        case .history: L10n.tr("History")
        case .system: L10n.tr("System")
        case .labs: L10n.tr("Labs")
        case .about: L10n.tr("About")
        }
    }

    var symbol: String {
        switch self {
        case .dictation: "mic"
        case .translation: "character.bubble"
        case .aiService: "sparkles"
        case .formatting: "textformat"
        case .dictionary: "character.book.closed"
        case .overlay: "rectangle.on.rectangle"
        case .history: "clock"
        case .system: "gearshape"
        case .labs: "flask"
        case .about: "info.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .dictation: L10n.tr("Choose your microphone, shortcut, and speech recognition.")
        case .translation: L10n.tr("Translate selected text, independently of dictation.")
        case .aiService: L10n.tr("Set up AI polishing and voice editing with your own AI service.")
        case .formatting: L10n.tr("Format punctuation and spacing on this Mac, without an AI service.")
        case .dictionary: L10n.tr("Review and manage preferred spellings.")
        case .overlay: L10n.tr("Preview and customize recording feedback.")
        case .history: L10n.tr("Your recent dictations, edits, and translations.")
        case .system: L10n.tr("Permissions, language, startup, and troubleshooting.")
        case .labs: L10n.tr("Experimental features. Enable only what you need.")
        case .about: L10n.tr("Version, updates, and project information.")
        }
    }
}

extension Notification.Name {
    /// Posted with a `SettingsSection` object to select that page in an open Settings window.
    static let showSettingsSection = Notification.Name("Talkless.showSettingsSection")
}
