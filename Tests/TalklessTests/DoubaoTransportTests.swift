import Foundation
import Synchronization
import Testing
@testable import Talkless

@Suite struct DoubaoTransportTests {
    @Test func sharedTransportCreatesIndependentUnstartedStreams() throws {
        let transport = DoubaoTransport()
        let configuration = transport.session.configuration
        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        let first = transport.makeTask(request: try DoubaoConfig(apiKey: "first").request())
        let second = transport.makeTask(request: try DoubaoConfig(apiKey: "second", inputLanguage: .japanese).request())
        defer { first.cancel(); second.cancel() }
        #expect(first !== second)
        #expect(first.state == .suspended && second.state == .suspended)
        #expect(first.originalRequest?.value(forHTTPHeaderField: "X-Api-Key") == "first")
        #expect(second.originalRequest?.value(forHTTPHeaderField: "X-Api-Key") == "second")
        #expect(second.originalRequest?.url?.lastPathComponent == "bigmodel_nostream")
        first.cancel()
        #expect(second.state == .suspended)
        let third = transport.makeTask(request: try DoubaoConfig(apiKey: "third").request())
        #expect(third.state == .suspended)
        third.cancel()
        #expect(DoubaoTransport.shared === DoubaoTransport.shared)
    }

    @Test func handshakeAndRedirectCallbacksAreIsolatedPerTask() throws {
        let transport = DoubaoTransport()
        let opens = Mutex(0)
        let task = transport.makeTask(request: try DoubaoConfig(apiKey: "synthetic").request(), onOpen: {
            opens.withLock { $0 += 1 }
        })
        defer { task.cancel() }
        let delegate = try #require(task.delegate as? DoubaoTaskDelegate)
        delegate.urlSession(transport.session, webSocketTask: task, didOpenWithProtocol: nil)
        #expect(opens.withLock { $0 } == 1)
        let response = try #require(HTTPURLResponse(url: URL(string: "https://openspeech.bytedance.com")!,
                                                  statusCode: 302, httpVersion: nil, headerFields: nil))
        let rejected = Mutex(false)
        delegate.urlSession(transport.session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://example.invalid")!)) { request in
            rejected.withLock { $0 = request == nil }
        }
        #expect(rejected.withLock { $0 })
    }
}
