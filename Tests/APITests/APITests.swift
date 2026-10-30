import Foundation
import Synchronization

private struct Failure: Error, CustomStringConvertible { let description: String }
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(description: message) }
}
private let expectedUserAgent = "Talkless/\(ProcessInfo.processInfo.environment["TALKLESS_TEST_EXPECTED_VERSION"] ?? "0.1.0")"
private func requestBody(_ request: URLRequest) throws -> Data {
    let data: Data
    if let body = request.httpBody { data = body }
    else if let stream = request.httpBodyStream {
        stream.open()
        defer { stream.close() }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw Failure(description: "Unreadable request body") }
            if count == 0 { break }
            output.append(contentsOf: buffer.prefix(count))
        }
        data = output
    } else { throw Failure(description: "Missing request body") }
    return data
}
private func json(_ request: URLRequest) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: requestBody(request)) as? [String: Any] else { throw Failure(description: "Invalid request JSON") }
    return object
}
private func expectError(_ expected: LLMClient.ClientError, _ operation: () throws -> Void) throws {
    do { try operation(); throw Failure(description: "Expected \(expected)") }
    catch let error as LLMClient.ClientError { try expect(error == expected, "Expected \(expected), got \(error)") }
}
private func expectAsyncError(_ expected: LLMClient.ClientError, _ operation: () async throws -> Void) async throws {
    do { try await operation(); throw Failure(description: "Expected \(expected)") }
    catch let error as LLMClient.ClientError { try expect(error == expected, "Expected \(expected), got \(error)") }
}

private final class MockProtocol: URLProtocol, @unchecked Sendable {
    enum Stub: Sendable {
        case reply(Int, String)
        case bytes(Data)
        case hang
        case fail(URLError.Code)
        case redirect(String)
    }
    struct State {
        var handler: (@Sendable (URLRequest) throws -> Stub)?
        var requests = 0
        var stopped = 0
        var errors: [String] = []
    }
    static let state = Mutex(State())
    static func install(_ handler: @escaping @Sendable (URLRequest) throws -> Stub) {
        state.withLock { $0 = State(handler: handler) }
    }
    static var count: Int { state.withLock { $0.requests } }
    static var stoppedCount: Int { state.withLock { $0.stopped } }
    static func verify() throws {
        let errors = state.withLock { $0.errors }
        try expect(errors.isEmpty, errors.joined(separator: "; "))
    }
    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockProtocol.self]
        return configuration
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let handler = Self.state.withLock { state in
            state.requests += 1
            return state.handler
        }
        do {
            guard let handler else { throw Failure(description: "Unexpected request") }
            // Assert on every dispatched request, including discovery pagination and cloud ASR,
            // not merely on a request builder or URLSession configuration.
            try expect(request.value(forHTTPHeaderField: "User-Agent") == expectedUserAgent, "missing or incorrect Talkless User-Agent")
            switch try handler(request) {
            case .hang: return
            case .fail(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
            case .redirect(let location):
                let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
                var target = request
                target.url = URL(string: location)!
                client?.urlProtocol(self, wasRedirectedTo: target, redirectResponse: response)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            case .reply(let status, let text):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(text.utf8))
                client?.urlProtocolDidFinishLoading(self)
            case .bytes(let data):
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            Self.state.withLock { $0.errors.append(String(describing: error)) }
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() { Self.state.withLock { $0.stopped += 1 } }
}

@main
private struct APITests {
    static let chatReply = #"{"choices":[{"finish_reason":"stop","message":{"role":"assistant","content":"Polished text","reasoning_content":"DO NOT INSERT"}}]}"#
    static func config(_ apiProtocol: LLMProtocol = .chatCompletions, base: String = "https://unit.test/v1", model: String = "selected-model") -> LLMClient.Config {
        LLMClient.Config(baseURL: base, apiKey: "test-only-key", model: model, apiProtocol: apiProtocol)
    }
    static func complete(_ config: LLMClient.Config, timeout: TimeInterval = 2) async throws -> String {
        try await LLMClient.complete(system: "Keep meaning.", user: "Dictated text.", config: config, timeout: timeout, sessionConfiguration: MockProtocol.configuration)
    }
    static func models(_ config: LLMClient.Config) async throws -> [RemoteModel] {
        try await LLMClient.fetchModels(config: config, timeout: 2, sessionConfiguration: MockProtocol.configuration)
    }
    static func main() async throws {
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        localization.interfaceLanguage = .english
        defer { withExtendedLifetime(localization) {} }
        let tests: [(String, () async throws -> Void)] = [
            ("bundleVersionUserAgentAndSafeFallback", testUserAgent),
            ("cloudTranscriptionHeadersAndPayload", testCloudTranscription),
            ("legacyConfigAndURLNormalization", testURLs),
            ("maliciousURLsAndValidation", testValidation),
            ("chatCompletionsHeadersAndPayload", testChat),
            ("openRouterFreePresetAndExplicitDiscovery", testOpenRouter),
            ("responsesHeadersAndPayload", testResponses),
            ("anthropicMessagesHeadersAndTextOnly", testAnthropic),
            ("geminiNativeHeadersPayloadAndThoughtFiltering", testGemini),
            ("explicitAuthAndLocalhostNoKey", testAuth),
            ("thinkingDefaultsAndKnownDisabledOnly", testThinking),
            ("finishReasonsRefusalsToolsAndEmpty", testFailures),
            ("finalTextPreservesLiteralMarkupAndCode", testClean),
            ("httpErrorsAreSanitizedAndNeverRetried", testStatuses),
            ("modelDiscoveryChatAndResponses", testOpenAIModels),
            ("customRootModelDiscoveryDoesNotInjectVersion", testRootModels),
            ("anthropicModelPagination", testAnthropicModels),
            ("geminiModelPaginationAndFiltering", testGeminiModels),
            ("paginationCursorValidationAndBound", testPaginationBound),
            ("cancellationStopsRequest", testCancellation),
            ("timeoutIsBounded", testTimeout),
            ("responseSizeIsBounded", testResponseSize),
            ("redirectPolicyPreventsKeyLeak", testRedirectPolicy),
            ("actualCrossOriginRedirectRejected", testRedirect),
        ]
        for (name, test) in tests {
            try await test()
            try MockProtocol.verify()
            print("PASS \(name)")
        }
        print("\(tests.count) API tests passed; all HTTP intercepted by URLProtocol; no API keys or paid requests used.")
    }

    static func testUserAgent() async throws {
        for version in ["2026.1030.52139", "1.2.3", "0.1.0"] {
            try expect(LLMAPITransport.userAgent(version: version) == "Talkless/\(version)", "valid bundle version changed")
        }
        let invalidVersions: [String?] = [nil, "", " ", ".", "1..0", ".1", "1.", "not-a-version",
            "1.0\r\nX-Injected: true", "1.0\n", "1.0\t", "1.0\u{0}", "1.0/extra", " 1.0", "１.０", String(repeating: "1", count: 65)]
        for version in invalidVersions {
            try expect(LLMAPITransport.userAgent(version: version) == "Talkless/0.1.0", "invalid metadata did not fall back safely")
        }
        try expect(LLMAPITransport.userAgent() == expectedUserAgent, "User-Agent did not use the actual bundle version")
    }

    static func testCloudTranscription() async throws {
        MockProtocol.install { request in
            try expect(request.httpMethod == "POST", "cloud transcription not POST")
            try expect(request.url?.absoluteString == "https://unit.test/proxy/v1/audio/transcriptions", "cloud endpoint changed")
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-asr-key", "cloud bearer changed")
            try expect(request.timeoutInterval == 60, "cloud timeout changed")
            guard let contentType = request.value(forHTTPHeaderField: "Content-Type"),
                  contentType.hasPrefix("multipart/form-data; boundary=talkless-") else {
                throw Failure(description: "cloud multipart content type changed")
            }
            let body = String(decoding: try requestBody(request), as: UTF8.self)
            for (name, value) in [("model", "selected-asr-model"), ("response_format", "json"), ("language", "zh"), ("prompt", "Talkless")] {
                try expect(body.contains("name=\"\(name)\"\r\n\r\n\(value)\r\n"), "cloud \(name) field changed")
            }
            try expect(body.contains("filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF"), "cloud WAV body missing")
            return .reply(200, #"{"text":"  Recognized text\n"}"#)
        }
        let session = URLSession(configuration: MockProtocol.configuration)
        defer { session.invalidateAndCancel() }
        let value = CloudTranscriptionSession.Config(baseURL: "https://unit.test/proxy/v1", apiKey: "test-only-asr-key",
            model: "selected-asr-model", language: "zh", prompt: "Talkless")
        let result = try await CloudTranscriptionSession.transcribe(samples: [0, 0.25, -0.25], config: value, session: session)
        try expect(result == "Recognized text" && MockProtocol.count == 1, "cloud transcript or request count changed")
    }

    static func testURLs() async throws {
        let legacy = LLMClient.Config(baseURL: "https://unit.test/v1", apiKey: "test-only-key", model: "selected-model")
        try expect(legacy.apiProtocol == .chatCompletions && legacy.maxOutputTokens == 4096 && legacy.thinking == .modelDefault, "legacy initializer changed")
        let cases: [(String, LLMProtocol, String)] = [
            ("https://api.openai.com", .responses, "https://api.openai.com/responses"),
            ("https://api.openai.com/v1", .responses, "https://api.openai.com/v1/responses"),
            ("https://unit.test/responses", .responses, "https://unit.test/responses"),
            ("https://unit.test/responses/", .responses, "https://unit.test/responses"),
            ("https://unit.test", .chatCompletions, "https://unit.test/chat/completions"),
            ("http://localhost:11434", .chatCompletions, "http://localhost:11434/chat/completions"),
            (" https://api.openai.com/v1/\n", .chatCompletions, "https://api.openai.com/v1/chat/completions"),
            ("https://api.openai.com/v1/responses/", .responses, "https://api.openai.com/v1/responses"),
            ("https://api.deepseek.com", .chatCompletions, "https://api.deepseek.com/chat/completions"),
            ("https://api.anthropic.com", .anthropicMessages, "https://api.anthropic.com/messages"),
            ("https://api.anthropic.com/v1", .anthropicMessages, "https://api.anthropic.com/v1/messages"),
            ("https://api.anthropic.com/v1/messages", .anthropicMessages, "https://api.anthropic.com/v1/messages"),
            ("https://unit.test/proxy/company/v1", .responses, "https://unit.test/proxy/company/v1/responses"),
            ("https://generativelanguage.googleapis.com", .geminiGenerateContent, "https://generativelanguage.googleapis.com/models/chosen:generateContent"),
            ("https://generativelanguage.googleapis.com/v1beta", .geminiGenerateContent, "https://generativelanguage.googleapis.com/v1beta/models/chosen:generateContent"),
            ("https://unit.test/proxy/v1beta/models/old:generateContent", .geminiGenerateContent, "https://unit.test/proxy/v1beta/models/chosen:generateContent"),
            ("http://localhost:11434/v1", .chatCompletions, "http://localhost:11434/v1/chat/completions"),
            ("http://[::1]:11434/v1", .responses, "http://[::1]:11434/v1/responses"),
        ]
        for (base, proto, expected) in cases {
            let url = try LLMClient.endpointURL(baseURL: base, apiProtocol: proto, model: "models/chosen")
            try expect(url.absoluteString == expected, "URL \(url) != \(expected)")
        }
    }

    static func testValidation() async throws {
        for base in ["", "not-a-url", "file:///tmp/key", "http://example.com", "http://localhost.evil.test", "http://127.0.0.1.evil.test", "https://name:pass@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#fragment", "https://example.com:0", "https://example.com:65536", "https://example.com/a/../v1", "https://example.com/a/%2e%2e/v1", "https://example.com/a%2fv1", "https://example.com/a%5cv1", "https://example.com/%252e%252e/v1", "https://example.com/a//v1", "https://example.com/a\\v1", "https://example.com/\r\nv1", "https://example.com/v1/messages"] {
            try expectError(.invalidURL) { _ = try LLMClient.makeRequest(system: "", user: "", config: config(base: base)) }
        }
        var value = config()
        value.apiKey = ""
        try expectError(.missingKey) { _ = try LLMClient.makeRequest(system: "", user: "", config: value) }
        value.apiKey = "key\r\nheader"
        try expectError(.invalidKey) { _ = try LLMClient.makeRequest(system: "", user: "", config: value) }
        value = config(model: " ")
        try expectError(.missingModel) { _ = try LLMClient.makeRequest(system: "", user: "", config: value) }
        for model in ["../evil", "foo/bar", "foo?key=x", "foo#bar", "foo%2fbar", ".."] {
            try expectError(.invalidModel) { _ = try LLMClient.makeRequest(system: "", user: "", config: config(.geminiGenerateContent, model: model)) }
        }
        for timeout in [0, -1, Double.infinity, Double.nan, 121] {
            try expectError(.invalidTimeout) { _ = try LLMClient.makeRequest(system: "", user: "", config: config(), timeout: timeout) }
        }
        value = config(.anthropicMessages)
        value.maxOutputTokens = nil
        try expectError(.invalidTokenLimit) { _ = try LLMClient.makeRequest(system: "", user: "", config: value) }
        value = config(.responses)
        value.maxOutputTokens = 15
        try expectError(.invalidTokenLimit) { _ = try LLMClient.makeRequest(system: "", user: "", config: value) }
    }

    static func testChat() async throws {
        MockProtocol.install { request in
            try expect(request.httpMethod == "POST", "not POST")
            try expect(request.url?.path == "/v1/chat/completions", "bad endpoint")
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key", "bad bearer header")
            try expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "bad content type")
            let body = try json(request)
            try expect(body["model"] as? String == "selected-model", "model changed")
            let messages = body["messages"] as? [[String: String]]
            try expect(messages == [["role": "system", "content": "Keep meaning."], ["role": "user", "content": "Dictated text."]], "messages changed")
            try expect(body["max_tokens"] as? Int == 4096, "generic token parameter changed")
            try expect(body["temperature"] == nil && body["thinking"] == nil && body["reasoning_effort"] == nil, "unexpected optional fields")
            try expect(body["stream"] as? Bool == false, "stream enabled")
            return .reply(200, chatReply)
        }
        let result = try await complete(config())
        try expect(result == "Polished text", "reasoning leaked")
        let native = try LLMClient.makeRequest(system: "", user: "", config: config(base: "https://api.openai.com/v1"))
        let nativeBody = try json(native)
        try expect(nativeBody["max_completion_tokens"] as? Int == 4096, "OpenAI modern cap missing")
    }

    static func testOpenRouter() async throws {
        let preset = PolishProviderState(provider: .openRouter)
        let value = LLMClient.Config(baseURL: preset.baseURL, apiKey: "test-only-router-key", model: preset.model,
                                     apiProtocol: preset.apiProtocol, authMode: preset.authMode)
        MockProtocol.install { request in
            try expect(request.httpMethod == "POST", "OpenRouter completion is not POST")
            try expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions", "OpenRouter endpoint changed")
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-router-key", "OpenRouter bearer missing")
            let body = try json(request)
            try expect(body["model"] as? String == "openrouter/free", "OpenRouter free route was replaced")
            try expect(body["models"] == nil && body["route"] == nil, "OpenRouter request contains fallback routing")
            try expect(body["max_tokens"] as? Int == 4096 && body["stream"] as? Bool == false, "OpenRouter chat options changed")
            try expect(body["thinking"] == nil && body["reasoning_effort"] == nil, "OpenRouter has guessed model-specific flags")
            return .reply(200, chatReply)
        }
        let result = try await complete(value)
        try expect(result == "Polished text" && MockProtocol.count == 1, "OpenRouter completion failed or made extra requests")
        try MockProtocol.verify()

        MockProtocol.install { request in
            try expect(request.httpMethod == "GET" && request.httpBody == nil, "OpenRouter discovery generated text")
            try expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/models", "OpenRouter discovery endpoint changed")
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-router-key", "OpenRouter discovery bearer missing")
            return .reply(200, #"{"data":[{"id":"openrouter/free","pricing":{"prompt":"0","completion":"0"}},{"id":"synthetic-provider/paid-choice","pricing":{"prompt":"0.001","completion":"0.002"}}]}"#)
        }
        let discovered = try await models(value)
        try expect(discovered.map(\.id) == ["openrouter/free", "synthetic-provider/paid-choice"],
                   "explicit discovery must allow paid models without silently selecting them")
        try expect(value.model == "openrouter/free" && MockProtocol.count == 1, "discovery changed the preset or made extra requests")
        try MockProtocol.verify()
        var explicitChoice = value
        explicitChoice.model = "synthetic-provider/paid-choice"
        let explicitRequest = try LLMClient.makeRequest(system: "", user: "", config: explicitChoice)
        let explicitBody = try json(explicitRequest)
        try expect(explicitBody["model"] as? String == explicitChoice.model, "explicitly selected OpenRouter model was replaced")

        for status in [402, 429, 503] {
            MockProtocol.install { request in
                let body = try json(request)
                try expect(body["model"] as? String == "openrouter/free", "OpenRouter fell back to another model")
                return .reply(status, "Free route unavailable")
            }
            try await expectAsyncError(.httpStatus(status)) { _ = try await complete(value) }
            try expect(MockProtocol.count == 1, "OpenRouter failure triggered retries or paid fallback")
            try MockProtocol.verify()
        }
    }

    static func testResponses() async throws {
        MockProtocol.install { request in
            try expect(request.url?.path == "/v1/responses", "bad Responses endpoint")
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key", "bad auth")
            let body = try json(request)
            try expect(body["instructions"] as? String == "Keep meaning." && body["input"] as? String == "Dictated text.", "bad Responses payload")
            try expect(body["store"] as? Bool == false && body["stream"] as? Bool == false, "storage/stream enabled")
            try expect(body["max_output_tokens"] as? Int == 4096 && body["reasoning"] == nil, "bad Responses config")
            return .reply(200, #"{"status":"completed","output":[{"type":"reasoning","summary":[{"text":"secret"}]},{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"One"},{"type":"output_text","text":"Two"}]}]}"#)
        }
        let result = try await complete(config(.responses))
        try expect(result == "One\nTwo", "wrong Responses text")
    }

    static func testAnthropic() async throws {
        MockProtocol.install { request in
            try expect(request.url?.path == "/v1/messages", "bad Messages endpoint")
            try expect(request.value(forHTTPHeaderField: "x-api-key") == "test-only-key", "missing Anthropic key")
            try expect(request.value(forHTTPHeaderField: "Authorization") == nil, "unexpected bearer")
            try expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "missing version")
            let body = try json(request)
            try expect(body["system"] as? String == "Keep meaning.", "system not top level")
            try expect(body["messages"] as? [[String: String]] == [["role": "user", "content": "Dictated text."]], "bad Messages roles")
            try expect(body["max_tokens"] as? Int == 4096 && body["thinking"] == nil && body["temperature"] == nil, "unexpected model-specific defaults")
            return .reply(200, #"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"secret"},{"type":"redacted_thinking","data":"secret"},{"type":"text","text":"Final text"}]}"#)
        }
        let result = try await complete(config(.anthropicMessages))
        try expect(result == "Final text", "Anthropic reasoning leaked")
    }

    static func testGemini() async throws {
        MockProtocol.install { request in
            try expect(request.url?.path == "/v1beta/models/selected-model:generateContent", "bad Gemini endpoint")
            try expect(request.url?.query == nil, "key in URL")
            try expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-only-key", "missing Google key")
            let body = try json(request)
            let system = body["systemInstruction"] as? [String: [[String: String]]]
            try expect(system?["parts"] == [["text": "Keep meaning."]], "bad Gemini system")
            let contents = body["contents"] as? [[String: Any]]
            try expect(contents?.first?["role"] as? String == "user", "bad Gemini role")
            try expect(contents?.first?["parts"] as? [[String: String]] == [["text": "Dictated text."]], "bad Gemini text")
            let generation = body["generationConfig"] as? [String: Any]
            try expect(generation?["maxOutputTokens"] as? Int == 4096 && generation?["thinkingConfig"] == nil, "bad Gemini config")
            try expect(body["model"] == nil && body["stream"] == nil, "generic fields leaked into Gemini")
            return .reply(200, #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"thought":true,"text":"secret"},{"text":"Final"}]}}]}"#)
        }
        let result = try await complete(config(.geminiGenerateContent, base: "https://unit.test/v1beta"))
        try expect(result == "Final", "Gemini thoughts leaked")
    }

    static func testAuth() async throws {
        for proto in LLMProtocol.allCases {
            var value = config(proto)
            value.authMode = .bearer
            let bearer = try LLMClient.makeRequest(system: "", user: "", config: value)
            try expect(bearer.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key", "explicit bearer ignored")
            value.authMode = .apiKey
            let apiKey = try LLMClient.makeRequest(system: "", user: "", config: value)
            try expect(apiKey.value(forHTTPHeaderField: proto == .geminiGenerateContent ? "x-goog-api-key" : "x-api-key") == "test-only-key", "explicit key ignored")
            value.baseURL = "http://localhost:9999/v1"
            value.apiKey = ""
            let local = try LLMClient.makeRequest(system: "", user: "", config: value)
            try expect(local.value(forHTTPHeaderField: "Authorization") == nil && local.value(forHTTPHeaderField: "x-api-key") == nil, "keyless localhost rejected")
        }
    }

    static func testThinking() async throws {
        for proto in LLMProtocol.allCases {
            var value = config(proto, model: "claude-opus-5-5")
            let body = try json(LLMClient.makeRequest(system: "", user: "", config: value))
            try expect(body["thinking"] == nil && body["reasoning"] == nil && body["reasoning_effort"] == nil, "thinking enabled by default")
            value.thinking = .disabled
            try expectError(.unsupportedThinking) { _ = try LLMClient.makeRequest(system: "", user: "", config: value) }
        }
        for (base, proto, model, field) in [
            ("https://api.openai.com/v1", LLMProtocol.responses, "gpt-5.5", "reasoning"),
            ("https://api.deepseek.com", .chatCompletions, "deepseek-v4-pro", "thinking")
        ] {
            var value = config(proto, base: base, model: model)
            try expect(LLMClient.supportsDisablingThinking(config: value), "known documented capability missing")
            value.thinking = .disabled
            let body = try json(LLMClient.makeRequest(system: "", user: "", config: value))
            try expect(body[field] != nil, "explicit disable parameter missing")
            value.baseURL = base + "/proxy/v1"
            try expect(!LLMClient.supportsDisablingThinking(config: value), "proxy capability guessed")
        }
        try expect(!LLMClient.supportsDisablingThinking(config: config(.responses, base: "https://api.openai.com/v1", model: "always-on-or-unknown")), "unknown model inferred")
        try expect(!LLMClient.supportsDisablingThinking(config: config(.responses, base: "https://api.openai.com", model: "gpt-5.5")), "root endpoint silently treated as versioned API")
        var anthropic = config(.anthropicMessages, base: "https://api.anthropic.com/v1", model: "claude-opus-5-5")
        try expect(!LLMClient.supportsDisablingThinking(config: anthropic), "Anthropic capability guessed from generic example")
        let anthropicBody = try json(LLMClient.makeRequest(system: "", user: "", config: anthropic))
        try expect(anthropicBody["thinking"] == nil, "Anthropic default forced unsupported thinking parameter")
        anthropic.thinking = .disabled
        try expectError(.unsupportedThinking) { _ = try LLMClient.makeRequest(system: "", user: "", config: anthropic) }
    }

    static func testFailures() async throws {
        let cases: [(LLMProtocol, String, LLMClient.ClientError)] = [
            (.chatCompletions, #"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}"#, .incomplete),
            (.chatCompletions, #"{"choices":[{"message":{"content":"partial"}}]}"#, .incomplete),
            (.chatCompletions, #"{"choices":[{"finish_reason":"stop","message":{"refusal":"no","content":"not final"}}]}"#, .refusal),
            (.chatCompletions, #"{"choices":[{"finish_reason":"tool_calls","message":{"content":"not final"}}]}"#, .unsupportedToolCall),
            (.chatCompletions, #"{"choices":[{"finish_reason":"stop","message":{"content":null,"reasoning_content":"secret"}}]}"#, .emptyResponse),
            (.responses, #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"message","content":[{"type":"output_text","text":"partial"}]}]}"#, .incomplete),
            (.responses, #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"no"}]}]}"#, .refusal),
            (.responses, #"{"status":"completed","output":[{"type":"function_call","name":"tool"}]}"#, .unsupportedToolCall),
            (.responses, #"{"status":"completed","output":[{"type":"reasoning","summary":[]}]}"#, .emptyResponse),
            (.anthropicMessages, #"{"stop_reason":"max_tokens","content":[{"type":"text","text":"partial"}]}"#, .incomplete),
            (.anthropicMessages, #"{"stop_reason":"refusal","content":[{"type":"text","text":"no"}]}"#, .refusal),
            (.anthropicMessages, #"{"stop_reason":"end_turn","content":[{"type":"tool_use","text":"not final"}]}"#, .unsupportedToolCall),
            (.anthropicMessages, #"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"secret"}]}"#, .emptyResponse),
            (.geminiGenerateContent, #"{"candidates":[{"finishReason":"MAX_TOKENS","content":{"parts":[{"text":"partial"}]}}]}"#, .incomplete),
            (.geminiGenerateContent, #"{"promptFeedback":{"blockReason":"SAFETY"}}"#, .refusal),
            (.geminiGenerateContent, #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"functionCall":{"name":"tool"}}]}}]}"#, .unsupportedToolCall),
            (.geminiGenerateContent, #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"thought":true,"text":"secret"}]}}]}"#, .emptyResponse),
            (.responses, "not json with SECRET", .invalidResponse),
        ]
        for (proto, reply, expected) in cases {
            MockProtocol.install { _ in .reply(200, reply) }
            try await expectAsyncError(expected) { _ = try await complete(config(proto)) }
            try expect(MockProtocol.count == 1, "unexpected retry on malformed or incomplete response")
        }
    }

    static func testClean() async throws {
        for literal in ["<analysis>keep this literal</analysis>", "The tag `<analysis>` is not closed.",
                        "```swift\nlet value = true\n```", "<think>literal markup</think>", "\"Keep quotes\""] {
            try expect(LLMClient.clean(literal) == literal, "Final text content was altered")
        }
        try expect(LLMClient.clean("  Final\n") == "Final", "Outer whitespace retained")
    }

    static func testStatuses() async throws {
        for status in [401, 403, 429, 500, 503] {
            MockProtocol.install { _ in .reply(status, "SECRET key and dictated text") }
            try await expectAsyncError(.httpStatus(status)) { _ = try await complete(config()) }
            try expect(MockProtocol.count == 1, "status retried")
            try expect(!LLMClient.ClientError.httpStatus(status).localizedDescription.contains("SECRET"), "secret in error")
        }
        MockProtocol.install { _ in .fail(.cannotConnectToHost) }
        try await expectAsyncError(.network) { _ = try await complete(config()) }
    }

    static func testOpenAIModels() async throws {
        for proto in [LLMProtocol.chatCompletions, .responses] {
            MockProtocol.install { request in
                try expect(request.httpMethod == "GET" && request.httpBody == nil, "discovery generated text")
                try expect(request.url?.path == "/proxy/v1/models", "bad discovery URL")
                try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-only-key", "discovery auth missing")
                return .reply(200, #"{"data":[{"id":"user-can-select"},{"id":"second","display_name":"Second"},{"id":"second"}]}"#)
            }
            let suffix = proto == .responses ? "responses" : "chat/completions"
            let result = try await models(config(proto, base: "https://unit.test/proxy/v1/" + suffix, model: ""))
            try expect(result == [RemoteModel(id: "user-can-select"), RemoteModel(id: "second", displayName: "Second")], "models not parsed/deduplicated")
        }
    }

    static func testRootModels() async throws {
        let cases: [(LLMProtocol, String)] = [
            (.chatCompletions, "https://unit.test"),
            (.chatCompletions, "https://unit.test/chat/completions"),
            (.responses, "https://unit.test"),
            (.responses, "https://unit.test/responses"),
            (.responses, "https://unit.test/models"),
            (.anthropicMessages, "https://unit.test"),
            (.anthropicMessages, "https://unit.test/messages"),
            (.geminiGenerateContent, "https://unit.test"),
            (.geminiGenerateContent, "https://unit.test/models/selected-model:generateContent"),
        ]
        for (proto, base) in cases {
            MockProtocol.install { request in
                try expect(request.httpMethod == "GET" && request.url?.path == "/models", "root discovery injected an API version")
                switch proto {
                case .anthropicMessages: return .reply(200, #"{"data":[{"id":"chosen"}],"has_more":false}"#)
                case .geminiGenerateContent: return .reply(200, #"{"models":[{"name":"models/chosen","supportedGenerationMethods":["generateContent"]}]}"#)
                case .chatCompletions, .responses: return .reply(200, #"{"data":[{"id":"chosen"}]}"#)
                }
            }
            let result = try await models(config(proto, base: base, model: ""))
            try expect(result.map(\.id) == ["chosen"] && MockProtocol.count == 1, "root discovery failed")
            try MockProtocol.verify()
        }
        MockProtocol.install { request in
            try expect(request.url?.path == "/models" && request.value(forHTTPHeaderField: "Authorization") == nil, "keyless root discovery changed")
            return .reply(200, #"{"data":[]}"#)
        }
        var local = config(base: "http://localhost:11434")
        local.apiKey = ""
        _ = try await models(local)
    }

    static func testAnthropicModels() async throws {
        MockProtocol.install { request in
            try expect(request.url?.path == "/v1/models" && request.httpMethod == "GET", "bad Anthropic model URL")
            try expect(request.value(forHTTPHeaderField: "x-api-key") == "test-only-key" && request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "discovery headers missing")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            if let after = query?.first(where: { $0.name == "after_id" })?.value {
                try expect(after == "cursor&with=symbols", "cursor encoded unsafely")
                return .reply(200, #"{"data":[{"id":"model-b","display_name":"Model B"}],"has_more":false,"last_id":"model-b"}"#)
            }
            return .reply(200, #"{"data":[{"id":"model-a","display_name":"Model A"}],"has_more":true,"last_id":"cursor&with=symbols"}"#)
        }
        let result = try await models(config(.anthropicMessages, base: "https://unit.test/v1/messages", model: ""))
        try expect(result.map(\.id) == ["model-a", "model-b"] && MockProtocol.count == 2, "pagination failed")
    }

    static func testGeminiModels() async throws {
        MockProtocol.install { request in
            try expect(request.url?.path == "/v1beta/models", "bad Gemini model URL")
            try expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-only-key", "Google discovery auth missing")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            if let token = query?.first(where: { $0.name == "pageToken" })?.value {
                try expect(token == "opaque+/=&token", "pageToken corrupted")
                return .reply(200, #"{"models":[{"name":"models/text-b","supportedGenerationMethods":["generateContent"]}]}"#)
            }
            return .reply(200, #"{"models":[{"name":"models/text-a","displayName":"Text A","supportedGenerationMethods":["generateContent","countTokens"]},{"name":"models/embed","supportedGenerationMethods":["embedContent"]}],"nextPageToken":"opaque+/=&token"}"#)
        }
        let result = try await models(config(.geminiGenerateContent, base: "https://unit.test/v1beta", model: ""))
        try expect(result == [RemoteModel(id: "text-a", displayName: "Text A"), RemoteModel(id: "text-b")], "Gemini filtering/name normalization failed")
        try expect(MockProtocol.count == 2, "Gemini paging missing")
    }

    static func testPaginationBound() async throws {
        MockProtocol.install { _ in .reply(200, #"{"data":[{"id":"a"}],"has_more":true,"last_id":"same"}"#) }
        try await expectAsyncError(.paginationLimit) { _ = try await models(config(.anthropicMessages)) }
        try expect(MockProtocol.count == 2, "duplicate cursor not stopped")
        MockProtocol.install { _ in .reply(200, #"{"data":[{"id":"a"}],"has_more":true}"#) }
        try await expectAsyncError(.paginationLimit) { _ = try await models(config(.anthropicMessages)) }
        MockProtocol.install { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let token = query?.first(where: { $0.name == "pageToken" })?.value.flatMap(Int.init) ?? 0
            return .reply(200, "{\"models\":[],\"nextPageToken\":\"\(token + 1)\"}")
        }
        try await expectAsyncError(.paginationLimit) { _ = try await models(config(.geminiGenerateContent)) }
        try expect(MockProtocol.count == LLMClient.maximumModelPages, "page cap not enforced")
    }

    static func testCancellation() async throws {
        MockProtocol.install { _ in .hang }
        let task = Task { try await complete(config()) }
        try await Task.sleep(for: .milliseconds(40))
        task.cancel()
        do { _ = try await task.value; throw Failure(description: "cancel returned text") }
        catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(40)) // URLSession invalidation delivers stopLoading asynchronously.
        try expect(MockProtocol.count == 1 && MockProtocol.stoppedCount > 0, "cancel didn't stop task")
        MockProtocol.install { _ in .hang }
        let discovery = Task { try await models(config()) }
        try await Task.sleep(for: .milliseconds(40))
        discovery.cancel()
        do { _ = try await discovery.value; throw Failure(description: "cancel returned models") }
        catch is CancellationError {}
    }

    static func testTimeout() async throws {
        MockProtocol.install { _ in .hang }
        let start = ProcessInfo.processInfo.systemUptime
        try await expectAsyncError(.timedOut) { _ = try await complete(config(), timeout: 0.05) }
        try expect(ProcessInfo.processInfo.systemUptime - start < 1, "timeout unbounded")
        try expect(MockProtocol.count == 1, "timeout retried")
    }

    static func testResponseSize() async throws {
        MockProtocol.install { _ in .bytes(Data(repeating: 32, count: LLMClient.maximumResponseBytes + 1)) }
        try await expectAsyncError(.invalidResponse) { _ = try await complete(config()) }
    }

    static func testRedirectPolicy() async throws {
        let original = try LLMClient.makeRequest(system: "secret text", user: "private", config: config())
        for target in ["https://evil.test/v1/chat/completions", "http://unit.test/v1/chat/completions", "https://unit.test:444/v1/chat/completions", "https://user:pass@unit.test/v1/chat/completions"] {
            var proposed = original
            proposed.url = URL(string: target)!
            let response = HTTPURLResponse(url: original.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!
            try expect(LLMAPITransport.SameOriginRedirects.permittedRequest(original: original, response: response, proposed: proposed) == nil, "unsafe redirect permitted")
        }
        var proposed = original
        proposed.url = URL(string: "https://unit.test:443/canonical/v1/chat/completions")!
        let preserve = HTTPURLResponse(url: original.url!, statusCode: 307, httpVersion: nil, headerFields: nil)!
        try expect(LLMAPITransport.SameOriginRedirects.permittedRequest(original: original, response: preserve, proposed: proposed) != nil, "same-origin redirect refused")
        let rewrite = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!
        try expect(LLMAPITransport.SameOriginRedirects.permittedRequest(original: original, response: rewrite, proposed: proposed) == nil, "method-changing POST redirect permitted")
    }

    static func testRedirect() async throws {
        MockProtocol.install { _ in .redirect("https://evil.test/collect") }
        try await expectAsyncError(.redirect) { _ = try await complete(config()) }
        try expect(MockProtocol.count == 1, "cross-origin request leaked key")
    }
}
