import Foundation

/// A fix Talkless learned on its own from how dictations were corrected.
struct LearnedFix: Codable, Equatable, Identifiable, Sendable {
    var heard: String
    var term: String
    var firstSeen: Date
    /// Last time the mishearing was observed or fixed. Fixes unused for `retention` retire.
    var lastSeen: Date
    /// Distinct dictations whose polished text made this correction.
    var observations: Int
    /// Dictations this fix corrected after it took effect.
    var applied = 0
    var active = false

    var id: String { DictionaryLearning.key(heard) }
}

/// What learning did and when, so the dictionary can show its progress.
struct LearningEvent: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Seen often enough: the fix took effect.
        case learned
        /// Not needed for `DictionaryLearning.retention`: the fix retired.
        case retired
        /// Smart cleanup changed the fix back: it retired at once.
        case undone
    }
    var kind: Kind
    var heard: String
    var term: String
    var date: Date
    var id: String { "\(kind.rawValue)-\(DictionaryLearning.key(heard))-\(date.timeIntervalSince1970)" }
}

struct LearnedDictionary: Codable, Equatable, Sendable {
    var fixes: [LearnedFix] = []
    /// Pairs the user removed; never learned again.
    var blocked: Set<String> = []
    /// Existing history is read once, so learning starts with what is already on this Mac.
    var seeded = false
    /// Newest first, capped at `DictionaryLearning.maximumEvents`.
    var events: [LearningEvent] = []

    init(fixes: [LearnedFix] = [], blocked: Set<String> = [], seeded: Bool = false, events: [LearningEvent] = []) {
        self.fixes = fixes
        self.blocked = blocked
        self.seeded = seeded
        self.events = events
    }

    /// Older saved dictionaries have no events; keep their fixes instead of discarding them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fixes = try c.decodeIfPresent([LearnedFix].self, forKey: .fixes) ?? []
        blocked = try c.decodeIfPresent(Set<String>.self, forKey: .blocked) ?? []
        seeded = try c.decodeIfPresent(Bool.self, forKey: .seeded) ?? false
        events = try c.decodeIfPresent([LearningEvent].self, forKey: .events) ?? []
    }

    mutating func record(_ kind: LearningEvent.Kind, _ fix: LearnedFix, at date: Date) {
        events.insert(LearningEvent(kind: kind, heard: fix.heard, term: fix.term, date: date), at: 0)
        if events.count > DictionaryLearning.maximumEvents { events.removeLast(events.count - DictionaryLearning.maximumEvents) }
    }
}

/// Self-improving dictionary: corrections that keep recurring take effect automatically, feed
/// recognition hints and polish context, and retire once recognition stops producing them.
/// Everything is local; no model is called.
enum DictionaryLearning {
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    static let maximumFixes = 300
    static let maximumEvents = 50

    static func key(_ text: String) -> String { DictionaryTerms.reviewIdentity(text) }

    static func pairKey(heard: String, term: String) -> String {
        DictionaryTerms.reviewKey(heard + "\u{1F}" + term)
    }

    /// Two short Chinese characters collide with ordinary words more easily, so they need more evidence.
    static func threshold(for heard: String) -> Int {
        let compact = heard.filter { !$0.isWhitespace }
        let han = compact.unicodeScalars.allSatisfy { (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value) }
        return han && compact.count <= 2 ? 3 : 2
    }

    /// Learn from one finished dictation: `raw` is the recognized text after existing fixes,
    /// `output` is the final polished text in the same language.
    static func observe(raw: String, output: String, at date: Date, in state: LearnedDictionary,
                        manualTerms: [String], manualRules: [DictionaryReplacement],
                        dismissedTerms: Set<String> = []) -> LearnedDictionary {
        var state = state
        let protected = Set(manualTerms.map(key)).union(manualRules.map { key($0.heard) })
        for correction in DictionaryCorrectionExtractor.extract(raw: raw, output: output) {
            let heard = correction.source, term = correction.term
            let heardKey = key(heard)
            // Polish undid a learned fix: the evidence no longer supports it.
            if let index = state.fixes.firstIndex(where: { $0.active && key($0.term) == heardKey && key($0.heard) == key(term) }) {
                let undone = state.fixes.remove(at: index)
                state.record(.undone, undone, at: date)
                continue
            }
            guard heard.count >= 2, heard.count <= DictionaryReplacements.maximumHeardLength,
                  !protected.contains(heardKey),
                  !state.blocked.contains(pairKey(heard: heard, term: term)),
                  dismissedTerms.isDisjoint(with: DictionaryTerms.legacyReviewKeys(term).union([DictionaryTerms.reviewKey(term)]))
            else { continue }
            if let index = state.fixes.firstIndex(where: { $0.id == heardKey }) {
                if key(state.fixes[index].term) == key(term) {
                    state.fixes[index].observations += 1
                    state.fixes[index].lastSeen = max(state.fixes[index].lastSeen, date)
                    state.fixes[index].term = term
                } else {
                    // Conflicting corrections: start over rather than guess which one is right.
                    state.fixes[index] = LearnedFix(heard: heard, term: term, firstSeen: date, lastSeen: date, observations: 1)
                }
                if !state.fixes[index].active, state.fixes[index].observations >= threshold(for: heard) {
                    state.fixes[index].active = true
                    state.record(.learned, state.fixes[index], at: date)
                }
            } else {
                state.fixes.append(LearnedFix(heard: heard, term: term, firstSeen: date, lastSeen: date, observations: 1))
            }
        }
        if state.fixes.count > maximumFixes {
            // Drop the stalest evidence first; active fixes outrank pending ones.
            state.fixes = Array(state.fixes.sorted {
                $0.active != $1.active ? $0.active : $0.lastSeen > $1.lastSeen
            }.prefix(maximumFixes))
        }
        return state
    }

    /// Fixes that corrected this dictation stay alive.
    static func recordApplied(_ heardKeys: Set<String>, at date: Date, in state: LearnedDictionary) -> LearnedDictionary {
        guard !heardKeys.isEmpty else { return state }
        var state = state
        for index in state.fixes.indices where state.fixes[index].active && heardKeys.contains(state.fixes[index].id) {
            state.fixes[index].applied += 1
            state.fixes[index].lastSeen = max(state.fixes[index].lastSeen, date)
        }
        return state
    }

    /// Retire fixes recognition no longer needs, and forget evidence that never recurred.
    static func expire(_ state: LearnedDictionary, now: Date) -> LearnedDictionary {
        var state = state
        for fix in state.fixes where fix.active && now.timeIntervalSince(fix.lastSeen) > retention {
            state.record(.retired, fix, at: now)
        }
        state.fixes.removeAll { now.timeIntervalSince($0.lastSeen) > retention }
        return state
    }

    /// Active learned fixes that do not collide with anything the user wrote by hand.
    static func replacements(_ state: LearnedDictionary, manualTerms: [String],
                             manualRules: [DictionaryReplacement]) -> [DictionaryReplacement] {
        let protected = Set(manualTerms.map(key)).union(manualRules.map { key($0.heard) })
        return state.fixes.filter { $0.active && !protected.contains($0.id) }
            .map { DictionaryReplacement(heard: $0.heard, term: $0.term) }
    }

    static func terms(_ state: LearnedDictionary) -> [String] {
        var seen = Set<String>()
        return state.fixes.filter(\.active).map(\.term).filter { seen.insert(key($0)).inserted }
    }
}
