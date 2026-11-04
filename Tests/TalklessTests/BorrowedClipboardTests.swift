import AppKit
import Testing
@testable import Talkless

/// Every read is either an explicit simulated consumer or happens after the transaction.
/// No production insertion is called, and the general pasteboard is never read or written.
@MainActor
@Suite(.serialized) struct BorrowedClipboardTests {
    private func withPrivatePasteboard(_ body: @MainActor (NSPasteboard) async throws -> Void) async rethrows {
        let board = NSPasteboard(name: NSPasteboard.Name("talkless-tests-\(UUID().uuidString)"))
        let original = BorrowedClipboard.pasteboard
        BorrowedClipboard.pasteboard = board
        defer {
            BorrowedClipboard.pasteboard = original
            board.releaseGlobally()
        }
        board.clearContents()
        board.setString("user's own text", forType: .string)
        try await body(board)
    }

    @MainActor private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func untilWaiting() async {
            while continuation == nil { await Task.yield() }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @Test func delayedConsumerBeyondOld400msGetsTheRightText() async {
        await withPrivatePasteboard { board in
            var consumer: Task<Void, Never>?
            var received: String?
            let result = await TextIO.insert("slow dictation", isTargetCurrent: { true }, sendPaste: {
                consumer = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(650))
                    received = board.string(forType: .string)
                }
            })
            await consumer?.value
            #expect(result == .submitted)
            #expect(received == "slow dictation")
            #expect(board.string(forType: .string) == "user's own text")
        }
    }

    @Test func threeQueuedPastesWaitForTheirOwnDelayedConsumers() async {
        await withPrivatePasteboard { board in
            let gate = Gate()
            var events: [String] = []
            var posted = 0
            let sender: @MainActor () async -> Void = { posted += 1 }
            let wait: @MainActor (Duration) async -> Void = { duration in
                if duration == .seconds(2) { await gate.wait() }
            }
            let first = Task { await TextIO.insert("first", isTargetCurrent: { true }, wait: wait, sendPaste: sender) }
            await gate.untilWaiting()
            let second = Task { await TextIO.insert("second", isTargetCurrent: { true }, wait: wait, sendPaste: sender) }
            for _ in 0..<20 { await Task.yield() }
            let third = Task { await TextIO.insert("third", isTargetCurrent: { true }, wait: wait, sendPaste: sender) }
            for expectedPostCount in 1...3 {
                await gate.untilWaiting()
                for _ in 0..<20 { await Task.yield() }
                #expect(posted == expectedPostCount)
                events.append(board.string(forType: .string) ?? "")
                gate.release()
                if expectedPostCount == 1 { #expect(await first.value == .submitted) }
                if expectedPostCount == 2 { #expect(await second.value == .submitted) }
                if expectedPostCount == 3 { #expect(await third.value == .submitted) }
            }
            #expect(events == ["first", "second", "third"])
            #expect(board.string(forType: .string) == "user's own text")
        }
    }

    @Test func noReadSignalNeverBlocksFollowingUtterances() async {
        await withPrivatePasteboard { board in
            var posts = 0
            for text in ["first", "second", "third"] {
                let result = await TextIO.insert(text, isTargetCurrent: { true }, wait: { _ in }, sendPaste: { posts += 1 })
                #expect(result == .submitted)
                #expect(BorrowedClipboard.canBorrow)
                #expect(board.string(forType: .string) == "user's own text")
            }
            #expect(posts == 3)
        }
    }

    @Test func cancellingBeforePasteRestoresWithoutPostingKeys() async {
        await withPrivatePasteboard { board in
            let gate = Gate()
            var posted = false
            let insertion = Task {
                await TextIO.insert("cancelled", isTargetCurrent: { true }, wait: { _ in await gate.wait() }, sendPaste: { posted = true })
            }
            await gate.untilWaiting()
            insertion.cancel()
            gate.release()
            #expect(await insertion.value == .cancelled)
            #expect(!posted)
            #expect(board.string(forType: .string) == "user's own text")
        }
    }

    @Test func cancellingAfterKeysSettlesAndAllowsNextPaste() async {
        await withPrivatePasteboard { board in
            let gate = Gate()
            let insertion = Task {
                await TextIO.insert("late consumer", isTargetCurrent: { true }, wait: { duration in
                    if duration == .seconds(2) { await gate.wait() }
                }, sendPaste: {})
            }
            await gate.untilWaiting()
            insertion.cancel()
            gate.release()
            #expect(await insertion.value == .cancelled)
            #expect(await TextIO.insert("next", isTargetCurrent: { true }, wait: { _ in }, sendPaste: {}) == .submitted)
            #expect(board.string(forType: .string) == "user's own text")
        }
    }

    @Test func externalCopyBeforeKeysSkipsPasteAndPreservesIt() async {
        await withPrivatePasteboard { board in
            let gate = Gate()
            var posted = false
            let insertion = Task {
                await TextIO.insert("dictated", isTargetCurrent: { true }, wait: { _ in await gate.wait() }, sendPaste: { posted = true })
            }
            await gate.untilWaiting()
            board.clearContents()
            board.setString("external copy", forType: .string)
            gate.release()
            #expect(await insertion.value == .clipboardChanged)
            #expect(!posted)
            #expect(board.string(forType: .string) == "external copy")
        }
    }

    @Test func externalCopyDuringGraceWinsAndReleasesBlockedOwnership() async {
        await withPrivatePasteboard { board in
            let result = await TextIO.insert("dictated", isTargetCurrent: { true }, wait: { duration in
                if duration == .seconds(2) {
                    board.clearContents()
                    board.setString("external copy", forType: .string)
                }
            }, sendPaste: { #expect(board.string(forType: .string) == "dictated") })
            #expect(result == .submitted)
            #expect(BorrowedClipboard.canBorrow)
            #expect(board.string(forType: .string) == "external copy")
            #expect(await TextIO.insert("unread", isTargetCurrent: { true }, wait: { _ in }, sendPaste: {}) == .submitted)
            board.clearContents()
            board.setString("new external copy", forType: .string)
            let next = await TextIO.insert("next", isTargetCurrent: { true }, wait: { _ in }, sendPaste: {
                #expect(board.string(forType: .string) == "next")
            })
            #expect(next == .submitted)
            #expect(board.string(forType: .string) == "new external copy")
        }
    }

    @Test func explicitCopyDuringPendingPasteCannotBeRestoredOver() async {
        await withPrivatePasteboard { board in
            let result = await TextIO.insert("dictated", isTargetCurrent: { true }, wait: { _ in }, sendPaste: {
                #expect(TextIO.copyToClipboard("keep this"))
            })
            #expect(result == .submitted)
            #expect(board.string(forType: .string) == "keep this")
        }
    }

    @Test func targetChangeBeforeAndAfterPostingHasDifferentCleanup() async {
        await withPrivatePasteboard { board in
            var targetCurrent = true
            var posted = false
            #expect(await TextIO.insert("before", isTargetCurrent: { targetCurrent }, wait: { _ in targetCurrent = false }, sendPaste: { posted = true }) == .targetChanged)
            #expect(!posted)
            #expect(board.string(forType: .string) == "user's own text")
            targetCurrent = true
            #expect(await TextIO.insert("after", isTargetCurrent: { targetCurrent }, wait: { _ in }, sendPaste: { targetCurrent = false }) == .targetChanged)
            #expect(BorrowedClipboard.canBorrow)
            #expect(board.string(forType: .string) == "user's own text")
        }
    }

    @Test func cancelledQueuedInsertionNeverWrites() async {
        await withPrivatePasteboard { board in
            let gate = Gate()
            let first = Task {
                await TextIO.insert("first", isTargetCurrent: { true }, wait: { duration in
                    if duration == .seconds(2) { await gate.wait() }
                }, sendPaste: {})
            }
            await gate.untilWaiting()
            var posted = false
            let cancelled = Task { await TextIO.insert("cancelled", isTargetCurrent: { true }, wait: { _ in }, sendPaste: { posted = true }) }
            for _ in 0..<20 { await Task.yield() }
            cancelled.cancel()
            #expect(board.string(forType: .string) == "first")
            gate.release()
            #expect(await first.value == .submitted)
            #expect(await cancelled.value == .cancelled)
            #expect(!posted)
            #expect(board.string(forType: .string) == "user's own text")
        }
    }

    @Test func copyWaitsForPasteRestoration() async {
        await withPrivatePasteboard { board in
            let gate = Gate()
            let paste = Task {
                await TextIO.insert("dictated", isTargetCurrent: { true }, wait: { duration in
                    if duration == .seconds(2) { await gate.wait() }
                }, sendPaste: {})
            }
            await gate.untilWaiting()
            var copied = false
            let copy = Task {
                await TextIO.selectedTextViaCopy(isTargetCurrent: { true }, requestCopy: {
                    copied = true
                    board.clearContents()
                    board.setString("selected", forType: .string)
                }, wait: { _ in })
            }
            for _ in 0..<20 { await Task.yield() }
            #expect(!copied)
            #expect(board.string(forType: .string) == "dictated")
            gate.release()
            #expect(await paste.value == .submitted)
            #expect(await copy.value == "selected")
            #expect(board.string(forType: .string) == "user's own text")
        }
    }

    @Test func pasteWaitsForCopyToReturnItsClipboard() async {
        await withPrivatePasteboard { board in
            let gate = Gate()
            let copy = Task {
                await TextIO.selectedTextViaCopy(isTargetCurrent: { true }, requestCopy: {
                    board.clearContents()
                    board.setString("selected", forType: .string)
                }, wait: { _ in await gate.wait() })
            }
            await gate.untilWaiting()
            var posted = false
            let paste = Task {
                await TextIO.insert("dictated", isTargetCurrent: { true }, wait: { _ in }, sendPaste: {
                    posted = true
                    #expect(board.string(forType: .string) == "dictated")
                })
            }
            for _ in 0..<20 { await Task.yield() }
            #expect(!posted)
            gate.release()
            #expect(await copy.value == "selected")
            #expect(await paste.value == .submitted)
            #expect(board.string(forType: .string) == "user's own text")
        }
    }

    @Test func restoresEveryItemAndFormat() async {
        await withPrivatePasteboard { board in
            board.clearContents()
            let text = NSPasteboardItem()
            text.setString("rich", forType: .string)
            text.setString("<b>rich</b>", forType: .html)
            let second = NSPasteboardItem()
            second.setData(Data([0, 1, 2, 255]), forType: NSPasteboard.PasteboardType("test.binary"))
            board.writeObjects([text, second])
            let result = await TextIO.insert("dictated", isTargetCurrent: { true }, wait: { _ in }, sendPaste: {
                #expect(board.string(forType: .string) == "dictated")
                #expect(board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)
            })
            #expect(result == .submitted)
            #expect(board.pasteboardItems?.count == 2)
            #expect(board.pasteboardItems?.first?.string(forType: .html) == "<b>rich</b>")
            #expect(board.pasteboardItems?.last?.data(forType: NSPasteboard.PasteboardType("test.binary")) == Data([0, 1, 2, 255]))
        }
    }

    @Test func staleCleanupCannotReleaseANewerPaste() async throws {
        try await withPrivatePasteboard { board in
            let oldLease = try #require(BorrowedClipboard.borrow())
            let old = try #require(BorrowedClipboard.beginPaste("old", lease: oldLease))
            #expect(TextIO.copyToClipboard("user copy"))
            let newLease = try #require(BorrowedClipboard.borrow())
            let current = try #require(BorrowedClipboard.beginPaste("current", lease: newLease))
            BorrowedClipboard.finish(old)
            #expect(BorrowedClipboard.owns(current))
            BorrowedClipboard.finish(current)
            #expect(BorrowedClipboard.canBorrow && board.string(forType: .string) == "user copy")
        }
    }

    @Test func earlyClipboardReadDoesNotLockLaterPastes() async {
        await withPrivatePasteboard { board in
            for text in ["first", "second", "third"] {
                let result = await TextIO.insert(text, isTargetCurrent: { true }, wait: { duration in
                    if duration == .milliseconds(50) { #expect(board.string(forType: .string) == text) }
                }, sendPaste: {})
                #expect(result == .submitted && BorrowedClipboard.canBorrow)
            }
        }
    }
}
