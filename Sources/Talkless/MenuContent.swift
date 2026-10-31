import AppKit

/// Shared by the status menu and offline preview; building a menu never starts services.
@MainActor
enum MenuContent {
    enum DictationPhase { case idle, recording, processing }

    /// Something that stops dictation from working. Shown only while it is true.
    enum Problem: Int, CaseIterable {
        case accessibility, microphone, speechModel

        var title: String {
            switch self {
            case .accessibility: L10n.tr("Accessibility permission needed · Open Settings")
            case .microphone: L10n.tr("Microphone permission needed · Open Settings")
            case .speechModel: L10n.tr("Speech model not downloaded · Open Settings")
            }
        }
    }

    struct State {
        var dictationKeyTitle = L10n.tr("Fn / Globe")
        var holdToTalk = true
        var alternateFinishKeyTitle: String?
        var polishEnabled = false
        /// Display only. The global shortcut is registered elsewhere.
        var translationShortcutTitle: String?
        var dictation: DictationPhase = .idle
        var problems: [Problem] = []
        /// Shown only once this session has a dictation or edit result.
        var hasLastResult = false
    }

    struct Actions {
        /// Receives the problem row; its tag is the Problem raw value.
        var fix: Selector? = nil
        var copyLastResult: Selector? = nil
        let dictate: Selector
        let translate: Selector
        let openSettings: Selector
        let quit: Selector
    }

    static func populate(
        _ menu: NSMenu,
        state: State,
        target: AnyObject,
        actions: Actions,
        updateItem: NSMenuItem?
    ) {
        menu.removeAllItems()
        // Keep explicit enabled states and preserve the updater's validation snapshot.
        menu.autoenablesItems = false

        func label(_ title: String, toolTip: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            item.toolTip = toolTip
            return item
        }
        func action(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = target
            item.keyEquivalentModifierMask = .command
            return item
        }

        if let fix = actions.fix, !state.problems.isEmpty {
            for problem in state.problems {
                let item = action(problem.title, fix, key: "")
                item.keyEquivalentModifierMask = []
                item.tag = problem.rawValue
                menu.addItem(symbol(item, "exclamationmark.triangle"))
            }
            menu.addItem(.separator())
        }

        // Clickable commands; the gray subtitle shows the global shortcut without registering
        // it as a menu key equivalent. Status menus do not activate Talkless, so dictation and
        // translation still target the app that was frontmost.
        let dictation: NSMenuItem
        switch state.dictation {
        case .idle:
            dictation = action(L10n.tr("Start Dictation"), actions.dictate, key: "")
            dictation.subtitle = state.holdToTalk
                ? L10n.format("Hold %@", state.dictationKeyTitle)
                : L10n.format("Tap %@", state.dictationKeyTitle)
            dictation.toolTip = (state.holdToTalk
                ? L10n.format("Hold %@ to talk; release to finish.", state.dictationKeyTitle)
                : L10n.format("Tap %@ to start talking; press again to finish.", state.dictationKeyTitle))
                + L10n.tr(" Esc cancels recording or processing.")
        case .recording:
            dictation = action(L10n.tr("Finish Dictation"), actions.dictate, key: "")
            dictation.subtitle = L10n.tr("Press Esc to cancel")
        case .processing:
            dictation = label(L10n.tr("Recognizing"), toolTip: L10n.tr("Esc cancels."))
        }
        dictation.keyEquivalentModifierMask = []
        menu.addItem(symbol(dictation, state.dictation == .recording ? "stop.circle" : "mic"))

        let translation = action(L10n.tr("Translate selection"), actions.translate, key: "")
        translation.keyEquivalentModifierMask = []
        if let key = state.translationShortcutTitle {
            translation.subtitle = key
            translation.toolTip = L10n.format("Select text in another app, then press %@ to translate it.", key)
        }
        menu.addItem(symbol(translation, "character.bubble"))
        if state.hasLastResult, let copy = actions.copyLastResult {
            let item = action(L10n.tr("Copy Last Result"), copy, key: "")
            item.keyEquivalentModifierMask = []
            item.toolTip = L10n.tr("Copy the most recent dictation result to the clipboard.")
            menu.addItem(symbol(item, "doc.on.clipboard"))
        }

        menu.addItem(.separator())
        menu.addItem(symbol(action(L10n.tr("Settings…"), actions.openSettings, key: ","), "gearshape"))
        // Preserve UpdateController's target, enabled state, and status explanation.
        menu.addItem(symbol(updateItem ?? label(L10n.tr("Check for Updates…"), toolTip: L10n.tr("Updates are not configured for this build.")),
                            "arrow.triangle.2.circlepath"))
        menu.addItem(.separator())
        menu.addItem(symbol(action(L10n.tr("Quit Talkless"), actions.quit, key: "q"), "power"))
    }

    /// Every row has a symbol: a single icon would indent only its own title.
    private static func symbol(_ item: NSMenuItem, _ name: String) -> NSMenuItem {
        item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        item.image?.isTemplate = true
        // Newer macOS versions hide menu images unless explicitly requested.
        if #available(macOS 27.0, *) {
            item.preferredImageVisibility = .visible
        }
        return item
    }
}
