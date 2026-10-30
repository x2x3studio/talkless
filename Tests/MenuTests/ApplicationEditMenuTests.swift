import AppKit
import ObjectiveC

/// Every clipboard action is redirected to a private, synthetic pasteboard.
@MainActor
private final class TestEditor: NSTextView {
    let pasteboard = NSPasteboard.withUniqueName()
    var pasteCount = 0

    override func paste(_ sender: Any?) {
        pasteCount += 1
        _ = readSelection(from: pasteboard)
    }

    override func copy(_ sender: Any?) {
        pasteboard.clearContents()
        pasteboard.setString((string as NSString).substring(with: selectedRange()), forType: .string)
    }

    override func cut(_ sender: Any?) {
        copy(sender)
        insertText("", replacementRange: selectedRange())
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(paste(_:)) { return isEditable && pasteboard.string(forType: .string) != nil }
        return super.validateUserInterfaceItem(item)
    }
}

@MainActor
private final class EditorDelegate: NSObject, NSWindowDelegate {
    let editor = TestEditor()
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? { editor }
}

/// A deterministic key window even when CI/the current desktop refuses activation.
@MainActor
private final class TestApplication: NSApplication {
    var testWindow: NSWindow?
    override var keyWindow: NSWindow? { testWindow ?? super.keyWindow }
}

@main
struct ApplicationEditMenuTests {
    @MainActor static func main() {
        let app = TestApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            runTests()
            exit(0)
        }
        app.run()
    }

    @MainActor static func runTests() {
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        let app = NSApplication.shared
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            guard condition() else { fatalError("FAIL: \(message)") }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Synthetic editing regression"
        window.isReleasedWhenClosed = false
        let delegate = EditorDelegate()
        window.delegate = delegate
        let field = NSTextField(frame: NSRect(x: 20, y: 100, width: 420, height: 26))
        let secure = NSSecureTextField(frame: NSRect(x: 20, y: 50, width: 420, height: 26))
        window.contentView!.addSubview(field)
        window.contentView!.addSubview(secure)
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        (app as! TestApplication).testWindow = window
        func event(_ key: String, _ code: UInt16, shift: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero,
                            modifierFlags: shift ? [.command, .shift] : .command, timestamp: 0,
                            windowNumber: window.windowNumber, context: nil, characters: shift ? key.uppercased() : key,
                            charactersIgnoringModifiers: shift ? key.uppercased() : key, isARepeat: false, keyCode: code)!
        }
        let paste = event("v", 9)
        defer { delegate.editor.pasteboard.releaseGlobally(); window.orderOut(nil) }
        field.stringValue = "before"
        window.makeFirstResponder(field)
        let editor = delegate.editor
        editor.allowsUndo = true
        check(window.firstResponder === editor, "native text field uses injected field editor")
        editor.pasteboard.setString("https://synthetic.invalid/v1", forType: .string)
        editor.selectAll(nil)
        app.mainMenu = nil
        check(!window.performKeyEquivalent(with: paste), "without main menu the text field does not handle Cmd+V")
        check(editor.string == "before", "reproduced missing keyboard paste")
        check(app.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil), "context-menu equivalent paste action resolves")
        check(editor.string == "https://synthetic.invalid/v1", "direct paste works without a main menu")
        ApplicationEditMenu.install()
        let menu = app.mainMenu!
        let edit = menu.items.last!.submenu!
        check(edit.autoenablesItems, "native automatic validation is enabled")
        // macOS may append AutoFill, Dictation and Emoji commands of its own.
        let commands = Array(edit.items.prefix(7)).filter { !$0.isSeparatorItem }
        check(commands.allSatisfy { $0.target == nil }, "all editing targets use responder chain")
        check(commands.compactMap { $0.action.map(NSStringFromSelector) }
              == ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"], "standard selectors only")
        ApplicationEditMenu.install()
        check(app.mainMenu === menu && menu.items.count == 2, "installation does not duplicate menus")
        check(window.firstResponder === editor, "reinstallation preserves responder")
        editor.selectAll(nil)
        editor.pasteboard.clearContents()
        editor.pasteboard.setString("synthetic replacement", forType: .string)
        check(menu.performKeyEquivalent(with: paste), "Cmd+V dispatches through the installed main menu")
        check(editor.string == "synthetic replacement", "Cmd+V replaces selected URL text")
        check(menu.performKeyEquivalent(with: event("a", 0)), "Cmd+A dispatches")
        check(editor.selectedRange().length == editor.string.utf16.count, "Cmd+A selects all")
        check(menu.performKeyEquivalent(with: event("c", 8)), "Cmd+C dispatches")
        check(editor.pasteboard.string(forType: .string) == "synthetic replacement", "copy uses selected text")
        check(menu.performKeyEquivalent(with: event("x", 7)), "Cmd+X dispatches")
        check(editor.string.isEmpty, "cut removes selected text")
        check(menu.performKeyEquivalent(with: paste), "paste after cut")
        check(editor.string == "synthetic replacement", "paste restores synthetic text")
        editor.undoManager?.removeAllActions()
        editor.breakUndoCoalescing()
        editor.undoManager?.beginUndoGrouping()
        editor.selectAll(nil)
        editor.insertText("undo fixture", replacementRange: editor.selectedRange())
        editor.undoManager?.endUndoGrouping()
        check(menu.performKeyEquivalent(with: event("z", 6)), "Cmd+Z dispatches undo")
        check(editor.string == "synthetic replacement", "undo restores text")
        check(menu.performKeyEquivalent(with: event("z", 6, shift: true)), "Shift+Cmd+Z dispatches redo")
        check(editor.string == "undo fixture", "redo restores edit")
        secure.stringValue = "synthetic-key"
        window.makeFirstResponder(secure)
        guard let secureEditor = window.firstResponder as? NSTextView else { fatalError("No secure field editor") }
        // Secure fields require Apple's own field editor. Override only this test
        // instance's paste action to use the named board, retaining native secure validation.
        let originalClass: AnyClass = object_getClass(secureEditor)!
        let testClass: AnyClass = objc_allocateClassPair(originalClass, "TalklessSyntheticSecureEditor", 0)!
        let pasteBlock: @convention(block) (NSTextView, AnyObject?) -> Void = { view, _ in
            MainActor.assumeIsolated { _ = view.readSelection(from: editor.pasteboard) }
        }
        class_addMethod(testClass, #selector(NSText.paste(_:)), imp_implementationWithBlock(pasteBlock), "v@:@")
        objc_registerClassPair(testClass)
        object_setClass(secureEditor, testClass)
        defer { object_setClass(secureEditor, originalClass) }
        secureEditor.selectAll(nil)
        // Validation of native paste can inspect the general clipboard; dispatch the
        // exact installed key equivalent without that check in this isolated test only.
        let currentEdit = menu.items.last!.submenu!
        currentEdit.autoenablesItems = false
        currentEdit.items.first { $0.action == #selector(NSText.paste(_:)) }!.isEnabled = true
        check(menu.performKeyEquivalent(with: paste), "Cmd+V dispatches for native secure field")
        check(secureEditor.string == "synthetic replacement", "secure field receives synthetic paste")
        window.makeFirstResponder(nil)
        check(secure.stringValue == "synthetic replacement", "secure control commits pasted value")
        localization.interfaceLanguage = .simplifiedChinese
        ApplicationEditMenu.install()
        check(menu.items.last!.title == "\u{7F16}\u{8F91}", "menu can refresh language without duplication")
        check(menu.items.count == 2, "localized reinstall remains idempotent")
        print("PASS: \(assertions) native application editing checks; general clipboard and user preferences untouched")
    }
}
