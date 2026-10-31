import AppKit

/// Shared by the status menu and offline preview; building a menu never starts services.
@MainActor
enum MenuContent {
    struct State {
        var dictationKeyTitle = L10n.tr("Fn / Globe")
        var holdToTalk = true
        var alternateFinishKeyTitle: String?
        var polishEnabled = false
        /// Display only. The global shortcut is registered elsewhere.
        var translationShortcutTitle: String?
    }

    struct Actions {
        let openSettings: Selector
        let quit: Selector
    }

    /// Leading inset of command titles once their menu reserves an image column; shortcut
    /// reference text uses it too so every row starts on the same text edge.
    static let textInset: CGFloat = 34

    /// Readable shortcut reference, not a clickable menu command or key-equivalent registration.
    final class ShortcutRow: NSView {
        let functionLabel: NSTextField
        let shortcutLabel: NSTextField
        var preferredWidth: CGFloat {
            functionLabel.intrinsicContentSize.width + shortcutLabel.intrinsicContentSize.width + MenuContent.textInset + 44
        }

        init(function: String, shortcut: String, help: String) {
            functionLabel = NSTextField(labelWithString: function)
            shortcutLabel = NSTextField(labelWithString: shortcut)
            super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 26))
            autoresizingMask = [.width]
            for label in [functionLabel, shortcutLabel] {
                label.font = .menuFont(ofSize: 0)
                label.setAccessibilityElement(false)
                addSubview(label)
            }
            functionLabel.autoresizingMask = [.width]
            shortcutLabel.autoresizingMask = [.minXMargin]
            functionLabel.textColor = .labelColor
            shortcutLabel.textColor = .secondaryLabelColor
            shortcutLabel.alignment = .right
            toolTip = help
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            setAccessibilityLabel(function)
            setAccessibilityValue(shortcut)
            setAccessibilityHelp(help)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            let keyWidth = shortcutLabel.intrinsicContentSize.width
            let height = functionLabel.intrinsicContentSize.height
            let y = (bounds.height - height) / 2
            functionLabel.frame = NSRect(x: MenuContent.textInset, y: y,
                                         width: bounds.width - keyWidth - MenuContent.textInset - 44, height: height)
            shortcutLabel.frame = NSRect(x: bounds.width - keyWidth - 20, y: y, width: keyWidth, height: height)
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    static func populate(
        _ menu: NSMenu,
        state: State,
        target: AnyObject,
        actions: Actions,
        updateItem: NSMenuItem?
    ) {
        menu.removeAllItems()
        // Keep informational rows disabled and preserve the updater's validation snapshot.
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

        var shortcutRows: [ShortcutRow] = []
        func shortcut(_ function: String, key: String, help: String) {
            let item = label(function, toolTip: help)
            let row = ShortcutRow(function: function, shortcut: key, help: help)
            item.view = row
            shortcutRows.append(row)
            menu.addItem(item)
        }

        let dictationTitle = state.holdToTalk
            ? L10n.format("Dictation (hold %@)", state.dictationKeyTitle)
            : L10n.format("Dictation (tap %@)", state.dictationKeyTitle)
        let dictationHelp = state.holdToTalk
            ? L10n.format("Hold %@ to talk; release to finish.", state.dictationKeyTitle)
            : L10n.format("Tap %@ to start talking; press again to finish.", state.dictationKeyTitle)
        shortcut(dictationTitle, key: "",
                 help: dictationHelp + L10n.tr(" Esc cancels recording or processing."))
        if let key = state.translationShortcutTitle {
            shortcut(L10n.tr("Translate selection"), key: key,
                     help: L10n.format("Select text in another app, then press %@ to translate it.", key))
        }
        let width = max(300, shortcutRows.map(\.preferredWidth).max() ?? 0)
        for row in shortcutRows {
            row.setFrameSize(NSSize(width: width, height: 26))
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
        }

        // Every command has a symbol: a single icon would indent only its own title.
        func symbol(_ item: NSMenuItem, _ name: String) -> NSMenuItem {
            item.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
            item.image?.isTemplate = true
            // Newer macOS versions hide menu images unless explicitly requested.
            if #available(macOS 27.0, *) {
                item.preferredImageVisibility = .visible
            }
            return item
        }
        menu.addItem(.separator())
        menu.addItem(symbol(action(L10n.tr("Settings…"), actions.openSettings, key: ","), "gearshape"))
        // Preserve UpdateController's target, enabled state, and status explanation.
        menu.addItem(symbol(updateItem ?? label(L10n.tr("Check for Updates…"), toolTip: L10n.tr("Updates are not configured for this build.")),
                            "arrow.triangle.2.circlepath"))
        menu.addItem(.separator())
        menu.addItem(symbol(action(L10n.tr("Quit Talkless"), actions.quit, key: "q"), "power"))
    }
}
