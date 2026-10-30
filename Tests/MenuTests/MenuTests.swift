import AppKit

@MainActor
private final class MenuTarget: NSObject {
    var calls: [String] = []
    var previewMenu: NSMenu?

    @objc func openMenu(_ sender: NSButton) {
        previewMenu?.popUp(positioning: nil, at: NSPoint(x: sender.frame.minX, y: sender.frame.minY), in: sender.superview)
    }
    @objc func openSettings() { calls.append("settings") }
    @objc func updates() { calls.append("updates") }
    @objc func quit() { calls.append("quit") }

    var actions: MenuContent.Actions {
        .init(openSettings: #selector(openSettings), quit: #selector(quit))
    }
}

@main
struct MenuTests {
    @MainActor private static var previewWindow: NSWindow?
    @MainActor private static let target = MenuTarget()
    @MainActor private static let updater = MenuTarget()

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            precondition(condition(), message)
        }
        func menu(_ state: MenuContent.State = .init(), updatesEnabled: Bool = true) -> NSMenu {
            let menu = NSMenu()
            let update = NSMenuItem(title: "Check for Updates…", action: #selector(MenuTarget.updates), keyEquivalent: "")
            update.target = updater
            update.isEnabled = updatesEnabled
            update.toolTip = updatesEnabled ? nil : "Updates are paused during dictation."
            MenuContent.populate(menu, state: state, target: target, actions: target.actions, updateItem: update)
            menu.update()
            check(!menu.autoenablesItems, "Native validation must not override explicit item states")
            check(menu.items.contains { $0 === update }, "Keep the exact updater-owned item")
            check(update.target === updater && update.action == #selector(MenuTarget.updates), "Keep the updater target and selector")
            check(update.isEnabled == updatesEnabled, "Preserve the updater enabled state after native validation")
            check(update.toolTip == (updatesEnabled ? nil : "Updates are paused during dictation."), "Keep the updater explanation")
            let expectedKeys = [state.dictationKeyTitle, state.alternateFinishKeyTitle, state.translationShortcutTitle].compactMap { $0 }
            let entries = Array(menu.items.prefix(while: { !$0.isSeparatorItem }))
            check(entries.count == expectedKeys.count, "One reference row per configured shortcut")
            let rows = entries.compactMap { $0.view as? MenuContent.ShortcutRow }
            check(rows.count == entries.count, "Shortcut information uses native two-column views")
            check(Set(rows.map { $0.frame.width }).count == 1, "All shortcut rows have the same full width")
            for (index, entry) in entries.enumerated() {
                check(!entry.isEnabled && entry.action == nil && entry.target == nil, "Shortcut rows are noninteractive")
                check(entry.keyEquivalent.isEmpty, "Informational shortcuts must not register duplicate equivalents")
                check(entry.toolTip?.isEmpty == false, "Explain shortcut behavior")
                let row = rows[index]
                row.layout()
                check(row.functionLabel.stringValue == entry.title && row.shortcutLabel.stringValue == expectedKeys[index], "Function on the left, shortcut on the right")
                check(row.frame.width >= 300 && row.frame.width >= row.preferredWidth, "Rows fit labels with a minimum 300-point width")
                check(row.functionLabel.frame.minX == 20 && row.shortcutLabel.frame.maxX == row.bounds.width - 20, "Align the columns with equal outer insets")
                check(row.functionLabel.frame.maxX < row.shortcutLabel.frame.minX && row.shortcutLabel.alignment == .right, "Columns have a clear gap and right-aligned shortcuts")
                check(row.accessibilityLabel() == entry.title && row.accessibilityValue() as? String == expectedKeys[index], "Accessibility preserves function and shortcut")
                check(row.hitTest(.zero) == nil, "Custom informational views cannot intercept clicks")
                check(row.functionLabel.textColor == .labelColor, "Informational text is readable rather than disabled-gray")
            }
            return menu
        }
        func titles(_ menu: NSMenu) -> [String] {
            menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        }
        let suffix = ["—", "Settings…", "Check for Updates…", "—", "Quit Talkless"]
        let fullState = MenuContent.State(alternateFinishKeyTitle: "Right Option ⌥", translationShortcutTitle: "⌃⌥T")
        let fullTitles = ["Dictation (hold)", "Alternate finish", "Translate selection"] + suffix
        let idle = menu(fullState)
        check(titles(idle) == fullTitles, "Exact minimal ordering: shortcuts, settings and updates, quit")
        check(idle.items[0].toolTip?.contains("release to finish") == true, "Hold mode explains release")
        check(idle.items[1].toolTip?.contains("AI is currently off by default") == true, "Alternate finish explains the saved AI default")
        check(idle.items[1].toolTip?.contains("from the start of the recording") == true, "Alternate finish uses the session-start setting, not a live preference")

        var toggleState = fullState
        toggleState.dictationKeyTitle = "Right Control ⌃"
        toggleState.holdToTalk = false
        toggleState.alternateFinishKeyTitle = "Fn / Globe"
        toggleState.polishEnabled = true
        toggleState.translationShortcutTitle = "⌃⌥⌘R"
        let toggle = menu(toggleState)
        check(titles(toggle) == ["Dictation (toggle)", "Alternate finish", "Translate selection"] + suffix,
              "Custom shortcut titles and toggle mode are reflected without actions")
        check(toggle.items[0].toolTip?.contains("tap again to finish") == true, "Toggle mode explains second tap")
        check(toggle.items[1].toolTip?.contains("alternate finish skips AI") == true, "AI-on default explains the alternate purpose")
        check(titles(menu()) == ["Dictation (hold)"] + suffix, "Disabled optional shortcuts leave no extra rows or separators")
        check(titles(menu(.init(translationShortcutTitle: "⌃⌥T"))) == ["Dictation (hold)", "Translate selection"] + suffix,
              "Translation is independent of alternate finish")
        check(titles(menu(.init(alternateFinishKeyTitle: "Right Option ⌥"))) == ["Dictation (hold)", "Alternate finish"] + suffix,
              "Alternate finish is independent of translation")

        // The builder intentionally has no recording phase or permission state. Only the updater
        // changes availability while recording/processing; no Start/Stop/Cancel or setup actions appear.
        for phase in ["recording", "processing"] {
            let busy = menu(fullState, updatesEnabled: false)
            check(titles(busy) == fullTitles, "\(phase) keeps the exact same minimal rows")
            check(busy.items.filter { $0.isEnabled }.map(\.title) == ["Settings…", "Quit Talkless"], "Only settings and quit remain enabled when updates are paused")
        }
        check(idle.items.filter { $0.isEnabled }.map(\.title) == ["Settings…", "Check for Updates…", "Quit Talkless"], "Only the three intended actions are enabled")
        check(target.calls.isEmpty && updater.calls.isEmpty, "Constructing and validating menus has no action side effects")
        for (title, key, selector, expected) in [
            ("Settings…", ",", #selector(MenuTarget.openSettings), "settings"),
            ("Quit Talkless", "q", #selector(MenuTarget.quit), "quit")
        ] {
            let entry = idle.items.first { $0.title == title }!
            check(entry.target === target && entry.action == selector, "Correct target and selector for \(title)")
            check(entry.keyEquivalent == key && entry.keyEquivalentModifierMask == .command, "Native Command shortcut for \(title)")
            idle.performActionForItem(at: idle.index(of: entry))
            check(target.calls.last == expected, "Native menu dispatch reaches \(expected)")
        }
        let update = idle.items.first { $0.title == "Check for Updates…" }!
        idle.performActionForItem(at: idle.index(of: update))
        check(updater.calls == ["updates"] && target.calls == ["settings", "quit"], "Updates dispatch to their own owner")

        MenuContent.populate(idle, state: .init(), target: target, actions: target.actions, updateItem: nil)
        idle.update()
        check(titles(idle) == ["Dictation (hold)"] + suffix, "Rebuilding replaces stale rows and retains an unavailable update entry")
        let unavailable = idle.items.first { $0.title == "Check for Updates…" }!
        check(!unavailable.isEnabled && unavailable.action == nil && unavailable.target == nil, "Missing updater is noninteractive")
        check(unavailable.toolTip == "Updates are not configured for this build.", "Missing updater explains why")
        print("PASS \(assertions) native menu ordering, informational shortcuts, updater states, and target/action assertions")

        // Screenshot fixture: exact production NSMenu in a regular visible window. No production
        // controller, credentials, microphone, history, global hotkey, updater, or selected-text read.
        if let index = CommandLine.arguments.firstIndex(of: "--preview") {
            let name = CommandLine.arguments.indices.contains(index + 1) ? CommandLine.arguments[index + 1] : "default"
            let state: MenuContent.State
            switch name {
            case "toggle": state = toggleState
            case "minimal": state = .init()
            default: state = fullState
            }
            target.previewMenu = menu(state, updatesEnabled: name != "busy")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 360),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Talkless menu — local preview"
            window.isReleasedWhenClosed = false
            let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 360))
            let description = NSTextField(labelWithString: "Synthetic \(name) settings · Native NSMenu")
            description.frame = NSRect(x: 24, y: 312, width: 392, height: 24)
            content.addSubview(description)
            let button = NSButton(title: "Open menu", target: target, action: #selector(MenuTarget.openMenu(_:)))
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 24, y: 260, width: 120, height: 32)
            content.addSubview(button)
            window.contentView = content
            window.center()
            previewWindow = window
            app.setActivationPolicy(.regular)
            app.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            print("Native menu preview ready: \(name). Click Open menu. Actions have no side effects; use Ctrl-C to exit.")
            app.run()
        }
    }
}
