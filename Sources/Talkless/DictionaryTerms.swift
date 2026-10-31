import CryptoKit
import Foundation

/// Editing the original newline format avoids a migration that rewrites or caps old dictionaries.
enum DictionaryTerms {
    static func terms(in text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func validated(_ term: String) -> String? {
        let value = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: \.isNewline),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    static func adding(_ term: String, to text: String) -> String? {
        guard let term = validated(term), !terms(in: text).contains(term) else { return nil }
        return text + (text.isEmpty || text.last?.isNewline == true ? "" : "\n") + term
    }

    /// Preserve every unrelated line, its case, spacing, and line separator.
    static func replacing(_ term: String, with replacement: String?, in text: String) -> String? {
        if let replacement, validated(replacement) == nil { return nil }
        let replacement = replacement.flatMap(validated)
        guard terms(in: text).contains(term) else { return nil }
        if let replacement, replacement != term, terms(in: text).contains(replacement) { return nil }
        var result = ""
        var line = ""
        var replaced = false
        func appendLine(separator: String) {
            if line.trimmingCharacters(in: .whitespaces) == term {
                if let replacement, !replaced { result += replacement + separator; replaced = true }
            } else {
                result += line + separator
            }
            line = ""
        }
        for character in text {
            if character.isNewline { appendLine(separator: String(character)) }
            else { line.append(character) }
        }
        appendLine(separator: "")
        return result
    }

    private static let reviewLocale = Locale(identifier: "en_US_POSIX")

    /// Review ignores case, but never rewrites the spelling saved in My terms or sent as a hint.
    static func reviewIdentity(_ term: String) -> String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .caseInsensitive, locale: reviewLocale)
            .precomposedStringWithCanonicalMapping
    }

    static func reviewKey(_ term: String) -> String {
        legacyReviewKey(reviewIdentity(term))
    }

    /// Old dismissals contain only digests, so migrate spellings as they are encountered.
    /// Common variants also preserve decisions whose original evidence is no longer in history.
    static func legacyReviewKeys(_ term: String) -> Set<String> {
        let identity = reviewIdentity(term)
        return Set([term, term.lowercased(with: reviewLocale), term.uppercased(with: reviewLocale),
                    term.capitalized(with: reviewLocale)]
            .filter { reviewIdentity($0) == identity }.map(legacyReviewKey))
    }

    private static func legacyReviewKey(_ term: String) -> String {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        return SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// An explicit "heard as" spelling the user wants fixed every time, independent of AI polish.
/// Rules exist only after a user action (edit a term, or "Always fix" in Review).
struct DictionaryReplacement: Codable, Equatable, Hashable, Sendable {
    var heard: String
    var term: String
}

enum DictionaryReplacements {
    static let maximumHeardLength = 48

    /// Split an editor field into heard spellings: one per line, or separated by commas.
    static func heardSpellings(in text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { $0.isNewline || ",，、;；".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert(DictionaryTerms.reviewIdentity($0)).inserted }
    }

    /// Why a heard spelling cannot fix `term`, or nil when it can.
    static func problem(heard: String, term: String, rules: [DictionaryReplacement], terms: [String]) -> String? {
        guard let value = DictionaryTerms.validated(heard) else { return L10n.tr("Enter each heard spelling on one line.") }
        let identity = DictionaryTerms.reviewIdentity(value)
        if value.count < 2 { return L10n.format("“%@” is too short to replace safely.", value) }
        if value.count > maximumHeardLength { return L10n.format("“%@” is too long.", value) }
        if identity == DictionaryTerms.reviewIdentity(term) {
            return L10n.format("“%@” is already the term itself.", value)
        }
        if terms.contains(where: { DictionaryTerms.reviewIdentity($0) == identity }) {
            return L10n.format("“%@” is in My terms, so it cannot be replaced.", value)
        }
        if let other = rules.first(where: { DictionaryTerms.reviewIdentity($0.heard) == identity && $0.term != term }) {
            return L10n.format("“%@” already fixes to “%@”.", value, other.term)
        }
        return nil
    }

    static func rules(for term: String, in rules: [DictionaryReplacement]) -> [DictionaryReplacement] {
        rules.filter { $0.term == term }
    }

    /// Replace the term's heard spellings, keeping every other rule and its order.
    static func setting(_ heard: [String], for term: String, in rules: [DictionaryReplacement]) -> [DictionaryReplacement] {
        rules.filter { $0.term != term } + heard.compactMap(DictionaryTerms.validated).map { DictionaryReplacement(heard: $0, term: term) }
    }

    /// Follow a term rename (nil deletes the term and its rules).
    static func renaming(_ term: String, to replacement: String?, in rules: [DictionaryReplacement]) -> [DictionaryReplacement] {
        guard let replacement else { return rules.filter { $0.term != term } }
        return rules.compactMap { rule in
            guard rule.term == term else { return rule }
            // A rename onto one of its own heard spellings would replace the term with itself.
            if DictionaryTerms.reviewIdentity(rule.heard) == DictionaryTerms.reviewIdentity(replacement) { return nil }
            return DictionaryReplacement(heard: rule.heard, term: replacement)
        }
    }

    /// Single pass over the original text: matches never overlap and replaced text is never
    /// matched again. Longer heard spellings win at the same position. Matching ignores case,
    /// width and diacritics. Latin/number spellings only match whole words; Han spellings
    /// match anywhere because Chinese has no spaces.
    static func apply(_ rules: [DictionaryReplacement], to text: String) -> (text: String, count: Int) {
        guard !rules.isEmpty, !text.isEmpty else { return (text, 0) }
        var matches: [(range: Range<String.Index>, term: String)] = []
        for rule in rules {
            guard let heard = DictionaryTerms.validated(rule.heard), heard.count >= 2 else { continue }
            var start = text.startIndex
            while start < text.endIndex,
                  let range = text.range(of: heard, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                         range: start..<text.endIndex) {
                if isWholeWord(range, in: text) { matches.append((range, rule.term)) }
                start = text.index(after: range.lowerBound)
            }
        }
        guard !matches.isEmpty else { return (text, 0) }
        matches.sort {
            $0.range.lowerBound != $1.range.lowerBound ? $0.range.lowerBound < $1.range.lowerBound
                : text.distance(from: $0.range.lowerBound, to: $0.range.upperBound) > text.distance(from: $1.range.lowerBound, to: $1.range.upperBound)
        }
        var result = ""
        var cursor = text.startIndex
        var count = 0
        for match in matches where match.range.lowerBound >= cursor {
            result += text[cursor..<match.range.lowerBound]
            result += match.term
            if text[match.range] != match.term { count += 1 }
            cursor = match.range.upperBound
        }
        result += text[cursor...]
        return (result, count)
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        (character.isLetter || character.isNumber) && !isHan(character)
    }

    private static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value)
        }
    }

    private static func isWholeWord(_ range: Range<String.Index>, in text: String) -> Bool {
        let first = text[range.lowerBound]
        let last = text[text.index(before: range.upperBound)]
        if isWordCharacter(first), range.lowerBound > text.startIndex,
           isWordCharacter(text[text.index(before: range.lowerBound)]) { return false }
        if isWordCharacter(last), range.upperBound < text.endIndex,
           isWordCharacter(text[range.upperBound]) { return false }
        return true
    }
}

/// Plain-text dictionary transfer: one term per line, optionally `Term = heard, heard`.
/// Blank lines and `#` comments are ignored. Import only adds; it never deletes or rewrites.
enum DictionaryTransfer {
    struct Merge: Equatable {
        var dictionary: String
        var rules: [DictionaryReplacement]
        var addedTerms = 0
        var addedFixes = 0
        var skipped = 0
    }

    static func export(terms: [String], rules: [DictionaryReplacement]) -> String {
        terms.map { term in
            let heard = DictionaryReplacements.rules(for: term, in: rules).map(\.heard)
            return heard.isEmpty ? term : term + " = " + heard.joined(separator: ", ")
        }.joined(separator: "\n") + (terms.isEmpty ? "" : "\n")
    }

    static func merge(_ text: String, into dictionary: String, rules: [DictionaryReplacement]) -> Merge {
        var result = Merge(dictionary: dictionary, rules: rules)
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard let term = DictionaryTerms.validated(parts[0]) else { result.skipped += 1; continue }
            if let updated = DictionaryTerms.adding(term, to: result.dictionary) {
                result.dictionary = updated
                result.addedTerms += 1
            }
            guard parts.count == 2 else { continue }
            let terms = DictionaryTerms.terms(in: result.dictionary)
            for heard in DictionaryReplacements.heardSpellings(in: parts[1]) {
                let identity = DictionaryTerms.reviewIdentity(heard)
                if result.rules.contains(where: { $0.term == term && DictionaryTerms.reviewIdentity($0.heard) == identity }) { continue }
                if DictionaryReplacements.problem(heard: heard, term: term, rules: result.rules, terms: terms) == nil {
                    result.rules.append(DictionaryReplacement(heard: heard, term: term))
                    result.addedFixes += 1
                } else {
                    result.skipped += 1
                }
            }
        }
        return result
    }
}
