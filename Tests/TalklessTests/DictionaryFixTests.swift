import Foundation
import Testing
@testable import Talkless

/// Dictionary fixes exercised through the real app module, without extracted source.
@Suite struct DictionaryFixTests {
    private func fix(_ text: String, _ rules: [(String, String)]) -> String {
        DictionaryReplacements.apply(rules.map { DictionaryReplacement(heard: $0.0, term: $0.1) }, to: text).text
    }

    @Test func replacesWholeLatinWordsOnly() {
        #expect(fix("open talk less now", [("talk less", "Talkless")]) == "open Talkless now")
        #expect(fix("talklessness", [("talkless", "Talkless")]) == "talklessness")
    }

    @Test func treatsHanNeighborsAsBoundaries() {
        #expect(fix("\u{7528}talkless\u{5199}", [("talkless", "Talkless")]) == "\u{7528}Talkless\u{5199}")
    }

    @Test func prefersLongerSpellingAndNeverRematches() {
        #expect(fix("open cloud code app", [("cloud code", "Claude Code"), ("code", "CODE")]) == "open Claude Code app")
    }

    @Test func countsOnlyRealChanges() {
        let rules = [DictionaryReplacement(heard: "talkless", term: "Talkless")]
        #expect(DictionaryReplacements.apply(rules, to: "Talkless").count == 0)
        #expect(DictionaryReplacements.apply(rules, to: "talkless and TALKLESS").count == 2)
    }

    @Test func transferRoundTrips() {
        let rules = [DictionaryReplacement(heard: "a one", term: "A1")]
        let text = DictionaryTransfer.export(terms: ["A1", "B2"], rules: rules)
        let merged = DictionaryTransfer.merge(text, into: "", rules: [])
        #expect(merged.dictionary == "A1\nB2")
        #expect(merged.rules == rules)
    }

    @Test func importIgnoresLinesWithoutATerm() {
        let merged = DictionaryTransfer.merge("=x\n# comment\n\nTerm", into: "", rules: [])
        #expect(merged.dictionary == "Term")
        #expect(merged.skipped == 1)
    }
}
