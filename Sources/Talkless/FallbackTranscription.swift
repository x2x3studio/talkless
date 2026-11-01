import AVFoundation
import Foundation

/// Keeps the online preview, but never combines it with local text. The recorder owns the
/// complete PCM snapshot; after an online failure the local recognizer gets that snapshot once.
final class FallbackTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    typealias Factory = @Sendable () throws -> any TranscriptionSession
    private let online: any TranscriptionSession
    private let makeLocal: Factory
    private let onFallback: @MainActor @Sendable () -> Void
    private let lock = NSLock()
    private var local: (any TranscriptionSession)?
    private var cancelled = false
    private var fallingBack = false
    private var partial: (@MainActor @Sendable (String) -> Void)?

    var onPartial: (@MainActor @Sendable (String) -> Void)? {
        get { lock.withLock { partial } }
        set { lock.withLock { partial = newValue } }
    }

    init(online: any TranscriptionSession, makeLocal: @escaping Factory,
         onFallback: @escaping @MainActor @Sendable () -> Void) {
        self.online = online
        self.makeLocal = makeLocal
        self.onFallback = onFallback
        online.onPartial = { [weak self] text in
            guard let self else { return }
            let callback = self.lock.withLock { self.cancelled || self.fallingBack ? nil : self.partial }
            callback?(text)
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard !lock.withLock({ cancelled || fallingBack }) else { return }
        online.feed(buffer)
    }

    func finish(samples: [Float]) async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !lock.withLock({ cancelled }) else { throw CancellationError() }
            do {
                let result = try await online.finish(samples: samples)
                try Task.checkCancellation()
                guard !lock.withLock({ cancelled }) else { throw CancellationError() }
                return result
            } catch {
                if error is CancellationError || Task.isCancelled || lock.withLock({ cancelled }) {
                    throw CancellationError()
                }
                lock.withLock { fallingBack = true }
                online.cancel()
                await onFallback()
                try Task.checkCancellation()
                guard !lock.withLock({ cancelled }) else { throw CancellationError() }
                let recognizer = try makeLocal()
                let accepted = lock.withLock {
                    guard !cancelled else { return false }
                    local = recognizer
                    return true
                }
                guard accepted else { recognizer.cancel(); throw CancellationError() }
                recognizer.onPartial = { [weak self] text in
                    guard let self else { return }
                    let callback = self.lock.withLock { self.cancelled ? nil : self.partial }
                    callback?(text)
                }
                // No retry loop: a local failure is reported, not converted to partial output.
                let result = try await recognizer.finish(samples: samples)
                try Task.checkCancellation()
                guard !lock.withLock({ cancelled }) else { throw CancellationError() }
                return result
            }
        } onCancel: { self.cancel() }
    }

    func cancel() {
        let local = lock.withLock {
            cancelled = true
            partial = nil
            return self.local
        }
        online.cancel()
        local?.cancel()
    }
}
