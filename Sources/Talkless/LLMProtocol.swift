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
        case .chatCompletions: "OpenAI Chat Completions"
        case .responses: "OpenAI Responses"
        case .geminiGenerateContent: "Gemini Generate Content"
        case .anthropicMessages: "Anthropic Messages"
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
        case .automatic: "Protocol default"
        case .bearer: "Bearer token"
        case .apiKey: "API key header"
        }
    }
}

enum LLMThinkingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case modelDefault
    case disabled

    var id: String { rawValue }
    var label: String {
        switch self {
        case .modelDefault: "Model default"
        case .disabled: "Disable thinking (supported models only)"
        }
    }
}

struct RemoteModel: Identifiable, Hashable, Sendable {
    let id: String
    var displayName: String? = nil
}
