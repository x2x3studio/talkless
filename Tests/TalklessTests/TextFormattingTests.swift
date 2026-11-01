import Testing
@testable import Talkless

@Suite struct TextFormattingTests {
    func f(_ text: String, _ punctuation: PunctuationStyle = .keepAll, _ spacing: LatinSpacing = .none) -> String {
        TextFormatting.apply(text, punctuation: punctuation, spacing: spacing)
    }

    @Test func defaultsKeepTextExceptSpacesAroundLatin() {
        #expect(f("用 Python 写 3 个脚本。") == "用Python写3个脚本。")
        #expect(f("Hello, world. 你好！") == "Hello, world. 你好！", "Latin-to-Latin and punctuation spaces stay")
        #expect(f("第一行 A\n第二行 B") == "第一行A\n第二行B", "Line breaks are never removed")
    }

    @Test func spacedSetsOffLatinAndNumbers() {
        #expect(f("用Python写3个脚本", .keepAll, .spaced) == "用 Python 写 3 个脚本")
        #expect(f("用 Python 写", .keepAll, .spaced) == "用 Python 写", "No doubled spaces")
        #expect(f("版本v1.2.3发布", .keepAll, .spaced) == "版本 v1.2.3 发布", "Versions stay intact")
    }

    @Test func noTrailingDropsOnlyTheFinalPeriodLikeMark() {
        #expect(f("今天开会。明天出差。", .noTrailing) == "今天开会。明天出差")
        #expect(f("你来吗？", .noTrailing) == "你来吗？", "Questions keep their mark")
        #expect(f("Ship it.", .noTrailing) == "Ship it")
        #expect(f("Wait...", .noTrailing) == "Wait...", "A dotted ellipsis stays")
        #expect(f("第一条，\n第二条。", .noTrailing) == "第一条\n第二条", "Every line ends without a period")
    }

    @Test func spacesReplacePunctuationButNotDecimalsOrURLs() {
        #expect(f("你好，世界。今天开会！", .spaces) == "你好 世界 今天开会")
        #expect(f("Hello, world. See x.com today.", .spaces) == "Hello world See x.com today")
        #expect(f("价格是3.14元。", .spaces) == "价格是3.14元")
        #expect(f("你好，Tom。", .spaces, .none) == "你好 Tom", "Replacement spaces survive the no-space option")
        #expect(f("你好，Tom。", .spaces, .spaced) == "你好 Tom")
    }
}
