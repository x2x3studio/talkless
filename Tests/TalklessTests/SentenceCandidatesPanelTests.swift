import AppKit
import Foundation
import Testing
@testable import Talkless

@Suite struct SentenceCandidatesCountdownTests {
    @Test func pauseResumesOnlyRemainingBudget() {
        var countdown = SentenceCandidatesCountdown(timeout: 10, now: 100)
        #expect(countdown.remaining(at: 103) == 7)
        countdown.setPaused(true, now: 103)
        #expect(countdown.isPaused)
        #expect(countdown.remaining(at: 1_000) == 7)
        // Duplicate enter/exit notifications do not reset the clock.
        countdown.setPaused(true, now: 1_000)
        countdown.setPaused(false, now: 1_100)
        countdown.setPaused(false, now: 1_103)
        #expect(countdown.remaining(at: 1_104) == 3)
        countdown.setPaused(true, now: 1_105)
        #expect(countdown.remaining(at: 2_000) == 2)
        countdown.setPaused(false, now: 2_000)
        #expect(countdown.remaining(at: 2_001) == 1)
        #expect(countdown.remaining(at: 2_002) == 0)
        #expect(countdown.remaining(at: 9_000) == 0)
    }

    @Test func exhaustedAndInvalidTimeouts() {
        for timeout: TimeInterval in [0, -1, .infinity, -.infinity, .nan] {
            var countdown = SentenceCandidatesCountdown(timeout: timeout, now: 10)
            #expect(countdown.remaining(at: 10) == 0)
            countdown.setPaused(true, now: 10)
            countdown.setPaused(false, now: 30)
            #expect(countdown.remaining(at: 30) == 0)
        }
        let countdown = SentenceCandidatesCountdown(timeout: 4, now: 10)
        #expect(countdown.remaining(at: 9) == 4)
    }
}

@Suite struct SentenceCandidatesHighlightTests {
    private func highlighted(_ candidates: [String], _ index: Int) -> [String] {
        SentenceCandidatesHighlight.ranges(candidates: candidates, index: index).map {
            String(candidates[index][$0])
        }
    }

    @Test func defaultIncludesDifferencesFromEveryAlternative() {
        let candidates = ["Send old text today", "Send new text today", "Send old text tomorrow"]
        #expect(highlighted(candidates, 0) == ["old", "today"])
        #expect(highlighted(candidates, 1) == ["new"])
        #expect(highlighted(candidates, 2) == ["tomorrow"])
        #expect(highlighted(["old words", "new words", "other text"], 0) == ["old words"])
        #expect(highlighted(["old", "new", "new"], 0) == ["old"])
    }

    @Test func unicodeDeletionsAndUnchangedText() {
        let candidates = ["\u{4ECA}\u{5929}\u{53BB}\u{5317}\u{4EAC} 👩🏽‍💻", "\u{660E}\u{5929}\u{53BB}\u{4E0A}\u{6D77} 👩🏽‍💻", "\u{4ECA}\u{5929}\u{53BB}\u{5317}\u{4EAC}"]
        #expect(highlighted(candidates, 0) == ["\u{4ECA}", "\u{5317}\u{4EAC}", "👩🏽‍💻"])
        #expect(highlighted(candidates, 1) == ["\u{660E}", "\u{4E0A}\u{6D77}"])
        #expect(highlighted(candidates, 2).isEmpty)
        #expect(highlighted(["Same", "Same"], 0).isEmpty)
        #expect(highlighted(["Same", "Same"], 1).isEmpty)
        #expect(SentenceCandidatesHighlight.ranges(candidates: [], index: 0).isEmpty)
        #expect(SentenceCandidatesHighlight.ranges(candidates: ["Same"], index: 2).isEmpty)
    }
}

/// No NSApplication, accessibility queries, selection reads, key events or real clocks.
@MainActor @Suite struct SentenceCandidatesPanelTests {
    @MainActor private final class Harness {
        struct Shown {
            let candidates: [String]
            let select: (Int) -> Void
            let hover: (Bool) -> Void
        }
        struct Sleeper {
            let delay: TimeInterval
            let continuation: CheckedContinuation<Void, any Error>
        }
        var now: TimeInterval = 100
        var shown: [Shown] = []
        var hides = 0
        var sleepers: [Sleeper] = []
        var initiallyHovered = false
        var countdownUpdates: [(remaining: TimeInterval, paused: Bool)] = []

        func makePanel() -> SentenceCandidatesPanel {
            SentenceCandidatesPanel(presentation: .init(show: { [self] candidates, select, hover in
                shown.append(Shown(candidates: candidates, select: select, hover: hover))
                if initiallyHovered { hover(true) }
            }, hide: { [self] in hides += 1 }, updateCountdown: { [self] remaining, paused in
                countdownUpdates.append((remaining, paused))
            }), now: { [self] in now }, sleep: { [self] delay in
                // Intentionally ignores cancellation: stale callbacks must be harmless even
                // when cancellation races with a timer that has already become runnable.
                try await withCheckedThrowingContinuation { continuation in
                    sleepers.append(Sleeper(delay: delay, continuation: continuation))
                }
            })
        }

        func wakeAll(at time: TimeInterval? = nil) {
            if let time { now = time }
            let pending = sleepers
            sleepers.removeAll()
            for sleeper in pending { sleeper.continuation.resume() }
        }
    }

    private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }

    @Test func timeoutSelectsFirstWithoutExplicitConsent() async throws {
        let harness = Harness()
        let panel = harness.makePanel()
        let task = Task { await panel.choose(candidates: ["Default sentence", "Other sentence"], timeout: 5) }
        defer { panel.cancel(); harness.wakeAll() }
        #expect(await eventually { harness.sleepers.count == 1 })
        #expect(harness.sleepers.first?.delay == 1)
        #expect(harness.countdownUpdates.last?.remaining == 5)
        #expect(harness.countdownUpdates.last?.paused == false)
        harness.wakeAll(at: 101)
        try #require(await eventually { harness.sleepers.count == 1 })
        #expect(harness.countdownUpdates.last?.remaining == 4)
        harness.wakeAll(at: 105)
        let selection = await task.value
        #expect(selection == .init(text: "Default sentence", explicit: false))
        #expect(harness.hides == 1)
        panel.cancel()
        #expect(harness.hides == 1)
    }

    @Test func clickingAnyWholeSentenceCompletesImmediately() async throws {
        for index in 0..<3 {
            let harness = Harness()
            let panel = harness.makePanel()
            let candidates = ["\u{9ED8}\u{8BA4}\u{6574}\u{53E5}。", "\u{7B2C}\u{4E8C}\u{53E5}\n\u{4FDD}\u{7559}\u{6362}\u{884C}。", String(repeating: "\u{5B8C}\u{6574}\u{7684}\u{957F}\u{53E5} 👩🏽‍💻 ", count: 300)]
            let task = Task { await panel.choose(candidates: candidates, timeout: 10) }
            defer { panel.cancel(); harness.wakeAll() }
            try #require(await eventually { harness.shown.count == 1 })
            #expect(harness.shown[0].candidates == candidates)
            harness.shown[0].select(-1)
            harness.shown[0].select(3)
            #expect(harness.hides == 0)
            harness.shown[0].select(index)
            harness.shown[0].select((index + 1) % 3)
            #expect(await task.value == .init(text: candidates[index], explicit: true))
            #expect(harness.hides == 1)
        }
    }

    @Test func hoveringEntirePresentationPausesAndResumes() async throws {
        let harness = Harness()
        let panel = harness.makePanel()
        let task = Task { await panel.choose(candidates: ["first", "second"], timeout: 10) }
        defer { panel.cancel(); harness.wakeAll() }
        try #require(await eventually { harness.sleepers.count == 1 })
        harness.now = 103
        harness.shown[0].hover(true)
        #expect(harness.countdownUpdates.last?.remaining == 7)
        #expect(harness.countdownUpdates.last?.paused == true)
        harness.wakeAll(at: 1_000)
        await Task.yield()
        #expect(harness.hides == 0)
        #expect(harness.sleepers.isEmpty)
        harness.shown[0].hover(false)
        try #require(await eventually { harness.sleepers.count == 1 })
        #expect(harness.sleepers[0].delay == 1)
        #expect(harness.countdownUpdates.last?.remaining == 7)
        #expect(harness.countdownUpdates.last?.paused == false)
        harness.wakeAll(at: 1_007)
        #expect(await task.value == .init(text: "first", explicit: false))
    }

    @Test func pointerAlreadyInsidePausesBeforeTimerIsArmed() async throws {
        let harness = Harness()
        harness.initiallyHovered = true
        let panel = harness.makePanel()
        let task = Task { await panel.choose(candidates: ["first", "second"], timeout: 5) }
        defer { panel.cancel(); harness.wakeAll() }
        try #require(await eventually { harness.shown.count == 1 })
        #expect(harness.sleepers.isEmpty)
        harness.now = 200
        harness.shown[0].hover(false)
        try #require(await eventually { harness.sleepers.count == 1 })
        #expect(harness.sleepers[0].delay == 1)
        #expect(harness.countdownUpdates.last?.remaining == 5)
        harness.wakeAll(at: 205)
        #expect(await task.value == .init(text: "first", explicit: false))
    }

    @Test func explicitCancelAndTaskCancellationCloseAndReturnNil() async throws {
        for cancelTask in [false, true] {
            let harness = Harness()
            let panel = harness.makePanel()
            let task = Task { await panel.choose(candidates: ["first", "second"], timeout: 5) }
            defer { panel.cancel(); harness.wakeAll() }
            try #require(await eventually { harness.shown.count == 1 })
            harness.shown[0].hover(true)
            if cancelTask { task.cancel() } else { panel.cancel() }
            #expect(await task.value == nil)
            #expect(harness.hides == 1)
            harness.shown[0].select(0)
            harness.shown[0].hover(false)
            harness.wakeAll(at: 200)
            await Task.yield()
            #expect(harness.hides == 1)
        }
    }

    @Test func staleTimeoutHoverClickAndCancellationCannotAffectNextChoice() async throws {
        let harness = Harness()
        let panel = harness.makePanel()
        let first = Task { await panel.choose(candidates: ["old", "old alternative"], timeout: 5) }
        defer { panel.cancel(); harness.wakeAll() }
        try #require(await eventually { harness.sleepers.count == 1 })
        let oldUI = harness.shown[0]
        harness.now = 101
        let second = Task { await panel.choose(candidates: ["new", "new alternative"], timeout: 20) }
        try #require(await eventually { harness.shown.count == 2 && harness.sleepers.count == 2 })
        #expect(await first.value == nil)
        first.cancel()
        oldUI.select(1)
        oldUI.hover(true)
        #expect(harness.hides == 1)
        // Both timer callbacks run, but only the new operation may re-arm itself.
        harness.wakeAll(at: 106)
        try #require(await eventually { harness.sleepers.count == 1 })
        #expect(harness.sleepers[0].delay == 1)
        #expect(harness.countdownUpdates.last?.remaining == 15)
        #expect(harness.hides == 1)
        harness.wakeAll(at: 121)
        #expect(await second.value == .init(text: "new", explicit: false))
        #expect(harness.hides == 2)
    }

    @Test func cancellationQueuedBeforeReplacementCannotCloseReplacement() async throws {
        let harness = Harness()
        let panel = harness.makePanel()
        let first = Task { await panel.choose(candidates: ["old"], timeout: 5) }
        defer { panel.cancel(); harness.wakeAll() }
        try #require(await eventually { harness.shown.count == 1 })
        first.cancel()
        let second = Task { await panel.choose(candidates: ["new"], timeout: 5) }
        try #require(await eventually { harness.shown.count == 2 })
        #expect(await first.value == nil)
        harness.shown[1].select(0)
        #expect(await second.value == .init(text: "new", explicit: true))
        #expect(harness.hides == 2)
    }

    @Test func emptyAndAlreadyCancelledCallsNeverShow() async {
        let harness = Harness()
        let panel = harness.makePanel()
        #expect(await panel.choose(candidates: [], timeout: 5) == nil)
        let cancelled = Task { await panel.choose(candidates: ["first", "second"], timeout: 5) }
        cancelled.cancel()
        #expect(await cancelled.value == nil)
        #expect(harness.shown.isEmpty)
        #expect(harness.hides == 0)
    }

    @Test func nativeOffscreenPanelRendersFullSentencesAndCountdown() throws {
        // Construct AppKit without activating it or ordering a window onscreen. The screen,
        // content and clicks below are synthetic; no global mouse/keyboard events are sent.
        _ = NSApplication.shared
        let visible = NSRect(x: 0, y: 0, width: 1_280, height: 800)
        let presenter = SentenceCandidatesWindow(presentsOnScreen: false, visibleFrame: { visible })
        let long = String(repeating: "Synthetic candidate has complete text, not an ellipsis. \u{6D4B}\u{8BD5}\u{957F}\u{53E5}。\n", count: 40)
        let candidates = ["Keep the old sentence.", "Keep the new sentence.", long]
        var clicked: Int?
        presenter.show(candidates, onSelect: { clicked = $0 }, onHover: { _ in
            Issue.record("Offscreen rendering must not sample the global pointer")
        })
        defer { presenter.hide() }
        let panel = try #require(presenter.window)
        let content = try #require(panel.contentView)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
        #expect(!panel.isVisible && !panel.isKeyWindow)
        #expect(!panel.isMovableByWindowBackground)
        #expect(!panel.ignoresMouseEvents)
        #expect(visible.contains(panel.frame))
        #expect(panel.frame.midX == visible.midX)

        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        let allViews = descendants(content)
        let fields = allViews.compactMap { $0 as? NSTextField }
        let scroll = try #require(allViews.compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        #expect(scroll.hasVerticalScroller)
        #expect(document.frame.height > scroll.contentSize.height)
        for sentence in candidates {
            let field = try #require(fields.first { $0.stringValue == sentence })
            #expect(field.maximumNumberOfLines == 0)
            #expect(!field.isSelectable && !field.isEditable)
            #expect(field.lineBreakMode == .byWordWrapping)
        }
        for sentence in candidates.prefix(2) {
            let field = try #require(fields.first { $0.stringValue == sentence })
            let word = sentence.contains("old") ? "old" : "new"
            let range = (sentence as NSString).range(of: word)
            #expect(field.attributedStringValue.attribute(.backgroundColor, at: range.location,
                                                         effectiveRange: nil) != nil)
        }
        presenter.updateCountdown(remaining: 5, paused: false)
        #expect(fields.contains { $0.stringValue == L10n.format("%d seconds · default", 5) })
        presenter.updateCountdown(remaining: 4, paused: true)
        #expect(fields.contains { $0.stringValue == L10n.tr("Paused") })
        content.layoutSubtreeIfNeeded()
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        #expect(bitmap.representation(using: .png, properties: [:])?.isEmpty == false)
        let secondRow = try #require(document.subviews.dropFirst().first)
        #expect(secondRow.acceptsFirstMouse(for: nil))
        #expect(secondRow.accessibilityPerformPress())
        #expect(clicked == 1)
    }

    @Test func zeroTimeoutUsesDefault() async throws {
        let harness = Harness()
        let panel = harness.makePanel()
        let task = Task { await panel.choose(candidates: ["first", "second"], timeout: 0) }
        defer { panel.cancel(); harness.wakeAll() }
        try #require(await eventually { harness.sleepers.count == 1 })
        #expect(harness.sleepers[0].delay == 0)
        harness.wakeAll()
        #expect(await task.value == .init(text: "first", explicit: false))
    }
}
