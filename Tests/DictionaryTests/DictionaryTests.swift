import AppKit
import Foundation
import SwiftUI

// No history singleton, standard defaults, Keychain, microphone, model, or network is used.
enum TalklessError: Error { case message(String) }
@MainActor final class ModelManager {
    static let shared = ModelManager()
    let isChecking = false
    let activeModelID = "synthetic-model"
    func installedDirectory(_ id: String) -> URL? { nil }
}
enum ModelCatalog {
    struct Model { let name: String }
    static func model(id: String) -> Model? { nil }
}
final class DictionaryMemoryDefaults: UserDefaults, @unchecked Sendable {
    var values: [String: Any] = [:]
    init() { super.init(suiteName: "talkless-dictionary-tests-\(UUID().uuidString)")! }
    override func object(forKey key: String) -> Any? { values[key] }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
}
@MainActor final class DictionaryMemoryCredentials: CredentialStoring {
    func credential(for provider: PolishProvider) throws -> String? { nil }
    func setCredential(_ value: String, for provider: PolishProvider) throws {}
}

@main
struct DictionaryTests {
    @MainActor
    static func main() async throws {
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        localization.interfaceLanguage = .english
        defer { withExtendedLifetime(localization) {} }
        var assertions = 0
        func check(_ value: @autoclosure () -> Bool, _ description: String) {
            assertions += 1
            guard value() else { fatalError("FAIL: \(description)") }
        }
        func extraction(_ raw: String, _ output: String) -> [DictionaryCorrection] {
            DictionaryCorrectionExtractor.extract(raw: raw, output: output)
        }
        func entry(_ raw: String = "Please open Talkles for this meeting.",
                   _ output: String = "Please open Talkless for this meeting.",
                   kind: HistoryEntry.Kind = .dictation) -> HistoryEntry {
            HistoryEntry(kind: kind, app: "Synthetic App", raw: raw, output: output, duration: 2)
        }
        func settings(_ d: DictionaryMemoryDefaults) -> AppSettings {
            AppSettings(defaults: d, credentialStore: DictionaryMemoryCredentials())
        }

        check(extraction("Please open Talkles for this meeting.", "Please open Talkless for this meeting.").map(\.term) == ["Talkless"], "Latin spelling correction")
        check(extraction("Talkles", "Talkless").map(\.term) == ["Talkless"], "standalone spelling")
        check(extraction("please open the document", "Please open the document").isEmpty, "sentence capitalization is not a term")
        check(extraction("He walk to the office every day", "He walks to the office every day").isEmpty, "simple grammar suffix is not a term")
        check(extraction("Please contact Richard for this meeting", "Please contact Richards for this meeting").map(\.term) == ["Richards"],
              "existing proper-name suffix correction remains available")
        check(extraction("Please use Window for this task", "Please use Windows for this task").map(\.term) == ["Windows"],
              "existing product-name suffix correction remains available")
        check(extraction("talkles", "talkless").map(\.term) == ["talkless"], "lowercase doubled final s is spelling evidence")
        check(extraction("Use open ai for this task", "Use OpenAI for this task").map(\.term) == ["OpenAI"], "bounded multiword spelling")
        check(extraction("Please check user_id in this file", "Please check user_ID in this file").isEmpty, "identifier case-only change excluded")
        for spelling in ["Talkless", "talkless", "TALKLESS", "tAlKlEsS"] {
            check(extraction("talkless", spelling).isEmpty, "standalone case-only change excluded: \(spelling)")
            check(extraction("Please open talkless for this meeting", "Please open \(spelling) for this meeting").isEmpty,
                  "mid-sentence case-only change excluded: \(spelling)")
        }
        let caseContext = extraction("please OPEN Talkles FOR THIS meeting", "Please open Talkless for this meeting")
        check(caseContext.map(\.term) == ["Talkless"], "case-only surrounding tokens do not hide a spelling correction")
        check(caseContext.first?.sourceSnippet == "please OPEN Talkles FOR THIS meeting", "case folding preserves raw evidence")
        check(extraction("Please check user_id in this file", "Please check USER-ID in this file").isEmpty,
              "case plus identifier punctuation-only change excluded")
        check(extraction("Stra\u{df}e", "STRASSE").isEmpty, "Unicode case folding excludes case-only length changes")
        check(extraction("Please visit Cafe tomorrow morning", "Please visit Caf\u{e9} tomorrow morning").map(\.term) == ["Caf\u{e9}"], "accent correction")
        check(extraction("Please visit Cafe\u{301} tomorrow morning", "Please visit Caf\u{e9} tomorrow morning").isEmpty, "canonical Unicode equivalence is not a correction")
        // Han strings are escaped so these standalone tests are independent of source encoding.
        let hanRaw = "\u{8BF7}\u{5728}\u{98DE}\u{8F93}\u{91CC}\u{8054}\u{7CFB}\u{5F20}\u{4E09}\u{3002}"
        let hanOutput = "\u{8BF7}\u{5728}\u{98DE}\u{4E66}\u{91CC}\u{8054}\u{7CFB}\u{5F20}\u{4E09}\u{3002}"
        let han = extraction(hanRaw, hanOutput)
        check(han.map(\.term) == ["\u{98DE}\u{4E66}"], "Han correction expands to short name")
        check(han.first?.source == "\u{98DE}\u{8F93}", "Han raw evidence retained")
        check(extraction("\u{4ECA}\u{5929}\u{8BA8}\u{8BBA}\u{6DF1}\u{6E21}\u{5B66}\u{4E60}\u{7684}\u{6A21}\u{578B}",
                         "\u{4ECA}\u{5929}\u{8BA8}\u{8BBA}\u{6DF1}\u{5EA6}\u{5B66}\u{4E60}\u{7684}\u{6A21}\u{578B}").map(\.term) == ["\u{6DF1}\u{5EA6}"], "Han word correction")
        check(extraction("We use Talkles \u{1F469}\u{200D}\u{1F4BB} during meetings", "We use Talkless \u{1F469}\u{200D}\u{1F4BB} during meetings").map(\.term) == ["Talkless"], "emoji grapheme context")
        check(extraction("\u{98DE}\u{8F93}", "\u{98DE}\u{4E66}").isEmpty, "unanchored Han fragments stay conservative")
        check(extraction("", "").isEmpty, "empty")
        check(extraction("... -- \n", "!? \n").isEmpty, "punctuation only")
        check(extraction("hello, world!", "hello world.").isEmpty, "punctuation formatting excluded")
        check(extraction("Please open user_id for this test", "Please open user-id for this test").isEmpty, "identifier punctuation-only change excluded")
        check(extraction("Hello world", "Hello wonderful world").isEmpty, "insertions excluded")
        check(extraction("Hello wonderful world", "Hello world").isEmpty, "deletions excluded")
        check(extraction("Please make the report a lot better now", "Kindly improve this document substantially").isEmpty, "large rewrite excluded")
        check(extraction("We met on 2025 during the event", "We met on 2026 during the event").isEmpty, "numeric correction is not a term")
        check(extraction("We want to use the red car", "We want to use the blue car").isEmpty, "unrelated vocabulary change excluded")
        check(extraction("\u{6211}\u{4EEC}\u{4ECA}\u{5929}\u{4E0B}\u{5348}\u{5F00}\u{4F1A}", "We will have a meeting this afternoon").isEmpty, "cross-script translation excluded")
        check(extraction("We use \u{98DE}\u{4E66} for this meeting", "We use Feishu for this meeting").isEmpty, "isolated translated name excluded")
        check(extraction(String(repeating: "a", count: 2_000), "Talkless").isEmpty, "oversize strings rejected")
        check(extraction(String(repeating: "word ", count: 170) + "Talkles", String(repeating: "word ", count: 170) + "Talkless").isEmpty, "token alignment cap")
        let long = extraction(String(repeating: "x", count: 80) + " please use Talkles for this", String(repeating: "x", count: 80) + " please use Talkless for this")
        check(long.first?.sourceSnippet.hasPrefix("…") == true, "snippets bounded around change")
        check(long.first?.sourceSnippet.contains("Talkles") == true, "snippet includes original spelling")

        let rawDictionary = "  OpenAI \r\n\tTalkless\t\nOpenAI\n\nopenAI\r\u{98DE}\u{4E66}\u{2028}My  Project\n"
        check(DictionaryTerms.terms(in: rawDictionary) == ["OpenAI", "Talkless", "openAI", "\u{98DE}\u{4E66}", "My  Project"], "legacy terms preserved with case and spacing")
        check(DictionaryTerms.adding("newTerm", to: rawDictionary) == rawDictionary + "newTerm", "append does not rewrite old text")
        check(DictionaryTerms.adding("OpenAI", to: rawDictionary) == nil, "exact duplicate add blocked")
        check(DictionaryTerms.adding("OPENAI", to: rawDictionary) != nil, "explicit case-distinct terms allowed")
        check(DictionaryTerms.adding("a\nb", to: rawDictionary) == nil, "multiline term rejected")
        check(DictionaryTerms.adding("a\u{0}b", to: rawDictionary) == nil, "control character term rejected")
        check(DictionaryTerms.adding("   ", to: rawDictionary) == nil, "empty term rejected")
        check(DictionaryTerms.replacing("Talkless", with: "TalkLess", in: rawDictionary) == rawDictionary.replacingOccurrences(of: "\tTalkless\t", with: "TalkLess"), "edit preserves unrelated storage bytes")
        check(DictionaryTerms.replacing("OpenAI", with: nil, in: rawDictionary) == "\tTalkless\t\n\nopenAI\r\u{98DE}\u{4E66}\u{2028}My  Project\n", "delete removes exact duplicate lines without deleting other cases")
        check(DictionaryTerms.replacing("Talkless", with: "OpenAI", in: rawDictionary) == nil, "edit duplicate blocked")
        check(DictionaryTerms.replacing("Talkless", with: "\n", in: rawDictionary) == nil, "invalid edit cannot delete a term")
        let hugeDictionary = (0..<1_000).map { "Term\($0)" }.joined(separator: "\n")
        check(DictionaryTerms.terms(in: DictionaryTerms.adding("FinalTerm", to: hugeDictionary)!).count == 1_001, "existing dictionary never truncated")
        check(DictionaryTerms.reviewKey("Caf\u{e9}") == DictionaryTerms.reviewKey("Cafe\u{301}"), "dismissal key Unicode normalized")
        check(DictionaryTerms.reviewKey("Go") == DictionaryTerms.reviewKey("go"), "dismissal keys ignore capitalization")
        check(DictionaryTerms.reviewKey("CAF\u{c9}") == DictionaryTerms.reviewKey("Cafe\u{301}"), "review identity combines case folding and canonical Unicode")
        check(DictionaryTerms.reviewKey("Cafe") != DictionaryTerms.reviewKey("Caf\u{e9}"), "accent differences remain meaningful")
        check(DictionaryTerms.reviewKey("Stra\u{df}e") == DictionaryTerms.reviewKey("STRASSE"), "Unicode case folding handles expanded letters")
        check(DictionaryTerms.reviewKey("\u{3c3}") == DictionaryTerms.reviewKey("\u{3c2}"), "Unicode case folding handles final sigma")
        check(DictionaryTerms.reviewKey("IDENTIFIER") == DictionaryTerms.reviewKey("identifier"), "review folding uses fixed non-Turkish locale")
        check(DictionaryTerms.reviewKey("I") != DictionaryTerms.reviewKey("\u{131}"), "dotless i remains distinct independent of system locale")
        check(DictionaryTerms.legacyReviewKeys("\u{131}").isDisjoint(with: DictionaryTerms.legacyReviewKeys("I")),
              "legacy variants cannot merge distinct Unicode identities")
        check(DictionaryTerms.reviewKey("\u{98DE}\u{4E66}") != DictionaryTerms.reviewKey("\u{98DE}\u{8F93}"), "Han spellings remain distinct")

        let defaults = DictionaryMemoryDefaults()
        defaults.set(rawDictionary, forKey: "dictionary")
        let app = settings(defaults)
        check(app.dictionary == rawDictionary, "legacy storage loaded unchanged")
        let roundTrip = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry()))
        check(roundTrip.kind == .dictation, "history schema remains compatible")

        // Self-learning dictionary.
        let day: TimeInterval = 24 * 60 * 60
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let learnDefaults = DictionaryMemoryDefaults()
        let learner = settings(learnDefaults)
        check(learner.dictionaryLearningEnabled, "learning is on by default")
        learner.learnFromDictation(raw: "Please open Talkles now.", output: "Please open Talkless now.", fired: [], at: start)
        check(learner.learnedDictionary.fixes.count == 1 && !learner.learnedDictionary.fixes[0].active, "one sighting is only watched")
        check(learner.recognitionReplacements.isEmpty && learner.recognitionTerms.isEmpty, "watched fixes do not apply")
        learner.learnFromDictation(raw: "Talkles works.", output: "Talkless works.", fired: [], at: start + 60)
        check(learner.learnedDictionary.fixes.first?.active == true, "a repeated correction takes effect automatically")
        check(learner.recognitionReplacements == [DictionaryReplacement(heard: "Talkles", term: "Talkless")], "learned fix applies before polish")
        check(learner.recognitionTerms == ["Talkless"], "learned term becomes a recognition and polish hint")
        check(learner.learnedDictionary.events.map(\.kind) == [.learned] && learner.learnedDictionary.events[0].term == "Talkless",
              "taking effect is recorded in the learning log")
        check(settings(learnDefaults).learnedDictionary == learner.learnedDictionary, "learned fixes persist across launches")
        check(learner.dictionaryTerms.isEmpty, "learning never edits the user's own terms")

        let tracked = DictionaryReplacements.applyTracking(learner.recognitionReplacements, to: "open talkles and Talkless")
        check(tracked.text == "open Talkless and Talkless" && tracked.fired == [DictionaryLearning.key("Talkles")], "applied fixes are reported")
        learner.learnFromDictation(raw: tracked.text, output: tracked.text, fired: tracked.fired, at: start + 20 * day)
        check(learner.learnedDictionary.fixes[0].applied == 1 && learner.learnedDictionary.fixes[0].lastSeen == start + 20 * day,
              "a fix that is still needed stays fresh")
        learner.expireLearnedFixes(now: start + 49 * day)
        check(learner.learnedDictionary.fixes.count == 1, "a fix used within 30 days stays")
        learner.expireLearnedFixes(now: start + 51 * day)
        check(learner.learnedDictionary.fixes.isEmpty, "a fix unused for 30 days retires on its own")
        check(learner.learnedDictionary.events.first?.kind == .retired, "retiring is recorded in the learning log")
        let legacyState = try JSONDecoder().decode(LearnedDictionary.self, from: Data(#"{"fixes":[],"blocked":[],"seeded":true}"#.utf8))
        check(legacyState.seeded && legacyState.events.isEmpty, "dictionaries saved before the log still load")

        let han2 = "\u{75DB}\u{4E8B}", hanFixed = "\u{540C}\u{4E8B}"
        check(DictionaryLearning.threshold(for: han2) == 3 && DictionaryLearning.threshold(for: "Talkles") == 2,
              "two-character Chinese needs more evidence")
        var hanState = LearnedDictionary()
        for minute in 0..<2 {
            hanState = DictionaryLearning.observe(raw: "\u{65B0}\u{6765}\u{7684}\(han2)\u{5F88}\u{597D}", output: "\u{65B0}\u{6765}\u{7684}\(hanFixed)\u{5F88}\u{597D}",
                                                  at: start + Double(minute), in: hanState, manualTerms: [], manualRules: [])
        }
        check(hanState.fixes.allSatisfy { !$0.active }, "two sightings of a two-character Chinese fix are not enough")

        let manualState = DictionaryLearning.observe(raw: "Talkles works.", output: "Talkless works.", at: start, in: LearnedDictionary(),
                                                     manualTerms: ["Talkles"], manualRules: [])
        check(manualState.fixes.isEmpty, "a spelling in My terms is never learned as a mistake")
        var conflict = LearnedDictionary()
        conflict = DictionaryLearning.observe(raw: "Use Notian here.", output: "Use Notion here.", at: start, in: conflict, manualTerms: [], manualRules: [])
        conflict = DictionaryLearning.observe(raw: "Use Notian here.", output: "Use Nation here.", at: start + 1, in: conflict, manualTerms: [], manualRules: [])
        check(conflict.fixes.count == 1 && conflict.fixes[0].term == "Nation" && conflict.fixes[0].observations == 1,
              "conflicting corrections start over instead of guessing")
        let protectedReplacements = DictionaryLearning.replacements(
            LearnedDictionary(fixes: [LearnedFix(heard: "talk less", term: "TalkLess", firstSeen: start, lastSeen: start, observations: 2, active: true)]),
            manualTerms: ["Talkless"], manualRules: [DictionaryReplacement(heard: "talk less", term: "Talkless")])
        check(protectedReplacements.isEmpty, "hand-written fixes win over learned ones")

        let undoDefaults = DictionaryMemoryDefaults()
        let undo = settings(undoDefaults)
        undo.learnFromDictation(raw: "Talkles works.", output: "Talkless works.", fired: [], at: start)
        undo.learnFromDictation(raw: "Talkles works.", output: "Talkless works.", fired: [], at: start + 1)
        undo.learnFromDictation(raw: "Talkless works.", output: "Talkles works.", fired: [], at: start + 2)
        check(!undo.learnedDictionary.fixes.contains { $0.active }, "polish reverting a learned fix retires it")
        check(undo.learnedDictionary.events.first?.kind == .undone, "an undone fix is recorded in the learning log")

        let removeDefaults = DictionaryMemoryDefaults()
        let remover = settings(removeDefaults)
        for second in 0..<2 { remover.learnFromDictation(raw: "Talkles works.", output: "Talkless works.", fired: [], at: start + Double(second)) }
        remover.removeLearnedFix(remover.learnedDictionary.fixes[0])
        for second in 2..<5 { remover.learnFromDictation(raw: "Talkles works.", output: "Talkless works.", fired: [], at: start + Double(second)) }
        check(remover.learnedDictionary.fixes.isEmpty, "a removed fix is never learned again")

        let keepDefaults = DictionaryMemoryDefaults()
        let keeper = settings(keepDefaults)
        for second in 0..<2 { keeper.learnFromDictation(raw: "Talkles works.", output: "Talkless works.", fired: [], at: start + Double(second)) }
        keeper.keepLearnedFix(keeper.learnedDictionary.fixes[0])
        check(keeper.dictionaryTerms == ["Talkless"] && keeper.activeDictionaryReplacements == [DictionaryReplacement(heard: "Talkles", term: "Talkless")]
              && keeper.learnedDictionary.fixes.isEmpty, "keeping a fix moves it to the user's own entries")

        let offDefaults = DictionaryMemoryDefaults()
        let off = settings(offDefaults)
        for second in 0..<2 { off.learnFromDictation(raw: "Talkles works.", output: "Talkless works.", fired: [], at: start + Double(second)) }
        off.dictionaryLearningEnabled = false
        check(off.recognitionReplacements.isEmpty && off.recognitionTerms.isEmpty, "turning learning off stops learned fixes")
        off.learnFromDictation(raw: "Use Notian here.", output: "Use Notion here.", fired: [], at: start + 3)
        check(off.learnedDictionary.fixes.count == 1, "nothing is learned while off")

        let seedDefaults = DictionaryMemoryDefaults()
        let seeder = settings(seedDefaults)
        let now = Date()
        let samples = [("Talkles works.", "Talkless works.", now - 60), ("Open Talkles.", "Open Talkless.", now - 120)]
        seeder.seedLearnedDictionary(from: samples.map { (raw: $0.0, output: $0.1, date: $0.2) }, now: now)
        check(seeder.learnedDictionary.seeded && seeder.learnedDictionary.fixes.first?.active == true, "existing history seeds learning once")
        seeder.removeLearnedFix(seeder.learnedDictionary.fixes[0])
        seeder.seedLearnedDictionary(from: samples.map { (raw: $0.0, output: $0.1, date: $0.2) }, now: now)
        check(seeder.learnedDictionary.fixes.isEmpty, "seeding never runs twice")

        let legacyDefaults = DictionaryMemoryDefaults()
        legacyDefaults.set(try JSONEncoder().encode(Set([DictionaryTerms.reviewKey("Talkless")])), forKey: "dictionaryReview.dismissed.v1")
        let legacy = settings(legacyDefaults)
        for second in 0..<3 { legacy.learnFromDictation(raw: "Talkles works.", output: "Talkless works.", fired: [], at: start + Double(second)) }
        check(legacy.learnedDictionary.fixes.isEmpty, "spellings dismissed in the old Review list are never learned")

        // Explicit "heard as" fixes.
        func fix(_ text: String, _ rules: [(String, String)]) -> String {
            DictionaryReplacements.apply(rules.map { DictionaryReplacement(heard: $0.0, term: $0.1) }, to: text).text
        }
        check(fix("open talk less now", [("talk less", "Talkless")]) == "open Talkless now", "Latin phrase replaced")
        check(fix("Open TALK LESS.", [("talk less", "Talkless")]) == "Open Talkless.", "matching ignores case")
        check(fix("talklessness", [("talkless", "Talkless")]) == "talklessness", "Latin matches whole words only")
        check(fix("retalkless", [("talkless", "Talkless")]) == "retalkless", "no match inside a longer word")
        check(fix("\u{7528}talkless\u{5199}", [("talkless", "Talkless")]) == "\u{7528}Talkless\u{5199}", "Han neighbors are word boundaries for Latin")
        check(fix("\u{6211}\u{5728}\u{7528}\u{6258}\u{514B}\u{52D2}\u{65AF}\u{5199}\u{7A3F}", [("\u{6258}\u{514B}\u{52D2}\u{65AF}", "Talkless")]) == "\u{6211}\u{5728}\u{7528}Talkless\u{5199}\u{7A3F}", "Han spelling matches without spaces")
        check(fix("\u{6258}\u{514B}\u{52D2}\u{65AF}\u{548C}\u{6258}\u{514B}\u{52D2}\u{65AF}", [("\u{6258}\u{514B}\u{52D2}\u{65AF}", "Talkless")]) == "Talkless\u{548C}Talkless", "every occurrence is fixed")
        check(fix("open cloud code app", [("cloud code", "Claude Code"), ("code", "CODE")]) == "open Claude Code app",
              "longer spelling wins and replaced text is not matched again")
        check(fix("\u{FF54}\u{FF41}\u{FF4C}\u{FF4B}\u{FF4C}\u{FF45}\u{FF53}", [("talkles", "Talkless")]) == "Talkless", "full-width input matches")
        check(fix("nothing here", [("talkles", "Talkless")]) == "nothing here", "no match leaves text unchanged")
        check(DictionaryReplacements.apply([DictionaryReplacement(heard: "talkless", term: "Talkless")], to: "Talkless").count == 0,
              "already-correct text does not count as a fix")
        check(DictionaryReplacements.apply([DictionaryReplacement(heard: "a", term: "A")], to: "a b").text == "a b",
              "single-character rules are ignored")
        check(DictionaryReplacements.heardSpellings(in: "talk less\nTalk Less, \u{6258}\u{514B}\u{52D2}\u{65AF}\u{FF0C}\u{6258}\u{514B}") == ["talk less", "\u{6258}\u{514B}\u{52D2}\u{65AF}", "\u{6258}\u{514B}"],
              "editor splits lines and commas and drops case duplicates")
        let rules = [DictionaryReplacement(heard: "talk less", term: "Talkless"), DictionaryReplacement(heard: "cloud", term: "Claude")]
        check(DictionaryReplacements.problem(heard: "Talk Less", term: "Talkless", rules: rules, terms: ["Talkless", "Claude"]) == nil,
              "a term may keep its own heard spelling")
        check(DictionaryReplacements.problem(heard: "cloud", term: "Talkless", rules: rules, terms: ["Talkless", "Claude"]) != nil,
              "one heard spelling cannot fix two terms")
        check(DictionaryReplacements.problem(heard: "claude", term: "Talkless", rules: rules, terms: ["Talkless", "Claude"]) != nil,
              "a confirmed term is never replaced")
        check(DictionaryReplacements.problem(heard: "talkless", term: "Talkless", rules: [], terms: ["Talkless"]) != nil,
              "a term cannot fix itself")
        check(DictionaryReplacements.problem(heard: "x", term: "Talkless", rules: [], terms: []) != nil, "too-short spellings rejected")
        check(DictionaryReplacements.renaming("Talkless", to: "TalkLess", in: rules)
              == [DictionaryReplacement(heard: "talk less", term: "TalkLess"), rules[1]], "rename keeps fixes")
        check(DictionaryReplacements.renaming("Talkless", to: "Talk Less", in: rules) == [rules[1]],
              "renaming onto a heard spelling drops that self-replacement")
        check(DictionaryReplacements.renaming("Talkless", to: nil, in: rules) == [rules[1]], "deleting a term drops its fixes")
        check(DictionaryReplacements.setting(["talkles"], for: "Talkless", in: rules)
              == [rules[1], DictionaryReplacement(heard: "talkles", term: "Talkless")], "setting replaces only that term's fixes")
        let fixDefaults = DictionaryMemoryDefaults()
        let fixSettings = settings(fixDefaults)
        fixSettings.dictionary = "Talkless"
        fixSettings.dictionaryReplacements = rules
        check(fixSettings.activeDictionaryReplacements == [rules[0]], "fixes for terms not in My terms are inactive")
        check(settings(fixDefaults).dictionaryReplacements == rules, "fixes persist across launches")
        fixDefaults.set(Data("malformed".utf8), forKey: "dictionaryReplacements.v1")
        check(settings(fixDefaults).dictionaryReplacements.isEmpty, "malformed stored fixes are ignored safely")
        let exported = DictionaryTransfer.export(terms: ["Talkless", "OpenAI"], rules: rules)
        check(exported == "Talkless = talk less\nOpenAI\n", "export writes terms with their fixes")
        let merged = DictionaryTransfer.merge("# shared list\n\nTalkless = talk less, talkles\nClaude = cloud\nNew Term\nBroken = Talkless\n=x",
                                              into: "Talkless", rules: [rules[0]])
        check(merged.dictionary == "Talkless\nClaude\nNew Term\nBroken", "import adds only new terms, keeping existing ones")
        check(merged.rules == [rules[0], DictionaryReplacement(heard: "talkles", term: "Talkless"), DictionaryReplacement(heard: "cloud", term: "Claude")],
              "import adds new fixes without duplicating existing ones")
        check(merged.addedTerms == 3 && merged.addedFixes == 2 && merged.skipped == 2,
              "a fix that would replace a confirmed term and an empty term are skipped")
        let roundTripped = DictionaryTransfer.merge(DictionaryTransfer.export(terms: ["A1", "B2"], rules: [DictionaryReplacement(heard: "a one", term: "A1")]),
                                                    into: "", rules: [])
        check(roundTripped.dictionary == "A1\nB2" && roundTripped.rules == [DictionaryReplacement(heard: "a one", term: "A1")],
              "export then import round-trips")
        print("Dictionary tests passed (\(assertions) assertions; offline synthetic data only)")
        if let index = CommandLine.arguments.firstIndex(of: "--screenshots"), CommandLine.arguments.count > index + 1 {
            try await screenshots(in: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
        }
    }

    @MainActor
    private static func screenshots(in directory: URL) async throws {
        let defaults = DictionaryMemoryDefaults()
        let settings = AppSettings(defaults: defaults, credentialStore: DictionaryMemoryCredentials())
        settings.dictionary = "Talkless\nOpenAI\nuser_ID\nMy  Project\n\u{98DE}\u{4E66}"
        settings.dictionaryReplacements = [DictionaryReplacement(heard: "talk less", term: "Talkless"),
                                           DictionaryReplacement(heard: "\u{6258}\u{514B}\u{52D2}\u{65AF}", term: "Talkless")]
        for second in 0..<2 {
            settings.learnFromDictation(raw: "Please open Notian before our meeting.", output: "Please open Notion before our meeting.",
                                        fired: [], at: Date() - Double(second))
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let view = NSHostingView(rootView: DictionaryView(settings: settings).padding(28)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 570),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.title = "Dictionary — Synthetic data"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await Task.sleep(for: .milliseconds(150))
        func save(_ name: String) throws {
            view.layoutSubtreeIfNeeded()
            guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No screenshot bitmap") }
            view.cacheDisplay(in: view.bounds, to: image)
            guard let data = image.representation(using: .png, properties: [:]) else { fatalError("No PNG data") }
            try data.write(to: directory.appendingPathComponent(name))
        }
        try save("dictionary.png")
        print("Dictionary screenshots saved to \(directory.path)")
        window.orderOut(nil)
    }
}
