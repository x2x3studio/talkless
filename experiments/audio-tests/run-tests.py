#!/usr/bin/env python3
"""Compile production recorder and exercise its tap without microphone access.

Run: python3 -I experiments/audio-tests/run-tests.py
AVAudioEngine and Core Audio device queries are stubbed in the runtime test.
AVAudioConverter and buffers are real, and the production tap closure still
originates in @MainActor start().
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/Talkless/AudioRecorder.swift"

HARNESS = r'''
private enum TestHardware {
    nonisolated(unsafe) static var device: AudioDeviceID = 42
    nonisolated(unsafe) static var channels: UInt32 = 2
    nonisolated(unsafe) static var status: OSStatus = noErr
    nonisolated(unsafe) static var enginesCreated = 0
}
private func TestGetPropertyDataSize(_ object: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qualifierSize: UInt32,
    _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>) -> OSStatus {
    size.pointee = UInt32(MemoryLayout<AudioBufferList>.size)
    return TestHardware.status
}
private func TestGetPropertyData(_ object: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qualifierSize: UInt32,
    _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutableRawPointer) -> OSStatus {
    guard TestHardware.status == noErr else { return TestHardware.status }
    if address.pointee.mSelector == kAudioHardwarePropertyDefaultInputDevice {
        data.assumingMemoryBound(to: AudioDeviceID.self).pointee = TestHardware.device
    } else {
        precondition(address.pointee.mScope == kAudioDevicePropertyScopeInput)
        data.assumingMemoryBound(to: AudioBufferList.self).pointee = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: TestHardware.channels,
                                 mDataByteSize: 0, mData: nil))
    }
    return noErr
}
// Keep the callback non-Sendable, matching AVAudioNodeTapBlock in the SDK.
private final class TestAudioNode: @unchecked Sendable {
    private var callback: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    func outputFormat(forBus: Int) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                      channels: 2, interleaved: false)!
    }
    func installTap(onBus: Int, bufferSize: UInt32, format: AVAudioFormat?,
                    block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        precondition(callback == nil)
        callback = block
    }
    func removeTap(onBus: Int) { callback = nil }
    func deliver() {
        precondition(!Thread.isMainThread, "Test must invoke tap off main")
        let format = outputFormat(forBus: 0)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for channel in 0..<2 {
            for index in 0..<4_800 { buffer.floatChannelData![channel][index] = 0.25 }
        }
        callback!(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
    }
}
private final class TestAudioEngine {
    init() { TestHardware.enginesCreated += 1 }
    let inputNode = TestAudioNode()
    func prepare() {}
    func start() throws {
        let node = inputNode
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            node.deliver()
            completed.signal()
        }
        precondition(completed.wait(timeout: .now() + 5) == .success,
                     "Audio callback must complete while main actor is blocked")
    }
    func stop() {}
}
private final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers = 0
    private var levels = 0
    func buffer(_ buffer: AVAudioPCMBuffer) {
        precondition(!Thread.isMainThread)
        precondition(buffer.format.sampleRate == 16_000)
        precondition(buffer.format.channelCount == 1)
        precondition(buffer.frameLength > 0)
        lock.withLock { buffers += 1 }
    }
    func level(_ level: Float) {
        precondition(!Thread.isMainThread)
        precondition(level.isFinite && (0...1).contains(level))
        lock.withLock { levels += 1 }
    }
    func check() {
        lock.withLock { precondition(buffers == 3 && levels == 3) }
    }
}
@main struct Tests {
    @MainActor static func main() throws {
        let recorder = AudioRecorder()
        for unavailable in 0..<3 {
            TestHardware.device = unavailable == 0 ? 0 : 42
            TestHardware.channels = unavailable == 1 ? 0 : 2
            TestHardware.status = unavailable == 2 ? -1 : noErr
            do {
                try recorder.start()
                fatalError("Unavailable microphone must throw")
            } catch is TalklessError {}
            precondition(!recorder.isRunning)
            precondition(TestHardware.enginesCreated == 0,
                         "Must reject unavailable input before constructing audio engine")
        }
        TestHardware.device = 42
        TestHardware.channels = 2
        TestHardware.status = noErr
        print("PASS missing default device, no input channels, and Core Audio query failure")
        let observations = Observations()
        recorder.onBuffer = { observations.buffer($0) }
        recorder.onLevel = { observations.level($0) }
        for _ in 0..<3 {
            try recorder.start()
            precondition(recorder.isRunning)
            let samples = recorder.stop()
            precondition(!recorder.isRunning)
            // Resampler priming can reduce the first converted buffer's length.
            precondition(!samples.isEmpty && samples.count <= 1_600,
                         "Unexpected converted sample count: \(samples.count)")
            precondition(samples.allSatisfy { $0.isFinite })
            precondition(AudioRecorder.wavData(from: samples).count == 44 + samples.count * 2)
        }
        observations.check()
        print("PASS background tap, real 48 kHz stereo conversion, callbacks, stop/restart, WAV")
    }
}
'''


def run(*args):
    subprocess.run(args, check=True)


def tap_sil(source, directory, name):
    swift = directory / (name + ".swift")
    sil = directory / (name + ".sil")
    swift.write_text(source)
    run("xcrun", "swiftc", "-swift-version", "6", "-O", "-emit-sil", str(swift), "-o", str(sil))
    text = sil.read_text()
    # Find the actual callback function definition, not a reference to it.
    matches = re.findall(r"^// closure #\d+ in AudioRecorder\.start\(\)\n.*?^} // end sil function[^\n]*", text, re.M | re.S)
    taps = [body for body in matches if "AVAudioPCMBuffer" in body.split("\nbb0(", 1)[0]]
    assert len(taps) == 1, "Could not identify production audio tap in compiler SIL"
    return taps[0]


with tempfile.TemporaryDirectory(prefix="talkless-audio-tests-") as work:
    directory = Path(work)
    source = SOURCE.read_text()
    current = tap_sil(source, directory, "current")
    assert "// Isolation: nonisolated" in current
    assert "swift_task_isCurrentExecutor" not in current
    assert "swift_task_reportUnexpectedExecutor" not in current
    print("PASS production tap has no MainActor executor assertion", flush=True)

    # Negative control proves the test detects the original bug, without running
    # a deliberately crashing process or generating misleading crash reports.
    original = source.replace("{ @Sendable [weak self] buffer, _ in", "{ [weak self] buffer, _ in")
    assert original != source, "Explicit Sendable tap annotation is missing"
    baseline = tap_sil(original, directory, "baseline")
    assert "// Isolation: global_actor. type: MainActor" in baseline
    assert "swift_task_isCurrentExecutor" in baseline
    assert "swift_task_reportUnexpectedExecutor" in baseline
    print("PASS negative control detects the original main-actor tap assertion", flush=True)

    runtime = directory / "runtime.swift"
    stubbed = source.replace("AVAudioEngine", "TestAudioEngine")
    stubbed = stubbed.replace("AudioObjectGetPropertyDataSize", "TestGetPropertyDataSize")
    stubbed = stubbed.replace("AudioObjectGetPropertyData", "TestGetPropertyData")
    runtime.write_text(stubbed + HARNESS)
    executable = directory / "audio-tests"
    run("xcrun", "swiftc", "-swift-version", "6", "-O", "-parse-as-library", str(runtime), "-o", str(executable))
    run(str(executable))
