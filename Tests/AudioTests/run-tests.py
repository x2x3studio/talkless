#!/usr/bin/env python3
"""Compile production recorder and exercise its tap without microphone access.

Run: python3 -I Tests/AudioTests/run-tests.py
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
DEVICES = ROOT / "Sources/Talkless/AudioInputDevice.swift"

LOCALIZATION_STUB = r'''
// Extracted recorder fixtures use deterministic English without preferences or resources.
enum L10n {
    static func tr(_ key: String) -> String { key }
    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: key, locale: Locale(identifier: "en"), arguments: args)
    }
}
'''

HARNESS = r'''
private enum TestHardware {
    nonisolated(unsafe) static var device: AudioDeviceID = 42
    nonisolated(unsafe) static var channels: UInt32 = 2
    nonisolated(unsafe) static var status: OSStatus = noErr
    nonisolated(unsafe) static var enginesCreated = 0
    nonisolated(unsafe) static var defaultReads = 0
    nonisolated(unsafe) static var appliedDevice: AudioDeviceID?
    nonisolated(unsafe) static var selectionStatus: OSStatus = noErr
    nonisolated(unsafe) static var hasAudioUnit = true
    nonisolated(unsafe) static var devices: [AudioDeviceID] = [42, 99, 100]
    nonisolated(unsafe) static var selectedID: AudioDeviceID = 99
    nonisolated(unsafe) static var outputChannels: AVAudioChannelCount = 2
    nonisolated(unsafe) static var rate: Double = 48_000
}
private func TestSetProperty(_ unit: AudioUnit, _ property: AudioUnitPropertyID,
    _ scope: AudioUnitScope, _ element: AudioUnitElement, _ data: UnsafeRawPointer,
    _ size: UInt32) -> OSStatus {
    precondition(property == kAudioOutputUnitProperty_CurrentDevice)
    precondition(scope == kAudioUnitScope_Global && element == 0)
    precondition(size == MemoryLayout<AudioDeviceID>.size)
    TestHardware.appliedDevice = data.assumingMemoryBound(to: AudioDeviceID.self).pointee
    return TestHardware.selectionStatus
}
private func TestGetPropertyDataSize(_ object: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qualifierSize: UInt32,
    _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>) -> OSStatus {
    size.pointee = address.pointee.mSelector == kAudioHardwarePropertyDevices
        ? UInt32(TestHardware.devices.count * MemoryLayout<AudioDeviceID>.size)
        : UInt32(MemoryLayout<AudioBufferList>.size)
    return TestHardware.status
}
private func TestGetPropertyData(_ object: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qualifierSize: UInt32,
    _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutableRawPointer) -> OSStatus {
    guard TestHardware.status == noErr else { return TestHardware.status }
    switch address.pointee.mSelector {
    case kAudioHardwarePropertyDefaultInputDevice:
        TestHardware.defaultReads += 1
        data.assumingMemoryBound(to: AudioDeviceID.self).pointee = TestHardware.device
    case kAudioHardwarePropertyDevices:
        for (index, id) in TestHardware.devices.enumerated() {
            data.assumingMemoryBound(to: AudioDeviceID.self)[index] = id
        }
    case kAudioDevicePropertyDeviceUID, kAudioObjectPropertyName:
        let uid = object == TestHardware.selectedID ? "usb-mic" : "built-in"
        let name = object == TestHardware.selectedID ? "USB Microphone" : "Built-in Microphone"
        data.assumingMemoryBound(to: Unmanaged<CFString>?.self).pointee = .passRetained(
            (address.pointee.mSelector == kAudioDevicePropertyDeviceUID ? uid : name) as CFString)
    case kAudioDevicePropertyStreamConfiguration:
        precondition(address.pointee.mScope == kAudioDevicePropertyScopeInput)
        data.assumingMemoryBound(to: AudioBufferList.self).pointee = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: object == 100 ? 0 : TestHardware.channels,
                                 mDataByteSize: 0, mData: nil))
    default: fatalError("Unexpected Core Audio query")
    }
    return noErr
}
// Keep the callback non-Sendable, matching AVAudioNodeTapBlock in the SDK.
private final class TestAudioNode: @unchecked Sendable {
    private var callback: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var audioUnit: AudioUnit? { TestHardware.hasAudioUnit ? AudioUnit(bitPattern: 1) : nil }
    func outputFormat(forBus: Int) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                      channels: 1, interleaved: false)!
    }
    func inputFormat(forBus: Int) -> AVAudioFormat {
        precondition(TestHardware.appliedDevice != nil, "Select device before inspecting format")
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: TestHardware.rate,
                             channels: TestHardware.outputChannels, interleaved: false)!
    }
    func installTap(onBus: Int, bufferSize: UInt32, format: AVAudioFormat?,
                    block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        precondition(callback == nil)
        precondition(format == inputFormat(forBus: 0), "Tap must use selected hardware format, not cached client format")
        callback = block
    }
    func removeTap(onBus: Int) { callback = nil }
    func deliver() {
        precondition(!Thread.isMainThread, "Test must invoke tap off main")
        let format = inputFormat(forBus: 0)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for channel in 0..<2 {
            for index in 0..<4_800 { buffer.floatChannelData![channel][index] = 0.25 }
        }
        callback!(buffer, AVAudioTime(sampleTime: 0, atRate: 48_000))
    }
}
private final class TestAudioEngine: NSObject, @unchecked Sendable {
    nonisolated(unsafe) static var latest: TestAudioEngine?
    override init() {
        super.init()
        TestHardware.enginesCreated += 1
        TestHardware.appliedDevice = nil
        Self.latest = self
    }
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
    func stop() {
        MainActor.assertIsolated()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: self)
    }
    func interrupt() {
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { [self] in
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: self)
            completed.signal()
        }
        precondition(completed.wait(timeout: .now() + 5) == .success,
                     "Configuration observer must not block the Core Audio queue")
    }
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
    @MainActor static func main() async throws {
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
        let listed = try AudioInputDevices.available()
        precondition(listed.map(\.uid) == ["built-in", "usb-mic"])
        precondition(listed.map(\.name) == ["Built-in Microphone", "USB Microphone"])
        print("PASS enumeration keeps named input-capable devices only")
        let defaultReads = TestHardware.defaultReads
        TestHardware.devices = [42, 100]
        do {
            try recorder.start(deviceUID: "usb-mic")
            fatalError("Missing explicit microphone must throw rather than use default")
        } catch let error as TalklessError {
            precondition(error.localizedDescription.contains("selected microphone is unavailable"))
        }
        precondition(TestHardware.enginesCreated == 0)
        precondition(TestHardware.defaultReads == defaultReads)
        precondition(!recorder.isRunning)
        TestHardware.selectedID = 77 // Stable UID, different transient ID after reconnect.
        TestHardware.devices = [42, 77, 100]
        try recorder.start(deviceUID: "usb-mic")
        precondition(TestHardware.appliedDevice == 77)
        precondition(TestHardware.defaultReads == defaultReads)
        TestHardware.device = 0 // Explicit input works even with no default.
        TestHardware.selectedID = 88
        TestHardware.devices = [42, 88, 100]
        precondition(TestHardware.appliedDevice == 77, "No midrecording device mutation")
        try recorder.start(deviceUID: "usb-mic")
        precondition(TestHardware.appliedDevice == 88, "Resolve afresh on next recording")
        recorder.stop()
        TestHardware.device = 42
        print("PASS explicit selection, unplug error/no fallback, reconnect UID resolution, next-session changes")
        TestHardware.selectionStatus = -50
        do {
            try recorder.start(deviceUID: "usb-mic")
            fatalError("Device application failure must throw")
        } catch let error as TalklessError {
            precondition(error.localizedDescription.contains("Core Audio error -50"))
        }
        precondition(!recorder.isRunning)
        TestHardware.selectionStatus = noErr
        TestHardware.hasAudioUnit = false
        do {
            try recorder.start()
            fatalError("Missing audio unit must throw")
        } catch is TalklessError {}
        precondition(!recorder.isRunning)
        TestHardware.hasAudioUnit = true
        TestHardware.rate = 0
        TestHardware.outputChannels = 0
        do {
            try recorder.start()
            fatalError("Invalid input format must throw")
        } catch let error as TalklessError {
            precondition(error.localizedDescription == "No available microphone found")
        }
        precondition(!recorder.isRunning)
        TestHardware.rate = 48_000
        TestHardware.outputChannels = 2
        print("PASS device application and invalid-format errors leave recorder stopped")
        let observations = Observations()
        recorder.onBuffer = { observations.buffer($0) }
        recorder.onLevel = { observations.level($0) }
        for _ in 0..<3 {
            try recorder.start()
            precondition(recorder.isRunning)
            precondition(TestHardware.appliedDevice == 42)
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
        recorder.onBuffer = nil
        recorder.onLevel = nil
        var errors = 0
        recorder.onError = { message in
            MainActor.assertIsolated()
            precondition(message.contains("interrupted"))
            errors += 1
        }
        try recorder.start(deviceUID: "usb-mic")
        let interruptedEngine = TestAudioEngine.latest!
        interruptedEngine.interrupt()
        precondition(!recorder.isRunning, "Interruption closes the capture gate synchronously")
        precondition(recorder.interruptionError != nil)
        precondition(recorder.duration == 0, "Discard incomplete recording samples")
        for _ in 0..<10 { await Task.yield() }
        precondition(errors == 1, "Active interruption is reported once on main actor")
        interruptedEngine.interrupt()
        recorder.stop()
        precondition(recorder.interruptionError != nil, "Stop preserves interruption for finish-path check")
        try recorder.start()
        precondition(recorder.interruptionError == nil)
        interruptedEngine.interrupt()
        for _ in 0..<10 { await Task.yield() }
        precondition(errors == 1 && recorder.isRunning, "Old engine notification cannot abort new session")
        // Queue a valid notification, then replace its session before deferred teardown runs.
        TestAudioEngine.latest!.interrupt()
        precondition(recorder.stop().isEmpty)
        try recorder.start()
        for _ in 0..<10 { await Task.yield() }
        precondition(errors == 1 && recorder.isRunning, "Stale queued callback cannot abort new session")
        recorder.stop() // Stub stop posts a notification: it must not become an interruption.
        for _ in 0..<10 { await Task.yield() }
        precondition(errors == 1 && recorder.interruptionError == nil)
        print("PASS interruption stops capture, reports on main, discards partial audio, ignores normal stop and stale notifications")
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
    matches = re.findall(r"^// closure #\d+ in AudioRecorder\.start\(deviceUID:\)\n.*?^} // end sil function[^\n]*", text, re.M | re.S)
    taps = [body for body in matches if "AVAudioPCMBuffer" in body.split("\nbb0(", 1)[0]]
    assert len(taps) == 1, "Could not identify production audio tap in compiler SIL"
    return taps[0]


with tempfile.TemporaryDirectory(prefix="talkless-audio-tests-") as work:
    directory = Path(work)
    source = SOURCE.read_text() + "\n" + DEVICES.read_text() + LOCALIZATION_STUB
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
    stubbed = re.sub(r"\bAVAudioEngine\b", "TestAudioEngine", source)
    stubbed = stubbed.replace("AudioObjectGetPropertyDataSize", "TestGetPropertyDataSize")
    stubbed = stubbed.replace("AudioObjectGetPropertyData", "TestGetPropertyData")
    stubbed = stubbed.replace("AudioUnitSetProperty", "TestSetProperty")
    runtime.write_text(stubbed + HARNESS)
    executable = directory / "audio-tests"
    run("xcrun", "swiftc", "-swift-version", "6", "-O", "-parse-as-library", str(runtime), "-o", str(executable))
    run(str(executable))
