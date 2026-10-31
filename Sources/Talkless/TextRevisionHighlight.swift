import Foundation

/// Describes literal changes from a finalized transcript to its polished output, not why
/// they changed. This is separate from dictionary-term presence and is not for speech partials.
enum TextRevisionHighlight {
    // Decoration is optional: skip oversized inputs rather than guessing a large changed span.
    // The byte guard also bounds normalization/hashing of pathological combining graphemes.
    private static let maximumUTF8Bytes = 65_536
    private static let maximumTokens = 512

    private struct Token {
        let range: Range<String.Index>
        let identity: Int
    }

    /// Sorted, nonempty, nonoverlapping ranges in `revised`, at extended-grapheme boundaries.
    /// Alphabetic/numeric runs are compared as whole words; Han and kana, punctuation and
    /// emoji are individual graphemes. Adjacent changed tokens form one span, including any
    /// internal whitespace. Case and punctuation are literal; canonical equivalents match,
    /// but compatibility variants do not. Whitespace-only changes are not decorated.
    ///
    /// An empty/whitespace-only baseline or output, an unchanged output, or a whole-token
    /// deletion returns no ranges: deleted tokens have no position in the result. A surviving
    /// word with removed letters ("colour" → "color") is a replacement and is highlighted
    /// whole, not letter by letter. Alignment is textual, not a claim of grammatical or
    /// dictionary-caused correction. Ambiguous repeated tokens use a stable left-to-right diff.
    ///
    /// Work is bounded by 64 KiB and 512 visible tokens per input. Over either limit, return
    /// no decoration (the caller must still display the complete, unmodified output). Within
    /// those limits, token interning makes the LCS table at most 513 × 513 integer cells.
    static func ranges(original: String, revised: String) -> [Range<String.Index>] {
        guard !original.isEmpty, !revised.isEmpty,
              original.utf8.prefix(maximumUTF8Bytes + 1).count <= maximumUTF8Bytes,
              revised.utf8.prefix(maximumUTF8Bytes + 1).count <= maximumUTF8Bytes,
              original != revised else { return [] }

        // Spacing-only word splits/joins are not revisions of the visible characters.
        guard !hasSameVisibleCharacters(revised[...], as: original[...]) else { return [] }

        var identities: [Substring: Int] = [:]
        guard let old = tokenize(original, identities: &identities), !old.isEmpty,
              let new = tokenize(revised, identities: &identities), !new.isEmpty else { return [] }

        let columns = new.count + 1
        var lengths = [Int](repeating: 0, count: (old.count + 1) * columns)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                let cell = i * columns + j
                if old[i].identity == new[j].identity {
                    lengths[cell] = 1 + lengths[(i + 1) * columns + j + 1]
                } else {
                    lengths[cell] = max(lengths[(i + 1) * columns + j], lengths[cell + 1])
                }
            }
        }

        var result: [Range<String.Index>] = []
        var i = 0
        var j = 0
        var oldStart = 0
        var newStart = 0

        func appendChange(oldEnd: Int, newEnd: Int) {
            guard newStart < newEnd else { return }
            let range = new[newStart].range.lowerBound..<new[newEnd - 1].range.upperBound
            if oldStart < oldEnd {
                let oldRange = old[oldStart].range.lowerBound..<old[oldEnd - 1].range.upperBound
                if hasSameVisibleCharacters(revised[range], as: original[oldRange]) { return }
            }
            result.append(range)
        }

        while i < old.count || j < new.count {
            if i < old.count, j < new.count, old[i].identity == new[j].identity {
                appendChange(oldEnd: i, newEnd: j)
                i += 1
                j += 1
                oldStart = i
                newStart = j
            } else if i < old.count,
                      j == new.count || lengths[(i + 1) * columns + j] >= lengths[i * columns + j + 1] {
                // Prefer a deletion when LCS scores tie, making repeated-token alignment stable.
                i += 1
            } else {
                j += 1
            }
        }
        appendChange(oldEnd: i, newEnd: j)
        return result
    }

    private static func tokenize(_ text: String, identities: inout [Substring: Int]) -> [Token]? {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let start = index
            let character = text[index]
            index = text.index(after: index)
            if character.isWhitespace { continue }
            guard tokens.count < maximumTokens else { return nil }
            if isWordCharacter(character) {
                while index < text.endIndex, isWordCharacter(text[index]) {
                    index = text.index(after: index)
                }
            }
            let range = start..<index
            let spelling = text[range]
            let identity: Int
            if let existing = identities[spelling] {
                identity = existing
            } else {
                identity = identities.count
                identities[spelling] = identity
            }
            tokens.append(Token(range: range, identity: identity))
        }
        return tokens
    }

    // A locale-independent word approximation, not linguistic segmentation. Han and kana
    // need no spaces; keep those at Character granularity, including supplementary planes.
    private static func isWordCharacter(_ character: Character) -> Bool {
        if let scalar = character.unicodeScalars.first {
            switch scalar.value {
            case 0x3005, 0x3007, 0x303B,
                 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9D,
                 0x1AFF0...0x1AFFF, 0x1B000...0x1B16F,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2EE5F, 0x2F800...0x2FA1F, 0x30000...0x3347F:
                return false
            default: break
            }
        }
        return character == "_" || character.isLetter || character.isNumber
    }

    /// Compare Characters directly: canonical equivalence without normalizing source indices.
    /// Ignoring whitespace here also suppresses word splits/joins that only change spacing.
    private static func hasSameVisibleCharacters(_ lhs: Substring, as rhs: Substring) -> Bool {
        lhs.lazy.filter { !$0.isWhitespace }.elementsEqual(rhs.lazy.filter { !$0.isWhitespace })
    }
}
