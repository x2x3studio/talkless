import AVFoundation
import Foundation
import Testing
@testable import Talkless

private enum EnhancedFakeError: Error { case local, online }

/// Intentionally ignores cancellation, including callbacks already queued by a provider.
/// Tests explicitly release suspended work, so passing a deadline test cannot depend on
/// a cooperative model, an actual network connection, or leaked continuations.
private final class EnhancedFakeSession: TranscriptionSession, @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@MainActor @Sendable (String) -> Void)?
    private var result: Result<String, any Error>?
    private var waiter: CheckedContinuation<String, any Error>?
    private var received: [[Float]] = []
    private var buffers: [[Float]] = []
    private var cancellations = 0

    var onPartial: (@MainActor @Sendable (String) -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }
    var snapshots: [[Float]] { lock.withLock { received } }
    var fed: [[Float]] { lock.withLock { buffers } }
    var isCancelled: Bool { lock.withLock { cancellations > 0 } }
    var cancellationCount: Int { lock.withLock { cancellations } }

    init(_ result: Result<String, any Error>? = nil) { self.result = result }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let values = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        lock.withLock { buffers.append(values) }
    }

    func finish(samples: [Float]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<String, any Error>? = lock.withLock {
                received.append(samples)
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func complete(_ result: Result<String, any Error>) {
        let pending = lock.withLock {
            guard self.result == nil else { return Optional<CheckedContinuation<String, any Error>>.none }
            self.result = result
            let pending = waiter
            waiter = nil
            return pending
        }
        pending?.resume(with: result)
    }

    func cancel() { lock.withLock { cancellations += 1 } }
}

private final class EnhancedFinishProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String, any Error>?
    func record(_ value: Result<String, any Error>) { lock.withLock { result = value } }
    var isDone: Bool { lock.withLock { result != nil } }
    func value() async throws -> String {
        try #require(await enhancedEventually { self.isDone }, "finish must not join an uncooperative child")
        return try lock.withLock { result! }.get()
    }
}

private final class EnhancedTimingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String: String]] = []
    private weak var session: EnhancedTranscriptionSession?
    var events: [[String: String]] { lock.withLock { recorded } }
    func bind(_ session: EnhancedTranscriptionSession) { lock.withLock { self.session = session } }
    func record(_ metadata: [String: String]) {
        let session = lock.withLock { session }
        // Reenter the state lock to prove diagnostics are never invoked under it.
        _ = session?.secondaryTranscript
        lock.withLock { recorded.append(metadata) }
    }
}

private func enhancedEventually(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

private func enhancedStart(_ session: EnhancedTranscriptionSession, samples: [Float] = [1, 2, 3])
    -> (EnhancedFinishProbe, Task<Void, Never>) {
    let probe = EnhancedFinishProbe()
    let task = Task.detached {
        do { probe.record(.success(try await session.finish(samples: samples))) }
        catch { probe.record(.failure(error)) }
    }
    return (probe, task)
}

@Suite struct EnhancedTranscriptionTests {
    @Test func diagnosticsIdentifyEachProvidersFinishDurationAndOutcome() async throws {
        let local = EnhancedFakeSession()
        let online = EnhancedFakeSession(.failure(EnhancedFakeError.online))
        defer { local.complete(.success("cleanup")) }
        let timing = EnhancedTimingProbe()
        let operationID = UUID().uuidString
        let session = EnhancedTranscriptionSession(online: online, local: local,
                                                  operationID: operationID, diagnostics: { timing.record($0) })
        timing.bind(session)
        let (probe, _) = enhancedStart(session)
        try #require(await enhancedEventually {
            !local.snapshots.isEmpty && timing.events.contains { $0["stage"] == "enhanced_finish_failed" }
        })
        try await Task.sleep(for: .milliseconds(30))
        local.complete(.success("private transcript must not be logged"))
        #expect(try await probe.value() == "private transcript must not be logged")
        let events = timing.events
        #expect(events.count == 4)
        #expect(Set(events.compactMap { $0["operation_id"] }) == [operationID])
        for engine in ["qwen", "doubao"] {
            let route = events.filter { $0["engine"] == engine }
            #expect(route.map { $0["stage"] } == ["enhanced_finish_started",
                                                engine == "qwen" ? "enhanced_finish_completed" : "enhanced_finish_failed"])
            #expect(route.first?["duration_ms"] == "0")
            let milliseconds = try #require(route.last?["duration_ms"])
            let duration = try #require(Int(milliseconds))
            #expect(duration >= (engine == "qwen" ? 25 : 0))
        }
        #expect(events.allSatisfy { Set($0.keys) == ["operation_id", "engine", "stage", "duration_ms"] })
    }

    @Test func diagnosticsSkipRecordingFailureAndMeasureLateProviderReturn() async throws {
        let local = EnhancedFakeSession()
        let online = EnhancedFakeSession()
        defer { local.complete(.success("cleanup")) }
        let timing = EnhancedTimingProbe()
        let session = EnhancedTranscriptionSession(online: online, local: local,
                                                  finishTimeout: .milliseconds(30), diagnostics: { timing.record($0) })
        session.onlineFailed(EnhancedFakeError.online)
        let (probe, _) = enhancedStart(session)
        do { _ = try await probe.value(); Issue.record("Expected timeout") }
        catch { #expect(error is EnhancedTranscriptionSession.FinishError) }
        #expect(timing.events.count == 1)
        #expect(timing.events.first?["engine"] == "qwen")
        #expect(timing.events.first?["stage"] == "enhanced_finish_started")
        local.complete(.success("late speech"))
        try #require(await enhancedEventually { timing.events.count == 2 })
        #expect(timing.events.last?["stage"] == "enhanced_finish_completed")
        #expect(session.secondaryTranscript == nil)
    }

    @Test func feedsBothAndFinishesConcurrentlyWithOnlinePrimary() async throws {
        let local = EnhancedFakeSession()
        let online = EnhancedFakeSession()
        defer { local.complete(.success("cleanup")); online.complete(.success("cleanup")) }
        let session = EnhancedTranscriptionSession(online: online, local: local)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                               channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3))
        buffer.frameLength = 3
        for index in 0..<3 { buffer.floatChannelData![0][index] = Float(index + 1) }
        session.feed(buffer)
        #expect(local.fed == [[1, 2, 3]])
        #expect(online.fed == local.fed)
        let (probe, _) = enhancedStart(session)
        try #require(await enhancedEventually { local.snapshots.count == 1 && online.snapshots.count == 1 })
        #expect(local.snapshots == [[1, 2, 3]] && online.snapshots == local.snapshots)
        local.complete(.success("local speech"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(!probe.isDone)
        online.complete(.success("online speech"))
        #expect(try await probe.value() == "online speech")
        #expect(session.secondaryTranscript == "local speech")
    }

    @Test(arguments: [true, false]) func singleFailurePreservesOtherSuccess(onlineFails: Bool) async throws {
        let local = EnhancedFakeSession(onlineFails ? .success("local") : .failure(EnhancedFakeError.local))
        let online = EnhancedFakeSession(onlineFails ? .failure(EnhancedFakeError.online) : .success("online"))
        let session = EnhancedTranscriptionSession(online: online, local: local)
        #expect(try await session.finish(samples: []) == (onlineFails ? "local" : "online"))
        #expect(session.secondaryTranscript == nil)
    }

    @MainActor @Test(arguments: [true, false])
    func recordingFailureImmediatelyStopsOnlyThatRoute(onlineFails: Bool) async throws {
        let local = EnhancedFakeSession(.success("local"))
        let online = EnhancedFakeSession(.success("online"))
        let session = EnhancedTranscriptionSession(online: online, local: local)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                               channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        buffer.floatChannelData![0][0] = 0.5
        var previews: [String] = []
        session.onPartial = { previews.append($0) }
        let queued = online.onPartial
        queued?("before failure")
        session.feed(buffer)
        if onlineFails { session.onlineFailed(URLError(.timedOut)) }
        else { session.localFailed(EnhancedFakeError.local) }
        let failed = onlineFails ? online : local
        let surviving = onlineFails ? local : online
        #expect(failed.cancellationCount == 1)
        #expect(!surviving.isCancelled)
        session.feed(buffer)
        queued?("after failure")
        #expect(failed.fed == [[0.5]])
        #expect(surviving.fed == [[0.5], [0.5]])
        #expect(previews == (onlineFails ? ["before failure"] : ["before failure", "after failure"]))
        #expect(try await session.finish(samples: [0.5, 0.5]) == (onlineFails ? "local" : "online"))
        #expect(failed.snapshots.isEmpty, "Do not finish or re-upload to a failed provider")
        #expect(surviving.snapshots == [[0.5, 0.5]])
        #expect(session.secondaryTranscript == nil)
    }

    @Test func bothRecordingFailuresFinishImmediatelyAndKeepOriginalErrors() async throws {
        let local = EnhancedFakeSession()
        let online = EnhancedFakeSession()
        let session = EnhancedTranscriptionSession(online: online, local: local)
        session.onlineFailed(URLError(.timedOut))
        session.onlineFailed(CancellationError())
        session.localFailed(EnhancedFakeError.local)
        #expect(online.cancellationCount == 1 && local.cancellationCount == 1)
        let (probe, _) = enhancedStart(session)
        do { _ = try await probe.value(); Issue.record("Expected both failures") }
        catch EnhancedTranscriptionSession.FinishError.bothFailed(let localError, let onlineError) {
            #expect(localError as? EnhancedFakeError == .local)
            #expect((onlineError as? URLError)?.code == .timedOut)
        }
        #expect(local.snapshots.isEmpty && online.snapshots.isEmpty)
    }

    @Test(arguments: [true, false])
    func failureDuringFinishDoesNotJoinFailedProviderOrAcceptItsLateSuccess(onlineFails: Bool) async throws {
        let local = EnhancedFakeSession()
        let online = EnhancedFakeSession()
        defer { local.complete(.success("cleanup")); online.complete(.success("cleanup")) }
        let session = EnhancedTranscriptionSession(online: online, local: local)
        let (probe, _) = enhancedStart(session)
        try #require(await enhancedEventually { !local.snapshots.isEmpty && !online.snapshots.isEmpty })
        if onlineFails { session.onlineFailed(EnhancedFakeError.online) }
        else { session.localFailed(EnhancedFakeError.local) }
        let failed = onlineFails ? online : local
        let surviving = onlineFails ? local : online
        #expect(failed.isCancelled && !surviving.isCancelled)
        failed.complete(.success("late failed-provider speech"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(!probe.isDone)
        surviving.complete(.success("survived"))
        #expect(try await probe.value() == "survived")
        #expect(session.secondaryTranscript == nil)
        #expect(failed.cancellationCount == 1)
    }

    @Test func recordingFailureStillBoundsHungSurvivorAtFinishDeadline() async throws {
        let local = EnhancedFakeSession()
        let online = EnhancedFakeSession()
        defer { local.complete(.success("cleanup")) }
        let session = EnhancedTranscriptionSession(online: online, local: local, finishTimeout: .milliseconds(60))
        session.onlineFailed(EnhancedFakeError.online)
        let (probe, _) = enhancedStart(session)
        do { _ = try await probe.value(); Issue.record("Expected survivor timeout") }
        catch EnhancedTranscriptionSession.FinishError.bothFailed(let localError, let onlineError) {
            guard case EnhancedTranscriptionSession.FinishError.timeout = localError else {
                Issue.record("Pending local provider should time out"); return
            }
            #expect(onlineError as? EnhancedFakeError == .online)
        }
        #expect(local.isCancelled && online.isCancelled)
        #expect(online.snapshots.isEmpty)
    }

    @Test func longRecordingAloneDoesNotFailEitherRouteOrStartFinishDeadline() async throws {
        let local = EnhancedFakeSession(.success("local"))
        let online = EnhancedFakeSession(.success("online"))
        let session = EnhancedTranscriptionSession(online: online, local: local, finishTimeout: .milliseconds(30))
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                               channels: 1, interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].update(repeating: 0.5, count: 16_000)
        // More than 15 seconds of captured audio, without a real provider error.
        for _ in 0..<16 { session.feed(buffer) }
        // The injected finish budget must not tick during recording.
        try await Task.sleep(for: .milliseconds(60))
        session.feed(buffer)
        #expect(local.fed.count == 17 && online.fed.count == 17)
        #expect(!local.isCancelled && !online.isCancelled)
        #expect(try await session.finish(samples: []) == "online")
        #expect(session.secondaryTranscript == "local")
    }

    @Test func lateFailureAfterCompletionDoesNotCancelSuccessfulProviders() async throws {
        let local = EnhancedFakeSession(.success("local"))
        let online = EnhancedFakeSession(.success("online"))
        let session = EnhancedTranscriptionSession(online: online, local: local)
        #expect(try await session.finish(samples: []) == "online")
        session.onlineFailed(EnhancedFakeError.online)
        session.localFailed(EnhancedFakeError.local)
        #expect(!local.isCancelled && !online.isCancelled)
        #expect(session.secondaryTranscript == "local")
    }

    @Test func bothFailuresArePreserved() async throws {
        let session = EnhancedTranscriptionSession(
            online: EnhancedFakeSession(.failure(EnhancedFakeError.online)),
            local: EnhancedFakeSession(.failure(EnhancedFakeError.local)))
        do { _ = try await session.finish(samples: []); Issue.record("Expected both failures") }
        catch EnhancedTranscriptionSession.FinishError.bothFailed(let local, let online) {
            #expect(local as? EnhancedFakeError == .local)
            #expect(online as? EnhancedFakeError == .online)
        }
    }

    @Test func providerCancellationIsOnlyThatProvidersFailure() async throws {
        let session = EnhancedTranscriptionSession(online: EnhancedFakeSession(.failure(CancellationError())),
                                                  local: EnhancedFakeSession(.success("survived")))
        #expect(try await session.finish(samples: []) == "survived")
    }

    @Test(arguments: [true, false]) func firstSuccessHasBoundedGraceAndLateResultsAreIgnored(onlineFirst: Bool) async throws {
        let local = EnhancedFakeSession(onlineFirst ? nil : .success("first local"))
        let online = EnhancedFakeSession(onlineFirst ? .success("first online") : nil)
        defer { local.complete(.success("cleanup")); online.complete(.success("cleanup")) }
        let session = EnhancedTranscriptionSession(online: online, local: local,
                                                  secondaryWait: .milliseconds(60), finishTimeout: .seconds(1))
        let start = ContinuousClock.now
        let (probe, _) = enhancedStart(session)
        #expect(try await probe.value() == (onlineFirst ? "first online" : "first local"))
        #expect(start.duration(to: .now) >= .milliseconds(50))
        #expect(start.duration(to: .now) < .seconds(1))
        let late = onlineFirst ? local : online
        #expect(late.isCancelled)
        late.complete(.success("late speech must not overwrite"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(session.secondaryTranscript == nil)
    }

    @Test func onlineFirstStillCollectsLocalSecondaryWithinGrace() async throws {
        let local = EnhancedFakeSession()
        defer { local.complete(.success("cleanup")) }
        let session = EnhancedTranscriptionSession(online: EnhancedFakeSession(.success("online")), local: local)
        let (probe, _) = enhancedStart(session)
        try #require(await enhancedEventually { !local.snapshots.isEmpty })
        try await Task.sleep(for: .milliseconds(20))
        #expect(!probe.isDone)
        local.complete(.success("local"))
        #expect(try await probe.value() == "online")
        #expect(session.secondaryTranscript == "local")
    }

    @Test(arguments: [true, false]) func emptyDoesNotStartGraceOrDiscardSpeech(onlineEmpty: Bool) async throws {
        let local = EnhancedFakeSession(onlineEmpty ? nil : .success(" \n "))
        let online = EnhancedFakeSession(onlineEmpty ? .success("") : nil)
        defer { local.complete(.success("cleanup")); online.complete(.success("cleanup")) }
        let session = EnhancedTranscriptionSession(online: online, local: local,
                                                  secondaryWait: .milliseconds(10), finishTimeout: .seconds(1))
        let (probe, _) = enhancedStart(session)
        try #require(await enhancedEventually { !local.snapshots.isEmpty && !online.snapshots.isEmpty })
        try await Task.sleep(for: .milliseconds(60))
        #expect(!probe.isDone, "Empty success must not trigger the short grace deadline")
        (onlineEmpty ? local : online).complete(.success("actual speech"))
        #expect(try await probe.value() == "actual speech")
        #expect(session.secondaryTranscript == nil)
    }

    @Test(arguments: [true, false]) func emptyPlusFailureStillSucceeds(onlineFails: Bool) async throws {
        let session = EnhancedTranscriptionSession(
            online: EnhancedFakeSession(onlineFails ? .failure(EnhancedFakeError.online) : .success("")),
            local: EnhancedFakeSession(onlineFails ? .success("") : .failure(EnhancedFakeError.local)))
        #expect(try await session.finish(samples: []) == "")
    }

    @Test func bothEmptyReturnEmpty() async throws {
        let session = EnhancedTranscriptionSession(online: EnhancedFakeSession(.success(" \n")),
                                                  local: EnhancedFakeSession(.success("")))
        #expect(try await session.finish(samples: []) == "")
        #expect(session.secondaryTranscript == nil)
    }

    @Test func emptyPlusHungRecognizerReturnsEmptyAtOverallDeadline() async throws {
        let local = EnhancedFakeSession()
        defer { local.complete(.success("cleanup")) }
        let session = EnhancedTranscriptionSession(online: EnhancedFakeSession(.success("")), local: local,
                                                  finishTimeout: .milliseconds(60))
        let (probe, _) = enhancedStart(session)
        #expect(try await probe.value() == "")
        #expect(local.isCancelled)
    }

    @Test func totalDeadlineDoesNotJoinEitherHungRecognizer() async throws {
        let local = EnhancedFakeSession()
        let online = EnhancedFakeSession()
        defer { local.complete(.success("cleanup")); online.complete(.success("cleanup")) }
        let session = EnhancedTranscriptionSession(online: online, local: local, finishTimeout: .milliseconds(60))
        let (probe, _) = enhancedStart(session)
        do { _ = try await probe.value(); Issue.record("Expected timeout") }
        catch EnhancedTranscriptionSession.FinishError.bothFailed(let local, let online) {
            guard case EnhancedTranscriptionSession.FinishError.timeout = local,
                  case EnhancedTranscriptionSession.FinishError.timeout = online else {
                Issue.record("Both pending providers should time out"); return
            }
        }
        #expect(local.isCancelled && online.isCancelled)
    }

    @Test func totalDeadlineCapsGracePeriod() async throws {
        let local = EnhancedFakeSession()
        let online = EnhancedFakeSession()
        defer { local.complete(.success("cleanup")); online.complete(.success("cleanup")) }
        let session = EnhancedTranscriptionSession(online: online, local: local,
                                                  secondaryWait: .seconds(2), finishTimeout: .milliseconds(150))
        let start = ContinuousClock.now
        let (probe, _) = enhancedStart(session)
        try #require(await enhancedEventually { !local.snapshots.isEmpty })
        try await Task.sleep(for: .milliseconds(60))
        local.complete(.success("just in time"))
        #expect(try await probe.value() == "just in time")
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(online.isCancelled)
    }

    @Test(arguments: [true, false]) func explicitAndParentCancellationDoNotJoinChildren(explicit: Bool) async throws {
        let local = EnhancedFakeSession()
        let online = EnhancedFakeSession()
        defer { local.complete(.success("cleanup")); online.complete(.success("cleanup")) }
        let session = EnhancedTranscriptionSession(online: online, local: local)
        let (probe, task) = enhancedStart(session)
        try #require(await enhancedEventually { !local.snapshots.isEmpty && !online.snapshots.isEmpty })
        if explicit { session.cancel() } else { task.cancel() }
        do { _ = try await probe.value(); Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(local.isCancelled && online.isCancelled)
        #expect(session.secondaryTranscript == nil)
    }

    @MainActor @Test func onlyOnlinePreviewsAndNoCallbacksAfterCancel() async throws {
        let local = EnhancedFakeSession()
        let online = EnhancedFakeSession()
        let session = EnhancedTranscriptionSession(online: online, local: local)
        var previews: [String] = []
        session.onPartial = { previews.append($0) }
        let queued = online.onPartial
        local.onPartial?("local must be silent")
        queued?("online preview")
        session.cancel()
        queued?("queued before cancellation")
        session.onPartial = { previews.append($0) }
        queued?("callback reinstalled after cancellation")
        #expect(previews == ["online preview"])
        #expect(local.isCancelled && online.isCancelled)
        do { _ = try await session.finish(samples: []); Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(local.snapshots.isEmpty && online.snapshots.isEmpty)
    }

    @MainActor @Test func slowPreviewDoesNotHoldTheAudioFeedLock() {
        let local = EnhancedFakeSession()
        let online = EnhancedFakeSession()
        let session = EnhancedTranscriptionSession(online: online, local: local)
        session.onPartial = { _ in
            let fed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                // Construct the non-Sendable buffer on the simulated audio thread.
                let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                           channels: 1, interleaved: false)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
                buffer.frameLength = 1
                buffer.floatChannelData![0][0] = 0.5
                session.feed(buffer)
                fed.signal()
            }
            // Deliberately keep this UI callback active until feed finishes. A lock
            // held across delivery would stall feed and hit the bounded test timeout.
            #expect(fed.wait(timeout: .now() + 1) == .success)
        }
        online.onPartial?("preview with slow layout")
        #expect(local.fed == [[0.5]] && online.fed == [[0.5]])
    }

    @MainActor @Test func callbackCanCancelReentrantly() {
        let local = EnhancedFakeSession()
        let online = EnhancedFakeSession()
        let session = EnhancedTranscriptionSession(online: online, local: local)
        session.onPartial = { _ in session.cancel() }
        online.onPartial?("cancel inside callback")
        #expect(local.isCancelled && online.isCancelled)
    }

    @MainActor @Test func completedSessionSuppressesStalePreviewsAndRejectsSecondFinish() async throws {
        let online = EnhancedFakeSession(.success("online"))
        let local = EnhancedFakeSession(.success("local"))
        let session = EnhancedTranscriptionSession(online: online, local: local)
        session.onPartial = { _ in Issue.record("No previews after completion") }
        let queued = online.onPartial
        #expect(try await session.finish(samples: []) == "online")
        queued?("stale")
        do { _ = try await session.finish(samples: []); Issue.record("Expected single-use rejection") }
        catch { guard case EnhancedTranscriptionSession.FinishError.alreadyFinished = error else { throw error } }
        #expect(local.snapshots.count == 1 && online.snapshots.count == 1)
    }
}
