import Foundation

/// Literal markup and code are protected by the polishing contract, including translation.
/// This is a narrow guard, not a general test of semantic equivalence.
enum PolishValidation {
    static func validate(source: String, output: String) throws -> String {
        let patterns = [
            #"```[\s\S]*?```"#,
            #"`[^`\r\n]+`"#,
            #"</?[A-Za-z][A-Za-z0-9:_-]*(?:\s+[^<>]*?)?\s*/?>"#,
        ]
        for pattern in patterns {
            let expression = try NSRegularExpression(pattern: pattern)
            let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
            var required: [String: Int] = [:]
            for match in matches {
                guard let range = Range(match.range, in: source) else { continue }
                required[String(source[range]), default: 0] += 1
            }
            for (literal, count) in required {
                guard output.components(separatedBy: literal).count - 1 >= count else {
                    throw ValidationError.changedLiteral
                }
            }
        }
        return output
    }

    enum ValidationError: LocalizedError {
        case changedLiteral
        var errorDescription: String? {
            "Polishing changed literal code or markup. The original transcript is retained."
        }
    }
}
