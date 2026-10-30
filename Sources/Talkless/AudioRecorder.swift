import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Capture audio from the chosen microphone and convert it to 16 kHz mono Float32.
final class AudioRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
    )!

    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { lock.withLock { bufferCallback } }
        set { lock.withLock { bufferCallback = newValue } }
    }
    var onLevel: (@Sendable (Float) -> Void)? {
        get { lock.withLock { levelCallback } }
        set { lock.withLock { levelCallback = newValue } }
    }

    var onError: (@MainActor @Sendable (String) -> Void)? {
        get { lock.withLock { errorCallback } }
        set { lock.withLock { errorCallback = newValue } }
    }
    /// A finish action can inspect this before finalizing a partial streaming transcript.
    var interruptionError: String? { lock.withLock { recordingError } }

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var accepting = false
    private var samples: [Float] = []
    private var bufferCallback: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var levelCallback: (@Sendable (Float) -> Void)?
    private var errorCallback: (@MainActor @Sendable (String) -> Void)?
    private var configurationObserver: NSObjectProtocol?
    private var sessionID: UUID?
    private var recordingError: String?

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
    }

    var isRunning: Bool { lock.withLock { accepting } }

    @MainActor
    func start(deviceUID: String? = nil) throws {
        stop()
        lock.withLock { recordingError = nil }
        // Resolve before touching inputNode: it can advertise a fallback format even with
        // no hardware, and installing a tap in that state can raise NSException.
        var device = try AudioInputDevices.resolve(uid: deviceUID)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Set this engine's input only, before reading formats or building its converter.
        // Pin even System default to the device resolved for this recording session.
        guard let audioUnit = input.audioUnit else {
            throw TalklessError.message(L10n.tr("Cannot configure the microphone audio input"))
        }
        let status = AudioUnitSetProperty(
            audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &device, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw TalklessError.message(L10n.format("Cannot use the selected microphone (Core Audio error %d). Reconnect it or choose another microphone in Settings › Dictation › Audio.", status))
        }
        // The input scope reflects hardware; the output scope may still cache the previous
        // device's client format. Input nodes cannot convert between those formats.
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw TalklessError.message(L10n.tr("No available microphone found"))
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.format) else {
            throw TalklessError.message(L10n.tr("Cannot convert the microphone audio format"))
        }
        let sessionID = UUID()
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            self.converter = converter
            self.engine = engine
            self.sessionID = sessionID
            accepting = true
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { @Sendable [weak self] _ in
            self?.configurationChanged(sessionID: sessionID)
        }
        // AVAudioNodeTapBlock is non-Sendable; explicitly opt out of inherited MainActor isolation.
        // Core Audio invokes the tap on its audio thread, not the main actor.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { @Sendable [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
            if let interruptionError { throw TalklessError.message(interruptionError) }
        } catch { stop(); throw error }
    }

    @MainActor
    @discardableResult
    func stop() -> [Float] {
        let engine = lock.withLock {
            // Close the gate before teardown can send a configuration notification. Taking
            // this lock also waits for any in-flight conversion/callback to finish.
            accepting = false
            sessionID = nil
            return self.engine
        }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        return lock.withLock {
            self.engine = nil
            converter = nil
            return samples
        }
    }

    private func configurationChanged(sessionID: UUID) {
        let message = L10n.tr("Microphone recording was interrupted because the audio device changed or disconnected. Check your microphone and start again.")
        let shouldReport = lock.withLock {
            guard self.sessionID == sessionID, accepting else { return false }
            accepting = false
            recordingError = message
            samples.removeAll(keepingCapacity: true)
            return true
        }
        guard shouldReport else { return }
        // Core Audio calls on an internal queue. Never tear down/deallocate its engine
        // there; defer teardown and the UI callback, then reject stale session events.
        Task { @MainActor [weak self] in
            guard let self else { return }
            let current = self.lock.withLock { self.sessionID == sessionID }
            guard current else { return }
            self.stop()
            self.onError?(message)
        }
    }

    var duration: TimeInterval {
        lock.withLock { Double(samples.count) / Self.sampleRate }
    }

    private func process(_ buffer: AVAudioPCMBuffer) {
        // stop() waits for conversion and enqueueing so finalization cannot overtake the last callback.
        lock.withLock {
            guard accepting, let converter else { return }
            let ratio = Self.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let data = out.floatChannelData?[0] else { return }
            let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
            samples.append(contentsOf: chunk)
            let sum = chunk.reduce(Float(0)) { $0 + $1 * $1 }
            let db = 20 * log10(max(sqrt(sum / Float(chunk.count)), 1e-6))
            levelCallback?(max(0, min(1, (db + 50) / 40)))
            bufferCallback?(out)
        }
    }

    static func wavData(from samples: [Float]) -> Data {
        var data = Data()
        let byteCount = UInt32(samples.count * 2)
        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(byteCount)
        data.reserveCapacity(data.count + Int(byteCount))
        for s in samples { append(Int16(max(-1, min(1, s)) * Float(Int16.max))) }
        return data
    }
}

enum TalklessError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
