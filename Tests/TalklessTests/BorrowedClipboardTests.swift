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
        defer { BorrowedClipboard.pasteboard = original; board.releaseGlobally() }
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
