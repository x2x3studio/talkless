import AVFoundation

/// One recognition session per dictation: call `feed` while recording, then `finish` for the full transcript.
protocol TranscriptionSession: AnyObject, Sendable {
    /// Live preview (local or online streaming recognition), delivered on the main thread.
    var onPartial: (@MainActor @Sendable (String) -> Void)? { get set }
    /// Called on the audio thread.
    func feed(_ buffer: AVAudioPCMBuffer)
    func finish(samples: [Float]) async throws -> String
    func cancel()
}
