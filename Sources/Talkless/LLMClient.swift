import Foundation

/// Single-turn text polishing using native URLSession. No SDK, tools, retries, or protocol fallback.
enum LLMClient {
    struct Config: Sendable {
        var baseURL: String
        var apiKey: String
        var model: String
        var apiProtocol: LLMProtocol = .chatCompletions
        var authMode: LLMAuthMode = .automatic
        var maxOutputTokens: Int? = 4096
        var thinking: LLMThinkingMode = .modelDefault
    }

    enum ClientError: LocalizedError, Equatable {
        case invalidURL, missingKey, missingModel, invalidModel, invalidKey, invalidTimeout, invalidTokenLimit
        case invalidResponse, emptyResponse, incomplete, refusal, unsupportedToolCall, unsupportedThinking
        case httpStatus(Int)
        case redirect, timedOut, network, paginationLimit

        var errorDescription: String? {
            switch self {
            case .invalidURL: L10n.tr("Use an HTTPS API URL without credentials, query, or fragment. HTTP is allowed only for localhost.")
            case .missingKey: L10n.tr("Enter an API key for this language model service.")
            case .missingModel: L10n.tr("Select or enter a language model ID.")
            case .invalidModel: L10n.tr("The model ID is invalid for this API protocol.")
            case .invalidKey: L10n.tr("The API key contains invalid characters.")
            case .invalidTimeout: L10n.tr("The language model timeout must be greater than zero and at most 120 seconds.")
            case .invalidTokenLimit: L10n.tr("Set a positive output token limit (at least 16 for Responses). Anthropic requires a limit.")
            case .invalidResponse: L10n.tr("The language model returned an invalid response. Check the selected API protocol.")
            case .emptyResponse: L10n.tr("The language model returned no final text.")
            case .incomplete: L10n.tr("The language model response was incomplete. The original text has not been replaced.")
            case .refusal: L10n.tr("The language model declined this request. The original text has not been replaced.")
            case .unsupportedToolCall: L10n.tr("The language model requested a tool, which is not supported for text polishing.")
            case .unsupportedThinking: L10n.tr("Disabling thinking is not verified for this model and API URL. Use the model default or choose a supported non-reasoning model.")
            case .httpStatus(let status): L10n.format("Language model service returned HTTP %d. Check the API URL, key, model, and protocol.", status)
            case .redirect: L10n.tr("The API redirected outside its origin or changed the request method. Enter its final API URL instead.")
            case .timedOut: L10n.tr("The language model request timed out.")
            case .network: L10n.tr("Could not connect to the language model service.")
            case .paginationLimit: L10n.tr("The model list exceeded the pagination limit or returned an invalid cursor.")
            }
        }
    }

    static let maximumResponseBytes = 1_048_576
    static let maximumModelPages = 20

    static func complete(system: String, user: String, config: Config, timeout: TimeInterval = 30) async throws -> String {
        try await complete(system: system, user: user, config: config, timeout: timeout, sessionConfiguration: nil)
    }

    /// Configuration injection keeps tests entirely offline, including auth and request serialization.
    /// Without one, the shared session reuses warm connections across dictations.
    static func complete(system: String, user: String, config: Config, timeout: TimeInterval = 30,
                         sessionConfiguration: URLSessionConfiguration?) async throws -> String {
        let request = try makeRequest(system: system, user: user, config: config, timeout: timeout)
        let isolated = sessionConfiguration.map { LLMAPITransport.session(configuration: $0, timeout: timeout) }
        defer { isolated?.invalidateAndCancel() }
        let data = try await LLMAPITransport.data(for: request, session: isolated ?? LLMAPITransport.shared,
                                                  maximumBytes: maximumResponseBytes)
        try Task.checkCancellation()
        return try parseResponse(data, config: config)
    }

    static func makeRequest(system: String, user: String, config: Config, timeout: TimeInterval = 30) throws -> URLRequest {
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw ClientError.missingModel }
        guard !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ClientError.invalidModel }
        if let limit = config.maxOutputTokens {
            guard limit >= (config.apiProtocol == .responses ? 16 : 1) else { throw ClientError.invalidTokenLimit }
        } else if config.apiProtocol == .anthropicMessages { throw ClientError.invalidTokenLimit }
        let url = try endpointURL(baseURL: config.baseURL, apiProtocol: config.apiProtocol, model: model)
        var request = try LLMAPITransport.request(url: url, config: config, timeout: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any]
        switch config.apiProtocol {
        case .chatCompletions:
            body = ["model": model, "messages": [["role": "system", "content": system], ["role": "user", "content": user]], "stream": false]
            // Modern OpenAI uses max_completion_tokens. Other compatible services retain max_tokens.
            if let limit = config.maxOutputTokens {
                body[url.host?.lowercased() == "api.openai.com" ? "max_completion_tokens" : "max_tokens"] = limit
            }
        case .responses:
            body = ["model": model, "instructions": system, "input": user, "stream": false, "store": false]
            if let limit = config.maxOutputTokens { body["max_output_tokens"] = limit }
        case .anthropicMessages:
            body = ["model": model, "system": system, "messages": [["role": "user", "content": user]], "stream": false]
            body["max_tokens"] = config.maxOutputTokens
        case .geminiGenerateContent:
            body = ["systemInstruction": ["parts": [["text": system]]],
                    "contents": [["role": "user", "parts": [["text": user]]]]]
            if let limit = config.maxOutputTokens { body["generationConfig"] = ["maxOutputTokens": limit] }
        }
        // No sampling/effort/thinking extras by default: omitting thinking does not promise reasoning is off.
        if config.thinking == .disabled {
            guard supportsDisablingThinking(config: config) else { throw ClientError.unsupportedThinking }
            switch config.apiProtocol {
            case .chatCompletions:
                if url.host?.lowercased() == "api.openai.com" { body["reasoning_effort"] = "none" }
                else { body["thinking"] = ["type": "disabled"] }
            case .responses: body["reasoning"] = ["effort": "none"]
            case .anthropicMessages: body["thinking"] = ["type": "disabled"]
            case .geminiGenerateContent: throw ClientError.unsupportedThinking
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Conservative exact-model capability checks, not model presets or automatic model selection.
    /// Checked against official reasoning / Messages / DeepSeek create docs on 2026-10-30.
    /// Unknown IDs and custom proxy paths deliberately get no guessed provider-specific parameters.
    static func supportsDisablingThinking(config: Config) -> Bool {
        guard let url = try? endpointURL(baseURL: config.baseURL, apiProtocol: config.apiProtocol, model: config.model),
              url.scheme == "https", url.port == nil || url.port == 443 else { return false }
        let model = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (url.host?.lowercased(), config.apiProtocol, url.path) {
        case ("api.openai.com", .responses, "/v1/responses"), ("api.openai.com", .chatCompletions, "/v1/chat/completions"):
            return model == "gpt-5.5"
        case ("api.deepseek.com", .chatCompletions, "/chat/completions"), ("api.deepseek.com", .chatCompletions, "/v1/chat/completions"):
            return ["deepseek-flash", "deepseek-v4-pro"].contains(model)
        // Do not infer Anthropic support from generic model-list examples: current per-model
        // documentation can disagree, and some models reject disabled. Omit unless verified.
        default: return false
        }
    }

    static func thinkingGuidance(config: Config) -> String {
        if config.thinking == .disabled && supportsDisablingThinking(config: config) {
            return L10n.tr("Talkless requests thinking off using this model's documented parameter.")
        }
        return L10n.tr("Talkless does not request extra thinking. Some models reason by default or cannot disable reasoning; choose a non-reasoning model for faster polishing.")
    }

    static func endpointURL(baseURL: String, apiProtocol: LLMProtocol, model: String = "") throws -> URL {
        try LLMAPITransport.endpoint(baseURL: baseURL, apiProtocol: apiProtocol, model: model, models: false)
    }

    static func isLoopback(_ url: URL) -> Bool { LLMAPITransport.isLoopback(url) }

    static func fetchModels(config: Config, timeout: TimeInterval = 30) async throws -> [RemoteModel] {
        try await fetchModels(config: config, timeout: timeout, sessionConfiguration: .ephemeral)
    }

    static func fetchModels(config: Config, timeout: TimeInterval = 30,
                            sessionConfiguration: URLSessionConfiguration) async throws -> [RemoteModel] {
        try LLMAPITransport.validateTimeout(timeout)
        let base = try LLMAPITransport.endpoint(baseURL: config.baseURL, apiProtocol: config.apiProtocol, model: nil, models: true)
        let session = LLMAPITransport.session(configuration: sessionConfiguration, timeout: timeout)
        defer { session.invalidateAndCancel() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var cursor: String?
        var cursors = Set<String>()
        var seen = Set<String>()
        var result: [RemoteModel] = []
        for _ in 0..<maximumModelPages {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ClientError.timedOut }
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
            if config.apiProtocol == .anthropicMessages {
                components.queryItems = [URLQueryItem(name: "limit", value: "100")]
                if let cursor { components.queryItems?.append(URLQueryItem(name: "after_id", value: cursor)) }
            } else if config.apiProtocol == .geminiGenerateContent {
                components.queryItems = [URLQueryItem(name: "pageSize", value: "100")]
                if let cursor { components.queryItems?.append(URLQueryItem(name: "pageToken", value: cursor)) }
            }
            guard let url = components.url else { throw ClientError.invalidURL }
            var request = try LLMAPITransport.request(url: url, config: config, timeout: remaining)
            request.httpMethod = "GET"
            let data = try await LLMAPITransport.data(for: request, session: session, maximumBytes: maximumResponseBytes)
            let page = try parseModelPage(data, apiProtocol: config.apiProtocol)
            for model in page.models where seen.insert(model.id).inserted { result.append(model) }
            guard let next = page.nextCursor else { return result }
            guard !next.isEmpty, next.utf8.count <= 8192, cursors.insert(next).inserted else { throw ClientError.paginationLimit }
            cursor = next
        }
        throw ClientError.paginationLimit
    }

    private static func parseModelPage(_ data: Data, apiProtocol: LLMProtocol) throws -> (models: [RemoteModel], nextCursor: String?) {
        do {
            let decoder = JSONDecoder()
            switch apiProtocol {
            case .geminiGenerateContent:
                let page = try decoder.decode(GeminiModels.self, from: data)
                let models = try (page.models ?? []).filter { $0.supportedGenerationMethods?.contains("generateContent") == true }.map { item in
                    let id = item.name.hasPrefix("models/") ? String(item.name.dropFirst(7)) : item.name
                    guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.invalidResponse }
                    return RemoteModel(id: id, displayName: item.displayName)
                }
                return (models, page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 })
            case .chatCompletions, .responses, .anthropicMessages:
                let page = try decoder.decode(ModelList.self, from: data)
                let models = try page.data.map { item in
                    guard !item.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.invalidResponse }
                    return RemoteModel(id: item.id, displayName: item.display_name)
                }
                if apiProtocol == .anthropicMessages {
                    guard let more = page.has_more else { throw ClientError.invalidResponse }
                    if more {
                        guard let cursor = page.last_id, !cursor.isEmpty, !models.isEmpty else { throw ClientError.paginationLimit }
                        return (models, cursor)
                    }
                }
                return (models, nil)
            }
        } catch let error as ClientError { throw error }
        catch { throw ClientError.invalidResponse }
    }

    static func parseResponse(_ data: Data, config: Config) throws -> String {
        guard data.count <= maximumResponseBytes else { throw ClientError.invalidResponse }
        do {
            let decoder = JSONDecoder()
            let text: String
            switch config.apiProtocol {
            case .chatCompletions:
                let reply = try decoder.decode(ChatReply.self, from: data)
                guard let choice = reply.choices.first else { throw ClientError.emptyResponse }
                if choice.message.refusal != nil || choice.finish_reason == "content_filter" { throw ClientError.refusal }
                if ["tool_calls", "function_call"].contains(choice.finish_reason ?? "") ||
                    !(choice.message.tool_calls ?? []).isEmpty || choice.message.function_call != nil { throw ClientError.unsupportedToolCall }
                guard choice.finish_reason == "stop" else { throw ClientError.incomplete }
                guard choice.message.role == nil || choice.message.role == "assistant" else { throw ClientError.invalidResponse }
                text = choice.message.content ?? ""
            case .responses:
                let reply = try decoder.decode(ResponsesReply.self, from: data)
                if reply.output.contains(where: { $0.content?.contains(where: { $0.type == "refusal" }) == true }) { throw ClientError.refusal }
                if reply.output.contains(where: { $0.type.contains("call") }) { throw ClientError.unsupportedToolCall }
                guard reply.status == "completed", reply.incomplete_details == nil, reply.error == nil else { throw ClientError.incomplete }
                guard reply.output.allSatisfy({ ["message", "reasoning"].contains($0.type) }) else { throw ClientError.invalidResponse }
                let messages = reply.output.filter { $0.type == "message" }
                guard messages.allSatisfy({ ($0.status == nil || $0.status == "completed") && ($0.role == nil || $0.role == "assistant") }) else { throw ClientError.incomplete }
                text = messages.flatMap { $0.content ?? [] }.filter { $0.type == "output_text" }.compactMap(\.text).joined(separator: "\n")
            case .anthropicMessages:
                let reply = try decoder.decode(AnthropicReply.self, from: data)
                if reply.stop_reason == "refusal" || reply.content.contains(where: { $0.type == "refusal" }) { throw ClientError.refusal }
                if reply.stop_reason == "tool_use" || reply.content.contains(where: { $0.type.contains("tool_use") }) { throw ClientError.unsupportedToolCall }
                guard ["end_turn", "stop_sequence"].contains(reply.stop_reason ?? "") else { throw ClientError.incomplete }
                text = reply.content.filter { $0.type == "text" }.compactMap(\.text).joined(separator: "\n")
            case .geminiGenerateContent:
                let reply = try decoder.decode(GeminiReply.self, from: data)
                if let reason = reply.promptFeedback?.blockReason, reason != "BLOCK_REASON_UNSPECIFIED" { throw ClientError.refusal }
                guard let candidate = reply.candidates?.first else { throw ClientError.emptyResponse }
                let parts = candidate.content?.parts ?? []
                if parts.contains(where: { $0.functionCall != nil }) { throw ClientError.unsupportedToolCall }
                if ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY"].contains(candidate.finishReason ?? "") { throw ClientError.refusal }
                guard candidate.finishReason == "STOP" else { throw ClientError.incomplete }
                text = parts.filter { $0.thought != true }.compactMap(\.text).joined(separator: "\n")
            }
            let result = clean(text)
            guard !result.isEmpty else { throw ClientError.emptyResponse }
            return result
        } catch let error as ClientError { throw error }
        catch { throw ClientError.invalidResponse }
    }

    /// Protocol-specific parsing already excludes reasoning blocks. Tags and code fences
    /// in a final text block may be literal dictation and must not be deleted.
    static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct ContentBlock: Decodable { let type: String; let text: String? }
    private struct PresentObject: Decodable {}
    private struct ChatReply: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let role: String?
                let content: String?
                let refusal: String?
                let tool_calls: [PresentObject]?
                let function_call: PresentObject?
            }
            let message: Message
            let finish_reason: String?
        }
        let choices: [Choice]
    }
    private struct ResponsesReply: Decodable {
        struct Output: Decodable { let type: String; let status: String?; let role: String?; let content: [ContentBlock]? }
        let status: String
        let incomplete_details: PresentObject?
        let error: PresentObject?
        let output: [Output]
    }
    private struct AnthropicReply: Decodable { let stop_reason: String?; let content: [ContentBlock] }
    private struct GeminiReply: Decodable {
        struct Feedback: Decodable { let blockReason: String? }
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String?; let thought: Bool?; let functionCall: PresentObject? }
                let parts: [Part]?
            }
            let content: Content?
            let finishReason: String?
        }
        let promptFeedback: Feedback?
        let candidates: [Candidate]?
    }
    private struct ModelList: Decodable {
        struct Item: Decodable { let id: String; let display_name: String? }
        let data: [Item]
        let has_more: Bool?
        let last_id: String?
    }
    private struct GeminiModels: Decodable {
        struct Item: Decodable { let name: String; let displayName: String?; let supportedGenerationMethods: [String]? }
        let models: [Item]?
        let nextPageToken: String?
    }
}
