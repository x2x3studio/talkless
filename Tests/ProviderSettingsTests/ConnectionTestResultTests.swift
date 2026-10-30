import Foundation

func testConnectionTestResult() throws -> Int {
    var assertions = 0
    func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        assertions += 1
        guard condition() else { fatalError("FAIL: \(description)") }
    }
    let config = LLMClient.Config(
        baseURL: "https://synthetic-provider.invalid/v1",
        apiKey: "synthetic-private-key-123",
        model: " synthetic-model ",
        apiProtocol: .chatCompletions
    )
    let receipt = ConnectionTestResult(provider: .custom, config: config, duration: 1.234, result: .success("OK."))
    check(receipt.isSuccess && receipt.output == "OK.", "successful receipt preserves actual response")
    check(receipt.model == "synthetic-model", "receipt shows the trimmed model sent by the client")
    check(receipt.duration == 1.234 && receipt.durationText == "1.23 s", "receipt preserves elapsed duration")
    check(receipt.diagnostics.contains("System input:\n\(ConnectionTestResult.systemInput)"), "copy includes exact system input")
    check(receipt.diagnostics.contains("Test input:\n\(ConnectionTestResult.userInput)"), "copy includes exact user input")
    check(receipt.diagnostics.contains("Response:\nOK."), "copy includes actual response")
    check(receipt.diagnostics.contains("Model: synthetic-model"), "copy includes tested model")
    check(receipt.diagnostics.contains("Duration: 1.23 s"), "copy includes duration")
    check(!receipt.diagnostics.contains(config.baseURL) && !receipt.diagnostics.contains(config.apiKey), "receipt excludes URL and credentials")

    let failed = ConnectionTestResult(provider: .openAI, config: config, duration: 0.1, result: .failure(LLMClient.ClientError.httpStatus(401)))
    check(!failed.isSuccess && failed.output.contains("401"), "typed HTTP failure retains actionable status code")
    check(failed.diagnostics.contains("Error:\n") && !failed.diagnostics.contains("Response:\n"), "failure copy labels the error")
    let unsafeError = NSError(domain: "unsafe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Authorization: Bearer \(config.apiKey) at \(config.baseURL)?token=leak"])
    let unknown = ConnectionTestResult(provider: .custom, config: config, duration: 0, result: .failure(unsafeError))
    check(!unknown.output.contains("leak") && !unknown.diagnostics.contains(config.apiKey), "unknown errors cannot echo private details")
    check(unknown.output == "The connection test failed. Check your provider settings and try again.", "unknown errors fail closed with useful guidance")

    let hidden = "Content hidden because it may contain credentials."
    let echoes = [
        "The key was \(config.apiKey)",
        "\(config.apiKey.uppercased())",
        Data(config.apiKey.utf8).base64EncodedString(),
        config.apiKey.replacingOccurrences(of: "-", with: "%2D"),
        "\"" + config.apiKey.replacingOccurrences(of: "-", with: "\\u002d") + "\"",
        "Authorization: Bearer a-different-provider-secret",
        "{\"x-api-key\": \"a-different-provider-secret\"}",
        "x-goog-api-key: another-secret",
        "access_token=another-secret",
        "{\"password\": \"another-secret\"}",
        "{\"secret\": \"another-secret\"}",
        "sk-unrelated-provider-credential",
        "AIzaUnrelatedProviderCredential",
        "https://user:other-secret@example.invalid/v1",
        "https://example.invalid/v1?password=other-secret",
        "https://example.invalid/#other-secret",
        String(repeating: "safe ", count: 2_000) + config.apiKey,
    ]
    for echo in echoes {
        let redacted = ConnectionTestResult(provider: .custom, config: config, duration: 1, result: .success(echo))
        check(redacted.output == hidden, "credential-shaped responses are withheld before display or truncation")
        check(!redacted.diagnostics.contains(config.apiKey), "clipboard uses sanitized output only")
    }

    // A valid private endpoint is also private, even without query or userinfo.
    var privateConfig = config
    privateConfig.baseURL = "https://private.company.example/customer-account/v1"
    privateConfig.apiKey = "proxy-credential-123"
    let privateEchoes = [
        "Connected to \(privateConfig.baseURL)",
        Data(privateConfig.baseURL.utf8).base64EncodedString(),
        "Connected to https://another-private.example/tenant/v1",
        "Here is the result: {\"value\":\"proxy\\u002dcredential\\u002d123\"}",
        "```json\n{\"value\":\"proxy\\u002dcredential\\u002d123\"}\n```",
        "```json\n{\"value\":\"proxy\\\\u002dcredential\\\\u002d123\"}\n```",
        "Echo: proxy\\x2dcredential\\x2d123",
        "Echo: proxy%5Cu002dcredential%5Cu002d123",
        "```json\n{\"url\":\"https:\\/\\/private.company.example/customer-account/v1\"}\n```",
    ]
    for echo in privateEchoes {
        let redacted = ConnectionTestResult(provider: .custom, config: privateConfig, duration: 1, result: .success(echo))
        check(redacted.output == hidden, "endpoint and embedded escaped-secret echoes fail closed")
        check(redacted.diagnostics.hasSuffix("Response:\n\(hidden)"), "copy contains only the privacy placeholder, not escaped secret or URL")
        check(!redacted.diagnostics.contains("private.company") && !redacted.diagnostics.contains("proxy"),
              "private endpoint and credential fragments do not enter copied diagnostics")
    }

    var urlConfig = config
    urlConfig.baseURL = "https://synthetic-user:synthetic%2Fpassword@example.invalid/v1?token=query%2Fsecret&other=other-secret#fragment-secret"
    for secret in ["synthetic-user", "synthetic/password", "query/secret", "other-secret", "fragment-secret", "query%2Fsecret", "query%252Fsecret"] {
        let redacted = ConnectionTestResult(provider: .custom, config: urlConfig, duration: 1, result: .success("Echo: \(secret)"))
        check(redacted.output == hidden, "userinfo, query, and fragment secrets are hidden even for rejected URLs")
    }
    var unsafeModel = config
    unsafeModel.model = config.apiKey
    let modelReceipt = ConnectionTestResult(provider: .custom, config: unsafeModel, duration: 1, result: .success("OK"))
    check(modelReceipt.model == hidden && !modelReceipt.diagnostics.contains(config.apiKey), "model metadata cannot expose a pasted credential")
    var keyless = config
    keyless.apiKey = ""
    let keylessReceipt = ConnectionTestResult(provider: .custom, config: keyless, duration: 1, result: .success("OK"))
    check(keylessReceipt.output == "OK", "empty localhost key does not redact all output")

    let multiline = "First line\nSecond line"
    check(ConnectionTestResult(provider: .custom, config: config, duration: 1, result: .success(multiline)).output == multiline,
          "normal multiline output is preserved")
    let long = ConnectionTestResult(provider: .custom, config: config, duration: 1, result: .success(String(repeating: "x", count: 8_100)))
    check(long.output == String(repeating: "x", count: 8_000) + "\nResponse truncated.", "large response is bounded with visible truncation")
    for duration: TimeInterval in [-1, .infinity, .nan] {
        check(ConnectionTestResult(provider: .custom, config: config, duration: duration, result: .success("OK")).duration == 0,
              "invalid duration cannot escape into diagnostics")
    }

    // Serialize only: no URLSession, real credentials, or provider requests.
    for apiProtocol in LLMProtocol.allCases {
        var source = config
        source.apiProtocol = apiProtocol
        let testConfig = ConnectionTestResult.configuration(from: source)
        check(testConfig.maxOutputTokens == 1024, "connection test uses a bounded independent token budget")
        check(source.maxOutputTokens == 4096, "test configuration leaves live settings untouched")
        let request = try LLMClient.makeRequest(system: ConnectionTestResult.systemInput, user: ConnectionTestResult.userInput, config: testConfig)
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        switch apiProtocol {
        case .chatCompletions:
            let messages = body["messages"] as! [[String: String]]
            check(messages == [["role": "system", "content": ConnectionTestResult.systemInput], ["role": "user", "content": ConnectionTestResult.userInput]],
                  "Chat sends exactly the displayed fixed inputs")
        case .responses:
            check(body["instructions"] as? String == ConnectionTestResult.systemInput && body["input"] as? String == ConnectionTestResult.userInput,
                  "Responses sends exactly the displayed fixed inputs")
        case .anthropicMessages:
            let messages = body["messages"] as! [[String: String]]
            check(body["system"] as? String == ConnectionTestResult.systemInput && messages == [["role": "user", "content": ConnectionTestResult.userInput]],
                  "Messages sends exactly the displayed fixed inputs")
        case .geminiGenerateContent:
            let instruction = body["systemInstruction"] as! [String: [[String: String]]]
            let contents = body["contents"] as! [[String: Any]]
            check(instruction["parts"] == [["text": ConnectionTestResult.systemInput]] && contents.first?["parts"] as? [[String: String]] == [["text": ConnectionTestResult.userInput]],
                  "Gemini sends exactly the displayed fixed inputs")
        }
        check(!String(data: request.httpBody!, encoding: .utf8)!.contains(config.apiKey), "fixed prompt excludes auth credentials")
    }
    return assertions
}
