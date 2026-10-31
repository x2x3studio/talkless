import Combine
import Foundation
import NaturalLanguage

struct DictionaryCorrection: Equatable, Sendable {
    let source: String
    let term: String
    let sourceSnippet: String
    let outputSnippet: String
}

/// This is spelling evidence, not semantic correction or a replacement rule. No model is called.
/// Character-aware word alignment preserves Latin identifiers and finds short Han corrections.
enum DictionaryCorrectionExtractor {
    static let maximumCharacters = 1_200
    static let maximumTokens = 160
    private struct Token {
        let text: String
        let range: Range<String.Index>
        let han: Bool
    }
    private struct Change {
        var source: Range<Int>
        var output: Range<Int>
    }

    static func extract(from entry: HistoryEntry, legacyDismissals: Bool = false) -> [DictionaryCorrection] {
        guard entry.kind == .dictation else { return [] }
        return extract(raw: entry.raw, output: entry.output, legacyDismissals: legacyDismissals)
    }

    /// Legacy alignment is used only to recover existing dismissal digests, never new suggestions.
    static func extract(raw: String, output: String, legacyDismissals: Bool = false) -> [DictionaryCorrection] {
        // Prefix limits avoid walking or aligning unbounded history strings.
        guard raw.utf8.count <= maximumCharacters * 4, output.utf8.count <= maximumCharacters * 4,
              raw.count <= maximumCharacters, output.count <= maximumCharacters else { return [] }
        let a = tokens(raw), b = tokens(output)
        guard !a.isEmpty, !b.isEmpty, a.count <= maximumTokens, b.count <= maximumTokens else { return [] }
        func identity(_ text: String) -> String {
            legacyDismissals ? text : DictionaryTerms.reviewIdentity(text)
        }
        let changes = differences(a.map { identity($0.text) }, b.map { identity($0.text) })
        guard !changes.isEmpty, changes.count <= 3 else { return [] }
        let changed = changes.reduce(0) { $0 + max($1.source.count, $1.output.count) }
        let total = max(a.count, b.count)
        // A standalone Latin spelling can be useful; whole sentences and translated phrases are not.
        let standalone = a.count <= 2 && b.count <= 2 && !a.contains(where: \.han) && !b.contains(where: \.han)
        guard standalone || (total - changed >= 2 && Double(changed) / Double(total) <= 0.4) else { return [] }
        var results: [DictionaryCorrection] = []
        var seen = Set<String>()
        for change in changes {
            guard !change.source.isEmpty, !change.output.isEmpty else { continue } // No insertions/deletions.
            var source = change.source, target = change.output
            let sourceHan = a[source].allSatisfy(\.han), outputHan = b[target].allSatisfy(\.han)
            guard sourceHan == outputHan else { continue } // Cross-script translation is not spelling evidence.
            if outputHan {
                guard source.count == target.count, source.count <= 2 else { continue }
                // Extend to the locally tokenized output word, or a two-character context for unknown names.
                let word = hanWord(containing: target, tokens: b, in: output)
                let left = target.lowerBound - word.lowerBound
                let right = word.upperBound - target.upperBound
                guard source.lowerBound >= left, source.upperBound + right <= a.count,
                      Array(a[(source.lowerBound - left)..<source.lowerBound].map(\.text)) == Array(b[word.lowerBound..<target.lowerBound].map(\.text)),
                      Array(a[source.upperBound..<(source.upperBound + right)].map(\.text)) == Array(b[target.upperBound..<word.upperBound].map(\.text)) else { continue }
                source = (source.lowerBound - left)..<(source.upperBound + right)
                target = word
                // Without shared characters this is too likely to be ordinary rewriting.
                guard source.count >= 2, source.count <= 6,
                      change.source.count * 2 <= source.count else { continue }
            } else {
                guard source.count <= 3, target.count <= 3,
                      !a[source].contains(where: \.han), !b[target].contains(where: \.han) else { continue }
            }
            let sourceRange = a[source.lowerBound].range.lowerBound..<a[source.upperBound - 1].range.upperBound
            let outputRange = b[target.lowerBound].range.lowerBound..<b[target.upperBound - 1].range.upperBound
            let before = String(raw[sourceRange]), after = String(output[outputRange])
            guard identity(before) != identity(after),
                  before.count <= 48, after.count <= 48,
                  !before.contains(where: \.isNewline), !after.contains(where: \.isNewline),
                  safePhrase(before), safePhrase(after) else { continue }
            if !outputHan {
                // Hyphen/apostrophe formatting alone is not evidence of a learned spelling.
                guard identity(before).filter({ !"_-'’".contains($0) })
                    != identity(after).filter({ !"_-'’".contains($0) }) else { continue }
                let old = spelling(before, legacyDismissals: legacyDismissals)
                let new = spelling(after, legacyDismissals: legacyDismissals)
                if legacyDismissals {
                    let sentenceStart = source.lowerBound == 0 || raw[..<sourceRange.lowerBound].last(where: { !$0.isWhitespace }).map { ".!?。！？".contains($0) } == true
                    if sentenceStart, before.lowercased() == after.lowercased(),
                       after.first?.isUppercase == true, after.dropFirst().allSatisfy({ !$0.isLetter || $0.isLowercase }) { continue }
                }
                let plainBefore = String(old), plainAfter = String(new)
                if before == before.lowercased(), after == after.lowercased(),
                   ["s", "es", "ed", "ing"].contains(where: { suffix in
                       // A doubled final s (talkles → talkless) is spelling, not a simple plural.
                       let shorter = plainBefore.count < plainAfter.count ? plainBefore : plainAfter
                       if !legacyDismissals, suffix == "s", shorter.hasSuffix("s") { return false }
                       return plainAfter == plainBefore + suffix || plainBefore == plainAfter + suffix
                   }) { continue }
                guard old.count >= 3, new.count >= 3,
                      old.allSatisfy({ $0.isLetter || $0.isNumber }), new.allSatisfy({ $0.isLetter || $0.isNumber }),
                      distance(old, new) <= min(3, max(1, max(old.count, new.count) / 3)) else { continue }
            }
            // Keep observed case variants for legacy dismissal migration; the scanner groups them.
            guard seen.insert(after).inserted else { continue }
            results.append(DictionaryCorrection(source: before, term: after,
                                                sourceSnippet: snippet(raw, around: sourceRange),
                                                outputSnippet: snippet(output, around: outputRange)))
        }
        return results
    }

    private static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value)
        }
    }

    private static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let start = index, character = text[index]
            index = text.index(after: index)
            if isHan(character) {
                result.append(Token(text: String(character), range: start..<index, han: true))
            } else if character.isLetter || character.isNumber {
                while index < text.endIndex {
                    let c = text[index]
                    guard !isHan(c), c.isLetter || c.isNumber || "_-'’".contains(c) else { break }
                    index = text.index(after: index)
                }
                result.append(Token(text: String(text[start..<index]), range: start..<index, han: false))
            }
            if result.count > maximumTokens { break }
        }
        return result
    }

    private static func differences(_ a: [String], _ b: [String]) -> [Change] {
        let width = b.count + 1
        var lcs = [Int](repeating: 0, count: (a.count + 1) * width)
        for i in (0..<a.count).reversed() {
            for j in (0..<b.count).reversed() {
                lcs[i * width + j] = a[i] == b[j] ? lcs[(i + 1) * width + j + 1] + 1
                    : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
            }
        }
        var i = 0, j = 0, changes: [Change] = []
        while i < a.count || j < b.count {
            if i < a.count, j < b.count, a[i] == b[j] { i += 1; j += 1; continue }
            let startI = i, startJ = j
            while i < a.count || j < b.count {
                if i < a.count, j < b.count, a[i] == b[j] { break }
                if i < a.count, j == b.count || lcs[(i + 1) * width + j] >= lcs[i * width + j + 1] { i += 1 }
                else { j += 1 }
            }
            changes.append(Change(source: startI..<i, output: startJ..<j))
        }
        return changes
    }

    private static func hanWord(containing change: Range<Int>, tokens: [Token], in text: String) -> Range<Int> {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        let start = tokenizer.tokenRange(at: tokens[change.lowerBound].range.lowerBound).lowerBound
        let end = tokenizer.tokenRange(at: tokens[change.upperBound - 1].range.lowerBound).upperBound
        var lower = change.lowerBound, upper = change.upperBound
        while lower > 0, tokens[lower - 1].han, tokens[lower - 1].range.lowerBound >= start { lower -= 1 }
        while upper < tokens.count, tokens[upper].han, tokens[upper].range.upperBound <= end { upper += 1 }
        if upper - lower == 1 {
            if lower > 0, tokens[lower - 1].han, tokens[lower - 1].range.upperBound == tokens[lower].range.lowerBound { lower -= 1 }
            else if upper < tokens.count, tokens[upper].han, tokens[upper - 1].range.upperBound == tokens[upper].range.lowerBound { upper += 1 }
        }
        return lower..<upper
    }

    private static func safePhrase(_ text: String) -> Bool {
        text.allSatisfy { $0.isLetter || $0.isNumber || $0 == " " || "_-'’".contains($0) }
            && text.contains(where: \.isLetter)
    }

    private static func spelling(_ text: String, legacyDismissals: Bool) -> [Character] {
        let identity = legacyDismissals ? text.precomposedStringWithCanonicalMapping.lowercased()
            : DictionaryTerms.reviewIdentity(text)
        return Array(identity.filter { !$0.isWhitespace && !"_-'’".contains($0) })
    }

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for (i, old) in a.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, new) in b.enumerated() {
                next[j + 1] = min(row[j + 1] + 1, next[j] + 1, row[j] + (old == new ? 0 : 1))
            }
            row = next
        }
        return row[b.count]
    }

    private static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -36, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 36, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…")
            + text[start..<end].replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            + (end == text.endIndex ? "" : "…")
    }
}

struct DictionaryCandidate: Identifiable, Sendable {
    var id: String { DictionaryTerms.reviewKey(term) }
    let term: String
    let correction: DictionaryCorrection
    let date: Date
    let app: String
    let evidenceEntryID: UUID
    var entryIDs: Set<UUID>
    var occurrenceCount: Int { entryIDs.count }
}

enum DictionaryReviewScanner {
    static let historyLimit = 500
    static let candidateLimit = 100

    struct Result: Sendable {
        let candidates: [DictionaryCandidate]
        let dismissed: Set<String>
    }

    static func scan(_ entries: [HistoryEntry], excluding excluded: Set<String> = []) -> [DictionaryCandidate] {
        scanWithDismissals(entries, excluding: excluded, dismissed: []).candidates
    }

    static func scanWithDismissals(_ entries: [HistoryEntry], excluding excluded: Set<String>,
                                   dismissed: Set<String>) -> Result {
        var evidence: [(HistoryEntry, DictionaryCorrection, String)] = []
        var migratedDismissals = dismissed
        var seenEntries = Set<UUID>()
        // Resolve legacy decisions before capping candidates: an older case variant may dismiss
        // newer evidence too. The immutable input lets every observed variant share that decision.
        for entry in entries.prefix(historyLimit) {
            if Task.isCancelled { return Result(candidates: [], dismissed: dismissed) }
            guard seenEntries.insert(entry.id).inserted else { continue }
            let corrections = DictionaryCorrectionExtractor.extract(from: entry)
            if !dismissed.isEmpty {
                let legacyCorrections = DictionaryCorrectionExtractor.extract(from: entry, legacyDismissals: true)
                for term in Set((corrections + legacyCorrections).map(\.term)) {
                    let legacy = DictionaryTerms.legacyReviewKeys(term).intersection(dismissed)
                    if !legacy.isEmpty {
                        migratedDismissals.subtract(legacy)
                        migratedDismissals.insert(DictionaryTerms.reviewKey(term))
                    }
                }
            }
            for correction in corrections {
                evidence.append((entry, correction, DictionaryTerms.reviewKey(correction.term)))
            }
        }
        let excluded = excluded.union(migratedDismissals)
        var candidates: [String: DictionaryCandidate] = [:]
        // History is newest-first. Keep its original display spelling and count distinct dictations.
        for (entry, correction, key) in evidence {
            if Task.isCancelled { return Result(candidates: [], dismissed: dismissed) }
            guard !excluded.contains(key) else { continue }
            if candidates[key] != nil {
                candidates[key]?.entryIDs.insert(entry.id)
            } else if candidates.count < candidateLimit {
                candidates[key] = DictionaryCandidate(term: correction.term, correction: correction,
                                                      date: entry.date, app: entry.app, evidenceEntryID: entry.id, entryIDs: [entry.id])
            }
        }
        let sorted = candidates.values.sorted {
            if $0.occurrenceCount != $1.occurrenceCount { return $0.occurrenceCount > $1.occurrenceCount }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.term < $1.term
        }
        return Result(candidates: sorted, dismissed: migratedDismissals)
    }
}

@MainActor
final class DictionaryReviewStore: ObservableObject {
    static let shared = DictionaryReviewStore(settings: .shared)
    static let dismissalStorageKey = "dictionaryReview.dismissed.v1"
    @Published private(set) var candidates: [DictionaryCandidate] = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var dismissedCount = 0
    @Published private(set) var lastScanEntryCount = 0
    private let settings: AppSettings
    private let defaults: UserDefaults
    private var dismissed: Set<String>
    private var latestEntries: [HistoryEntry] = []
    private var manuallyScannedIDs = Set<UUID>()
    private var authorizedEntries: [HistoryEntry] {
        settings.dictionaryReviewEnabled ? latestEntries : latestEntries.filter { manuallyScannedIDs.contains($0.id) }
    }
    private var subscriptions = Set<AnyCancellable>()
    private var historySubscription: AnyCancellable?
    private var scanTask: Task<Void, Never>?
    private var generation = 0

    init(settings: AppSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        dismissed = defaults.data(forKey: Self.dismissalStorageKey)
            .flatMap { try? JSONDecoder().decode(Set<String>.self, from: $0) } ?? []
        dismissedCount = dismissed.count
        settings.$dictionaryReviewEnabled.dropFirst().sink { [weak self] enabled in
            guard let self else { return }
            if enabled { self.scanHistory(manual: false) }
            else { self.cancelScan() } // Do not finish a pending automatic scan after opting out.
        }.store(in: &subscriptions)
        settings.$dictionary.dropFirst().sink { [weak self] dictionary in
            guard let self else { return }
            self.objectWillChange.send()
            guard self.hasScanned else { return }
            if !self.authorizedEntries.isEmpty { self.scheduleScan(self.authorizedEntries, dictionary: dictionary) }
        }.store(in: &subscriptions)
    }

    var pendingCandidates: [DictionaryCandidate] {
        let confirmed = Set(settings.dictionaryTerms.map(DictionaryTerms.reviewKey))
        return candidates.filter { !dismissed.contains($0.id) && !confirmed.contains($0.id) }
    }

    /// The existing history publisher is the source of truth; suggestions never write to history.
    func observeHistory(_ publisher: AnyPublisher<[HistoryEntry], Never>) {
        historySubscription = publisher.sink { [weak self] entries in
            guard let self else { return }
            self.latestEntries = Array(entries.prefix(DictionaryReviewScanner.historyLimit))
            if self.settings.dictionaryReviewEnabled {
                self.scanHistory(manual: false)
            } else if !self.manuallyScannedIDs.isEmpty {
                self.scheduleScan(self.authorizedEntries)
            } else {
                // Revoking automatic scanning permits pruning deleted evidence, never fresh extraction.
                let remaining = Set(self.latestEntries.map(\.id))
                self.candidates = self.candidates.compactMap { candidate in
                    guard remaining.contains(candidate.evidenceEntryID) else { return nil }
                    var candidate = candidate
                    candidate.entryIDs.formIntersection(remaining)
                    return candidate
                }
            }
        }
    }

    /// Explicitly scanning once does not opt the user into future history mining.
    func scanHistory(manual: Bool = true) {
        hasScanned = true
        if manual { manuallyScannedIDs = Set(latestEntries.map(\.id)) }
        scheduleScan(latestEntries)
    }

    @discardableResult
    func accept(_ candidate: DictionaryCandidate) -> Bool {
        guard pendingCandidates.contains(where: { $0.id == candidate.id }),
              let dictionary = DictionaryTerms.adding(candidate.term, to: settings.dictionary) else { return false }
        settings.dictionary = dictionary
        return true
    }

    func dismiss(_ candidate: DictionaryCandidate) {
        guard candidates.contains(where: { $0.id == candidate.id }) else { return }
        dismissed.insert(candidate.id)
        persistDismissals()
    }

    /// An explicit UI action is required to show previously dismissed spellings again.
    func resetDismissals() {
        dismissed.removeAll()
        persistDismissals()
    }

    private func persistDismissals(rescan: Bool = true) {
        defaults.set(try? JSONEncoder().encode(dismissed), forKey: Self.dismissalStorageKey)
        dismissedCount = dismissed.count
        if rescan {
            // Replace pending migration even with no history, so stale evidence is also pruned.
            if hasScanned { scheduleScan(authorizedEntries) }
            else { cancelScan() }
        }
    }

    private func cancelScan() {
        generation += 1
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private func scheduleScan(_ entries: [HistoryEntry], dictionary: String? = nil) {
        cancelScan()
        let token = generation
        let excluded = Set(DictionaryTerms.terms(in: dictionary ?? settings.dictionary).map(DictionaryTerms.reviewKey))
        let dismissed = self.dismissed
        isScanning = true
        scanTask = Task { [weak self] in
            let work = Task.detached(priority: .utility) {
                DictionaryReviewScanner.scanWithDismissals(entries, excluding: excluded, dismissed: dismissed)
            }
            let result = await withTaskCancellationHandler(operation: { await work.value }, onCancel: { work.cancel() })
            guard let self, !Task.isCancelled, token == self.generation else { return }
            if self.dismissed != result.dismissed {
                self.dismissed = result.dismissed
                self.persistDismissals(rescan: false)
            }
            self.candidates = result.candidates
            self.lastScanEntryCount = entries.count
            self.isScanning = false
            self.scanTask = nil
        }
    }
}
