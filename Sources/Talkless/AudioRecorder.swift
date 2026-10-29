import AVFoundation
import CoreAudio
import Foundation

/// Capture audio from the default microphone and convert it to 16 kHz mono Float32.
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

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var accepting = false
    private var samples: [Float] = []
    private var bufferCallback: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var levelCallback: (@Sendable (Float) -> Void)?

    var isRunning: Bool { lock.withLock { accepting } }

    @MainActor
    func start() throws {
        stop()
        // An input node can advertise a fallback format even when no input device exists.
        // Check Core Audio before touching inputNode, whose tap can otherwise raise NSException.
        try Self.requireDefaultInputDevice()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw TalklessError.message("No available microphone found")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.format) else {
            throw TalklessError.message("Cannot convert the microphone audio format")
        }
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            self.converter = converter
            self.engine = engine
            accepting = true
        }
        // AVAudioNodeTapBlock is non-Sendable; explicitly opt out of inherited MainActor isolation.
        // Core Audio invokes the tap on its audio thread, not the main actor.
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { @Sendable [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        do { try engine.start() }
        catch { stop(); throw error }
    }

    @MainActor
    @discardableResult
    func stop() -> [Float] {
        let engine = lock.withLock { self.engine }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        return lock.withLock {
            accepting = false
            self.engine = nil
            converter = nil
            return samples
        }
    }

    var duration: TimeInterval {
        lock.withLock { Double(samples.count) / Self.sampleRate }
    }

    private static func requireDefaultInputDevice() throws {
        let unavailable = TalklessError.message("No available microphone found. Connect a microphone and select it in System Settings › Sound › Input.")
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { throw unavailable }

        address.mSelector = kAudioDevicePropertyStreamConfiguration
        address.mScope = kAudioDevicePropertyScopeInput
        size = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { throw unavailable }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else {
            throw unavailable
        }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        guard buffers.contains(where: { $0.mNumberChannels > 0 }) else { throw unavailable }
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
