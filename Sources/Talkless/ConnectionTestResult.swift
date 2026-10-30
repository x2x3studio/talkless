import Foundation

/// An in-memory, shareable receipt. Never retain configuration, credentials, headers,
/// endpoint URLs, raw errors, or unredacted provider output in presentation state.
struct ConnectionTestResult {
    static let systemInput = "You are checking an API connection. Reply briefly."
    static let userInput = "Reply with OK."

    let provider: String
    let model: String
    let apiProtocol: LLMProtocol
    let duration: TimeInterval
    let isSuccess: Bool
    let output: String

    static func configuration(from config: LLMClient.Config) -> LLMClient.Config {
        var result = config
        result.maxOutputTokens = 1024
        return result
    }

    init(provider: PolishProvider, config: LLMClient.Config, duration: TimeInterval,
         result: Result<String, Error>) {
        self.provider = provider.title
        self.model = Self.safeText(config.model.trimmingCharacters(in: .whitespacesAndNewlines), config: config)
        self.apiProtocol = config.apiProtocol
        self.duration = duration.isFinite ? max(0, duration) : 0
        switch result {
        case .success(let response):
            isSuccess = true
            output = Self.safeText(response, config: config)
        case .failure(let error):
            isSuccess = false
            // ClientError descriptions are app-owned, never the HTTP body or an NSError's
            // userInfo. Unknown errors can echo URLs, credentials, and request headers.
            output = (error as? LLMClient.ClientError)?.localizedDescription
                ?? L10n.tr("The connection test failed. Check your provider settings and try again.")
        }
    }

    var status: String { L10n.tr(isSuccess ? "Connection successful" : "Connection failed") }
    var durationText: String { L10n.format("%.2f s", duration) }

    var diagnostics: String {
        [
            "Talkless — \(L10n.tr("Connection test"))",
            "\(L10n.tr("Status")): \(status)",
            "\(L10n.tr("Provider")): \(provider)",
            "\(L10n.tr("Model")): \(model)",
            "\(L10n.tr("Protocol")): \(apiProtocol.label)",
            "\(L10n.tr("Duration")): \(durationText)",
            "",
            "\(L10n.tr("System input")):\n\(Self.systemInput)",
            "",
            "\(L10n.tr("Test input")):\n\(Self.userInput)",
            "",
            "\(L10n.tr(isSuccess ? "Response" : "Error")):\n\(output)",
        ].joined(separator: "\n")
    }

    /// Fail closed for credential-shaped output, including an API echoing credentials
    /// that aren't the configured key. Known URL secrets are checked even on invalid
    /// endpoints, and encoded echoes are checked before any truncation.
    private static func safeText(_ text: String, config: LLMClient.Config) -> String {
        let baseURL = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = URLComponents(string: baseURL)
        var secrets = [config.apiKey, config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines), baseURL]
        if let components {
            secrets += [components.user, components.password, components.fragment].compactMap { $0 }
            secrets += (components.queryItems ?? []).flatMap { [$0.name, $0.value].compactMap { $0 } }
            if let user = components.user, let password = components.password {
                secrets.append("\(user):\(password)")
            }
        }
        let candidates = secrets.filter { !$0.isEmpty }.flatMap { secret -> [String] in
            var variants = [secret, Data(secret.utf8).base64EncodedString()]
            if let encoded = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
                variants.append(encoded)
            }
            if let data = try? JSONSerialization.data(withJSONObject: [secret]),
               let json = String(data: data, encoding: .utf8) {
                variants.append(String(json.dropFirst(2).dropLast(2)))
            }
            return variants
        }
        var decoded = text
        for _ in 0..<3 {
            let next = decoded.removingPercentEncoding ?? decoded
            if next == decoded { break }
            decoded = next
        }
        // Decode JSON-escaped strings as well (e.g. "sk\\u002d...").
        if let data = decoded.data(using: .utf8),
           let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            decoded += "\n" + String(describing: value)
        }
        // A fixed OK prompt has no reason to return encoded characters. Withhold
        // Unicode/hex/slash escapes anywhere, not just a parseable JSON document:
        // prose, code fences, and nested strings must not conceal a credential or URL.
        let credentialPattern = #"(?i)(authorization|proxy-authorization|x-api-key|x-goog-api-key|api[_ -]?key|access[_ -]?token|["']?(?:password|secret|token)["']?\s*[:=]|bearer\s+|basic\s+|\bsk-[a-z0-9_-]+|\bAIza[a-z0-9_-]+|https?://|\\(?:u[0-9a-f]{4}|x[0-9a-f]{2}|/))"#
        if candidates.contains(where: { text.localizedCaseInsensitiveContains($0) || decoded.localizedCaseInsensitiveContains($0) })
            || decoded.range(of: credentialPattern, options: .regularExpression) != nil {
            return L10n.tr("Content hidden because it may contain credentials.")
        }
        // Keep a malicious or unexpectedly verbose provider from growing the settings
        // view or clipboard without bounds. Both surfaces use exactly the same text.
        let limit = 8_000
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n" + L10n.tr("Response truncated.")
    }
}
