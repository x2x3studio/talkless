import AVFoundation
import Foundation

/// Runs both recognizers for one utterance. Only online supplies live previews.
/// `finish` prefers a nonempty online result received before the deadline; the other
/// nonempty result is available through `secondaryTranscript` after `finish` returns.
final class EnhancedTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    enum FinishError: LocalizedError {
        case alreadyFinished
        case timeout
        case bothFailed(local: any Error, online: any Error)

        var errorDescription: String? {
            L10n.tr("Enhanced recognition could not finish. Check the local model and Doubao connection, then try again.")
        }
    }

    private enum Source { case local, online }
    private typealias TranscriptResult = Result<String, any Error>
    private typealias Waiter = CheckedContinuation<String, any Error>

    private let local: any TranscriptionSession
    private let online: any TranscriptionSession
    private let secondaryWait: Duration
    private let finishTimeout: Duration
    // Protect state only, never UI callbacks: feed uses this lock on the audio thread.
    private let lock = NSLock()
    private var partial: (@MainActor @Sendable (String) -> Void)?
    private var secondary: String?
    private var cancelled = false
    private var started = false
    private var completed = false
    private var waiter: Waiter?
    private var localResult: TranscriptResult?
    private var onlineResult: TranscriptResult?
    private var deadline: ContinuousClock.Instant?
    private var hasNonemptyResult = false
    private var tasks: [Task<Void, Never>] = []

    var onPartial: (@MainActor @Sendable (String) -> Void)? {
        get { lock.withLock { partial } }
        set { lock.withLock { partial = cancelled || completed ? nil : newValue } }
    }

    var secondaryTranscript: String? { lock.withLock { secondary } }

    /// Shorter deadlines may be injected for tests; production limits cannot be raised.
    init(online: any TranscriptionSession, local: any TranscriptionSession,
         secondaryWait: Duration = .seconds(2), finishTimeout: Duration = .seconds(20)) {
        self.online = online
        self.local = local
        self.secondaryWait = min(max(secondaryWait, .zero), .seconds(2))
        self.finishTimeout = min(max(finishTimeout, .zero), .seconds(20))
        local.onPartial = nil
        online.onPartial = { [weak self] text in
            guard let self else { return }
            let callback = self.lock.withLock {
                self.cancelled || self.completed ? nil : self.partial
            }
            // State is checked when the queued main-actor preview actually executes.
            // No suspension separates the snapshot and delivery, so main-actor cancel
            // cannot interleave. A background cancel can race an already-started
            // delivery; it is deliberately not a blocking UI callback barrier.
            callback?(text)
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard lock.withLock({ !cancelled && !started }) else { return }
        // Both calls are synchronous on the audio thread; the recorder's non-Sendable
        // buffer never crosses a task boundary. Each recognizer owns its sample copy.
        local.feed(buffer)
        online.feed(buffer)
    }

    func finish(samples: [Float]) async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: String = try await withCheckedThrowingContinuation { continuation in
                beginFinish(samples: samples, continuation: continuation)
            }
            try Task.checkCancellation()
            guard !lock.withLock({ cancelled }) else { throw CancellationError() }
            return result
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let work: Completion? = lock.withLock {
            guard !cancelled else { return nil }
            cancelled = true
            partial = nil
            return completeLocked(.failure(CancellationError()), cancelBoth: true)
        }
        work?.run()
    }

    private func beginFinish(samples: [Float], continuation: Waiter) {
        let rejection: (any Error)? = lock.withLock {
            guard !cancelled else { return CancellationError() }
            guard !started else { return FinishError.alreadyFinished }
            started = true
            waiter = continuation
            let end = ContinuousClock.now.advanced(by: finishTimeout)
            deadline = end
            // Deliberately unstructured: neither timeout nor cancellation joins a
            // recognizer that ignores task cancellation (e.g. synchronous inference).
            tasks.append(Task.detached { [weak self, local] in
                let result: TranscriptResult
                do {
                    try Task.checkCancellation()
                    result = .success(try await local.finish(samples: samples))
                }
                catch { result = .failure(error) }
                self?.receive(result, from: .local)
            })
            tasks.append(Task.detached { [weak self, online] in
                let result: TranscriptResult
                do {
                    try Task.checkCancellation()
                    result = .success(try await online.finish(samples: samples))
                }
                catch { result = .failure(error) }
                self?.receive(result, from: .online)
            })
            scheduleDeadlineLocked(end)
            return nil
        }
        if let rejection { continuation.resume(throwing: rejection) }
    }

    private func scheduleDeadlineLocked(_ end: ContinuousClock.Instant) {
        tasks.append(Task.detached { [weak self] in
            do { try await ContinuousClock().sleep(until: end) }
            catch { return }
            self?.expire()
        })
    }

    private func receive(_ result: TranscriptResult, from source: Source) {
        let work: Completion? = lock.withLock {
            guard !completed, !cancelled, let deadline else { return nil }
            let now = ContinuousClock.now
            // A delayed watchdog must not allow a result arriving after the deadline
            // to replace the first success or mutate the published secondary text.
            guard now < deadline else { return completeLocked(bestResultLocked()) }
            switch source {
            case .local: localResult = result
            case .online: onlineResult = result
            }
            if localResult != nil, onlineResult != nil {
                return completeLocked(bestResultLocked())
            }
            if !hasNonemptyResult, Self.nonempty(result) != nil {
                hasNonemptyResult = true
                let end = min(deadline, now.advanced(by: secondaryWait))
                self.deadline = end
                scheduleDeadlineLocked(end)
            }
            // An empty success is retained but starts no grace period. Give the other
            // recognizer the full remaining budget to recover actual speech.
            return nil
        }
        work?.run()
    }

    private func expire() {
        let work: Completion? = lock.withLock {
            guard !completed, let deadline, ContinuousClock.now >= deadline else { return nil }
            return completeLocked(bestResultLocked())
        }
        work?.run()
    }

    private static func nonempty(_ result: TranscriptResult?) -> String? {
        guard case .success(let text) = result,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    // Called only under lock. Empty output is a valid success if neither side has
    // speech; a pending recognizer counts as timed out once the deadline expires.
    private func bestResultLocked() -> TranscriptResult {
        let onlineText = Self.nonempty(onlineResult)
        let localText = Self.nonempty(localResult)
        if let onlineText {
            secondary = localText
            return .success(onlineText)
        }
        if let localText { return .success(localText) }
        if case .success = localResult { return .success("") }
        if case .success = onlineResult { return .success("") }
        func failure(_ result: TranscriptResult?) -> any Error {
            if case .failure(let error) = result { return error }
            return FinishError.timeout
        }
        return .failure(FinishError.bothFailed(local: failure(localResult), online: failure(onlineResult)))
    }

    private struct Completion {
        let waiter: Waiter?
        let result: TranscriptResult
        let tasks: [Task<Void, Never>]
        let recognizers: [any TranscriptionSession]

        func run() {
            tasks.forEach { $0.cancel() }
            recognizers.forEach { $0.cancel() }
            waiter?.resume(with: result)
        }
    }

    private func completeLocked(_ result: TranscriptResult, cancelBoth: Bool = false) -> Completion? {
        guard !completed else { return nil }
        completed = true
        partial = nil
        let work = Completion(
            waiter: waiter, result: result, tasks: tasks,
            recognizers: [(cancelBoth || localResult == nil) ? local : nil,
                          (cancelBoth || onlineResult == nil) ? online : nil].compactMap { $0 }
        )
        waiter = nil
        tasks = []
        return work
    }
}
