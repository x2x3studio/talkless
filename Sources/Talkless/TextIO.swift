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
    enum SelectionReading: Equatable, Sendable {
        case text(String)
        /// An explicit zero-length selection: nothing is selected, so do not try ⌘C.
        case empty
        /// The app does not report it (many web views and Electron apps): ⌘C may still work.
        case unavailable
    }

    /// Only the system boundary is replaceable; tests never query real apps or send keys.
    @MainActor struct SelectionEnvironment {
        var frontmostPID: @MainActor () -> pid_t?
        var ownPID: pid_t
        var read: @MainActor (pid_t) async -> SelectionReading
        var findCopy: @MainActor (pid_t) async -> (@MainActor () -> Bool)?
        var postCopy: @MainActor (pid_t) -> Void

        static var live: Self {
            Self(
                frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
                ownPID: ProcessInfo.processInfo.processIdentifier,
                read: { pid in
                    await SelectionAXWorker.run(fallback: .unavailable) { budget in
                        SelectionAXLookup(access: SystemSelectionAX(), budget: budget).read(pid: pid)
                    }
                },
                findCopy: { pid in
                    let item: SelectionCopyItem? = await SelectionAXWorker.run(fallback: nil) { budget in
                        let lookup = SelectionAXLookup(access: SystemSelectionAX(), budget: budget)
                        return lookup.copyItem(pid: pid).map { SelectionCopyItem(element: $0) }
                    }
                    guard let item else { return nil }
                    return { item.press() }
                },
                postCopy: { postShortcut(vKeyC, to: $0) }
            )
        }

        func isCurrent(_ pid: pid_t) -> Bool {
            !Task.isCancelled && pid > 0 && pid != ownPID && frontmostPID() == pid
        }
    }

    /// Read without touching the clipboard. A stale/cancelled reading is never adopted.
    static func selectionViaAX(targetPID: pid_t? = nil, environment: SelectionEnvironment = .live) async -> SelectionReading {
        guard let pid = targetPID ?? environment.frontmostPID(), environment.isCurrent(pid) else { return .unavailable }
        let reading = await environment.read(pid)
        guard environment.isCurrent(pid) else { return .unavailable }
        return reading
    }

    /// Keep the original PID across BOTH awaits: unavailable must not copy from a new app.
    static func selectedText(targetPID: pid_t? = nil, environment: SelectionEnvironment = .live) async -> String? {
        guard let pid = targetPID ?? environment.frontmostPID(), environment.isCurrent(pid) else { return nil }
        let reading = await selectionViaAX(targetPID: pid, environment: environment)
        guard environment.isCurrent(pid) else { return nil }
        switch reading {
        case .text(let text): return text
        case .empty: return nil
        case .unavailable: return await selectedTextViaCopy(targetPID: pid, environment: environment)
        }
    }

    /// Discover Copy before borrowing the clipboard. The bounded press is the only AX call
    /// left on MainActor, immediately after the transaction's target/cancellation checks.
    static func selectedTextViaCopy(targetPID: pid_t? = nil, environment: SelectionEnvironment = .live) async -> String? {
        guard let pid = targetPID ?? environment.frontmostPID(), environment.isCurrent(pid) else { return nil }
        let copy = await environment.findCopy(pid)
        guard environment.isCurrent(pid) else { return nil }
        return await selectedTextViaCopy(
            isTargetCurrent: { environment.isCurrent(pid) },
            requestCopy: {
                if copy?() != true, environment.isCurrent(pid) { environment.postCopy(pid) }
            }
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

    /// `.submitted` means the paste shortcut was posted, not verified document insertion.
    @discardableResult
    static func insert(_ text: String, targetPID: pid_t? = nil) async -> PasteOutcome {
        guard let pid = targetPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return .targetChanged }
        return await insert(text,
                            isTargetCurrent: { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid },
                            sendPaste: { await postPaste(to: pid) })
    }

    /// The queue covers writing, posting, the consumption grace period and restoration.
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
            defer { BorrowedClipboard.finish(paste) }
            // Let the clipboard write and any just-released dictation key settle first.
            await wait(.milliseconds(50))
            guard BorrowedClipboard.owns(paste) else { return .clipboardChanged }
            if cancellation.isCancelled || !isTargetCurrent() {
                return cancellation.isCancelled ? .cancelled : .targetChanged
            }
            // Complete Command-up even if cancellation arrives after posting starts.
            await sendPaste()
            // A finite compatibility grace, never proof that the target consumed text.
            // Keep the transaction occupied through this wait, including cancellation.
            await wait(.seconds(2))
            guard !cancellation.isCancelled else { return .cancelled }
            guard isTargetCurrent() else { return .targetChanged }
            return .submitted
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

/// One queue for synchronous AX IPC. Deadlines start at submission, so queued stale work
/// cannot receive a fresh budget. Cancellation is checked between every IPC call.
enum SelectionAXWorker {
    private static let queue = DispatchQueue(label: "app.talkless.selection-ax", qos: .userInitiated)

    static func run<Result: Sendable>(
        fallback: Result,
        limits: SelectionAXBudget.Limits = .init(),
        _ operation: @escaping @Sendable (SelectionAXBudget) -> Result
    ) async -> Result {
        let cancellation = SelectionAXCancellation()
        let deadline = ProcessInfo.processInfo.systemUptime + limits.seconds
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let budget = SelectionAXBudget(limits: limits, deadline: deadline, cancellation: cancellation)
                    guard budget.isActive else { continuation.resume(returning: fallback); return }
                    let result = operation(budget)
                    continuation.resume(returning: budget.isActive ? result : fallback)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

final class SelectionAXCancellation: Sendable {
    private let flag = Mutex(false)
    var isCancelled: Bool { flag.withLock { $0 } }
    func cancel() { flag.withLock { $0 = true } }
}

/// Queue-confined. A visit is charged for EVERY attribute/children access, including
/// repeated access to an element; this is stricter than counting distinct tree nodes.
final class SelectionAXBudget {
    struct Limits: Sendable {
        var seconds: TimeInterval = 0.15
        var visits: Int = 128
        var messagingTimeout: Float = 0.025
    }
    private let limits: Limits
    private let deadline: TimeInterval
    private let cancellation: SelectionAXCancellation
    private let now: () -> TimeInterval
    private var visits = 0

    init(limits: Limits = .init(), deadline: TimeInterval, cancellation: SelectionAXCancellation,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.limits = limits
        self.deadline = deadline
        self.cancellation = cancellation
        self.now = now
    }

    var isActive: Bool { !cancellation.isCancelled && now() < deadline }
    var canVisit: Bool { isActive && visits < limits.visits }

    func nextTimeout() -> Float? {
        guard canVisit else { return nil }
        visits += 1
        let remaining = deadline - now()
        guard remaining > 0 else { return nil }
        return min(limits.messagingTimeout, Float(remaining))
    }
}

/// Narrow AX adapter lets offline tests run the actual traversal with synthetic nodes.
protocol SelectionAXAccess {
    associatedtype Element
    func application(_ pid: pid_t) -> Element
    func setTimeout(_ seconds: Float, on element: Element) -> Bool
    func attribute(_ name: String, of element: Element) -> Any?
    func element(from value: Any) -> Element?
    func children(of element: Element, limit: Int) -> [Element]
}

struct SelectionAXLookup<Access: SelectionAXAccess> {
    let access: Access
    let budget: SelectionAXBudget

    private func value(_ name: String, of element: Access.Element) -> Any? {
        guard let timeout = budget.nextTimeout(), access.setTimeout(timeout, on: element), budget.isActive else { return nil }
        let value = access.attribute(name, of: element)
        return budget.isActive ? value : nil
    }

    private func children(_ element: Access.Element) -> [Access.Element] {
        guard let timeout = budget.nextTimeout(), access.setTimeout(timeout, on: element), budget.isActive else { return [] }
        let result = access.children(of: element, limit: 64)
        return budget.isActive ? Array(result.prefix(64)) : []
    }

    func read(pid: pid_t) -> TextIO.SelectionReading {
        let app = access.application(pid)
        guard let focused = value(kAXFocusedUIElementAttribute, of: app),
              let element = access.element(from: focused) else { return .unavailable }
        if let text = value(kAXSelectedTextAttribute, of: element) as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .text(text) }
        // Empty strings alone are unreliable in web views. Keep the existing explicit-range rule.
        if let range = value(kAXSelectedTextRangeAttribute, of: element) as? CFRange,
           range.location >= 0, range.length == 0 { return .empty }
        return .unavailable
    }

    func copyItem(pid: pid_t) -> Access.Element? {
        let app = access.application(pid)
        guard let value = value(kAXMenuBarAttribute, of: app), let bar = access.element(from: value) else { return nil }
        // Preserve locale-independent Cmd+C matching and the existing shallow search shape.
        for top in children(bar).dropFirst().prefix(4) {
            for menu in children(top) {
                for item in children(menu) {
                    guard budget.canVisit else { return nil }
                    guard (self.value(kAXMenuItemCmdCharAttribute, of: item) as? String)?.lowercased() == "c",
                          self.value(kAXMenuItemCmdModifiersAttribute, of: item) as? Int == 0,
                          self.value(kAXEnabledAttribute, of: item) as? Bool == true else { continue }
                    return item
                }
            }
        }
        return nil
    }
}

private struct SystemSelectionAX: SelectionAXAccess {
    func application(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }
    func setTimeout(_ seconds: Float, on element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, seconds) == .success
    }
    func attribute(_ name: String, of element: AXUIElement) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if name == kAXSelectedTextRangeAttribute {
            guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
            var range = CFRange()
            return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
        }
        return value
    }
    func element(from value: Any) -> AXUIElement? {
        let object = value as CFTypeRef
        guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        return (object as! AXUIElement)
    }
    func children(of element: AXUIElement, limit: Int) -> [AXUIElement] {
        var values: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, limit, &values) == .success,
              let values else { return [] }
        return (values as [AnyObject]).compactMap { self.element(from: $0) }
    }
}

/// The reference crosses the queue only after lookup ends; its sole use is a MainActor
/// press after PID/cancellation validation. No concurrent access to the AX element.
private struct SelectionCopyItem: @unchecked Sendable {
    let element: AXUIElement
    @MainActor func press() -> Bool {
        guard AXUIElementSetMessagingTimeout(element, 0.025) == .success else { return false }
        let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
        // A timeout can mean a pending Copy. Never duplicate it with a shortcut.
        return status == .success || status == .cannotComplete
    }
}

/// Clipboard leases are scoped to one queued operation and always released at its end.
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
        guard canBorrow else { return nil }
        let board = pasteboard
        let change = board.changeCount
        guard let saved = snapshot(board), board.changeCount == change else { return nil }
        return Lease(saved: saved, board: board, change: change)
    }

    static func beginPaste(_ text: String, lease: Lease) -> Paste? {
        guard canBorrow, lease.board === pasteboard, pasteboard.changeCount == lease.change else { return nil }
        let item = NSPasteboardItem()
        guard item.setString(text, forType: .string) else { return nil }
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"))
        let cleared = pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            giveBack(lease, ifUnchangedSince: cleared)
            return nil
        }
        let paste = Paste(lease: lease, change: pasteboard.changeCount)
        activePaste = paste
        return paste
    }

    static func owns(_ paste: Paste) -> Bool {
        activePaste?.token == paste.token && paste.lease.board === pasteboard
            && pasteboard.changeCount == paste.change
    }

    /// Clear this operation even when another app changed the clipboard; never restore over it.
    static func finish(_ paste: Paste) {
        guard activePaste?.token == paste.token else { return }
        let restore = owns(paste)
        invalidatePaste()
        if restore { giveBack(paste.lease, ifUnchangedSince: paste.change) }
    }

    static func giveBack(_ lease: Lease, ifUnchangedSince change: Int) {
        guard lease.board === pasteboard, pasteboard.changeCount == change else { return }
        restore(lease.saved)
    }

    /// Explicit user copy wins over any pending restoration.
    @discardableResult
    static func keep(_ text: String) -> Bool {
        invalidatePaste()
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    private static func invalidatePaste() {
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
