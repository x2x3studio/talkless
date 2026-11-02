import AppKit
import ApplicationServices
import Carbon
import Synchronization

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
        return await selectedTextViaCopy(
            isTargetCurrent: { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid },
            requestCopy: { if !pressCopyMenuItem(of: pid) { postShortcut(vKeyC, to: pid) } }
        )
    }

    /// Injectable copy action for tests; all clipboard transactions share the insertion queue.
    static func selectedTextViaCopy(
        isTargetCurrent: @escaping @MainActor () -> Bool,
        requestCopy: @escaping @MainActor () -> Void,
        wait: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> String? {
        await withClipboardOperation(cancelledValue: nil) { cancellation in
            // A timed-out paste still owns the clipboard. Selection acquisition must not
            // consume its lazy data or replace text that a slow recipient may still request.
            guard BorrowedClipboard.canBorrow, isTargetCurrent(), !cancellation.isCancelled else { return nil }
            let pasteboard = BorrowedClipboard.pasteboard
            guard let lease = BorrowedClipboard.borrow() else { return nil }
            let before = pasteboard.changeCount
            requestCopy()

            var result: String?
            var wholeLine = false
            // Once Copy was requested, finish observing/returning the borrowed clipboard
            // even if the caller cancels. Otherwise a late copy could corrupt the next paste.
            for _ in 0..<20 {
                await wait(.milliseconds(25))
                if pasteboard.changeCount != before { break }
            }
            let after = pasteboard.changeCount
            // Exactly one change is the app's copy; more may include a copy by the user.
            if after == before + 1, isTargetCurrent(), !cancellation.isCancelled {
                result = pasteboard.string(forType: .string)
                wholeLine = copiedLineWithoutSelection(pasteboard)
            }
            // The app's copy is ours to undo; anything newer belongs to the user.
            if after == before + 1 { BorrowedClipboard.giveBack(lease, ifUnchangedSince: after) }
            guard !wholeLine, let result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return result
        }
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

    /// Copy acquisition and insertion must never overlap their borrowed clipboard contents.
    private static var clipboardQueue: Task<Void, Never>?

    /// A caller's cancellation must reach its queued operation, not just its await of the task.
    /// The handler can run off the main actor, so this flag is synchronized.
    private final class ClipboardCancellation: Sendable {
        private let cancelled = Mutex(false)
        var isCancelled: Bool { cancelled.withLock { $0 } }
        func cancel() { cancelled.withLock { $0 = true } }
    }

    private static func withClipboardOperation<Result: Sendable>(
        cancelledValue: Result,
        _ operation: @escaping @MainActor (ClipboardCancellation) async -> Result
    ) async -> Result {
        let cancellation = ClipboardCancellation()
        return await withTaskCancellationHandler {
            let previous = clipboardQueue
            let task = Task { @MainActor in
                await previous?.value
                guard !cancellation.isCancelled else { return cancelledValue }
                return await operation(cancellation)
            }
            clipboardQueue = Task { @MainActor in _ = await task.value }
            return await task.value
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// `.submitted` means lazy clipboard data was requested after posting began, NOT that
    /// the target inserted it. Clipboard managers can also request data: this is a heuristic.
    @discardableResult
    static func insert(_ text: String, targetPID: pid_t? = nil) async -> PasteOutcome {
        guard let pid = targetPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return .targetChanged }
        return await insert(text,
                            isTargetCurrent: { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid },
                            sendPaste: { await postPaste(to: pid) })
    }

    /// The queue covers writing, posting, observing a request, and finishing the lease.
    /// Tests inject all app interaction and may advance the bounded wait without real time.
    @discardableResult
    static func insert(_ text: String,
                       isTargetCurrent: @escaping @MainActor () -> Bool,
                       wait: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                       sendPaste: @escaping @MainActor () async -> Void) async -> PasteOutcome {
        await withClipboardOperation(cancelledValue: .cancelled) { cancellation in
            guard BorrowedClipboard.canBorrow else { return .blocked }
            guard isTargetCurrent() else { return .targetChanged }
            guard let lease = BorrowedClipboard.borrow() else { return .clipboardChanged }
            guard let paste = BorrowedClipboard.beginPaste(text, lease: lease) else { return .writeFailed }
            // Let the clipboard write and any just-released dictation key settle first.
            await wait(.milliseconds(50))
            guard BorrowedClipboard.owns(paste) else { return .clipboardChanged }
            if cancellation.isCancelled || !isTargetCurrent() {
                BorrowedClipboard.finish(paste)
                return cancellation.isCancelled ? .cancelled : .targetChanged
            }
            paste.provider.arm()
            // Once key posting starts, complete the shortcut, especially Command-up.
            // Every exit after this point must preserve the text unless a request was observed.
            await sendPaste()
            for _ in 0..<120 {
                guard BorrowedClipboard.owns(paste) else { return .clipboardChanged }
                guard !cancellation.isCancelled else { return .cancelled }
                guard isTargetCurrent() else { return .targetChanged }
                if paste.provider.wasRequested {
                    // A request is not insertion confirmation. A short grace lets the
                    // requesting app finish copying data before returning the user's items.
                    await wait(.milliseconds(100))
                    guard BorrowedClipboard.owns(paste) else { return .clipboardChanged }
                    guard !cancellation.isCancelled else { return .cancelled }
                    guard isTargetCurrent() else { return .targetChanged }
                    BorrowedClipboard.finish(paste)
                    return .submitted
                }
                await wait(.milliseconds(25))
            }
            guard BorrowedClipboard.owns(paste) else { return .clipboardChanged }
            guard !cancellation.isCancelled else { return .cancelled }
            guard isTargetCurrent() else { return .targetChanged }
            // No timer restores this lease, even if a callback arrives later. It remains
            // blocked until ownership changes or the user explicitly keeps new clipboard text.
            return .unconfirmed
        }
    }

    /// Text the user asked to keep (copy buttons, results saved for ⌘V). Ends any borrow.
    @discardableResult
    static func copyToClipboard(_ text: String) -> Bool {
        BorrowedClipboard.keep(text)
    }

    /// A complete, human-like shortcut: Command down, key down, key up, Command up, a few
    /// milliseconds apart. Some apps ignore a lone key event that only carries a Command flag.
    private static func postPaste(to pid: pid_t) async {
        for event in shortcutEvents(vKeyV) {
            // PID-directed delivery cannot leak the remaining shortcut into another app if
            // focus changes between events. The transaction also checks focus on both sides.
            event.postToPid(pid)
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

/// The callback may arrive on any thread. It only supplies its own item, never reads or
/// changes the pasteboard, and never schedules a restore. Invalidated providers cannot signal
/// a newer transaction. Requests before key posting are deliberately not counted.
final class PasteDataProvider: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    private struct State {
        var valid = true
        var armed = false
        var requested = false
    }
    private let state = Mutex(State())
    private let text: String

    init(_ text: String) { self.text = text }
    var wasRequested: Bool { state.withLock { $0.valid && $0.requested } }
    func arm() { state.withLock { $0.armed = true } }
    func invalidate() { state.withLock { $0.valid = false } }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        state.withLock { state in
            guard state.valid, type == .string else { return }
            if item.setString(text, forType: type), state.armed { state.requested = true }
        }
    }
}

/// The one place Talkless touches the general pasteboard. An unresolved paste keeps its
/// original multi-item snapshot and blocks both new pastes and automatic selection copies.
@MainActor
enum BorrowedClipboard {
    typealias Snapshot = [[NSPasteboard.PasteboardType: Data]]
    struct Lease {
        fileprivate let saved: Snapshot
        fileprivate let board: NSPasteboard
        fileprivate let change: Int
    }
    struct Paste {
        fileprivate let token = UUID()
        fileprivate let lease: Lease
        fileprivate let change: Int
        let provider: PasteDataProvider
    }

    /// Tests swap in a private named board. A lease is also bound to that exact board.
    static var pasteboard: NSPasteboard = .general {
        didSet { invalidatePaste() }
    }
    private static var activePaste: Paste?

    static var canBorrow: Bool {
        if let activePaste, !owns(activePaste) { invalidatePaste() }
        return activePaste == nil
    }

    static func borrow() -> Lease? {
        // Never snapshot our own lazy text: doing so would manufacture a receipt.
        guard canBorrow else { return nil }
        let board = pasteboard
        let change = board.changeCount
        guard let saved = snapshot(board), board.changeCount == change else { return nil }
        return Lease(saved: saved, board: board, change: change)
    }

    static func beginPaste(_ text: String, lease: Lease) -> Paste? {
        guard canBorrow, lease.board === pasteboard, pasteboard.changeCount == lease.change else { return nil }
        let provider = PasteDataProvider(text)
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.string])
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        let cleared = pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            provider.invalidate()
            giveBack(lease, ifUnchangedSince: cleared)
            return nil
        }
        let paste = Paste(lease: lease, change: pasteboard.changeCount, provider: provider)
        activePaste = paste
        return paste
    }

    static func owns(_ paste: Paste) -> Bool {
        activePaste?.token == paste.token && paste.lease.board === pasteboard
            && pasteboard.changeCount == paste.change
    }

    /// Called only before posting, or after a request plus grace. No unconfirmed timer path.
    static func finish(_ paste: Paste) {
        guard owns(paste) else { return }
        invalidatePaste()
        giveBack(paste.lease, ifUnchangedSince: paste.change)
    }

    static func giveBack(_ lease: Lease, ifUnchangedSince change: Int) {
        guard lease.board === pasteboard, pasteboard.changeCount == change else { return }
        restore(lease.saved)
    }

    /// Explicit user copy is allowed to replace an unresolved paste. Old tokens become inert.
    @discardableResult
    static func keep(_ text: String) -> Bool {
        invalidatePaste()
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private static func invalidatePaste() {
        activePaste?.provider.invalidate()
        activePaste = nil
    }

    private static func snapshot(_ board: NSPasteboard) -> Snapshot? {
        var result: Snapshot = []
        for item in board.pasteboardItems ?? [] {
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                // If a promised format cannot be captured, do not destroy it by borrowing.
                guard let data = item.data(forType: type) else { return nil }
                entry[type] = data
            }
            result.append(entry)
        }
        return result
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
