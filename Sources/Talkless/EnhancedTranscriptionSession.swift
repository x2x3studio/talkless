import AVFoundation
import Foundation

@MainActor
final class EnhancedFailureRelay {
    weak var session: EnhancedTranscriptionSession?
}

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
    private let operationID: String
    private let diagnostics: @Sendable ([String: String]) -> Void
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
         secondaryWait: Duration = .seconds(2), finishTimeout: Duration = .seconds(20),
         operationID: String = UUID().uuidString,
         diagnostics: @escaping @Sendable ([String: String]) -> Void = { _ in }) {
        self.online = online
        self.local = local
        self.operationID = operationID
        self.diagnostics = diagnostics
        self.secondaryWait = min(max(secondaryWait, .zero), .seconds(2))
        self.finishTimeout = min(max(finishTimeout, .zero), .seconds(20))
        local.onPartial = nil
        online.onPartial = { [weak self] text in
            guard let self else { return }
            let callback = self.lock.withLock {
                self.cancelled || self.completed || self.onlineResult != nil ? nil : self.partial
            }
            // State is checked when the queued main-actor preview actually executes.
            // No suspension separates the snapshot and delivery, so main-actor cancel
            // cannot interleave. A background cancel can race an already-started
            // delivery; it is deliberately not a blocking UI callback barrier.
            callback?(text)
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        // Check each route immediately before feeding it: failure can arrive while the
        // other route copies this buffer. Never hold the state lock across provider code.
        // An already-started feed may race failure; cancel stops that provider's upload.
        if lock.withLock({ !cancelled && !started && localResult == nil }) {
            local.feed(buffer)
        }
        if lock.withLock({ !cancelled && !started && onlineResult == nil }) {
            online.feed(buffer)
        }
    }

    /// Route real provider errors here, including errors received while recording.
    /// These methods are thread-safe and cancel only the failed route. Recording length
    /// alone is not a failure; the finish deadlines begin only when `finish` is called.
    func onlineFailed(_ error: any Error) { receive(.failure(error), from: .online) }
    func localFailed(_ error: any Error) { receive(.failure(error), from: .local) }

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
        var completion: Completion?
        let rejection: (any Error)? = lock.withLock {
            guard !cancelled else { return CancellationError() }
            guard !started else { return FinishError.alreadyFinished }
            started = true
            waiter = continuation
            let end = ContinuousClock.now.advanced(by: finishTimeout)
            deadline = end
            // Deliberately unstructured: neither timeout nor cancellation joins a
            // recognizer that ignores task cancellation (e.g. synchronous inference).
            if localResult == nil {
                tasks.append(Task.detached { [weak self, local, diagnostics, operationID] in
                    guard self?.canFinish(.local) == true else { return }
                    let result = await Self.finishRecognizer(local, samples: samples, engine: "qwen",
                                                             operationID: operationID, diagnostics: diagnostics)
                    self?.receive(result, from: .local)
                })
            }
            if onlineResult == nil {
                tasks.append(Task.detached { [weak self, online, diagnostics, operationID] in
                    guard self?.canFinish(.online) == true else { return }
                    let result = await Self.finishRecognizer(online, samples: samples, engine: "doubao",
                                                             operationID: operationID, diagnostics: diagnostics)
                    self?.receive(result, from: .online)
                })
            }
            if localResult != nil, onlineResult != nil {
                completion = completeLocked(bestResultLocked())
            } else {
                scheduleDeadlineLocked(end)
            }
            return nil
        }
        if let rejection { continuation.resume(throwing: rejection) }
        completion?.run()
    }

    /// Logs actual provider finish duration, including a late return after the session
    /// deadline. A hung provider has only a start event. Never logs speech or error text.
    /// The injected sink runs on the worker, outside the session lock, and must not block.
    private static func finishRecognizer(_ recognizer: any TranscriptionSession, samples: [Float],
                                         engine: String, operationID: String,
                                         diagnostics: @Sendable ([String: String]) -> Void) async -> TranscriptResult {
        let start = ContinuousClock.now
        func trace(_ stage: String, duration: Duration) {
            let components = duration.components
            let milliseconds = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
            diagnostics(["operation_id": operationID, "engine": engine, "stage": stage,
                         "duration_ms": String(milliseconds)])
        }
        trace("enhanced_finish_started", duration: .zero)
        do {
            try Task.checkCancellation()
            let text = try await recognizer.finish(samples: samples)
            trace("enhanced_finish_completed", duration: start.duration(to: .now))
            return .success(text)
        } catch {
            trace("enhanced_finish_failed", duration: start.duration(to: .now))
            return .failure(error)
        }
    }

    private func scheduleDeadlineLocked(_ end: ContinuousClock.Instant) {
        tasks.append(Task.detached { [weak self] in
            do { try await ContinuousClock().sleep(until: end) }
            catch { return }
            self?.expire()
        })
    }

    private func canFinish(_ source: Source) -> Bool {
        lock.withLock { !cancelled && !completed && resultLocked(from: source) == nil }
    }

    private func resultLocked(from source: Source) -> TranscriptResult? {
        switch source {
        case .local: localResult
        case .online: onlineResult
        }
    }

    private func receive(_ result: TranscriptResult, from source: Source) {
        var failedRecognizer: (any TranscriptionSession)?
        let work: Completion? = lock.withLock {
            guard !completed, !cancelled else { return nil }
            let now = ContinuousClock.now
            // A delayed watchdog must not allow a result arriving after the deadline
            // to replace the first success or mutate the published secondary text.
            if let deadline, now >= deadline { return completeLocked(bestResultLocked()) }
            // An onError callback can precede finish's return (or cancellation). Keep
            // the first terminal outcome and ignore duplicates and late successes.
            guard resultLocked(from: source) == nil else { return nil }
            switch source {
            case .local: localResult = result
            case .online: onlineResult = result
            }
            if case .failure = result {
                failedRecognizer = source == .local ? local : online
            }
            // Recording-time failures disable only their route. Even when both fail,
            // retain the errors until finish installs its continuation.
            guard let deadline else { return nil }
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
        // State is terminal before cancelling: provider cancellation may itself report
        // an error synchronously. Never call provider code while holding the state lock.
        failedRecognizer?.cancel()
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
