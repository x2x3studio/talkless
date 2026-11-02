import AppKit
import Testing
@testable import Talkless

/// Uses a private named pasteboard, so the user's real clipboard is never touched.
@MainActor
@Suite(.serialized) struct BorrowedClipboardTests {
    private func withPrivatePasteboard(_ body: @MainActor (NSPasteboard) async throws -> Void) async rethrows {
        let board = NSPasteboard(name: NSPasteboard.Name("talkless-tests-\(UUID().uuidString)"))
        let original = BorrowedClipboard.pasteboard
        BorrowedClipboard.pasteboard = board
        defer {
            // Cancel private-board give-back tasks before restoring the production dependency.
            _ = BorrowedClipboard.borrow()
            BorrowedClipboard.pasteboard = original
            board.releaseGlobally()
        }
        board.clearContents()
        board.setString("user's own text", forType: .string)
        try await body(board)
    }

    @Test func givesBackTheUsersContents() async {
        await withPrivatePasteboard { board in
            let lease = BorrowedClipboard.borrow()
            let change = BorrowedClipboard.writeTransient("dictated")
            #expect(board.string(forType: .string) == "dictated")
            #expect(board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)
            BorrowedClipboard.giveBack(lease, ifUnchangedSince: change)
            #expect(board.string(forType: .string) == "user's own text")
        }
    }

    @Test func neverOverwritesWhatTheUserCopiedMeanwhile() async {
        await withPrivatePasteboard { board in
            let lease = BorrowedClipboard.borrow()
            let change = BorrowedClipboard.writeTransient("dictated")
            board.clearContents()
            board.setString("copied by the user", forType: .string)
            BorrowedClipboard.giveBack(lease, ifUnchangedSince: change)
            #expect(board.string(forType: .string) == "copied by the user")
        }
    }

    @Test func backToBackBorrowsKeepTheOriginal() async throws {
        try await withPrivatePasteboard { board in
            let first = BorrowedClipboard.borrow()
            let firstChange = BorrowedClipboard.writeTransient("first dictation")
            BorrowedClipboard.giveBack(first, ifUnchangedSince: firstChange, after: .milliseconds(50))
            // The next dictation starts before the first give-back runs.
            let second = BorrowedClipboard.borrow()
            let secondChange = BorrowedClipboard.writeTransient("second dictation")
            BorrowedClipboard.giveBack(second, ifUnchangedSince: secondChange, after: .milliseconds(50))
            try await Task.sleep(for: .milliseconds(150))
            #expect(board.string(forType: .string) == "user's own text", "The first dictation is never mistaken for the user's clipboard")
        }
    }

    @Test func keptTextCancelsAPendingGiveBack() async throws {
        try await withPrivatePasteboard { board in
            let lease = BorrowedClipboard.borrow()
            let change = BorrowedClipboard.writeTransient("dictated")
            BorrowedClipboard.giveBack(lease, ifUnchangedSince: change, after: .milliseconds(50))
            #expect(BorrowedClipboard.keep("result to paste later"))
            try await Task.sleep(for: .milliseconds(150))
            #expect(board.string(forType: .string) == "result to paste later")
        }
    }

    /// Holds the clipboard transaction at a known suspension without wall-clock timing.
    @MainActor private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { continuation = $0 } }
        func untilWaiting() async {
            while continuation == nil { await Task.yield() }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @Test func cancellingInsertionBeforePasteRestoresClipboardWithoutPostingKeys() async {
        await withPrivatePasteboard { board in
            let gate = Gate()
            var pasted: [String] = []
            let insertion = Task {
                await TextIO.insert("cancelled result", wait: { _ in await gate.wait() }, sendPaste: {
                    pasted.append(board.string(forType: .string) ?? "")
                })
            }
            await gate.untilWaiting()
            #expect(board.string(forType: .string) == "cancelled result")
            insertion.cancel()
            gate.release()
            let inserted = await insertion.value
            #expect(!inserted)
            #expect(pasted.isEmpty)
            #expect(board.string(forType: .string) == "user's own text")
        }
    }

    @Test func externalClipboardChangeSkipsPasteAndPreservesTheNewContents() async {
        await withPrivatePasteboard { board in
            let gate = Gate()
            var posted = false
            let insertion = Task {
                await TextIO.insert("dictated", wait: { _ in await gate.wait() }, sendPaste: { posted = true })
            }
            await gate.untilWaiting()
            board.clearContents()
            board.setString("user copied meanwhile", forType: .string)
            gate.release()
            let pasted = await insertion.value
            #expect(!pasted)
            #expect(!posted)
            #expect(board.string(forType: .string) == "user copied meanwhile")
        }
    }

    @Test func cancelledQueuedInsertionCannotWriteIntoTheNextRound() async {
        await withPrivatePasteboard { board in
            let gate = Gate()
            var pasted: [String] = []
            let send: @MainActor () async -> Void = { pasted.append(board.string(forType: .string) ?? "") }
            let first = Task { await TextIO.insert("first", wait: { _ in await gate.wait() }, sendPaste: send) }
            await gate.untilWaiting()
            let cancelled = Task { await TextIO.insert("cancelled", wait: { _ in }, sendPaste: send) }
            // Let the second operation enqueue behind the suspended first operation.
            for _ in 0..<20 { await Task.yield() }
            cancelled.cancel()
            gate.release()
            let firstInserted = await first.value
            let cancelledInserted = await cancelled.value
            #expect(firstInserted)
            #expect(!cancelledInserted)
            await TextIO.insert("second", wait: { _ in }, sendPaste: send)
            await TextIO.insert("third", wait: { _ in }, sendPaste: send)
            #expect(pasted == ["first", "second", "third"])
            let original = BorrowedClipboard.borrow()
            BorrowedClipboard.giveBack(original, ifUnchangedSince: board.changeCount)
            #expect(board.string(forType: .string) == "user's own text")
        }
    }

    @Test func copyWaitsUntilPendingPasteHasPostedItsKeys() async {
        await withPrivatePasteboard { board in
            let gate = Gate()
            var events: [String] = []
            let paste = Task {
                await TextIO.insert("dictated", wait: { _ in await gate.wait() }, sendPaste: {
                    events.append("paste: " + (board.string(forType: .string) ?? ""))
                })
            }
            await gate.untilWaiting()
            let copy = Task {
                await TextIO.selectedTextViaCopy(isTargetCurrent: { true }, requestCopy: {
                    events.append("copy")
                    board.clearContents()
                    board.setString("selected", forType: .string)
                }, wait: { _ in })
            }
            for _ in 0..<20 { await Task.yield() }
            #expect(events.isEmpty)
            #expect(board.string(forType: .string) == "dictated")
            gate.release()
            let inserted = await paste.value
            #expect(inserted)
            let selection = await copy.value
            #expect(selection == "selected")
            #expect(events == ["paste: dictated", "copy"])
            #expect(board.string(forType: .string) == "user's own text")
        }
    }

    @Test func pasteWaitsForCopyToReadAndReturnItsClipboard() async {
        await withPrivatePasteboard { board in
            let gate = Gate()
            var pasted: [String] = []
            let copy = Task {
                await TextIO.selectedTextViaCopy(isTargetCurrent: { true }, requestCopy: {
                    board.clearContents()
                    board.setString("selected", forType: .string)
                }, wait: { _ in await gate.wait() })
            }
            await gate.untilWaiting()
            let paste = Task {
                await TextIO.insert("dictated", wait: { _ in }, sendPaste: {
                    pasted.append(board.string(forType: .string) ?? "")
                })
            }
            for _ in 0..<20 { await Task.yield() }
            #expect(pasted.isEmpty)
            #expect(board.string(forType: .string) == "selected")
            gate.release()
            let selection = await copy.value
            let inserted = await paste.value
            #expect(inserted)
            #expect(selection == "selected")
            #expect(pasted == ["dictated"])
            let original = BorrowedClipboard.borrow()
            BorrowedClipboard.giveBack(original, ifUnchangedSince: board.changeCount)
            #expect(board.string(forType: .string) == "user's own text")
        }
    }

    @Test func restoresEveryItemAndType() async {
        await withPrivatePasteboard { board in
            board.clearContents()
            let text = NSPasteboardItem(); text.setString("rich", forType: .string); text.setString("<b>rich</b>", forType: .html)
            let second = NSPasteboardItem(); second.setString("second item", forType: .string)
            board.writeObjects([text, second])
            let lease = BorrowedClipboard.borrow()
            let change = BorrowedClipboard.writeTransient("dictated")
            BorrowedClipboard.giveBack(lease, ifUnchangedSince: change)
            #expect(board.pasteboardItems?.count == 2)
            #expect(board.pasteboardItems?.first?.string(forType: .html) == "<b>rich</b>")
        }
    }
}
