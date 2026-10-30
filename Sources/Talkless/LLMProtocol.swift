import Foundation

/// The selected wire format, never inferred from a model name.
enum LLMProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatCompletions
    case responses
    case geminiGenerateContent
    case anthropicMessages

    var id: String { rawValue }
    var label: String {
        switch self {
        case .chatCompletions: L10n.tr("OpenAI Chat Completions")
        case .responses: L10n.tr("OpenAI Responses")
        case .geminiGenerateContent: L10n.tr("Gemini Generate Content")
        case .anthropicMessages: L10n.tr("Anthropic Messages")
        }
    }
}

enum LLMAuthMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case bearer
    case apiKey

    var id: String { rawValue }
    var label: String {
        switch self {
        case .automatic: L10n.tr("Protocol default")
        case .bearer: L10n.tr("Bearer token")
        case .apiKey: L10n.tr("API key header")
        }
    }
}

enum LLMThinkingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case modelDefault
    case disabled

    var id: String { rawValue }
    var label: String {
        switch self {
        case .modelDefault: L10n.tr("Model default")
        case .disabled: L10n.tr("Disable thinking (supported models only)")
        }
    }
}

struct RemoteModel: Identifiable, Hashable, Sendable {
    let id: String
    var displayName: String? = nil
}
