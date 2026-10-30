import Foundation

/// URL and transport policy shared by generation and explicit model discovery.
enum LLMAPITransport {
    static func endpoint(baseURL: String, apiProtocol: LLMProtocol, model: String?, models: Bool) throws -> URL {
        var components = try validatedBase(baseURL)
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }

        // A full endpoint may be pasted instead of a base URL. Remove only its known suffix.
        let suffixes: [(String, LLMProtocol)] = [
            ("/chat/completions", .chatCompletions), ("/responses", .responses), ("/messages", .anthropicMessages)
        ]
        if let suffix = suffixes.first(where: { path.hasSuffix($0.0) }) {
            guard suffix.1 == apiProtocol else { throw LLMClient.ClientError.invalidURL }
            path.removeLast(suffix.0.count)
        } else if path.hasSuffix(":generateContent") {
            guard apiProtocol == .geminiGenerateContent,
                  let range = path.range(of: "/models/", options: .backwards),
                  !path[range.upperBound...].contains("/") else { throw LLMClient.ClientError.invalidURL }
            path = String(path[..<range.lowerBound])
        } else if path.hasSuffix("/models") {
            path.removeLast("/models".count)
        }

        let suffix: String
        if models {
            suffix = "/models"
        } else {
            switch apiProtocol {
            case .chatCompletions: suffix = "/chat/completions"
            case .responses: suffix = "/responses"
            case .anthropicMessages: suffix = "/messages"
            case .geminiGenerateContent:
                var name = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if name.hasPrefix("models/") { name.removeFirst("models/".count) }
                let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
                guard !name.isEmpty, name != ".", name != "..",
                      name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
                    throw LLMClient.ClientError.invalidModel
                }
                suffix = "/models/\(name):generateContent"
            }
        }
        components.percentEncodedPath = path + suffix
        guard let url = components.url else { throw LLMClient.ClientError.invalidURL }
        return url
    }

    static func validatedBase(_ value: String) throws -> URLComponents {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !value.isEmpty, !value.contains("\\"),
              !value.unicodeScalars.contains(where: { forbidden.contains($0) }),
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url, scheme == "https" || isLoopback(url) else {
            throw LLMClient.ClientError.invalidURL
        }
        let path = components.percentEncodedPath
        // Encoded path separators and dot segments are ambiguous to proxies and URL normalizers.
        guard !path.contains("//"),
              !path.lowercased().contains("%2f"), !path.lowercased().contains("%5c"),
              !path.lowercased().contains("%25"),
              let decoded = path.removingPercentEncoding,
              !decoded.unicodeScalars.contains(where: { forbidden.contains($0) }),
              !decoded.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw LLMClient.ClientError.invalidURL
        }
        return components
    }

    static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if ["localhost", "::1", "[::1]"].contains(host) { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy {
            !$0.isEmpty && $0.allSatisfy({ $0 >= "0" && $0 <= "9" }) && UInt8($0) != nil
        }
    }

    static func request(url: URL, config: LLMClient.Config, timeout: TimeInterval) throws -> URLRequest {
        try validateTimeout(timeout)
        guard !config.apiKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LLMClient.ClientError.invalidKey
        }
        let key = config.apiKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty || isLoopback(url) else { throw LLMClient.ClientError.missingKey }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !key.isEmpty {
            switch config.authMode {
            case .bearer:
                request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            case .apiKey:
                request.setValue(key, forHTTPHeaderField: config.apiProtocol == .geminiGenerateContent ? "x-goog-api-key" : "x-api-key")
            case .automatic:
                switch config.apiProtocol {
                case .anthropicMessages: request.setValue(key, forHTTPHeaderField: "x-api-key")
                case .geminiGenerateContent: request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
                case .chatCompletions, .responses: request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                }
            }
        }
        if config.apiProtocol == .anthropicMessages {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    static func validateTimeout(_ timeout: TimeInterval) throws {
        guard timeout.isFinite, timeout > 0, timeout <= 120 else { throw LLMClient.ClientError.invalidTimeout }
    }

    static func session(configuration: URLSessionConfiguration, timeout: TimeInterval) -> URLSession {
        // Copy the caller's configuration so tests and callers do not observe mutations.
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
    }

    static func data(for request: URLRequest, session: URLSession, maximumBytes: Int) async throws -> Data {
        try Task.checkCancellation()
        do {
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    let (bytes, response) = try await session.bytes(for: request)
                    try Task.checkCancellation()
                    guard let response = response as? HTTPURLResponse else { throw LLMClient.ClientError.invalidResponse }
                    if (300..<400).contains(response.statusCode) { throw LLMClient.ClientError.redirect }
                    guard (200..<300).contains(response.statusCode) else {
                        // Neither provider errors nor network errors may echo dictated text or credentials to the UI.
                        throw LLMClient.ClientError.httpStatus(response.statusCode)
                    }
                    guard response.expectedContentLength <= maximumBytes else { throw LLMClient.ClientError.invalidResponse }
                    var data = Data()
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        guard data.count < maximumBytes else { throw LLMClient.ClientError.invalidResponse }
                        data.append(byte)
                    }
                    return data
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(request.timeoutInterval))
                    throw LLMClient.ClientError.timedOut
                }
                defer { group.cancelAll() }
                guard let data = try await group.next() else { throw LLMClient.ClientError.invalidResponse }
                return data
            }
        } catch let error as LLMClient.ClientError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .timedOut: throw LLMClient.ClientError.timedOut
            default: throw LLMClient.ClientError.network
            }
        } catch {
            throw LLMClient.ClientError.network
        }
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return lhs.scheme?.lowercased() == rhs.scheme?.lowercased() &&
            lhs.host?.lowercased() == rhs.host?.lowercased() && port(lhs) == port(rhs)
    }

    /// Never forward keys or text across origins or downgrade HTTPS. POST redirects must preserve the method/body.
    final class SameOriginRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        static func permittedRequest(original: URLRequest?, response: HTTPURLResponse, proposed: URLRequest) -> URLRequest? {
            guard let original, let origin = original.url, let target = proposed.url,
                  target.user == nil, target.password == nil, target.fragment == nil,
                  sameOrigin(origin, target) else { return nil }
            if original.httpMethod == "POST" {
                guard response.statusCode == 307 || response.statusCode == 308,
                      proposed.httpMethod == "POST" else { return nil }
            }
            return proposed
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(Self.permittedRequest(original: task.originalRequest, response: response, proposed: request))
        }
    }
}
