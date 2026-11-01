import AVFoundation
import Foundation
import Testing
@testable import Talkless

private final class FallbackFakeSession: TranscriptionSession, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@MainActor @Sendable (String) -> Void)?
    var onPartial: (@MainActor @Sendable (String) -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }
    let result: Result<String, Error>
    private var received: [[Float]] = []
    private var cancelled = false
    var snapshots: [[Float]] { lock.withLock { received } }
    var isCancelled: Bool { lock.withLock { cancelled } }
    init(_ result: Result<String, Error>) { self.result = result }
    func feed(_ buffer: AVAudioPCMBuffer) {}
    func finish(samples: [Float]) async throws -> String {
        lock.withLock { received.append(samples) }
        if isCancelled { throw CancellationError() }
        return try result.get()
    }
    func cancel() { lock.withLock { cancelled = true } }
}

@Suite struct FallbackTranscriptionTests {
    @Test func onlineSuccessDoesNotStartLocal() async throws {
        let online = FallbackFakeSession(.success("online final"))
        let local = FallbackFakeSession(.success("local final"))
        let session = FallbackTranscriptionSession(online: online, makeLocal: {
            Issue.record("Local must remain idle when online succeeds")
            return local
        }, onFallback: { Issue.record("Unexpected fallback") })
        #expect(try await session.finish(samples: [1, 2, 3]) == "online final")
        #expect(local.snapshots.isEmpty)
    }

    @MainActor @Test func onlineFailureReplaysTheWholeUtteranceExactlyOnce() async throws {
        let online = FallbackFakeSession(.failure(DoubaoError.timeout))
        let local = FallbackFakeSession(.success("complete local transcript"))
        var transitions = 0
        var previews: [String] = []
        let session = FallbackTranscriptionSession(online: online, makeLocal: { local }, onFallback: { transitions += 1 })
        session.onPartial = { previews.append($0) }
        online.onPartial?("incomplete online words")
        let samples: [Float] = [0.1, 0.2, 0.3]
        #expect(try await session.finish(samples: samples) == "complete local transcript")
        #expect(local.snapshots == [samples])
        #expect(transitions == 1 && online.isCancelled)
        online.onPartial?("stale online callback")
        #expect(previews == ["incomplete online words"], "Never combine stale online output with the local transcript")
    }

    @Test func cancellationNeverFallsBack() async throws {
        let online = FallbackFakeSession(.failure(CancellationError()))
        let session = FallbackTranscriptionSession(online: online, makeLocal: {
            Issue.record("Cancellation must not start local inference")
            return FallbackFakeSession(.success("wrong"))
        }, onFallback: { Issue.record("Cancellation must not notify fallback") })
        do { _ = try await session.finish(samples: []); Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }

    @MainActor @Test func cancellationAtHandoffNeverCreatesLocalSession() async throws {
        let online = FallbackFakeSession(.failure(DoubaoError.connection))
        var session: FallbackTranscriptionSession?
        session = FallbackTranscriptionSession(online: online, makeLocal: {
            Issue.record("Cancelled handoff must not create a local session")
            return FallbackFakeSession(.success("wrong"))
        }, onFallback: { session?.cancel() })
        do { _ = try await session!.finish(samples: [1]); Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
    }

    @Test func localFailureDoesNotReturnOnlinePartialOrRetry() async throws {
        let online = FallbackFakeSession(.failure(DoubaoError.connection))
        let local = FallbackFakeSession(.failure(DoubaoError.invalidAudio))
        let session = FallbackTranscriptionSession(online: online, makeLocal: { local }, onFallback: {})
        do { _ = try await session.finish(samples: [1]); Issue.record("Expected local failure") }
        catch { #expect(error is DoubaoError) }
        #expect(local.snapshots.count == 1)
    }
}
