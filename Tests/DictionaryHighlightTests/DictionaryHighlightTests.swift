import Foundation

@main
struct DictionaryHighlightTests {
    static func main() {
        var assertions = 0
        func check(_ value: @autoclosure () -> Bool, _ description: String) {
            assertions += 1
            guard value() else { fatalError("FAIL: \(description)") }
        }
        func expect(_ text: String, terms: [String], _ expected: [String], _ description: String) {
            let ranges = DictionaryHighlightMatcher(terms: terms).ranges(in: text)
            let matches = ranges.map { String(text[$0]) }
            check(matches == expected, "\(description): got \(matches), expected \(expected)")
            let boundaries = Set(text.indices).union([text.endIndex])
            var previousEnd = text.startIndex
            for range in ranges {
                check(boundaries.contains(range.lowerBound) && boundaries.contains(range.upperBound), "\(description): grapheme-safe endpoints")
                check(range.lowerBound >= previousEnd && range.lowerBound < range.upperBound, "\(description): ordered nonempty nonoverlap")
                let nsRange = NSRange(range, in: text)
                check(Range(nsRange, in: text) == range, "\(description): Foundation index bridge")
                check(Array((text as NSString).substring(with: nsRange).utf8) == Array(text[range].utf8), "\(description): original bytes preserved")
                previousEnd = range.upperBound
            }
        }

        expect("", terms: ["OpenAI"], [], "empty text")
        expect("OpenAI", terms: [], [], "empty dictionary")
        expect("OpenAI openai OPENAI OpenAI", terms: ["OpenAI"], ["OpenAI", "OpenAI"], "case-sensitive repeated presence")
        expect("OpenAI openai OPENAI", terms: ["OpenAI", "OPENAI"], ["OpenAI", "OPENAI"], "case-distinct terms")
        expect("Talkles Talkless TalkLess", terms: ["Talkless"], ["Talkless"], "presence, not fuzzy correction")
        expect("chair CHAIR AI API APIs XAPI API2 2API", terms: ["AI", "API"], ["AI", "API"], "whole words and digits")
        expect("7 17 70 x7 7x", terms: ["7"], ["7"], "numeric terms need boundaries")
        expect("_API API_ my_API API_v2 user_id user_id2", terms: ["API", "user_id"], ["user_id"], "underscore identifiers")
        expect("OpenAI's OpenAI\u{2019}s pre-OpenAI OpenAI-like OpenAI\u{2010}like OpenAI\u{2011}like", terms: ["OpenAI"], [], "apostrophes and hyphens join words")
        expect("'OpenAI' \u{2018}OpenAI\u{2019} \u{201C}OpenAI\u{201D} OpenAI\u{2014}API OpenAI\u{2013}API", terms: ["OpenAI", "API"], ["OpenAI", "OpenAI", "OpenAI", "OpenAI", "API", "OpenAI", "API"], "quotes and dashes delimit words")
        expect("OpenAI's API-like rock'n'roll user_id", terms: ["OpenAI's", "API-like", "rock'n'roll", "user_id"], ["OpenAI's", "API-like", "rock'n'roll", "user_id"], "full lexical punctuation terms")
        expect("OpenAI's OpenAI\u{2019}s", terms: ["OpenAI's"], ["OpenAI's"], "apostrophe variants are not normalized")
        expect("(C++), C+++ C++17 XC++ C++Builder C++-like C++.", terms: ["C++"], ["C++", "C++"], "C++ punctuation and exterior boundaries")
        expect(".NET .NETCore X.NET ..NET (.NET), .NET-Framework", terms: [".NET"], [".NET", ".NET"], ".NET punctuation and exterior boundaries")
        expect("C++ C# .NET a.b [x] a+b (a+)+", terms: ["C++", "C#", ".NET", "a.b", "[x]", "a+b", "(a+)+"], ["C++", "C#", ".NET", "a.b", "[x]", "a+b", "(a+)+"], "terms are literal, never regular expressions")
        expect("\u{7528}\u{98DE}\u{4E66}\u{8054}\u{7CFB}\u{5F20}\u{4E09}\u{FF0C}\u{98DE}\u{4E66}\u{91CC}\u{4E5F}\u{652F}\u{6301}OpenAI\u{5199}\u{4F5C}\u{3002}", terms: ["\u{98DE}\u{4E66}", "\u{5F20}\u{4E09}", "OpenAI"], ["\u{98DE}\u{4E66}", "\u{5F20}\u{4E09}", "\u{98DE}\u{4E66}", "OpenAI"], "Chinese substrings and Latin next to Han")
        expect("A\u{98DE}\u{4E66}B \u{98DE}\u{4E66}2 \u{20000}\u{98DE}\u{4E66}\u{30000} \u{98DE}\u{4E66}\u{3005}", terms: ["\u{98DE}\u{4E66}"], ["\u{98DE}\u{4E66}", "\u{98DE}\u{4E66}", "\u{98DE}\u{4E66}", "\u{98DE}\u{4E66}"], "Han terms do not require spaces")
        expect("\u{20000}OpenAI\u{30000} \u{3007}OpenAI\u{3005}", terms: ["OpenAI"], ["OpenAI", "OpenAI"], "extended Han and iteration marks delimit Latin")
        expect("\u{98DE}\u{4E66}API\u{529F}\u{80FD} A\u{98DE}\u{4E66}API\u{529F}\u{80FD} \u{98DE}\u{4E66}APIs \u{98DE}\u{4E66}API\u{5DE5}\u{5177}2", terms: ["\u{98DE}\u{4E66}API"], ["\u{98DE}\u{4E66}API", "\u{98DE}\u{4E66}API", "\u{98DE}\u{4E66}API"], "mixed Han and Latin term boundary follows endpoint")
        expect("\u{E9}API API\u{E9} \u{3B1}API API\u{3B2} \u{416}API API\u{416}", terms: ["API"], [], "non-Han letters are lexical")

        expect("New York New  York New\tYork New\nYork New\u{A0}York", terms: ["New York"], ["New York"], "phrase spacing is literal")
        expect("New York New  York New\tYork", terms: ["New  York", "New\tYork"], ["New  York", "New\tYork"], "legacy spaces and tabs are preserved")
        expect("x OpenAI y", terms: [" OpenAI "], [" OpenAI "], "caller-supplied exterior spaces are literal")
        expect("New Yorker New York2 XNew York (New York)", terms: ["New York"], ["New York"], "phrase exterior lexical boundaries")

        expect("Caf\u{E9} Cafe\u{301}", terms: ["Caf\u{E9}"], ["Caf\u{E9}", "Cafe\u{301}"], "decomposed input matches NFC term")
        expect("Caf\u{E9} Cafe\u{301}", terms: ["Cafe\u{301}"], ["Caf\u{E9}", "Cafe\u{301}"], "decomposed term matches NFC input")
        expect("\u{C5} A\u{30A} \u{212B}", terms: ["\u{C5}", "A\u{30A}", "\u{212B}"], ["\u{C5}", "A\u{30A}", "\u{212B}"], "canonical duplicate terms do not duplicate ranges")
        expect("a\u{323}\u{301} a\u{301}\u{323}", terms: ["\u{1EA1}\u{301}"], ["a\u{323}\u{301}", "a\u{301}\u{323}"], "canonically reordered combining marks")
        expect("\u{AC00} \u{1100}\u{1161}", terms: ["\u{AC00}"], ["\u{AC00}", "\u{1100}\u{1161}"], "Hangul canonical decomposition")
        expect("AI \u{FF21}\u{FF29} \u{FB00} ff", terms: ["AI", "ff"], ["AI", "ff"], "no compatibility normalization")
        expect("\u{E9} e\u{301} e", terms: ["e", "\u{301}"], ["e"], "never match part of accented grapheme")
        expect("\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}\u{1F469}\u{200D}\u{1F4BB} \u{1F469} \u{1F469}\u{1F3FD} \u{1F469}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466} \u{1F1E8}\u{1F1F3} \u{1F1E8}\u{1F1E6}", terms: ["\u{1F469}", "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}", "\u{1F1E8}\u{1F1F3}", "\u{1F1E8}"], ["\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}", "\u{1F469}", "\u{1F1E8}\u{1F1F3}"], "emoji ZWJ skin tones and regional indicators stay whole")
        expect("\u{2764} \u{2764}\u{FE0F} \u{2615}\u{FE0F} \u{2615}", terms: ["\u{2764}", "\u{2615}"], ["\u{2764}", "\u{2615}"], "variation selectors are not stripped")
        expect("\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB} Cafe\u{301} \u{98DE}\u{4E66} \u{1F1E8}\u{1F1F3} OpenAI", terms: ["Caf\u{E9}", "\u{98DE}\u{4E66}", "OpenAI"], ["Cafe\u{301}", "\u{98DE}\u{4E66}", "OpenAI"], "mixed script indices after multiscalar graphemes")

        expect("New York City and New York", terms: ["New", "New York", "New York City", "York", "City"], ["New York City", "New York"], "longest at same start wins")
        expect("New York City", terms: ["York City", "New York"], ["New York"], "leftmost match wins across overlapping starts")
        expect("New YorkCity", terms: ["New", "New York"], ["New"], "invalid longer boundary falls back to valid shorter term")
        expect("\u{98DE}\u{4E66}\u{98DE}\u{4E66}", terms: ["\u{98DE}\u{4E66}", "\u{4E66}\u{98DE}", "\u{98DE}"], ["\u{98DE}\u{4E66}", "\u{98DE}\u{4E66}"], "adjacent nonoverlapping matches")
        expect("\u{98DE}\u{4E66}\u{91CC}", terms: ["\u{98DE}", "\u{98DE}\u{4E66}", "\u{98DE}\u{4E66}\u{91CC}"], ["\u{98DE}\u{4E66}\u{91CC}"], "longest Han substring")
        expect("OpenAI", terms: ["OpenAI", "OpenAI", "", "Open"], ["OpenAI"], "duplicates and invalid prefix ignored")

        expect("OpenAI\0 OpenAI\nOpenAI", terms: ["", " ", "\t", "\n", "\u{301}", "\u{200D}", "OpenAI\0", "OpenAI\nOpenAI", "OpenAI"], ["OpenAI", "OpenAI", "OpenAI"], "invalid terms do not poison valid entries")
        let legacy = String(repeating: "legacy", count: 100)
        expect("\(legacy) OpenAI", terms: [legacy, "OpenAI"], [legacy, "OpenAI"], "legacy term longer than add-dialog limit")
        let enormous = String(repeating: "a", count: 65_537)
        expect("\(enormous) OpenAI", terms: [enormous, "OpenAI"], ["OpenAI"], "enormous terms ignored without starving later terms")
        let pathologicalGrapheme = "a" + String(repeating: "\u{301}", count: 40_000)
        expect("\(pathologicalGrapheme) OpenAI", terms: [pathologicalGrapheme, "OpenAI"], ["OpenAI"], "byte bound handles enormous single graphemes")
        let manyTerms = (0..<2_000).map { "Project\($0)" }
        expect("Project0 Project1999 Project10000", terms: manyTerms, ["Project0", "Project1999"], "no arbitrary dictionary count limit")

        let reusable = DictionaryHighlightMatcher(terms: ["OpenAI", "Caf\u{E9}"])
        for text in ["OpenAI", "Caf\u{E9}", "Cafe\u{301}", "OpenAI", ""] {
            check(reusable.ranges(in: text).count == (text.isEmpty ? 0 : 1), "immutable matcher reuse across revisions")
        }
        // Shared-prefix workload models repeated preview updates with thousands of saved terms.
        // No timing threshold: CI machines differ, but exercise the actual trie at realistic scale.
        let loadMatcher = DictionaryHighlightMatcher(terms: manyTerms)
        let preview = String(repeating: "ProjectX ", count: 100) + "Project1999"
        for _ in 0..<100 {
            check(loadMatcher.ranges(in: preview).map { String(preview[$0]) } == ["Project1999"], "shared-prefix repeated-preview workload")
        }
        let prefixMatcher = DictionaryHighlightMatcher(terms: [String(repeating: "\u{98DE}", count: 4_000) + "\u{4E66}", "OpenAI"])
        let repeatedPrefix = String(repeating: "\u{98DE}", count: 700) + " OpenAI"
        check(prefixMatcher.ranges(in: repeatedPrefix).map { String(repeatedPrefix[$0]) } == ["OpenAI"], "adversarial shared-prefix near misses remain bounded by displayed input")
        print("Dictionary highlight tests passed (\(assertions) assertions; Foundation only, offline synthetic data)")
    }
}
