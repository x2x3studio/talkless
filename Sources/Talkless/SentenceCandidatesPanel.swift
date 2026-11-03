import AppKit

/// Mouse-only choice UI. It never makes a window key or reads the target app's selection.
@MainActor
final class SentenceCandidatesPanel {
    struct Selection: Equatable, Sendable {
        let text: String
        let explicit: Bool
    }

    /// A presentation seam keeps async lifecycle tests independent of NSApplication/screens.
    struct Presentation {
        var show: ([String], @escaping (Int) -> Void, @escaping (Bool) -> Void) -> Void
        var hide: () -> Void
        var updateCountdown: (TimeInterval, Bool) -> Void = { _, _ in }
    }

    private struct Operation {
        let id: UUID
        let candidates: [String]
        let continuation: CheckedContinuation<Selection?, Never>
        var countdown: SentenceCandidatesCountdown
    }

    private let presentation: Presentation
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) async throws -> Void
    private var operation: Operation?
    private var timeoutTask: Task<Void, Never>?
    private var timeoutID = UUID()

    convenience init() {
        let window = SentenceCandidatesWindow()
        self.init(presentation: Presentation(show: window.show, hide: window.hide,
                                             updateCountdown: window.updateCountdown))
    }

    init(presentation: Presentation,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.presentation = presentation
        self.now = now
        self.sleep = sleep
    }

    /// A new choice cancels the previous one. Empty input and cancelled tasks return nil.
    /// Callers normally provide 2–3 candidates; text and order are preserved verbatim.
    func choose(candidates: [String], timeout: TimeInterval) async -> Selection? {
        guard !Task.isCancelled else { return nil }
        cancel()
        guard !candidates.isEmpty else { return nil }
        let id = UUID()
        let result: Selection? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                operation = Operation(id: id, candidates: candidates, continuation: continuation,
                                      countdown: SentenceCandidatesCountdown(timeout: timeout, now: now()))
                presentation.show(candidates, { [weak self] index in
                    self?.select(index: index, id: id)
                }, { [weak self] inside in
                    self?.setPointerInside(inside, id: id)
                })
                armTimeout(id: id)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id: id, selection: nil) }
        }
        // Cancellation can race with a queued click/timer on the main actor.
        return Task.isCancelled ? nil : result
    }

    func cancel() {
        guard let id = operation?.id else { return }
        finish(id: id, selection: nil)
    }

    private func select(index: Int, id: UUID) {
        guard let operation, operation.id == id, operation.candidates.indices.contains(index) else { return }
        finish(id: id, selection: Selection(text: operation.candidates[index], explicit: true))
    }

    private func setPointerInside(_ inside: Bool, id: UUID) {
        guard operation?.id == id else { return }
        operation?.countdown.setPaused(inside, now: now())
        armTimeout(id: id)
    }

    private func armTimeout(id: UUID) {
        guard let operation, operation.id == id else { return }
        timeoutTask?.cancel()
        timeoutTask = nil
        timeoutID = UUID()
        let remaining = operation.countdown.remaining(at: now())
        presentation.updateCountdown(remaining, operation.countdown.isPaused)
        guard !operation.countdown.isPaused else { return }
        let timerID = timeoutID
        // Refresh the visible seconds without animation/frame timers.
        let delay = min(remaining, 1)
        let sleep = self.sleep
        timeoutTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled, let self,
                  self.timeoutID == timerID, let current = self.operation,
                  current.id == id, !current.countdown.isPaused else { return }
            guard current.countdown.remaining(at: self.now()) <= 0 else {
                self.armTimeout(id: id)
                return
            }
            self.finish(id: id, selection: Selection(text: current.candidates[0], explicit: false))
        }
    }

    private func finish(id: UUID, selection: Selection?) {
        guard let operation, operation.id == id else { return }
        self.operation = nil
        timeoutID = UUID()
        timeoutTask?.cancel()
        timeoutTask = nil
        presentation.hide()
        operation.continuation.resume(returning: selection)
    }
}

/// Monotonic, deterministic countdown: hovering consumes no remaining time.
struct SentenceCandidatesCountdown {
    private var budget: TimeInterval
    private var startedAt: TimeInterval?
    var isPaused: Bool { startedAt == nil }

    init(timeout: TimeInterval, now: TimeInterval) {
        // Invalid durations behave like zero rather than trapping in Duration conversion.
        budget = timeout.isFinite ? max(0, timeout) : 0
        startedAt = now
    }

    func remaining(at now: TimeInterval) -> TimeInterval {
        guard let startedAt else { return budget }
        return max(0, budget - max(0, now - startedAt))
    }

    mutating func setPaused(_ paused: Bool, now: TimeInterval) {
        guard paused != isPaused else { return }
        if paused {
            budget = remaining(at: now)
            startedAt = nil
        } else {
            startedAt = now
        }
    }
}

/// Reverse diffs mark the default's own differing words, not just the alternatives.
enum SentenceCandidatesHighlight {
    static func ranges(candidates: [String], index: Int) -> [Range<String.Index>] {
        guard candidates.indices.contains(index), let first = candidates.first else { return [] }
        guard index == 0 else {
            return TextRevisionHighlight.ranges(original: first, revised: candidates[index])
        }
        let ranges = candidates.dropFirst().flatMap {
            TextRevisionHighlight.ranges(original: $0, revised: first)
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}

@MainActor
final class SentenceCandidatesWindow: NSObject, NSWindowDelegate {
    private var panel: NonactivatingCandidatesPanel?
    private var trackingView: CandidatesTrackingView?
    private var countdownLabel: NSTextField?
    private let visibleFrame: () -> NSRect
    private let presentsOnScreen: Bool

    // Allows native offscreen rendering tests without reading the actual pointer or screen.
    init(presentsOnScreen: Bool = true, visibleFrame: @escaping () -> NSRect = {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        return screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_024, height: 768)
    }) {
        self.presentsOnScreen = presentsOnScreen
        self.visibleFrame = visibleFrame
        super.init()
    }

    var window: NSPanel? { panel }

    func updateCountdown(remaining: TimeInterval, paused: Bool) {
        let seconds = Int(min(ceil(max(0, remaining)), Double(Int32.max)))
        countdownLabel?.stringValue = paused ? L10n.tr("Paused") : L10n.format("%d seconds · default", seconds)
    }

    func show(_ candidates: [String], onSelect: @escaping (Int) -> Void,
              onHover: @escaping (Bool) -> Void) {
        hide()
        let visible = visibleFrame()
        let width = min(560, max(240, visible.width - 48))
        let inset: CGFloat = 16
        let headerHeight: CGFloat = 68
        let footerHeight: CGFloat = 34
        let rowWidth = width - 2 * inset
        let document = CandidatesFlippedView()
        var y: CGFloat = 0
        for (index, candidate) in candidates.enumerated() {
            let row = CandidateSentenceRow(text: candidate,
                                           ranges: SentenceCandidatesHighlight.ranges(candidates: candidates, index: index),
                                           isDefault: index == 0, width: rowWidth,
                                           onSelect: { onSelect(index) })
            row.setFrameOrigin(NSPoint(x: 0, y: y))
            document.addSubview(row)
            y += row.frame.height + 8
        }
        let documentHeight = max(0, y - 8)
        document.frame = NSRect(x: 0, y: 0, width: rowWidth, height: documentHeight)
        let bodyHeight = min(documentHeight, max(80, visible.height - 80 - headerHeight - footerHeight))
        let height = headerHeight + bodyHeight + footerHeight
        let root = CandidatesTrackingView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.onHover = onHover
        let backdrop = NSVisualEffectView(frame: root.bounds)
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 16
        backdrop.layer?.masksToBounds = true
        root.addSubview(backdrop)

        let header = CandidatesDragView(frame: NSRect(x: 0, y: 0, width: width, height: headerHeight))
        let title = CandidatesPassiveLabel(labelWithString: L10n.tr("Choose a sentence"))
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.frame = NSRect(x: inset, y: 14, width: rowWidth - 180, height: 20)
        header.addSubview(title)
        let countdown = CandidatesPassiveLabel(labelWithString: "")
        countdown.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countdown.textColor = .secondaryLabelColor
        countdown.alignment = .right
        countdown.frame = NSRect(x: width - inset - 180, y: 16, width: 180, height: 18)
        header.addSubview(countdown)
        countdownLabel = countdown
        let hint = CandidatesPassiveLabel(labelWithString: L10n.tr("Click a sentence, or wait to use the default."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: inset, y: 38, width: rowWidth, height: 16)
        header.addSubview(hint)
        root.addSubview(header)

        let scroll = NSScrollView(frame: NSRect(x: inset, y: headerHeight, width: rowWidth, height: bodyHeight))
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = documentHeight > bodyHeight
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = document
        root.addSubview(scroll)
        let footer = CandidatesPassiveLabel(labelWithString: L10n.tr("Pointer inside pauses the countdown."))
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.frame = NSRect(x: inset, y: headerHeight + bodyHeight + 10, width: rowWidth, height: 16)
        root.addSubview(footer)

        let panel = NonactivatingCandidatesPanel(contentRect: root.frame,
                                                 styleMask: [.borderless, .nonactivatingPanel],
                                                 backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = root
        panel.delegate = self
        let bottom = min(visible.minY + max(24, visible.height * 0.12), visible.maxY - height - 24)
        panel.setFrameOrigin(NSPoint(x: visible.midX - width / 2, y: max(visible.minY + 24, bottom)))
        self.panel = panel
        trackingView = root
        if presentsOnScreen {
            panel.orderFrontRegardless()
            root.refreshPointer()
        }
    }

    func hide() {
        trackingView?.onHover = nil
        trackingView = nil
        countdownLabel = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
        panel = nil
    }

    func windowDidMove(_ notification: Notification) {
        trackingView?.refreshPointer()
    }
}

private final class NonactivatingCandidatesPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private class CandidatesFlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class CandidatesTrackingView: CandidatesFlippedView {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    private var pointerInside: Bool?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
        refreshPointer()
    }

    override func mouseEntered(with event: NSEvent) { refreshPointer() }
    override func mouseExited(with event: NSEvent) { refreshPointer() }

    func refreshPointer() {
        guard let window, window.isVisible else { return }
        let inside = window.frame.contains(NSEvent.mouseLocation)
        guard inside != pointerInside else { return }
        pointerInside = inside
        onHover?(inside)
    }
}

/// Only this header drags the window; sentence text always selects instead.
private final class CandidatesDragView: CandidatesFlippedView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

private final class CandidatesPassiveLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class CandidateSentenceRow: CandidatesFlippedView {
    private let onSelect: () -> Void

    init(text: String, ranges: [Range<String.Index>], isDefault: Bool, width: CGFloat,
         onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 3
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])
        for range in ranges {
            attributed.addAttributes([
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.controlAccentColor,
                .backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.10),
            ], range: NSRange(range, in: text))
        }
        let textWidth = width - 24
        // Leave room for NSTextFieldCell's horizontal text inset when measuring wrapping.
        let textHeight = ceil(attributed.boundingRect(with: NSSize(width: textWidth - 6, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 4
        let labelHeight: CGFloat = isDefault ? 20 : 0
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: max(24, textHeight) + 24 + labelHeight))
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = (isDefault ? NSColor.controlAccentColor.withAlphaComponent(0.07)
                                  : NSColor.controlBackgroundColor.withAlphaComponent(0.65)).cgColor
        if isDefault {
            let badge = CandidatesPassiveLabel(labelWithString: L10n.tr("Default"))
            badge.font = .systemFont(ofSize: 10, weight: .semibold)
            badge.textColor = .secondaryLabelColor
            badge.frame = NSRect(x: 12, y: 10, width: textWidth, height: 16)
            addSubview(badge)
        }
        let label = CandidatesPassiveLabel(wrappingLabelWithString: text)
        label.attributedStringValue = attributed
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.isSelectable = false
        label.frame = NSRect(x: 12, y: 12 + labelHeight, width: textWidth, height: max(24, textHeight))
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(text)
        if isDefault { setAccessibilityHelp(L10n.tr("Default")) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onSelect() }
    override func accessibilityPerformPress() -> Bool { onSelect(); return true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
