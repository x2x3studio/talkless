import Foundation

/// Finds the presence of saved spellings, not evidence that a dictionary caused a correction.
/// Construct once for a recording, then pass only the text actually displayed by the HUD.
struct DictionaryHighlightMatcher: Sendable {
    // A corruption guard, not the add-dialog's term-length limit. Legacy phrases remain valid.
    private static let maximumTermUTF8Bytes = 65_536

    private struct Node: Sendable {
        var children: [Character: Int] = [:]
        var terminal = false
        var needsLeadingBoundary = false
        var needsTrailingBoundary = false
    }

    private enum CharacterKind {
        case lexical, han, joiner, other
    }

    private let nodes: [Node]

    init(terms: [String]) {
        var nodes = [Node()]
        for term in terms {
            // Bound work before normalization, including pathological single combining graphemes.
            guard !term.isEmpty,
                  term.utf8.prefix(Self.maximumTermUTF8Bytes + 1).count <= Self.maximumTermUTF8Bytes,
                  !term.contains(where: \.isNewline),
                  !term.unicodeScalars.contains(where: {
                      $0.properties.generalCategory == .control && $0 != "\t"
                  }),
                  term.unicodeScalars.contains(where: {
                      !$0.properties.isWhitespace && ![
                          Unicode.GeneralCategory.format, .nonspacingMark, .spacingMark, .enclosingMark,
                      ].contains($0.properties.generalCategory)
                  }) else { continue }

            let characters = Array(term.precomposedStringWithCanonicalMapping)
            let hasLexicalCharacter = characters.contains { Self.kind(of: $0) == .lexical }
            var node = 0
            for character in characters {
                if let child = nodes[node].children[character] {
                    node = child
                } else {
                    let child = nodes.count
                    nodes.append(Node())
                    nodes[node].children[character] = child
                    node = child
                }
            }
            nodes[node].terminal = true
            nodes[node].needsLeadingBoundary = hasLexicalCharacter && !characters[0].isWhitespace
                && Self.kind(of: characters[0]) != .han
            nodes[node].needsTrailingBoundary = hasLexicalCharacter && !characters[characters.count - 1].isWhitespace
                && Self.kind(of: characters[characters.count - 1]) != .han
        }
        self.nodes = nodes
    }

    /// Sorted, nonoverlapping original-string ranges, choosing the longest valid match at each start.
    /// Case and whitespace are literal. Canonically equivalent Unicode spellings compare equal,
    /// but compatibility variants do not. Every endpoint is an extended-grapheme boundary.
    func ranges(in text: String) -> [Range<String.Index>] {
        guard nodes.count > 1, !text.isEmpty else { return [] }

        // Character hashing/equality is canonically equivalent, so input need not be rewritten
        // or indexed through a normalized copy (whose UTF-16 offsets could differ).
        let characters = Array(text)
        let indices = Array(text.indices) + [text.endIndex]
        let kinds = characters.map(Self.kind)
        var result: [Range<String.Index>] = []
        var start = 0
        while start < characters.count {
            var node = 0
            var end = start
            var longestEnd: Int?
            while end < characters.count, let child = nodes[node].children[characters[end]] {
                node = child
                end += 1
                guard nodes[node].terminal else { continue }
                if (!nodes[node].needsLeadingBoundary || Self.hasLeadingBoundary(at: start, characters: characters, kinds: kinds)),
                   (!nodes[node].needsTrailingBoundary || Self.hasTrailingBoundary(at: end, characters: characters, kinds: kinds)) {
                    longestEnd = end
                }
            }
            if let end = longestEnd {
                result.append(indices[start]..<indices[end])
                start = end
            } else {
                start += 1
            }
        }
        return result
    }

    // Non-Han letters/numbers and underscores form words/identifiers. Apostrophes and hyphens
    // join lexical neighbors: don't highlight OpenAI in OpenAI's or API in pre-API/API-like.
    // Quotes not between lexical neighbors and en/em dashes are delimiters. Han can adjoin
    // either Han terms or Latin terms without intervening whitespace.
    private static func kind(of character: Character) -> CharacterKind {
        if "-'’‘ʼ\u{2010}\u{2011}".contains(character) { return .joiner }
        if let scalar = character.unicodeScalars.first {
            switch scalar.value {
            case 0x3005, 0x3007, 0x303B,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2EE5F, 0x2F800...0x2FA1F, 0x30000...0x3347F:
                return .han
            default: break
            }
        }
        if character == "_" || character.isLetter || character.isNumber { return .lexical }
        return .other
    }

    private static func hasLeadingBoundary(at start: Int, characters: [Character], kinds: [CharacterKind]) -> Bool {
        guard start > 0 else { return true }
        if kinds[start - 1] == .lexical { return false }
        if kinds[start - 1] == .joiner, start > 1, kinds[start - 2] == .lexical { return false }
        // A punctuation-bearing token cannot be cut from a longer repeated operator:
        // C+++ or ..NET are not the saved spelling C++/.NET.
        if kinds[start] == .other, characters[start - 1] == characters[start] { return false }
        return true
    }

    private static func hasTrailingBoundary(at end: Int, characters: [Character], kinds: [CharacterKind]) -> Bool {
        guard end < characters.count else { return true }
        if kinds[end] == .lexical { return false }
        if kinds[end] == .joiner, end + 1 < kinds.count, kinds[end + 1] == .lexical { return false }
        if kinds[end - 1] == .other, characters[end] == characters[end - 1] { return false }
        return true
    }
}
