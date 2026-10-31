import Foundation

/// One native execution boundary for an entire recorder lifetime. A deadline can
/// release callers, but cannot safely kill a HAL call. Keep its queue/resources
/// alive and permanently refuse new work rather than spawning replacement workers.
final class AudioOperationQueue: @unchecked Sendable {
    static let unresponsive = "The microphone is not responding. Quit and reopen Talkless, then try again."
    private let queue = DispatchQueue(label: "Talkless.native-audio", qos: .userInitiated)
    private let deadlines = DispatchQueue(label: "Talkless.audio-deadlines", qos: .userInitiated)
    private let lock = NSLock()
    private var operations: [UUID: Operation] = [:]
    private var cleanupPending = false
    private var poisoned = false

    private final class Operation: @unchecked Sendable {
        let id = UUID()
        var fail: (@Sendable (Error) -> Void)?
        var cancelled = false
        let timeout: @Sendable () -> Void
        init(timeout: @escaping @Sendable () -> Void) { self.timeout = timeout }
    }

    func run<Value: Sendable>(
        timeout: TimeInterval,
        onTimeout: @escaping @Sendable () -> Void,
        work: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let operation = Operation(timeout: onTimeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let rejection: Error? = lock.withLock {
                    if poisoned { return TalklessError.message(L10n.tr(Self.unresponsive)) }
                    if operation.cancelled { return CancellationError() }
                    operation.fail = { continuation.resume(throwing: $0) }
                    operations[operation.id] = operation
                    // Submission is serialized with cancellation/cleanup submission.
                    queue.async { [self] in
                        let result: Result<Value, Error>
                        if lock.withLock({ operation.cancelled || poisoned }) { result = .failure(CancellationError()) }
                        else { result = Result { try work() } }
                        let resume = lock.withLock {
                            operations.removeValue(forKey: operation.id)
                            let resume = operation.fail != nil
                            operation.fail = nil
                            return resume
                        }
                        if resume { continuation.resume(with: result) }
                    }
                    return nil
                }
                if let rejection { continuation.resume(throwing: rejection); return }
                scheduleDeadline(operation, seconds: timeout)
            }
        } onCancel: {
            // Leave its deadline alive until the native call actually returns.
            let fail = self.lock.withLock {
                operation.cancelled = true
                let fail = operation.fail
                operation.fail = nil
                return fail
            }
            fail?(CancellationError())
        }
    }

    /// Resolve callers immediately. Cleanup stays behind the in-flight native call;
    /// repeated cancellation cannot add unbounded cleanup jobs or native workers.
    func cancel(cleanup: @escaping @Sendable () -> Void, onTimeout: @escaping @Sendable () -> Void) {
        let result = lock.withLock { () -> (Operation?, [@Sendable (Error) -> Void]) in
            var failures: [@Sendable (Error) -> Void] = []
            for operation in operations.values {
                operation.cancelled = true
                if let fail = operation.fail { failures.append(fail) }
                operation.fail = nil
            }
            guard !cleanupPending else { return (nil, failures) }
            cleanupPending = true
            let operation = Operation(timeout: onTimeout)
            operations[operation.id] = operation
            queue.async { [self] in
                cleanup() // Also allowed after poison: release ONLY on the owning queue.
                lock.withLock {
                    operations.removeValue(forKey: operation.id)
                    cleanupPending = false
                }
            }
            return (operation, failures)
        }
        result.1.forEach { $0(CancellationError()) }
        if let operation = result.0 { scheduleDeadline(operation, seconds: 3) }
    }

    private func scheduleDeadline(_ operation: Operation, seconds: TimeInterval) {
        deadlines.asyncAfter(deadline: .now() + seconds) { [self] in
            let result = lock.withLock { () -> (Bool, [@Sendable (Error) -> Void]) in
                guard operations[operation.id] != nil, !poisoned else { return (false, []) }
                poisoned = true
                var failures: [@Sendable (Error) -> Void] = []
                for pending in operations.values {
                    pending.cancelled = true
                    if let fail = pending.fail { failures.append(fail) }
                    pending.fail = nil
                }
                return (true, failures)
            }
            guard result.0 else { return }
            operation.timeout()
            let error = TalklessError.message(L10n.tr(Self.unresponsive))
            result.1.forEach { $0(error) }
        }
    }
}
