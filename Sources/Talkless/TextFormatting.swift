import Foundation

/// How dictated punctuation appears. Applied on this Mac after recognition and smart cleanup.
enum PunctuationStyle: String, CaseIterable, Identifiable, Sendable {
    case keepAll, noTrailing, spaces

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepAll: L10n.tr("Keep all punctuation")
        case .noTrailing: L10n.tr("No punctuation at sentence end")
        case .spaces: L10n.tr("Spaces instead of punctuation")
        }
    }
}

/// Whether Latin words and numbers are set off from Chinese text by spaces.
enum LatinSpacing: String, CaseIterable, Identifiable, Sendable {
    case none, spaced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: L10n.tr("No spaces")
        case .spaced: L10n.tr("Spaces before and after")
        }
    }
}

/// Deterministic, local text formatting. It never touches decimals, versions, URLs or code
/// punctuation: ASCII marks count as punctuation only when whitespace or the end follows.
enum TextFormatting {
    static func apply(_ text: String, punctuation: PunctuationStyle, spacing: LatinSpacing) -> String {
        // Spacing first, so the spaces that replace punctuation are never removed again.
        let spaced = applySpacing(text, spacing)
        switch punctuation {
        case .keepAll: return spaced
        case .noTrailing: return mapLines(spaced, removingTrailingPunctuation)
        case .spaces: return mapLines(spaced, replacingPunctuationWithSpaces)
        }
    }

    static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value) || (0x20000...0x323AF).contains(scalar.value)
        }
    }

    private static func isLatinOrDigit(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    private static func boundary(_ a: Character, _ b: Character) -> Bool {
        (isHan(a) && isLatinOrDigit(b)) || (isLatinOrDigit(a) && isHan(b))
    }

    private static func applySpacing(_ text: String, _ spacing: LatinSpacing) -> String {
        let characters = Array(text)
        var result = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            result.append(character)
            index += 1
            guard index < characters.count else { break }
            switch spacing {
            case .spaced:
                if boundary(character, characters[index]) { result.append(" ") }
            case .none:
                // Drop spaces (not line breaks) that only separate Chinese from Latin or digits.
                var next = index
                while next < characters.count, characters[next] == " " { next += 1 }
                if next > index, next < characters.count, boundary(character, characters[next]) { index = next }
            }
        }
        return result
    }

    private static func mapLines(_ text: String, _ transform: (String) -> String) -> String {
        text.components(separatedBy: "\n").map(transform).joined(separator: "\n")
    }

    private static let trailingMarks: Set<Character> = ["。", "．", ".", "，", ",", "；", ";", "：", ":", "、"]
    private static let chineseMarks: Set<Character> = ["，", "。", "、", "；", "：", "！", "？", "…", "．", "～"]
    private static let asciiMarks: Set<Character> = [",", ".", ";", ":", "!", "?"]

    /// Questions and exclamations keep their marks; periods, commas and the like are dropped.
    private static func removingTrailingPunctuation(_ line: String) -> String {
        var line = line
        while let last = line.last, last == " " { line.removeLast() }
        while let last = line.last, trailingMarks.contains(last) {
            // Keep an ellipsis written as dots.
            if last == ".", line.hasSuffix("...") { break }
            line.removeLast()
        }
        return line
    }

    private static func replacingPunctuationWithSpaces(_ line: String) -> String {
        let characters = Array(line)
        var result = ""
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let isMark = chineseMarks.contains(character)
                || (asciiMarks.contains(character) && (next == nil || next == " "))
            if isMark {
                if result.last != " " && !result.isEmpty { result.append(" ") }
            } else if character == " " {
                if result.last != " " && !result.isEmpty { result.append(" ") }
            } else {
                result.append(character)
            }
        }
        while result.last == " " { result.removeLast() }
        return result
    }
}
