import AppKit

/// Accessory apps still need a main menu for Command-key editing in their windows.
/// This is separate from the status-item menu; nil targets use the native responder chain.
@MainActor
enum ApplicationEditMenu {
    private static let identifier = NSUserInterfaceItemIdentifier("TalklessEditMenu")

    static func install(in application: NSApplication = .shared) {
        let mainMenu = application.mainMenu ?? NSMenu()
        if mainMenu.items.isEmpty {
            // AppKit reserves the first top-level item for the application menu.
            let applicationItem = NSMenuItem()
            applicationItem.submenu = NSMenu(title: "Talkless")
            mainMenu.addItem(applicationItem)
        }
        let item = mainMenu.items.first { $0.identifier == identifier } ?? NSMenuItem()
        item.identifier = identifier
        item.title = L10n.tr("Edit")
        let editMenu = NSMenu(title: L10n.tr("Edit"))
        func add(_ title: String, _ action: Selector, _ key: String,
                 modifiers: NSEvent.ModifierFlags = .command) {
            let command = NSMenuItem(title: title, action: action, keyEquivalent: key)
            command.keyEquivalentModifierMask = modifiers
            // Leave target nil and autoenablesItems enabled: AppKit validates the focused
            // editor, including undo availability and secure-field copy/cut restrictions.
            editMenu.addItem(command)
        }
        add(L10n.tr("Undo"), Selector(("undo:")), "z")
        add(L10n.tr("Redo"), Selector(("redo:")), "Z", modifiers: [.command, .shift])
        editMenu.addItem(.separator())
        add(L10n.tr("Cut"), #selector(NSText.cut(_:)), "x")
        add(L10n.tr("Copy"), #selector(NSText.copy(_:)), "c")
        add(L10n.tr("Paste"), #selector(NSText.paste(_:)), "v")
        add(L10n.tr("Select All"), #selector(NSText.selectAll(_:)), "a")
        item.submenu = editMenu
        if item.menu == nil { mainMenu.addItem(item) }
        if application.mainMenu !== mainMenu { application.mainMenu = mainMenu }
    }
}
