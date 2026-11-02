import Foundation
import Testing
@testable import Talkless

private final class ImmediateDoubaoSocket: DoubaoSocket, @unchecked Sendable {
    private let events: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    init() { (events, continuation) = AsyncThrowingStream.makeStream() }
    private func frame(_ text: String, final: Bool) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: ["result": ["text": text]])
        var data = Data([0x11, final ? 0x92 : 0x90, 0x10, 0])
        var size = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &size) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }
    func send(_ data: Data) async throws {
        if data[1] >> 4 == 1 { continuation.yield(try frame("preview", final: false)) }
        else if data[1] & 2 != 0 { continuation.yield(try frame("final", final: true)) }
    }
    func receive() async throws -> Data {
        var iterator = events.makeAsyncIterator()
        guard let data = try await iterator.next() else { throw CancellationError() }
        return data
    }
    func close() { continuation.finish(throwing: CancellationError()) }
}

@Suite struct DoubaoResponsivenessTests {
    @MainActor @Test func networkCompletionMustNotWaitForMainThread() async throws {
        let socket = ImmediateDoubaoSocket()
        let session = try DoubaoTranscriptionSession(config: .init(apiKey: "synthetic"), socket: socket, timeout: 60)
        var previews: [String] = []
        session.onPartial = { previews.append($0) }
        let completed = DispatchSemaphore(value: 0)
        let work = Task.detached {
            defer { completed.signal() }
            return try await session.finish(samples: [])
        }
        // Simulate a busy UI while the fake server replies immediately on worker tasks.
        func occupyMainThread() -> DispatchTimeoutResult { completed.wait(timeout: .now() + 1) }
        let status = occupyMainThread()
        #expect(status == .success, "Immediate server response must finish even while the main thread is occupied")
        #expect(try await work.value == "final")
        for _ in 0..<10 { await Task.yield() }
        #expect(previews.isEmpty, "Queued previews must not overwrite a completed result")
    }
}
