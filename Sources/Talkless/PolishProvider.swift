import Foundation

/// Each provider keeps its own endpoint, model, protocol, and credential.
enum PolishProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case deepSeek
    case openAI
    case openRouter
    case gemini
    case anthropic
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .deepSeek: return "DeepSeek"
        case .openAI: return "OpenAI"
        case .openRouter: return "OpenRouter"
        case .gemini: return "Gemini"
        case .anthropic: return "Anthropic"
        case .custom: return "Custom"
        }
    }

    var defaultURL: String {
        switch self {
        case .deepSeek: return "https://api.deepseek.com"
        case .openAI: return "https://api.openai.com/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .custom: return ""
        }
    }

    var defaultProtocol: LLMProtocol {
        switch self {
        case .deepSeek, .openRouter, .custom: return .chatCompletions
        case .openAI: return .responses
        case .gemini: return .geminiGenerateContent
        case .anthropic: return .anthropicMessages
        }
    }

    var protocolOptions: [LLMProtocol] {
        switch self {
        case .deepSeek, .openRouter: return [.chatCompletions]
        case .openAI: return [.responses, .chatCompletions]
        case .gemini: return [.geminiGenerateContent]
        case .anthropic: return [.anthropicMessages]
        case .custom: return [.chatCompletions, .responses, .geminiGenerateContent, .anthropicMessages]
        }
    }

    var modelPlaceholder: String {
        self == .deepSeek ? "deepseek-chat" : "Fetch models or enter a model ID"
    }

    /// Only OpenRouter has an explicit starter route; saved model choices are never replaced.
    var defaultModel: String { self == .openRouter ? "openrouter/free" : "" }

    /// Match known hosts exactly: a look-alike domain remains a custom endpoint.
    static func matchingLegacyURL(_ value: String) -> PolishProvider {
        let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
        // Google's OpenAI compatibility endpoint must retain the Chat protocol.
        if url?.host?.lowercased() == "generativelanguage.googleapis.com",
           url?.path.split(separator: "/").contains("openai") == true { return .custom }
        switch url?.host?.lowercased() {
        case "api.deepseek.com", "deepseek.com": return .deepSeek
        case "api.openai.com": return .openAI
        case "openrouter.ai": return .openRouter
        case "generativelanguage.googleapis.com": return .gemini
        case "api.anthropic.com": return .anthropic
        default: return .custom
        }
    }
}

/// Deliberately excludes the API key; only this state is encoded in UserDefaults.
struct PolishProviderState: Codable, Equatable {
    var baseURL: String
    var model: String
    var apiProtocol: LLMProtocol
    var authMode: LLMAuthMode

    init(provider: PolishProvider) {
        baseURL = provider.defaultURL
        model = provider.defaultModel
        apiProtocol = provider.defaultProtocol
        authMode = .automatic
    }
}

struct StoredPolishSettings: Codable {
    var selectedProvider: PolishProvider
    var providers: [String: PolishProviderState]
}
