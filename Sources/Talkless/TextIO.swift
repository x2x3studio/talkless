import AppKit
import ApplicationServices

/// Read selected text and insert text into the frontmost app. Both require Accessibility permission.
@MainActor
enum TextIO {
    private static let vKeyV: CGKeyCode = 9
    private static let vKeyC: CGKeyCode = 8

    /// Read selected text from the focused control through Accessibility. Return nil if unavailable (many Electron apps do not support this).
    static func selectedTextViaAX() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// Try Accessibility first, then simulate ⌘C if needed and restore the clipboard afterward.
    static func selectedText() async -> String? {
        if let text = selectedTextViaAX() { return text }
        return await selectedTextViaCopy()
    }

    /// For apps that do not expose their selection through Accessibility: simulate ⌘C, read the
    /// copy, and give the user's clipboard back. Returns nil when nothing was copied.
    static func selectedTextViaCopy() async -> String? {
        let pasteboard = NSPasteboard.general
        let lease = BorrowedClipboard.borrow()
        let before = pasteboard.changeCount
        postKey(vKeyC, flags: .maskCommand)

        var result: String?
        var wholeLine = false
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(25))
            if pasteboard.changeCount != before {
                result = pasteboard.string(forType: .string)
                wholeLine = copiedLineWithoutSelection(pasteboard)
                break
            }
        }
        // The app's copy is ours to undo; anything newer belongs to the user.
        if pasteboard.changeCount != before { BorrowedClipboard.giveBack(lease, ifUnchangedSince: pasteboard.changeCount) }
        guard !wholeLine, let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return result
    }

    /// VS Code and its forks copy the whole current line when nothing is selected, and mark it.
    private static func copiedLineWithoutSelection(_ pasteboard: NSPasteboard) -> Bool {
        guard let data = pasteboard.data(forType: NSPasteboard.PasteboardType("vscode-editor-data")),
              let info = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return info["isFromEmptySelection"] as? Bool == true
    }

    /// Insert text at the cursor using the clipboard and ⌘V. Returns once ⌘V is posted; the
    /// user's clipboard comes back 400 ms later, so the next dictation never waits for it.
    static func insert(_ text: String) async {
        let lease = BorrowedClipboard.borrow()
        let change = BorrowedClipboard.writeTransient(text)
        postKey(vKeyV, flags: .maskCommand)
        BorrowedClipboard.giveBack(lease, ifUnchangedSince: change, after: .milliseconds(400))
    }

    /// Text the user asked to keep (copy buttons, results saved for ⌘V). Ends any borrow.
    @discardableResult
    static func copyToClipboard(_ text: String) -> Bool {
        BorrowedClipboard.keep(text)
    }

    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags) {
        let down = SyntheticKeyboardEvents.make(key: key, down: true, flags: flags)
        let up = SyntheticKeyboardEvents.make(key: key, down: false, flags: flags)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
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
