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
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        localization.interfaceLanguage = .english
        defer { withExtendedLifetime(localization) {} }
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
            let expectedKeys = ["", state.translationShortcutTitle].compactMap { $0 }
            let entries = Array(menu.items.prefix(while: { !$0.isSeparatorItem }))
            check(entries.count == expectedKeys.count, "One reference row per configured shortcut")
            let rows = entries.compactMap { $0.view as? MenuContent.ShortcutRow }
            check(rows.count == entries.count, "Shortcut information uses native reference views")
            check(rows.first?.shortcutLabel.stringValue.isEmpty == true, "Dictation describes gesture and key once, without a duplicate right-hand key")
            let settingsItem = menu.items.first { $0.action == #selector(MenuTarget.openSettings) }!
            check(settingsItem.image != nil && settingsItem.image?.isTemplate == true, "Actual Settings command has a native template gear")
            let commands = menu.items.filter { !$0.isSeparatorItem && $0.view == nil }
            check(commands.count == 3 && commands.allSatisfy { $0.image?.isTemplate == true },
                  "Settings, updates and quit all have template symbols so their titles share one text edge")
            if #available(macOS 27.0, *) {
                check(commands.allSatisfy { $0.preferredImageVisibility == .visible },
                      "Commands opt into visible symbols on systems that hide menu images by default")
            }
            check(entries.allSatisfy { $0.image == nil }, "Shortcut reference rows have no icons")
            check(Set(rows.map { $0.frame.width }).count == 1, "All shortcut rows have the same full width")
            for (index, entry) in entries.enumerated() {
                check(!entry.isEnabled && entry.action == nil && entry.target == nil, "Shortcut rows are noninteractive")
                check(entry.keyEquivalent.isEmpty, "Informational shortcuts must not register duplicate equivalents")
                check(entry.toolTip?.isEmpty == false, "Explain shortcut behavior")
                let row = rows[index]
                row.layout()
                check(row.functionLabel.stringValue == entry.title && row.shortcutLabel.stringValue == expectedKeys[index], "Function on the left, shortcut on the right")
                check(row.frame.width >= 300 && row.frame.width >= row.preferredWidth, "Rows fit labels with a minimum 300-point width")
                check(row.functionLabel.frame.minX == MenuContent.textInset && row.shortcutLabel.frame.maxX == row.bounds.width - 20,
                      "Reference text starts on the command title edge; shortcuts keep the trailing inset")
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
        let fullState = MenuContent.State(alternateFinishKeyTitle: "Right Option", translationShortcutTitle: "⌃⌥T")
        let fullTitles = ["Dictation (hold Fn / Globe)", "Translate selection"] + suffix
        let idle = menu(fullState)
        check(titles(idle) == fullTitles, "Exact minimal ordering: shortcuts, settings and updates, quit")
        check(idle.items[0].toolTip?.contains("release to finish") == true, "Hold mode explains release")
        check(idle.items[1].toolTip == "Select text in another app, then press ⌃⌥T to translate it.", "Translation keeps its actual shortcut instruction")
        check((idle.items[1].view as? MenuContent.ShortcutRow)?.accessibilityHelp() == idle.items[1].toolTip, "Accessible help describes the same translation action")

        var toggleState = fullState
        toggleState.dictationKeyTitle = "Right Control"
        toggleState.holdToTalk = false
        toggleState.alternateFinishKeyTitle = "Fn / Globe"
        toggleState.polishEnabled = true
        toggleState.translationShortcutTitle = "⌃⌥⌘R"
        let toggle = menu(toggleState)
        check(titles(toggle) == ["Dictation (tap Right Control)", "Translate selection"] + suffix,
              "Custom shortcut titles and toggle mode are reflected without actions")
        check(toggle.items[0].toolTip?.contains("press again to finish") == true, "Toggle mode explains second tap")
        check(toggle.items[1].toolTip == "Select text in another app, then press ⌃⌥⌘R to translate it.", "Customized translation is independent of polish settings")
        check(titles(menu()) == ["Dictation (hold Fn / Globe)"] + suffix, "Disabled optional shortcuts leave no extra rows or separators")
        check(titles(menu(.init(translationShortcutTitle: "⌃⌥T"))) == ["Dictation (hold Fn / Globe)", "Translate selection"] + suffix,
              "Translation is independent of alternate finish")
        check(titles(menu(.init(alternateFinishKeyTitle: "Right Option"))) == ["Dictation (hold Fn / Globe)"] + suffix,
              "Configured AI polishing shortcut is deliberately absent from the menu")

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
        check(titles(idle) == ["Dictation (hold Fn / Globe)"] + suffix, "Rebuilding replaces stale rows and retains an unavailable update entry")
        let unavailable = idle.items.first { $0.title == "Check for Updates…" }!
        check(!unavailable.isEnabled && unavailable.action == nil && unavailable.target == nil, "Missing updater is noninteractive")
        check(unavailable.toolTip == "Updates are not configured for this build.", "Missing updater explains why")
        for language in [InterfaceLanguage.english, .simplifiedChinese] {
            localization.interfaceLanguage = language
            for enabled in [false, true] {
                for alternate in [nil] + TriggerKey.allCases.map({ Optional($0.title) }) {
                    let state = MenuContent.State(alternateFinishKeyTitle: alternate, polishEnabled: enabled,
                                                  translationShortcutTitle: "⌃⌥T")
                    let rendered = menu(state)
                    check(rendered.items.count == 7, "Menu stays minimal regardless of polish state and binding")
                    check(!rendered.items.contains { $0.title == L10n.tr("Use AI polishing") || $0.title == L10n.tr("Skip AI polishing") },
                          "Neither AI polishing action appears in either language")
                }
            }
        }
        for language in [InterfaceLanguage.english, .simplifiedChinese] {
            localization.interfaceLanguage = language
            for key in TriggerKey.allCases {
                for mode in RecordingGestureMode.allCases {
                    let state = MenuContent.State(dictationKeyTitle: key.title, holdToTalk: mode == .hold,
                                                  alternateFinishKeyTitle: TriggerKey.rightCommand.title,
                                                  translationShortcutTitle: "⌃⌥⌘R")
                    let rendered = menu(state)
                    let expected: String
                    if language == .english {
                        expected = "Dictation (\(mode == .hold ? "hold" : "tap") \(key.title))"
                    } else {
                        expected = "\u{8BED}\u{97F3}\u{8F93}\u{5165}（\(mode == .hold ? "\u{957F}\u{6309}" : "\u{5355}\u{51FB}")\(key.title)）"
                    }
                    check(rendered.items[0].title == expected, "Each language, key and mode produces one descriptive dictation title")
                    check(rendered.items[0].toolTip?.contains(key.title) == true, "Instructions use the same configured key")
                    check(mode.title == (language == .english
                        ? (mode == .hold ? "Hold to dictate" : "Tap to dictate")
                        : (mode == .hold ? "\u{957F}\u{6309}\u{8F93}\u{5165}" : "\u{5355}\u{51FB}\u{8F93}\u{5165}")),
                          "Gesture names describe input, not toggling")
                }
            }
        }
        localization.interfaceLanguage = .english
        print("PASS \(assertions) native menu ordering, informational shortcuts, updater states, and target/action assertions")

        if let index = CommandLine.arguments.firstIndex(of: "--snapshots"),
           CommandLine.arguments.indices.contains(index + 1) {
            let output = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            try! FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let window = NSWindow(contentRect: NSRect(x: 180, y: 250, width: 440, height: 360),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Talkless — synthetic menu preview"
            window.appearance = NSAppearance(named: .aqua)
            window.orderFrontRegardless()
            for language in [InterfaceLanguage.simplifiedChinese, .english] {
                localization.interfaceLanguage = language
                for mode in RecordingGestureMode.allCases {
                    let state = MenuContent.State(dictationKeyTitle: TriggerKey.rightOption.title,
                                                  holdToTalk: mode == .hold,
                                                  alternateFinishKeyTitle: TriggerKey.rightCommand.title,
                                                  polishEnabled: mode == .hold,
                                                  translationShortcutTitle: "⌃⌥⌘R")
                    let nativeMenu = menu(state)
                    nativeMenu.items.first { $0.action == #selector(MenuTarget.updates) }?.title = L10n.tr("Check for Updates…")
                    let name = "menu-\(language == .english ? "en" : "zh")-\(mode.rawValue)"
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        guard let menuWindow = NSApplication.shared.windows.first(where: {
                            $0.isVisible && $0 !== window && $0.className.contains("Menu")
                        }), let content = menuWindow.contentView,
                           let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                            preconditionFailure("Native menu window was not available for \(name)")
                        }
                        content.cacheDisplay(in: content.bounds, to: bitmap)
                        let png = bitmap.representation(using: .png, properties: [:])!
                        precondition(png.count > 2_000, "Snapshot contains native menu glyphs")
                        try! png.write(to: output.appendingPathComponent("\(name).png"))
                        nativeMenu.cancelTracking()
                    }
                    nativeMenu.popUp(positioning: nil, at: NSPoint(x: 20, y: 310), in: window.contentView)
                }
            }
            window.orderOut(nil)
            print("Rendered four production native menus at \(output.path)")
        }

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
