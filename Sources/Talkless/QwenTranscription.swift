import AVFoundation
import Foundation
import MLX
import MLXAudioSTT

/// In-process Qwen3-ASR. The live window is replaceable, not an append-only transcript.
/// No VAD or silence gate: every captured sample reaches a decode window.
final class QwenTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    var onPartial: (@MainActor @Sendable (String) -> Void)? {
        get { state.lock.withLock { state.onPartial } }
        set { state.lock.withLock { state.onPartial = newValue } }
    }

    private let state: QwenCaptureState
    private let worker: Task<String, Error>

    /// Returns immediately; loading and inference never run on the audio/main thread.
    init(
        modelDirectory: URL,
        language: String? = nil,
        contextualStrings: [String] = [],
        onStatus: @escaping @MainActor @Sendable (String) -> Void = { _ in },
        onError: @escaping @MainActor @Sendable (String) -> Void = { _ in }
    ) {
        let state = QwenCaptureState()
        self.state = state
        worker = Task.detached(priority: .userInitiated) {
            do {
                return try await state.run(
                    modelDirectory: modelDirectory,
                    language: language,
                    context: contextualStrings.joined(separator: ", "),
                    onStatus: onStatus
                )
            } catch {
                if !(error is CancellationError) {
                    await state.reportError(error.localizedDescription, to: onError)
                }
                throw error
            }
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        guard buffer.format.sampleRate == 16_000,
              buffer.format.channelCount == 1,
              buffer.format.commonFormat == .pcmFormatFloat32,
              let channel = buffer.floatChannelData?[0] else {
            state.fail(TalklessError.message("Qwen recognition requires 16 kHz mono Float32 audio"))
            return
        }
        // AVAudioPCMBuffer belongs to the recorder. Only its value copy crosses threads.
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        state.enqueue(samples)
    }

    func finish(samples: [Float]) async throws -> String {
        state.close(samples: samples)
        let completion = QwenFinishCompletion()
        let worker = self.worker
        let state = self.state
        let resultTask = Task.detached {
            completion.resolve(await worker.result)
        }
        let watchdog = Task.detached {
            do { try await Task.sleep(for: .seconds(60)) }
            catch { return }
            state.cancel()
            worker.cancel()
            completion.resolve(.failure(TalklessError.message("Qwen transcription timed out; please try again")))
        }
        defer { watchdog.cancel(); resultTask.cancel() }
        return try await withTaskCancellationHandler {
            let result = try await completion.value()
            try Task.checkCancellation()
            return result
        } onCancel: {
            state.cancel()
            worker.cancel()
            completion.resolve(.failure(CancellationError()))
        }
    }

    func cancel() {
        state.cancel()
        worker.cancel()
    }

    deinit {
        state.cancel()
        worker.cancel()
    }

    /// Optional prewarming; the same singleton model is reused by subsequent sessions.
    static func prepareAssets(modelDirectory: URL) async throws {
        try await QwenModelRuntime.shared.prepare(modelDirectory: modelDirectory)
    }
}

/// An unstructured race: a task group would wait for uninterruptible MLX work on timeout.
private final class QwenFinishCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?

    func resolve(_ value: Result<String, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<String, Error>? in
            guard result == nil else { return nil }
            result = value
            let continuation = waiter
            waiter = nil
            return continuation
        }
        continuation?.resume(with: value)
    }

    func value() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let ready = lock.withLock { () -> Result<String, Error>? in
                if let result { return result }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}

/// Sole MLX owner. Cancellation discards a synchronous decode; the next decode waits.
private actor QwenModelRuntime {
    static let shared = QwenModelRuntime()

    // The box only crosses the initial loading-task boundary; model access stays here.
    private final class LoadedModel: @unchecked Sendable {
        let directory: URL
        let model: Qwen3ASRModel
        init(directory: URL, model: Qwen3ASRModel) {
            self.directory = directory
            self.model = model
        }
    }
    private var loaded: LoadedModel?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    // Actor reentrancy also needs an explicit gate while the async tokenizer loads.
    // Keep it held through generation, so even a model-directory change cannot race
    // an old decode. Cancelled waiters acquire, check cancellation, and release it.
    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    func prepare(modelDirectory: URL) async throws {
        await acquire()
        defer { release() }
        _ = try await model(at: modelDirectory)
        try Task.checkCancellation()
    }

    /// Called only while holding the operation gate.
    private func model(at directory: URL) async throws -> LoadedModel {
        let directory = directory.standardizedFileURL
        try Task.checkCancellation()
        if let loaded, loaded.directory == directory { return loaded }
        loaded = nil
        let result = try await Task.detached(priority: .userInitiated) {
            let files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
            guard files.contains(where: { $0.pathExtension == "safetensors" }) else {
                throw TalklessError.message("No safetensors weights found in the Qwen model directory")
            }
            let model = try await Qwen3ASRModel.fromModelDirectory(directory)
            return LoadedModel(directory: directory, model: model)
        }.value
        loaded = result
        return result
    }

    func decode(
        samples: [Float], modelDirectory: URL, language: String?, context: String
    ) async throws -> String {
        await acquire()
        defer { release() }
        let loaded = try await model(at: modelDirectory)
        try Task.checkCancellation()
        guard !samples.isEmpty else { return "" }
        let output = loaded.model.generate(
            audio: MLXArray(samples),
            maxTokens: 512,
            temperature: 0,
            context: context,
            language: language,
            // Our own windows are <=30 seconds. Disable the library's long-file splitter.
            chunkDuration: 1200,
            minChunkDuration: 1,
            repetitionPenalty: 1
        )
        try Task.checkCancellation()
        guard output.generationTokens < 512 else {
            throw TalklessError.message("Qwen reached the output limit for one window; try a shorter dictation")
        }
        return output.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Only the small inbox/callback/lifecycle fields below are shared. Window/text state
/// lives exclusively in run(). Wakeups are coalesced, audio is never coalesced or dropped.
private final class QwenCaptureState: @unchecked Sendable {
    let lock = NSLock()
    var onPartial: (@MainActor @Sendable (String) -> Void)?
    private var pending: [[Float]] = []
    private var pendingSamples = 0
    private let maxPendingSamples = 120 * 16_000
    private var receivedSamples = 0
    private var closed = false
    private var cancelled = false
    private var failure: (any Error)?
    private let wakeups: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (wakeups, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func enqueue(_ samples: [Float]) {
        lock.withLock {
            guard !closed, !cancelled else { return }
            guard pendingSamples + samples.count <= maxPendingSamples else {
                failLocked(TalklessError.message("Qwen stopped after the audio backlog exceeded 120 seconds; try a shorter dictation"))
                return
            }
            pending.append(samples)
            pendingSamples += samples.count
            receivedSamples += samples.count
            continuation.yield(())
        }
    }

    func close(samples: [Float]) {
        lock.withLock {
            guard !closed, !cancelled else { return }
            // Recover only missing tail samples, never re-recognize committed windows.
            if samples.count > receivedSamples {
                let missing = samples.count - receivedSamples
                guard pendingSamples + missing <= maxPendingSamples else {
                    failLocked(TalklessError.message("Qwen stopped after the audio backlog exceeded 120 seconds; try a shorter dictation"))
                    return
                }
                pending.append(Array(samples[receivedSamples...]))
                pendingSamples += missing
                receivedSamples = samples.count
            }
            closed = true
            continuation.yield(())
            continuation.finish()
        }
    }

    func fail(_ error: any Error) {
        lock.withLock {
            guard !closed, !cancelled else { return }
            failLocked(error)
        }
    }

    private func failLocked(_ error: any Error) {
        failure = error
        closed = true
        pending.removeAll()
        pendingSamples = 0
        continuation.yield(())
        continuation.finish()
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            closed = true
            pending.removeAll()
            pendingSamples = 0
            onPartial = nil
            continuation.finish()
        }
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        let status = lock.withLock { (cancelled, failure) }
        if status.0 { throw CancellationError() }
        if let error = status.1 { throw error }
    }

    @MainActor
    func reportError(_ message: String, to callback: @MainActor @Sendable (String) -> Void) {
        if !lock.withLock({ cancelled }) { callback(message) }
    }

    @MainActor
    private func publish(_ text: String) {
        let callback = lock.withLock { cancelled ? nil : onPartial }
        callback?(text)
    }

    func run(
        modelDirectory: URL, language: String?, context: String,
        onStatus: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> String {
        defer {
            lock.withLock {
                closed = true
                pending.removeAll()
                pendingSamples = 0
                continuation.finish()
            }
        }
        try checkCancellation()
        await MainActor.run {
            if !self.lock.withLock({ self.cancelled }) { onStatus("Loading the Qwen speech model…") }
        }
        try await QwenModelRuntime.shared.prepare(modelDirectory: modelDirectory)
        try checkCancellation()
        await MainActor.run {
            if !self.lock.withLock({ self.cancelled }) { onStatus("Local Qwen recognition is ready") }
        }

        let windowSamples = 30 * 16_000
        let decodeIntervalSamples = 2 * 16_000
        var audio: [Float] = []
        var committed = ""
        var liveText = ""
        var decodedSamples = 0

        for await _ in wakeups {
            try checkCancellation()
            let inbox = lock.withLock { () -> ([[Float]], Bool, (any Error)?) in
                let frames = pending
                pending = []
                pendingSamples = 0
                return (frames, closed, failure)
            }
            if let error = inbox.2 { throw error }
            for frame in inbox.0 { audio.append(contentsOf: frame) }

            while audio.count >= windowSamples {
                let cut = Self.commitBoundary(in: audio, limit: windowSamples)
                let text: String
                if decodedSamples == cut {
                    text = liveText
                } else {
                    text = try await QwenModelRuntime.shared.decode(
                        samples: Array(audio[..<cut]), modelDirectory: modelDirectory,
                        language: language, context: context
                    )
                }
                try checkCancellation()
                committed = Self.join(committed, text)
                // Non-overlapping acoustic ranges: retain ALL audio after the boundary.
                audio.removeFirst(cut)
                decodedSamples = 0
                liveText = ""
                await publish(committed)
            }

            if inbox.1 {
                if !audio.isEmpty, decodedSamples != audio.count {
                    liveText = try await QwenModelRuntime.shared.decode(
                        samples: audio, modelDirectory: modelDirectory,
                        language: language, context: context
                    )
                }
                try checkCancellation()
                let final = Self.join(committed, liveText)
                await publish(final)
                return final
            }

            // Skip stale intermediate snapshots when inference was slower than capture.
            // The next wakeup drains all accumulated PCM, rather than queueing every decode.
            if audio.count - decodedSamples >= decodeIntervalSamples {
                liveText = try await QwenModelRuntime.shared.decode(
                    samples: audio, modelDirectory: modelDirectory,
                    language: language, context: context
                )
                try checkCancellation()
                decodedSamples = audio.count
                await publish(Self.join(committed, liveText))
            }
        }
        try checkCancellation()
        throw TalklessError.message("The Qwen recognition session ended before completion")
    }

    /// Prefer the latest >=120ms low-energy run in the last five seconds of a 30s window.
    /// This ONLY chooses a cut; it is not VAD, endpointing, or removal of silence.
    /// Continuous speech without a clear dip still has a hard 30s boundary and may split a word.
    private static func commitBoundary(in audio: [Float], limit: Int) -> Int {
        let frameSamples = 320
        let frameCount = limit / frameSamples
        var energy = [Float](repeating: 0, count: frameCount)
        for index in 0..<frameCount {
            let start = index * frameSamples
            var sum: Float = 0
            for sample in audio[start..<(start + frameSamples)] { sum += sample * sample }
            energy[index] = sum / Float(frameSamples)
        }
        let median = energy.sorted()[frameCount / 2]
        let threshold = median * 0.01
        let lookbackFrames = 5 * 16_000 / frameSamples
        let searchStart = max(0, frameCount - lookbackFrames)
        var runStart: Int?
        var bestCut: Int?
        for index in searchStart...frameCount {
            if index < frameCount, energy[index] <= threshold {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                if index - start >= 6 {
                    bestCut = index == frameCount ? limit : ((start + index) / 2) * frameSamples
                }
                runStart = nil
            }
        }
        return bestCut ?? limit
    }

    /// Join disjoint windows, without fuzzy deduplication that could erase genuine repetition.
    private static func join(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        func isUnspaced(_ scalar: Unicode.Scalar?) -> Bool {
            guard let value = scalar?.value else { return false }
            return (0x2E80...0x9FFF).contains(value)
                || (0xF900...0xFAFF).contains(value)
                || (0xFF00...0xFFEF).contains(value)
                || (0x20000...0x323AF).contains(value)
        }
        let separator = isUnspaced(left.unicodeScalars.last) || isUnspaced(right.unicodeScalars.first) ? "" : " "
        return left + separator + right
    }
}
