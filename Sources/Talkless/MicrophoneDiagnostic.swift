import AVFoundation
import Foundation

/// Opt-in microphone smoke test. Never requests access, saves audio, or runs recognition.
@MainActor
enum MicrophoneDiagnostic {
    static func run(seconds: Double = 3) async throws -> Int {
        guard seconds.isFinite, seconds > 0, seconds <= 30 else {
            throw TalklessError.message("Microphone test duration must be between 0 and 30 seconds")
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw TalklessError.message("Microphone test requires existing microphone permission")
        }
        let recorder = AudioRecorder()
        let counter = BufferCounter()
        recorder.onBuffer = { buffer in
            counter.record(frameCount: Int(buffer.frameLength), offMain: !Thread.isMainThread)
        }
        try recorder.start()
        defer { recorder.stop() }
        try await Task.sleep(for: .seconds(seconds))
        recorder.stop()
        if let interruption = recorder.interruptionError {
            throw TalklessError.message(interruption)
        }
        let result = counter.snapshot()
        guard result.buffers > 0, result.frames > 0 else {
            throw TalklessError.message("Microphone test received no audio buffers")
        }
        guard result.offMainBuffers == result.buffers else {
            throw TalklessError.message("Microphone test unexpectedly received an audio callback on the main thread")
        }
        return result.buffers
    }

    private final class BufferCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var buffers = 0
        private var frames = 0
        private var offMainBuffers = 0

        func record(frameCount: Int, offMain: Bool) {
            lock.withLock {
                buffers += 1
                frames += frameCount
                if offMain { offMainBuffers += 1 }
            }
        }

        func snapshot() -> (buffers: Int, frames: Int, offMainBuffers: Int) {
            lock.withLock { (buffers, frames, offMainBuffers) }
        }
    }
}
