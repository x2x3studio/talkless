import Foundation

/// Raw model output must be parsed before the library discards the ASR boundary.
/// Never apply this parser to STTOutput.text: it may already be genuine speech.
enum QwenDecodedOutput: Equatable, Sendable {
    case transcript(String)
    case incompleteHeader
    case malformedHeader

    var previewText: String {
        if case .transcript(let text) = self { return text }
        return ""
    }

    func finalText() throws -> String {
        guard case .transcript(let text) = self else {
            throw QwenOutputError.invalidHeader
        }
        return text
    }
}

enum QwenOutputError: LocalizedError {
    case invalidHeader

    var errorDescription: String? {
        L10n.tr("Qwen returned an incomplete recognition header; no text was inserted. Please try again.")
    }
}

enum QwenOutputParser {
    // Fallback for model configs that omit support_languages. This is validation of
    // protocol metadata, not a restriction on words or languages in the transcript.
    private static let defaultLanguages = [
        "Chinese", "English", "Cantonese", "Arabic", "German", "French", "Spanish",
        "Portuguese", "Indonesian", "Italian", "Korean", "Russian", "Thai", "Vietnamese",
        "Japanese", "Turkish", "Hindi", "Malay", "Dutch", "Swedish", "Danish", "Finnish",
        "Polish", "Czech", "Filipino", "Persian", "Greek", "Hungarian", "Macedonian", "Romanian"
    ]

    static func parse(
        rawText: String, languageWasForced: Bool, supportedLanguages: [String] = []
    ) -> QwenDecodedOutput {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        // A forced-language prompt already contains the header and <asr_text>.
        // Everything generated after it is speech, even the words "language English".
        if languageWasForced { return .transcript(text) }
        if text.isEmpty { return .transcript("") }

        let assistant = "<|im_start|>assistant\n"
        if text == "<|im_start|>assistant" { return .incompleteHeader }
        if text.hasPrefix(assistant) {
            text = String(text.dropFirst(assistant.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return .incompleteHeader }
        }

        let prefix = "language "
        let marker = "<asr_text>"
        if prefix.hasPrefix(text) { return .incompleteHeader }
        guard text.hasPrefix(prefix) else {
            // These are protocol tokens only at the beginning, never a regex over speech.
            if text.hasPrefix("<|im_") || text.hasPrefix("<asr_") {
                return .malformedHeader
            }
            return .transcript(text)
        }

        let languages = (supportedLanguages.isEmpty ? defaultLanguages : supportedLanguages) + ["None"]
        let headerAndBody = String(text.dropFirst(prefix.count))
        guard let boundary = headerAndBody.range(of: marker) else {
            // Short audio can end after just "language Chinese", or part of the marker.
            let isIncomplete = languages.contains { language in
                (language + marker).hasPrefix(headerAndBody)
            }
            if isIncomplete { return .incompleteHeader }
            let hasExpectedLanguage = languages.contains { language in
                headerAndBody.hasPrefix(language + " ") || headerAndBody.hasPrefix(language + "<")
            }
            if hasExpectedLanguage || headerAndBody.contains("<asr_") {
                return .malformedHeader
            }
            // A plain sentence such as "language learning is fun" is not a header.
            return .transcript(text)
        }
        let language = headerAndBody[..<boundary.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard languages.contains(language) else { return .malformedHeader }
        // Parse exactly one boundary. Do not reinterpret or clean the body, even if
        // the speaker literally said "language English" or dictated another header.
        return .transcript(headerAndBody[boundary.upperBound...]
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
