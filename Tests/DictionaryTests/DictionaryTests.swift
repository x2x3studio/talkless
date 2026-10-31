import AppKit
import Combine
import CryptoKit
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
        func settled(_ store: DictionaryReviewStore) async {
            for _ in 0..<400 {
                if !store.isScanning { return }
                try? await Task.sleep(for: .milliseconds(5))
            }
            fatalError("Scan did not settle")
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
        check(DictionaryCorrectionExtractor.extract(from: entry(kind: .edit)).isEmpty, "voice edits never mined")
        check(DictionaryCorrectionExtractor.extract(from: entry(kind: .translation)).isEmpty, "translations never mined")
        check(extraction(String(repeating: "a", count: 2_000), "Talkless").isEmpty, "oversize strings rejected")
        check(extraction(String(repeating: "word ", count: 170) + "Talkles", String(repeating: "word ", count: 170) + "Talkless").isEmpty, "token alignment cap")
        let long = extraction(String(repeating: "x", count: 80) + " please use Talkles for this", String(repeating: "x", count: 80) + " please use Talkless for this")
        check(long.first?.sourceSnippet.hasPrefix("…") == true, "snippets bounded around change")
        check(long.first?.sourceSnippet.contains("Talkles") == true, "snippet includes original spelling")

        let repeated = entry("Talkles is open and Talkles works well", "Talkless is open and Talkless works well")
        let second = entry()
        let scanned = DictionaryReviewScanner.scan([repeated, repeated, second, entry(kind: .edit)])
        check(scanned.count == 1, "repeated spelling grouped")
        check(scanned.first?.occurrenceCount == 2, "occurrences count distinct dictation IDs only")
        let caseEntries = [entry("Talkles", "TALKLESS"), entry("Talkles", "Talkless"), entry("talkles", "talkless")]
        let caseRepeated = entry("Talkles is open and talkles works well", "Talkless is open and TALKLESS works well")
        let caseScanned = DictionaryReviewScanner.scan(caseEntries + [caseRepeated, caseRepeated])
        check(caseScanned.count == 1, "case variants share one review suggestion")
        check(caseScanned.first?.occurrenceCount == 4, "case variants count distinct entries, not repeated mentions")
        check(caseScanned.first?.term == "TALKLESS" && caseScanned.first?.evidenceEntryID == caseEntries[0].id,
              "newest evidence retains its original display spelling")
        check(caseScanned.first?.correction.outputSnippet == "TALKLESS", "newest snippet is not normalized")
        check(DictionaryReviewScanner.scan(caseEntries, excluding: [DictionaryTerms.reviewKey("Talkless")]).isEmpty,
              "normalized exclusion suppresses every case variant")
        check(DictionaryReviewScanner.scan([entry("Use open ai for this task", "Use OpenAI for this task"), entry("Use open ai for this task", "Use OPENAI for this task")]).count == 1, "multiword case variants share a review decision")
        check(DictionaryReviewScanner.scan([entry("talkless", "TALKLESS"), entry("Please check user_id in this file", "Please check user_ID in this file")]).isEmpty,
              "case-only history never yields candidates")
        let cappedHistory = Array(repeating: entry("unchanged", "unchanged"), count: 500) + [entry()]
        check(DictionaryReviewScanner.scan(cappedHistory).isEmpty, "only recent 500 inspected")
        let many = (0..<140).map { entry("Please use Project\($0)x for the event", "Please use Project\($0)y for the event") }
        check(DictionaryReviewScanner.scan(many).count == 100, "review candidates capped")
        let exclusions = Set((0..<100).map { DictionaryTerms.reviewKey("Project\($0)y") })
        check(DictionaryReviewScanner.scan(many, excluding: exclusions).count == 40, "excluded spellings cannot starve later candidates")

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
        check(!app.dictionaryReviewEnabled, "automatic mining off by default")
        check(app.dictionary == rawDictionary, "legacy storage loaded unchanged")
        let store = DictionaryReviewStore(settings: app, defaults: defaults)
        let history = CurrentValueSubject<[HistoryEntry], Never>([entry()])
        store.observeHistory(history.eraseToAnyPublisher())
        check(!store.hasScanned && store.candidates.isEmpty && !store.isScanning, "observing history does not mine before opt-in")
        store.scanHistory()
        await settled(store)
        check(store.hasScanned && store.candidates.isEmpty, "explicit scan excludes already-confirmed terms")
        check(store.pendingCandidates.isEmpty, "confirmed spelling excluded from review")
        check(!app.dictionaryReviewEnabled, "manual scan does not opt in")
        app.dictionary = "ExistingTerm"
        await settled(store)
        check(store.pendingCandidates.count == 1, "unconfirmed spelling remains available")
        let candidate = store.pendingCandidates[0]
        check(defaults.data(forKey: DictionaryReviewStore.dismissalStorageKey) == nil, "scan does not persist text or decisions")
        check(store.accept(candidate), "accept confirms candidate")
        check(app.dictionary == "ExistingTerm\nTalkless", "only accepted output spelling appended")
        check(!store.accept(candidate), "repeat accept is idempotent")
        check(history.value.count == 1 && history.value[0].raw.contains("Talkles"), "accept never mutates history")
        app.dictionary = DictionaryTerms.replacing("Talkless", with: nil, in: app.dictionary)!
        check(store.pendingCandidates.count == 1, "dictionary deletion does not erase evidence")
        store.dismiss(candidate)
        check(store.pendingCandidates.isEmpty && store.dismissedCount == 1, "dismiss hides candidate")
        let savedDismissals = defaults.data(forKey: DictionaryReviewStore.dismissalStorageKey)!
        check(!String(decoding: savedDismissals, as: UTF8.self).contains("Talkless"), "dismissal persistence uses digest not transcript")
        let restarted = DictionaryReviewStore(settings: settings(defaults), defaults: defaults)
        restarted.observeHistory(history.eraseToAnyPublisher())
        restarted.scanHistory()
        await settled(restarted)
        check(restarted.pendingCandidates.isEmpty && restarted.dismissedCount == 1, "dismissal survives restart")
        restarted.resetDismissals()
        await settled(restarted)
        check(restarted.pendingCandidates.count == 1, "only explicit reset restores dismissal")

        let caseDefaults = DictionaryMemoryDefaults()
        let caseSettings = settings(caseDefaults)
        let caseStore = DictionaryReviewStore(settings: caseSettings, defaults: caseDefaults)
        let caseHistory = CurrentValueSubject<[HistoryEntry], Never>(caseEntries)
        caseStore.observeHistory(caseHistory.eraseToAnyPublisher())
        caseStore.scanHistory()
        await settled(caseStore)
        let chosenCase = caseStore.pendingCandidates[0]
        for spelling in ["Talkless", "talkless", "TALKLESS", "tAlKlEsS"] {
            caseSettings.dictionary = spelling
            check(!caseStore.accept(chosenCase), "accept cannot add a case-variant duplicate: \(spelling)")
            await settled(caseStore)
            check(caseStore.pendingCandidates.isEmpty, "confirmed term suppresses all review cases: \(spelling)")
            check(caseSettings.dictionaryTerms == [spelling], "recognition hints retain confirmed spelling: \(spelling)")
        }
        caseSettings.dictionary = "ExistingTerm"
        await settled(caseStore)
        check(caseStore.accept(caseStore.pendingCandidates[0]), "case-aggregated candidate accepts")
        check(caseSettings.dictionary == "ExistingTerm\nTALKLESS", "accept saves chosen original uppercase spelling without normalization")
        await settled(caseStore)
        caseStore.scanHistory()
        await settled(caseStore)
        check(caseStore.pendingCandidates.isEmpty, "accepted case variants stay suppressed after rescan")
        caseSettings.dictionary = ""
        await settled(caseStore)
        caseStore.dismiss(caseStore.pendingCandidates[0])
        await settled(caseStore)
        caseHistory.send([entry("talkles", "talkless")])
        caseStore.scanHistory()
        await settled(caseStore)
        check(caseStore.pendingCandidates.isEmpty && caseStore.dismissedCount == 1, "dismissal covers a differently cased future rescan")
        let caseRestarted = DictionaryReviewStore(settings: settings(caseDefaults), defaults: caseDefaults)
        caseRestarted.observeHistory(caseHistory.eraseToAnyPublisher())
        caseRestarted.scanHistory()
        await settled(caseRestarted)
        check(caseRestarted.pendingCandidates.isEmpty, "case-insensitive dismissal survives restart")
        caseRestarted.resetDismissals()
        await settled(caseRestarted)
        check(caseRestarted.pendingCandidates.first?.term == "talkless", "reset restores newest original case")
        caseHistory.send([entry("talkless", "TALKLESS")])
        caseRestarted.scanHistory()
        await settled(caseRestarted)
        check(caseRestarted.pendingCandidates.isEmpty, "case-only rescan stays empty after reset")

        func legacyKey(_ term: String) -> String {
            let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        let legacyDefaults = DictionaryMemoryDefaults()
        let legacyDismissed: Set<String> = [legacyKey("TaLkLeSs"), legacyKey("Talkless"), legacyKey("UnseenTerm")]
        let legacyData = try JSONEncoder().encode(legacyDismissed)
        legacyDefaults.set(legacyData, forKey: DictionaryReviewStore.dismissalStorageKey)
        let legacySettings = settings(legacyDefaults)
        let legacyStore = DictionaryReviewStore(settings: legacySettings, defaults: legacyDefaults)
        let legacyHistory = CurrentValueSubject<[HistoryEntry], Never>([entry("talkles", "talkless"), entry("Talkles", "TaLkLeSs")] + many)
        legacyStore.observeHistory(legacyHistory.eraseToAnyPublisher())
        check(legacyDefaults.data(forKey: DictionaryReviewStore.dismissalStorageKey) == legacyData,
              "legacy decisions are not mined before authorized scan")
        legacyStore.scanHistory()
        await settled(legacyStore)
        check(legacyStore.pendingCandidates.count == 100 && !legacyStore.pendingCandidates.contains(where: { $0.id == DictionaryTerms.reviewKey("Talkless") }),
              "older observed mixed-case dismissal suppresses newer variants without starving candidate slots")
        let migrated = try JSONDecoder().decode(Set<String>.self, from: legacyDefaults.data(forKey: DictionaryReviewStore.dismissalStorageKey)!)
        check(migrated == [DictionaryTerms.reviewKey("Talkless"), legacyKey("UnseenTerm")], "observed legacy case decisions merge and unknown digests survive")
        check(legacyStore.dismissedCount == 2, "migration counts merged review identities")
        legacyHistory.send([entry("Talkles", "TALKLESS")])
        let legacyRestarted = DictionaryReviewStore(settings: settings(legacyDefaults), defaults: legacyDefaults)
        legacyRestarted.observeHistory(legacyHistory.eraseToAnyPublisher())
        legacyRestarted.scanHistory()
        await settled(legacyRestarted)
        check(legacyRestarted.pendingCandidates.isEmpty, "migrated decision survives original evidence removal and restart")
        legacyRestarted.resetDismissals()
        await settled(legacyRestarted)
        check(legacyRestarted.pendingCandidates.first?.term == "TALKLESS", "reset clears migrated and unknown legacy decisions")
        let sameEntryLegacy = DictionaryReviewScanner.scanWithDismissals([
            entry("Talkles is open and talkles works well", "Talkless is open and TaLkLeSs works well")
        ], excluding: [], dismissed: [legacyKey("TaLkLeSs")])
        check(sameEntryLegacy.candidates.isEmpty && sameEntryLegacy.dismissed == [DictionaryTerms.reviewKey("Talkless")],
              "legacy migration checks every distinct case spelling within one entry")
        let commonLegacy = DictionaryReviewScanner.scanWithDismissals([entry("talkles", "talkless")], excluding: [], dismissed: [legacyKey("Talkless")])
        check(commonLegacy.candidates.isEmpty && commonLegacy.dismissed == [DictionaryTerms.reviewKey("Talkless")],
              "legacy common case variant migrates even without original evidence")

        let caseOnlyLegacy = DictionaryReviewScanner.scanWithDismissals([
            entry("Use open ai for this task", "Use OPENAI for this task"),
            entry("Use openai for this task", "Use OpenAI for this task")
        ], excluding: [], dismissed: [legacyKey("OpenAI")])
        check(caseOnlyLegacy.candidates.isEmpty && caseOnlyLegacy.dismissed == [DictionaryTerms.reviewKey("OpenAI")],
              "legacy case-only evidence recovers mixed-case digest before new candidate aggregation")
        let legacyEvidenceOnly = DictionaryReviewScanner.scanWithDismissals([
            entry("Use openai for this task", "Use OpenAI for this task")
        ], excluding: [], dismissed: [legacyKey("Unrelated")])
        check(legacyEvidenceOnly.candidates.isEmpty && legacyEvidenceOnly.dismissed == [legacyKey("Unrelated")],
              "migration-only case evidence never becomes a new suggestion or decision")

        let resetDefaults = DictionaryMemoryDefaults()
        let resetStore = DictionaryReviewStore(settings: settings(resetDefaults), defaults: resetDefaults)
        let resetHistory = CurrentValueSubject<[HistoryEntry], Never>([
            entry(), entry("Please use OtherTrem for this meeting", "Please use OtherTerm for this meeting")
        ])
        resetStore.observeHistory(resetHistory.eraseToAnyPublisher())
        resetStore.scanHistory()
        await settled(resetStore)
        resetStore.dismiss(resetStore.pendingCandidates.first(where: { $0.term == "Talkless" })!)
        await settled(resetStore)
        check(resetStore.pendingCandidates.map(\.term) == ["OtherTerm"], "undismissed evidence remains before history clear")
        resetHistory.send([])
        check(resetStore.isScanning, "empty history schedules an authorized pruning scan")
        resetStore.resetDismissals()
        await settled(resetStore)
        check(resetStore.dismissedCount == 0, "empty-history scan cannot restore reset dismissals")
        check(resetStore.candidates.isEmpty && resetStore.pendingCandidates.isEmpty && resetStore.lastScanEntryCount == 0,
              "reset replaces empty pruning scan without retaining undismissed deleted evidence")
        let resetPersisted = try JSONDecoder().decode(Set<String>.self, from: resetDefaults.data(forKey: DictionaryReviewStore.dismissalStorageKey)!)
        check(resetPersisted.isEmpty, "reset persistence survives cancelled migration")
        resetHistory.send([entry()])
        resetStore.scanHistory()
        await settled(resetStore)
        check(resetStore.pendingCandidates.count == 1, "reset suggestion can reappear on a later explicit scan")

        let unicodeDefaults = DictionaryMemoryDefaults()
        let unicodeSettings = settings(unicodeDefaults)
        let unicodeStore = DictionaryReviewStore(settings: unicodeSettings, defaults: unicodeDefaults)
        let unicodeHistory = CurrentValueSubject<[HistoryEntry], Never>([
            entry("Please visit Cafe tomorrow morning", "Please visit Cafe\u{301} tomorrow morning"),
            entry("Please visit CAFE tomorrow morning", "Please visit CAF\u{c9} tomorrow morning")
        ])
        unicodeStore.observeHistory(unicodeHistory.eraseToAnyPublisher())
        unicodeStore.scanHistory()
        await settled(unicodeStore)
        check(unicodeStore.pendingCandidates.count == 1 && unicodeStore.pendingCandidates.first?.occurrenceCount == 2,
              "Unicode canonical and case variants aggregate")
        check(unicodeStore.accept(unicodeStore.pendingCandidates[0]), "Unicode suggestion accepts")
        check(Array(unicodeSettings.dictionary.utf8) == Array("Cafe\u{301}".utf8), "accept preserves original decomposed Unicode bytes")
        await settled(unicodeStore)
        unicodeSettings.dictionary = "CAF\u{c9}"
        await settled(unicodeStore)
        check(unicodeStore.pendingCandidates.isEmpty, "confirmed composed uppercase spelling suppresses decomposed suggestion")
        unicodeSettings.dictionary = ""
        await settled(unicodeStore)
        unicodeStore.dismiss(unicodeStore.pendingCandidates[0])
        await settled(unicodeStore)
        unicodeHistory.send([entry("Please visit CAFE tomorrow morning", "Please visit CAF\u{c9} tomorrow morning")])
        unicodeStore.scanHistory()
        await settled(unicodeStore)
        check(unicodeStore.pendingCandidates.isEmpty, "Unicode dismissal suppresses differently composed and cased rescan")

        let hanDefaults = DictionaryMemoryDefaults()
        let hanSettings = settings(hanDefaults)
        let hanStore = DictionaryReviewStore(settings: hanSettings, defaults: hanDefaults)
        let hanHistory = CurrentValueSubject<[HistoryEntry], Never>([entry(hanRaw, hanOutput)])
        hanStore.observeHistory(hanHistory.eraseToAnyPublisher())
        hanStore.scanHistory()
        await settled(hanStore)
        check(hanStore.accept(hanStore.pendingCandidates[0]), "Han candidate accepts unchanged")
        check(hanSettings.dictionary == "\u{98DE}\u{4E66}", "Han dictionary spelling preserved")
        await settled(hanStore)
        check(hanStore.pendingCandidates.isEmpty, "confirmed Han spelling excluded")
        hanSettings.dictionary = ""
        await settled(hanStore)
        hanStore.dismiss(hanStore.pendingCandidates[0])
        await settled(hanStore)
        hanStore.scanHistory()
        await settled(hanStore)
        check(hanStore.pendingCandidates.isEmpty, "Han dismissal survives rescan")

        let newEntry = entry("Please use NewTrem for this meeting", "Please use NewTerm for this meeting")
        history.send([newEntry] + history.value)
        await settled(store)
        check(store.candidates.isEmpty, "one-time scan does not mine new history or dismissed terms")
        app.dictionaryReviewEnabled = true
        await settled(store)
        check(store.candidates.count == 1, "opt-in scans existing local entries")
        check(settings(defaults).dictionaryReviewEnabled, "opt-in persists")
        check(app.dictionary == "ExistingTerm\n", "automatic scans never confirm terms")
        let newer = entry("Please use OtherTrem for this meeting", "Please use OtherTerm for this meeting")
        history.send([newer] + history.value)
        await settled(store)
        check(store.candidates.count == 2, "automatic mining observes future history")
        app.dictionaryReviewEnabled = false
        history.send([])
        await settled(store)
        check(store.candidates.isEmpty, "history clear removes cached evidence even after opting out")
        check(store.dismissedCount == 1, "history clear does not reset dismissal")
        check(app.dictionary == "ExistingTerm\n", "history clear does not erase confirmed terms")
        let autoDefaults = DictionaryMemoryDefaults()
        let autoSettings = settings(autoDefaults)
        let automatic = DictionaryReviewStore(settings: autoSettings, defaults: autoDefaults)
        let autoHistory = CurrentValueSubject<[HistoryEntry], Never>([entry()])
        automatic.observeHistory(autoHistory.eraseToAnyPublisher())
        autoSettings.dictionaryReviewEnabled = true
        autoSettings.dictionaryReviewEnabled = false
        autoHistory.send([newer])
        check(!automatic.isScanning, "opt-out cancels automatic scan without authorizing manual rescan")
        await settled(automatic)
        check(automatic.candidates.isEmpty, "cancelled automatic results are not applied")

        let capDefaults = DictionaryMemoryDefaults()
        let capSettings = settings(capDefaults)
        let capStore = DictionaryReviewStore(settings: capSettings, defaults: capDefaults)
        let capHistory = CurrentValueSubject<[HistoryEntry], Never>(many)
        capStore.observeHistory(capHistory.eraseToAnyPublisher())
        capStore.scanHistory()
        await settled(capStore)
        let capFirst = capStore.pendingCandidates[0]
        capStore.dismiss(capFirst)
        await settled(capStore)
        check(capStore.pendingCandidates.count == 100, "dismissal refills candidate slots")
        check(capStore.accept(capStore.pendingCandidates[0]), "capped candidate can be accepted")
        await settled(capStore)
        check(capStore.pendingCandidates.count == 100, "acceptance refills candidate slots")
        defaults.set(Data("malformed".utf8), forKey: DictionaryReviewStore.dismissalStorageKey)
        check(DictionaryReviewStore(settings: app, defaults: defaults).dismissedCount == 0, "invalid local dismissal data handled safely")
        let roundTrip = try JSONDecoder().decode(HistoryEntry.self, from: JSONEncoder().encode(entry()))
        check(roundTrip.kind == .dictation, "history schema remains compatible")

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
        let review = DictionaryReviewStore(settings: settings, defaults: defaults)
        let history = CurrentValueSubject<[HistoryEntry], Never>([
            HistoryEntry(kind: .dictation, app: "Synthetic Notes", raw: "Please open Notian before our meeting.",
                         output: "Please open Notion before our meeting.", duration: 3),
            HistoryEntry(kind: .dictation, app: "Synthetic Notes", raw: "\u{4ECA}\u{5929}\u{8BA8}\u{8BBA}\u{6DF1}\u{6E21}\u{5B66}\u{4E60}\u{7684}\u{6A21}\u{578B}",
                         output: "\u{4ECA}\u{5929}\u{8BA8}\u{8BBA}\u{6DF1}\u{5EA6}\u{5B66}\u{4E60}\u{7684}\u{6A21}\u{578B}", duration: 3)
        ])
        review.observeHistory(history.eraseToAnyPublisher())
        review.scanHistory()
        while review.isScanning { try await Task.sleep(for: .milliseconds(10)) }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let view = NSHostingView(rootView: DictionaryView(settings: settings, review: review).padding(28)
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
        try save("dictionary-terms.png")
        func findReview(_ element: Any) -> (any NSAccessibilityProtocol)? {
            guard let accessible = element as? any NSAccessibilityProtocol else { return nil }
            let label = accessible.accessibilityLabel() ?? accessible.accessibilityTitle() ?? ""
            if label.hasPrefix("Review (") { return accessible }
            for child in accessible.accessibilityChildren() ?? [] {
                if let found = findReview(child) { return found }
            }
            return nil
        }
        func segment(in parent: NSView) -> NSSegmentedControl? {
            if let control = parent as? NSSegmentedControl { return control }
            return parent.subviews.compactMap { segment(in: $0) }.first
        }
        if let button = findReview(view), button.accessibilityPerformPress() {
            // SwiftUI exposes the native tab as an accessibility action on newer systems.
        } else if let control = segment(in: view) {
            control.selectedSegment = 1
            control.sendAction(control.action, to: control.target)
        } else { fatalError("Review tab unavailable") }
        try await Task.sleep(for: .milliseconds(150))
        try save("dictionary-review.png")
        print("Dictionary screenshots saved to \(directory.path)")
        window.orderOut(nil)
    }
}
