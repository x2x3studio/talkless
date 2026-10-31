import AppKit

@MainActor
private final class MenuTarget: NSObject {
    var calls: [String] = []
    var previewMenu: NSMenu?

    @objc func openMenu(_ sender: NSButton) {
        previewMenu?.popUp(positioning: nil, at: NSPoint(x: sender.frame.minX, y: sender.frame.minY), in: sender.superview)
    }
    @objc func dictate() { calls.append("dictate") }
    @objc func translate() { calls.append("translate") }
    @objc func openSettings() { calls.append("settings") }
    @objc func updates() { calls.append("updates") }
    @objc func quit() { calls.append("quit") }

    var actions: MenuContent.Actions {
        .init(dictate: #selector(dictate), translate: #selector(translate), openSettings: #selector(openSettings), quit: #selector(quit))
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
            let rows = menu.items.filter { !$0.isSeparatorItem }
            check(rows.allSatisfy { $0.view == nil }, "Every row is a native menu item")
            check(rows.allSatisfy { $0.image?.isTemplate == true }, "Every row has a template symbol so all titles share one text edge")
            if #available(macOS 27.0, *) {
                check(rows.allSatisfy { $0.preferredImageVisibility == .visible },
                      "Rows opt into visible symbols on systems that hide menu images by default")
            }
            for entry in rows.prefix(2) {
                check(entry.keyEquivalent.isEmpty, "Global shortcuts are shown as subtitles, never registered as menu equivalents")
            }
            return menu
        }
        func titles(_ menu: NSMenu) -> [String] {
            menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        }
        let suffix = ["—", "Settings…", "Check for Updates…", "—", "Quit Talkless"]
        let fullState = MenuContent.State(alternateFinishKeyTitle: "Right Option", translationShortcutTitle: "⌃⌥T")
        let fullTitles = ["Start Dictation", "Translate selection"] + suffix
        let idle = menu(fullState)
        check(titles(idle) == fullTitles, "Exact ordering: dictation and translation commands, settings and updates, quit")
        check(idle.items[0].subtitle == "Hold Fn / Globe" && idle.items[0].toolTip?.contains("release to finish") == true,
              "Hold mode shows its key as a subtitle and explains release")
        check(idle.items[1].subtitle == "⌃⌥T" && idle.items[1].toolTip == "Select text in another app, then press ⌃⌥T to translate it.",
              "Translation shows its actual shortcut")
        check(idle.items.filter { $0.isEnabled }.map(\.title) == ["Start Dictation", "Translate selection", "Settings…", "Check for Updates…", "Quit Talkless"],
              "Both shortcut rows are now clickable commands")

        var toggleState = fullState
        toggleState.dictationKeyTitle = "Right Control"
        toggleState.holdToTalk = false
        toggleState.translationShortcutTitle = "⌃⌥⌘R"
        let toggle = menu(toggleState)
        check(toggle.items[0].subtitle == "Tap Right Control" && toggle.items[0].toolTip?.contains("press again to finish") == true,
              "Toggle mode shows its key and explains the second tap")
        let noShortcut = menu(.init())
        check(titles(noShortcut) == fullTitles && noShortcut.items[1].subtitle == nil && noShortcut.items[1].isEnabled,
              "Translation stays available from the menu without a global shortcut")
        check(titles(menu(.init(alternateFinishKeyTitle: "Right Option"))) == fullTitles,
              "Configured AI polishing shortcut is deliberately absent from the menu")

        var recordingState = fullState
        recordingState.dictation = .recording
        let recording = menu(recordingState, updatesEnabled: false)
        check(titles(recording) == ["Finish Dictation", "Translate selection"] + suffix, "Recording offers finishing from the menu")
        check(recording.items[0].isEnabled && recording.items[0].action == #selector(MenuTarget.dictate), "Finish uses the same dictation action")
        check(recording.items[0].subtitle == "Press Esc to cancel", "Recording explains cancel")
        var processingState = fullState
        processingState.dictation = .processing
        let processing = menu(processingState, updatesEnabled: false)
        check(titles(processing) == ["Recognizing", "Translate selection"] + suffix && !processing.items[0].isEnabled,
              "Processing shows status and cannot start another dictation")
        check(processing.items.filter { $0.isEnabled }.map(\.title) == ["Translate selection", "Settings…", "Quit Talkless"],
              "Updates pause while busy")
        check(target.calls.isEmpty && updater.calls.isEmpty, "Constructing and validating menus has no action side effects")
        for (title, selector, expected) in [
            ("Start Dictation", #selector(MenuTarget.dictate), "dictate"),
            ("Translate selection", #selector(MenuTarget.translate), "translate"),
            ("Settings…", #selector(MenuTarget.openSettings), "settings"),
            ("Quit Talkless", #selector(MenuTarget.quit), "quit"),
        ] {
            let entry = idle.items.first { $0.title == title }!
            check(entry.target === target && entry.action == selector, "Correct target and selector for \(title)")
            idle.performActionForItem(at: idle.index(of: entry))
            check(target.calls.last == expected, "Native menu dispatch reaches \(expected)")
        }
        for (title, key) in [("Settings…", ","), ("Quit Talkless", "q")] {
            let entry = idle.items.first { $0.title == title }!
            check(entry.keyEquivalent == key && entry.keyEquivalentModifierMask == .command, "Native Command shortcut for \(title)")
        }
        let update = idle.items.first { $0.title == "Check for Updates…" }!
        idle.performActionForItem(at: idle.index(of: update))
        check(updater.calls == ["updates"] && target.calls == ["dictate", "translate", "settings", "quit"], "Updates dispatch to their own owner")

        MenuContent.populate(idle, state: .init(), target: target, actions: target.actions, updateItem: nil)
        idle.update()
        check(titles(idle) == fullTitles, "Rebuilding replaces stale rows and retains an unavailable update entry")
        let unavailable = idle.items.first { $0.title == "Check for Updates…" }!
        check(!unavailable.isEnabled && unavailable.action == nil && unavailable.target == nil, "Missing updater is noninteractive")
        check(unavailable.toolTip == "Updates are not configured for this build.", "Missing updater explains why")
        for language in [InterfaceLanguage.english, .simplifiedChinese] {
            localization.interfaceLanguage = language
            for key in TriggerKey.allCases {
                for mode in RecordingGestureMode.allCases {
                    let rendered = menu(MenuContent.State(dictationKeyTitle: key.title, holdToTalk: mode == .hold,
                                                          translationShortcutTitle: "⌃⌥⌘R"))
                    check(rendered.items.count == 7, "Menu stays minimal for every key and mode")
                    let expected: String
                    if language == .english {
                        expected = "\(mode == .hold ? "Hold" : "Tap") \(key.title)"
                    } else {
                        expected = "\(mode == .hold ? "\u{957F}\u{6309}" : "\u{5355}\u{51FB}")\(key.title)"
                    }
                    check(rendered.items[0].title == (language == .english ? "Start Dictation" : "\u{5F00}\u{59CB}\u{8BED}\u{97F3}\u{8F93}\u{5165}"),
                          "Localized start command")
                    check(rendered.items[0].subtitle == expected, "Each language, key and mode produces one gesture subtitle")
                    check(rendered.items[0].toolTip?.contains(key.title) == true, "Instructions use the same configured key")
                }
            }
        }
        localization.interfaceLanguage = .english
        print("PASS \(assertions) native menu ordering, clickable dictation/translation commands, busy states, updater states, and target/action assertions")

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
                for mode in ["hold", "toggle", "recording"] {
                    let state = MenuContent.State(dictationKeyTitle: TriggerKey.rightOption.title,
                                                  holdToTalk: mode != "toggle",
                                                  alternateFinishKeyTitle: TriggerKey.rightCommand.title,
                                                  polishEnabled: mode == "hold",
                                                  translationShortcutTitle: "⌃⌥⌘R",
                                                  dictation: mode == "recording" ? .recording : .idle)
                    let nativeMenu = menu(state)
                    nativeMenu.items.first { $0.action == #selector(MenuTarget.updates) }?.title = L10n.tr("Check for Updates…")
                    let name = "menu-\(language == .english ? "en" : "zh")-\(mode)"
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
            print("Rendered six production native menus at \(output.path)")
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
