import Testing
@testable import Talkless

@Suite struct TextFormattingTests {
    func f(_ text: String, _ punctuation: PunctuationStyle = .keepAll, _ spacing: LatinSpacing = .none) -> String {
        TextFormatting.apply(text, punctuation: punctuation, spacing: spacing)
    }

    @Test func defaultsKeepTextExceptSpacesAroundLatin() {
        #expect(f("\u{7528} Python \u{5199} 3 \u{4E2A}\u{811A}\u{672C}\u{3002}") == "\u{7528}Python\u{5199}3\u{4E2A}\u{811A}\u{672C}\u{3002}")
        #expect(f("Hello, world. \u{4F60}\u{597D}\u{FF01}") == "Hello, world. \u{4F60}\u{597D}\u{FF01}", "Latin-to-Latin and punctuation spaces stay")
        #expect(f("\u{7B2C}\u{4E00}\u{884C} A\n\u{7B2C}\u{4E8C}\u{884C} B") == "\u{7B2C}\u{4E00}\u{884C}A\n\u{7B2C}\u{4E8C}\u{884C}B", "Line breaks are never removed")
    }

    @Test func spacedSetsOffLatinAndNumbers() {
        #expect(f("\u{7528}Python\u{5199}3\u{4E2A}\u{811A}\u{672C}", .keepAll, .spaced) == "\u{7528} Python \u{5199} 3 \u{4E2A}\u{811A}\u{672C}")
        #expect(f("\u{7528} Python \u{5199}", .keepAll, .spaced) == "\u{7528} Python \u{5199}", "No doubled spaces")
        #expect(f("\u{7248}\u{672C}v1.2.3\u{53D1}\u{5E03}", .keepAll, .spaced) == "\u{7248}\u{672C} v1.2.3 \u{53D1}\u{5E03}", "Versions stay intact")
    }

    @Test func noTrailingDropsOnlyTheFinalPeriodLikeMark() {
        #expect(f("\u{4ECA}\u{5929}\u{5F00}\u{4F1A}\u{3002}\u{660E}\u{5929}\u{51FA}\u{5DEE}\u{3002}", .noTrailing) == "\u{4ECA}\u{5929}\u{5F00}\u{4F1A}\u{3002}\u{660E}\u{5929}\u{51FA}\u{5DEE}")
        #expect(f("\u{4F60}\u{6765}\u{5417}\u{FF1F}", .noTrailing) == "\u{4F60}\u{6765}\u{5417}\u{FF1F}", "Questions keep their mark")
        #expect(f("Ship it.", .noTrailing) == "Ship it")
        #expect(f("Wait...", .noTrailing) == "Wait...", "A dotted ellipsis stays")
        #expect(f("\u{7B2C}\u{4E00}\u{6761}\u{FF0C}\n\u{7B2C}\u{4E8C}\u{6761}\u{3002}", .noTrailing) == "\u{7B2C}\u{4E00}\u{6761}\n\u{7B2C}\u{4E8C}\u{6761}", "Every line ends without a period")
    }

    @Test func spacesReplacePunctuationButNotDecimalsOrURLs() {
        #expect(f("\u{4F60}\u{597D}\u{FF0C}\u{4E16}\u{754C}\u{3002}\u{4ECA}\u{5929}\u{5F00}\u{4F1A}\u{FF01}", .spaces) == "\u{4F60}\u{597D} \u{4E16}\u{754C} \u{4ECA}\u{5929}\u{5F00}\u{4F1A}")
        #expect(f("Hello, world. See x.com today.", .spaces) == "Hello world See x.com today")
        #expect(f("\u{4EF7}\u{683C}\u{662F}3.14\u{5143}\u{3002}", .spaces) == "\u{4EF7}\u{683C}\u{662F}3.14\u{5143}")
        #expect(f("\u{4F60}\u{597D}\u{FF0C}Tom\u{3002}", .spaces, .none) == "\u{4F60}\u{597D} Tom", "Replacement spaces survive the no-space option")
        #expect(f("\u{4F60}\u{597D}\u{FF0C}Tom\u{3002}", .spaces, .spaced) == "\u{4F60}\u{597D} Tom")
    }
}
