import Foundation

@main
struct TextRevisionHighlightTests {
    static func main() {
        var assertions = 0
        func check(_ value: @autoclosure () -> Bool, _ description: String) {
            assertions += 1
            guard value() else { fatalError("FAIL: \(description)") }
        }
        func expect(_ original: String, _ revised: String, _ expected: [String], _ description: String) {
            let ranges = TextRevisionHighlight.ranges(original: original, revised: revised)
            let actual = ranges.map { String(revised[$0]) }
            check(actual.map { Array($0.utf8) } == expected.map { Array($0.utf8) },
                  "\(description): got \(actual), expected \(expected)")
            let boundaries = Set(revised.indices).union([revised.endIndex])
            var previousEnd = revised.startIndex
            for range in ranges {
                check(boundaries.contains(range.lowerBound) && boundaries.contains(range.upperBound),
                      "\(description): extended-grapheme endpoints")
                check(range.lowerBound >= previousEnd && range.lowerBound < range.upperBound,
                      "\(description): sorted nonempty nonoverlap")
                let nsRange = NSRange(range, in: revised)
                check(Range(nsRange, in: revised) == range, "\(description): Foundation range bridge")
                check(Array((revised as NSString).substring(with: nsRange).utf8) == Array(revised[range].utf8),
                      "\(description): original revised bytes preserved")
                previousEnd = range.upperBound
            }
        }

        expect("", "", [], "empty inputs")
        expect("", "New text", [], "no baseline means no revision evidence")
        expect("Old text", "", [], "empty output")
        expect("Same OpenAI text.", "Same OpenAI text.", [], "identical output is not dictionary presence")
        expect(" ", "New text", [], "whitespace baseline has no visible tokens")
        expect("Old text", " \n\t", [], "whitespace output")

        expect("We is ready.", "We are ready.", ["are"], "replacement highlights whole word")
        expect("a cat", "a car", ["car"], "shared letters do not fragment a replacement")
        expect("I is here", "I am here", ["am"], "small words stay whole")
        expect("hello", "Hello", ["Hello"], "case is literal")
        expect("cafe", "café", ["café"], "accent change is literal")
        expect("Use API1 now", "Use API2 now", ["API2"], "alphanumeric identifiers stay whole")
        expect("user_id", "user_name", ["user_name"], "underscore identifier stays whole")
        expect("Send old text today", "Send new words today", ["new words"], "adjacent replacements merge")
        expect("a cat and a dog", "a car and a fox", ["car", "fox"], "unchanged tokens divide spans")
        expect("We go", "Now we go", ["Now we"], "case edit adjacent to insertion")
        expect("we go", "Now we go", ["Now"], "insertion at beginning")
        expect("we go", "we all go", ["all"], "insertion in middle")
        expect("we go", "we go now", ["now"], "insertion at end")
        expect("we go", "we go right now!", ["right now!"], "insertion trims outer whitespace")
        expect("go", "going", ["going"], "word extension highlights complete new word")
        expect("x old y", "x new\twords y", ["new\twords"], "internal inserted whitespace preserved")
        expect("x old y", "x new\nwords y", ["new\nwords"], "internal newline preserved")

        expect("one two three", "one three", [], "pure word deletion")
        expect("very very good", "very good", [], "repeated-word deletion")
        expect("colour", "color", ["color"], "removed letters highlight surviving changed word")
        expect("cats", "cat", ["cat"], "removed suffix highlights surviving word")
        expect("not", "no", ["no"], "shortened small word is still a revision")
        expect("They do not agree", "They do agree", [], "whole word deletion has no revised range")
        expect("one, two!", "one two", [], "pure punctuation deletion")
        expect("Remove this. Keep that.", "Keep that.", [], "removed sentence")
        expect("cats run slow", "cat run quickly", ["cat", "quickly"], "shortened word and replacement both marked")
        expect("do not go now", "do go later", ["later"], "word deletion beside replacement")
        expect("one two", "two one", ["one"], "stable textual move looks like insertion and deletion")
        expect("a b a", "a a b", ["b"], "stable left-to-right repeated-token tie")

        expect("one  two\nthree", "one two\tthree", [], "whitespace-only changes ignored")
        expect("ice cream", "icecream", [], "whitespace-only word join ignored")
        expect("icecream", "ice cream", [], "whitespace-only word split ignored")
        expect("Hello world", "Hello, world.", [",", "."], "punctuation insertions retained")
        expect("Really?", "Really!", ["!"], "punctuation replacement")
        expect("Lets go", "Let's go", ["Let's"], "apostrophe inside word")
        expect("'hello'", "“hello”", ["“", "”"], "quote replacement does not tint word")
        expect("one-two", "one—two", ["—"], "hyphen to dash replacement")
        expect("Wait.", "Wait...", [".."], "repeated punctuation insertion")
        expect("x", "x?!", ["?!"], "adjacent inserted punctuation merges")

        expect("\u{4ECA}\u{5929}\u{5929}\u{6C14}\u{597D}\u{3002}", "\u{4ECA}\u{5929}\u{5929}\u{6C14}\u{5F88}\u{597D}\u{3002}", ["\u{5F88}"], "Han insertion without spaces")
        expect("\u{6211}\u{559C}\u{6B22}\u{732B}\u{3002}", "\u{6211}\u{559C}\u{6B22}\u{72D7}\u{3002}", ["\u{72D7}"], "Han replacement at character granularity")
        expect("\u{4ECA}\u{5929}\u{53BB}\u{5317}\u{4EAC}\u{3002}", "\u{660E}\u{5929}\u{53BB}\u{4E0A}\u{6D77}\u{3002}", ["\u{660E}", "\u{4E0A}\u{6D77}"], "separate Chinese changes")
        expect("\u{4ECA}\u{5929}\u{771F}\u{7684}\u{5F88}\u{597D}\u{3002}", "\u{4ECA}\u{5929}\u{5F88}\u{597D}\u{3002}", [], "Chinese pure deletion")
        expect("\u{7528}Talkles\u{5199}\u{4E2D}\u{6587}", "\u{7528}Talkless\u{5199}\u{4E2D}\u{6587}", ["Talkless"], "Latin tokens next to Han")
        expect("\u{4E2D}\u{6587}AI\u{4E2D}\u{6587}", "\u{4E2D}\u{6587}\u{FF21}\u{FF29}\u{4E2D}\u{6587}", ["\u{FF21}\u{FF29}"], "fullwidth compatibility variant stays distinct")
        expect("\u{732B}\u{304C}\u{3044}\u{308B}", "\u{72AC}\u{304C}\u{3044}\u{308B}", ["\u{72AC}"], "Japanese Han and kana need no spaces")
        expect("\u{304B}\u{306A}", "\u{304B}\u{306B}", ["\u{306B}"], "kana edits at character granularity")
        expect("\u{20000}\u{4F60}\u{597D}\u{30000}", "\u{20000}\u{60A8}\u{597D}\u{30000}", ["\u{60A8}"], "supplementary Han boundaries")
        expect("Привет мир", "Привет друг", ["друг"], "Cyrillic word replacement")
        expect("γεια κόσμε", "γεια φίλε", ["φίλε"], "Greek word replacement")
        expect("مرحبا بك", "مرحبا بكم", ["بكم"], "Arabic word extension")
        expect("नमस्ते मित्र", "नमस्ते दुनिया", ["दुनिया"], "Indic clusters remain whole")
        expect("안녕 친구", "안녕 세상", ["세상"], "Hangul word replacement")

        expect("Café", "Cafe\u{301}", [], "canonical-equivalent output unchanged")
        expect("a\u{323}\u{301}", "a\u{301}\u{323}", [], "canonical mark reordering unchanged")
        expect("가", "\u{1100}\u{1161}", [], "Hangul canonical equivalent unchanged")
        expect("Café old", "Cafe\u{301} new", ["new"], "canonical token equal amid other edits")
        expect("plain old", "Cafe\u{301} new", ["Cafe\u{301} new"], "decomposed revised range uses exact source bytes")
        expect("ff", "ﬀ", ["ﬀ"], "ligature compatibility is not canonical equality")
        expect("👩🏽‍💻 old", "👩🏽‍💻 Cafe\u{301}", ["Cafe\u{301}"], "indices after multiscalar emoji")
        expect("👩‍💻", "👩🏽‍💻", ["👩🏽‍💻"], "skin tone ZWJ replacement is one grapheme")
        expect("🇨🇦 hello", "🇨🇳 hello", ["🇨🇳"], "flag replacement is whole regional pair")
        expect("👨‍👩‍👧‍👦", "👩‍👩‍👧‍👦", ["👩‍👩‍👧‍👦"], "family emoji remains whole")
        expect("❤", "❤️", ["❤️"], "variation selector not stripped")
        expect("Hi 👋", "Hi 👋🏽!", ["👋🏽!"], "emoji and adjacent punctuation merge")
        expect("a\u{301}", "a\u{300}", ["a\u{300}"], "combining marks never split")

        let limitPrefix = String(repeating: "a ", count: 511)
        expect(limitPrefix + "old", limitPrefix + "new", ["new"], "512 tokens supported")
        let overLimitPrefix = String(repeating: "a ", count: 512)
        expect(overLimitPrefix + "old", overLimitPrefix + "new", [], "513 tokens skip decoration")
        expect("old", overLimitPrefix + "new", [], "revised token cap alone enforced")
        expect(overLimitPrefix + "old", "new", [], "original token cap alone enforced")
        let hugeWord = String(repeating: "a", count: 65_537)
        expect(hugeWord, "b", [], "original byte cap even for single word")
        expect("b", hugeWord, [], "revised byte cap even for single word")
        let hugeGrapheme = "a" + String(repeating: "\u{301}", count: 40_000)
        expect(hugeGrapheme, "b", [], "byte cap before pathological grapheme segmentation")
        expect("b", hugeGrapheme, [], "revised pathological grapheme also capped")
        expect(String(repeating: "a", count: 65_536), "b", ["b"], "exact byte limit allowed")

        // Exercise the maximum LCS table without flaky wall-clock assertions or real speech.
        let oldTokens = (0..<512).map { "old\($0)" }.joined(separator: " ")
        let newTokens = (0..<512).map { "new\($0)" }.joined(separator: " ")
        expect(oldTokens, newTokens, [newTokens], "maximum disjoint-token workload")
        let ambiguousOriginal = "a b a b a b"
        let ambiguousRevised = "b a b a b a"
        let first = TextRevisionHighlight.ranges(original: ambiguousOriginal, revised: ambiguousRevised)
        for _ in 0..<100 {
            check(TextRevisionHighlight.ranges(original: ambiguousOriginal, revised: ambiguousRevised) == first,
                  "deterministic repeated-token alignment")
        }

        // Removing whole visible tokens never marks unchanged surviving tokens. Keep spaces
        // between lexical tokens: deleting letters within a token is instead a word revision.
        let deletionTokens = ["alpha", "\u{732B}", "café", "👩🏽‍💻", "!", "beta"]
        let deletionSource = deletionTokens.joined(separator: " ")
        for mask in 1..<(1 << deletionTokens.count) {
            let revised = deletionTokens.enumerated().compactMap { offset, token in
                mask & (1 << offset) == 0 ? nil : token
            }.joined(separator: " ")
            expect(deletionSource, revised, [], "exhaustive whole-token deletion subset \(mask)")
        }
        print("Text revision highlight tests passed (\(assertions) assertions; Foundation only, offline synthetic data)")
    }
}
