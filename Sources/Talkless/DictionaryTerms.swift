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
