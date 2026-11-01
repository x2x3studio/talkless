import AppKit
import ApplicationServices
import Carbon

/// Read selected text and insert text into the frontmost app. Both require Accessibility permission.
@MainActor
enum TextIO {
    private static let vKeyV: CGKeyCode = 9
    private static let vKeyC: CGKeyCode = 8

    /// What Accessibility says about the focused control's selection.
    enum SelectionReading: Equatable {
        case text(String)
        /// An explicit zero-length selection: nothing is selected, so do not try ⌘C.
        case empty
        /// The app does not report it (many web views and Electron apps): ⌘C may still work.
        case unavailable
    }

    /// Read the selection without touching the clipboard. Some apps return an empty string
    /// even when text is selected, so only an explicit zero-length range counts as `.empty`.
    static func selectionViaAX() -> SelectionReading {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unavailable }
        let target = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(target, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unavailable }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
           let text = selected as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .text(text)
        }
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0, range.length == 0 {
                return .empty
            }
        }
        return .unavailable
    }

    /// Accessibility first; ⌘C only when the app cannot report its selection.
    static func selectedText() async -> String? {
        switch selectionViaAX() {
        case .text(let text): return text
        case .empty: return nil
        case .unavailable: return await selectedTextViaCopy()
        }
    }

    /// For apps that do not expose their selection through Accessibility: ask the app to copy
    /// (its own Edit › Copy menu item when available, otherwise ⌘C sent to that app only), read
    /// the copy, and give the user's clipboard back. Returns nil when nothing was copied.
    static func selectedTextViaCopy() async -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let pid = app.processIdentifier
        let pasteboard = NSPasteboard.general
        let lease = BorrowedClipboard.borrow()
        let before = pasteboard.changeCount
        if !pressCopyMenuItem(of: pid) { postShortcut(vKeyC, to: pid) }

        var result: String?
        var wholeLine = false
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(25))
            if pasteboard.changeCount != before { break }
        }
        let after = pasteboard.changeCount
        // Exactly one change is the app's copy; more may include a copy by the user.
        if after == before + 1, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            result = pasteboard.string(forType: .string)
            wholeLine = copiedLineWithoutSelection(pasteboard)
        }
        // The app's copy is ours to undo; anything newer belongs to the user.
        if after == before + 1 { BorrowedClipboard.giveBack(lease, ifUnchangedSince: after) }
        guard !wholeLine, let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return result
    }

    /// Press the app's own Copy menu item, found by its ⌘C key equivalent so it works in any
    /// interface language. Avoids depending on the keyboard layout or a focused event tap.
    private static func pressCopyMenuItem(of pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        func value(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var result: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success ? result : nil
        }
        func children(_ element: AXUIElement) -> [AXUIElement] {
            Array(((value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []).prefix(64))
        }
        guard let bar = value(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        // Edit is conventionally the third or fourth top-level menu; look at a few, not the whole tree.
        for top in children(bar as! AXUIElement).dropFirst().prefix(4) {
            for menu in children(top) {
                for item in children(menu) {
                    guard (value(item, kAXMenuItemCmdCharAttribute) as? String)?.lowercased() == "c",
                          (value(item, kAXMenuItemCmdModifiersAttribute) as? Int) == 0,
                          (value(item, kAXEnabledAttribute) as? Bool) == true else { continue }
                    let status = AXUIElementPerformAction(item, kAXPressAction as CFString)
                    return status == .success || status == .cannotComplete
                }
            }
        }
        return false
    }

    /// VS Code and its forks copy the whole current line when nothing is selected, and mark it.
    private static func copiedLineWithoutSelection(_ pasteboard: NSPasteboard) -> Bool {
        guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType("vscode-editor-data")),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return info["isFromEmptySelection"] as? Bool == true
    }

    /// Non-content facts that can swallow a paste: the Globe key's system action (it fires when
    /// Fn is released after dictating) and whether an input method is active.
    static func insertionContext() -> [String: String] {
        let globe = switch UserDefaults(suiteName: "com.apple.HIToolbox")?.object(forKey: "AppleFnUsageType") as? Int {
        case 0: "none"
        case 1: "input_source"
        case 2: "emoji"
        case 3: "dictation"
        case nil: "default"
        default: "unknown"
        }
        var inputMethod = false
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let type = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) {
            inputMethod = (Unmanaged<CFString>.fromOpaque(type).takeUnretainedValue() as String) == (kTISTypeKeyboardInputMode as String)
        }
        return ["globe_action": globe, "input_method": String(inputMethod)]
    }

    /// Pastes run one at a time; the next waits until this one's keys are posted.
    private static var pasteQueue: Task<Void, Never>?

    /// Insert text at the cursor using the clipboard and ⌘V. Returns once ⌘V is posted; the
    /// user's clipboard comes back 400 ms later, so the next dictation never waits for it.
    static func insert(_ text: String) async {
        let previous = pasteQueue
        let task = Task { @MainActor in
            await previous?.value
            let lease = BorrowedClipboard.borrow()
            let change = BorrowedClipboard.writeTransient(text)
            // Let the clipboard write and any just-released dictation key settle first.
            try? await Task.sleep(for: .milliseconds(50))
            await postShortcut(vKeyV)
            BorrowedClipboard.giveBack(lease, ifUnchangedSince: change, after: .milliseconds(400))
        }
        pasteQueue = task
        await task.value
    }

    /// Text the user asked to keep (copy buttons, results saved for ⌘V). Ends any borrow.
    @discardableResult
    static func copyToClipboard(_ text: String) -> Bool {
        BorrowedClipboard.keep(text)
    }

    /// A complete, human-like shortcut: Command down, key down, key up, Command up, a few
    /// milliseconds apart. Some apps ignore a lone key event that only carries a Command flag.
    private static func postShortcut(_ key: CGKeyCode) async {
        for event in shortcutEvents(key) {
            event.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Copy goes to the app that owns the selection only, never through the global event stream.
    private static func postShortcut(_ key: CGKeyCode, to pid: pid_t) {
        for event in shortcutEvents(key) { event.postToPid(pid) }
    }

    private static func shortcutEvents(_ key: CGKeyCode) -> [CGEvent] {
        let command: CGKeyCode = 0x37
        return [
            SyntheticKeyboardEvents.make(key: command, down: true, flags: .maskCommand),
            SyntheticKeyboardEvents.make(key: key, down: true, flags: .maskCommand),
            SyntheticKeyboardEvents.make(key: key, down: false, flags: .maskCommand),
            SyntheticKeyboardEvents.make(key: command, down: false, flags: []),
        ].compactMap { $0 }
    }
}

/// The one place Talkless touches the general pasteboard. A borrow captures the user's
/// contents; giving back restores them only if the pasteboard still holds what Talkless (or the
/// app it asked to copy) put there, so anything the user copied meanwhile always wins.
@MainActor
enum BorrowedClipboard {
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]
    struct Lease { fileprivate let saved: Snapshot }

    /// Always the general pasteboard in the app; tests swap in a private named one.
    static var pasteboard: NSPasteboard = .general
    private static var pending: (lease: Lease, change: Int, task: Task<Void, Never>)?

    /// The user's own contents. If a previous borrow's give-back is still pending and the
    /// pasteboard still holds our temporary text, that borrow's snapshot is the user's; this
    /// borrow takes over giving it back.
    static func borrow() -> Lease {
        defer { cancelPending() }
        if let pending, pasteboard.changeCount == pending.change { return pending.lease }
        return Lease(saved: snapshot())
    }

    /// Temporary text for a paste, marked so clipboard managers do not record it.
    static func writeTransient(_ text: String) -> Int {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        pasteboard.writeObjects([item])
        return pasteboard.changeCount
    }

    static func giveBack(_ lease: Lease, ifUnchangedSince change: Int, after delay: Duration? = nil) {
        guard let delay else {
            if pasteboard.changeCount == change { restore(lease.saved) }
            return
        }
        cancelPending()
        pending = (lease, change, Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let current = pending, current.change == change else { return }
            pending = nil
            if pasteboard.changeCount == change { restore(current.lease.saved) }
        })
    }

    /// Plain text the user keeps; it ends any pending give-back.
    @discardableResult
    static func keep(_ text: String) -> Bool {
        cancelPending()
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private static func cancelPending() {
        pending?.task.cancel()
        pending = nil
    }

    private static func snapshot() -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private static func restore(_ snapshot: Snapshot) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }
        pasteboard.writeObjects(snapshot.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        })
    }
}
