import Foundation

/// Minimal OpenAI-compatible Chat Completions client (OpenAI, DeepSeek, Qwen, Kimi, Groq, Ollama, etc.).
enum LLMClient {
    struct Config {
        var baseURL: String
        var apiKey: String
        var model: String
    }

    static func complete(system: String, user: String, config: Config, timeout: TimeInterval = 30) async throws -> String {
        guard let url = URL(string: config.baseURL.trimmingCharacters(in: .whitespaces))?
            .appendingPathComponent("chat/completions") else {
            throw TalklessError.message("Invalid language model API URL")
        }
        struct Message: Codable { let role: String; let content: String }
        struct Body: Encodable { let model: String; let messages: [Message]; let temperature: Double; let stream: Bool }
        struct Reply: Decodable {
            struct Choice: Decodable { let message: Message }
            let choices: [Choice]
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(Body(
            model: config.model,
            messages: [.init(role: "system", content: system), .init(role: "user", content: user)],
            temperature: 0.2,
            stream: false
        ))

        let (data, response) = try await URLSession.shared.data(for: request)
        try HTTP.check(response, data)
        guard let content = try JSONDecoder().decode(Reply.self, from: data).choices.first?.message.content else {
            throw TalklessError.message("The language model returned no content")
        }
        return clean(content)
    }

    /// Remove reasoning models' <think> sections and unnecessary code fences.
    static func clean(_ text: String) -> String {
        var s = text
        if let end = s.range(of: "</think>") {
            s = String(s[end.upperBound...])
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```"), s.hasSuffix("```"), s.count > 6 {
            s = String(s.dropFirst(3).dropLast(3))
            if let newline = s.firstIndex(of: "\n") { s = String(s[s.index(after: newline)...]) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }
}
