#!/usr/bin/env python3
"""Compile production audio code with deterministic native-engine/device stubs.
Real AVAudioConverter/buffers and the actual production tap/observer closures run.
No microphone permission, audio hardware, application launch, or user logs needed.
Run: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 -I Tests/AudioTests/run-tests.py
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Sources/Talkless/AudioRecorder.swift"
DEVICES = ROOT / "Sources/Talkless/AudioInputDevice.swift"

STUBS = r'''
enum L10n {
    static func tr(_ key: String) -> String { key }
    static func format(_ key: String, _ args: CVarArg...) -> String {
        String(format: key, locale: Locale(identifier: "en"), arguments: args)
    }
}
final class Diagnostics: @unchecked Sendable {
    static let shared = Diagnostics()
    private let lock = NSLock()
    private var entries: [(String, [String: String])] = []
    func record(event: String, metadata: [String: String] = [:]) {
        MainActor.assertIsolated() // No diagnostics calls, even async ones, from native callbacks.
        lock.withLock { entries.append((event, metadata)) }
    }
    func recordAsync(event: String, metadata: [String: String] = [:]) {
        record(event: event, metadata: metadata)
    }
    func snapshot() -> [(String, [String: String])] { lock.withLock { entries } }
}
'''

HARNESS = r'''
private enum TestClock {
    nonisolated(unsafe) static var now: TimeInterval = 10
}
private enum TestHardware {
    nonisolated(unsafe) static var device: AudioDeviceID = 42
    nonisolated(unsafe) static var channels: UInt32 = 2
    nonisolated(unsafe) static var status: OSStatus = noErr
    nonisolated(unsafe) static var enginesCreated = 0
    nonisolated(unsafe) static var defaultReads = 0
    nonisolated(unsafe) static var setCalls = 0
    nonisolated(unsafe) static var selectionStatus: OSStatus = noErr
    nonisolated(unsafe) static var hasAudioUnit = true
    nonisolated(unsafe) static var devices: [AudioDeviceID] = [42, 99, 100]
    nonisolated(unsafe) static var selectedID: AudioDeviceID = 99
    nonisolated(unsafe) static var invalidFormat = false
    nonisolated(unsafe) static var mismatchedFormat = false
    nonisolated(unsafe) static var changeOutputOnRead = 0
    nonisolated(unsafe) static var notifyBeforeFreeze = false
    nonisolated(unsafe) static var plans: [Plan] = []
    struct Plan {
        var prepareNotification = false
        var startNotification = false
        var stoppedAfterStart = false
        var changeFormatAtStart = false
        var deliverDuringStart = false
        var throwsOnStart = false
        var startupSeconds: Double = 0
    }
}
private func TestSetProperty(_ unit: AudioUnit, _ property: AudioUnitPropertyID,
    _ scope: AudioUnitScope, _ element: AudioUnitElement, _ data: UnsafeRawPointer,
    _ size: UInt32) -> OSStatus {
    precondition(property == kAudioOutputUnitProperty_CurrentDevice)
    precondition(scope == kAudioUnitScope_Global && element == 0)
    precondition(size == MemoryLayout<AudioDeviceID>.size)
    TestHardware.setCalls += 1
    TestAudioEngine.latest!.inputNode.actualDevice = data.assumingMemoryBound(to: AudioDeviceID.self).pointee
    return TestHardware.selectionStatus
}
private func TestGetProperty(_ unit: AudioUnit, _ property: AudioUnitPropertyID,
    _ scope: AudioUnitScope, _ element: AudioUnitElement, _ data: UnsafeMutableRawPointer,
    _ size: UnsafeMutablePointer<UInt32>) -> OSStatus {
    MainActor.assertIsolated()
    data.assumingMemoryBound(to: AudioDeviceID.self).pointee = TestAudioEngine.latest!.inputNode.actualDevice
    return noErr
}
private func TestGetPropertyDataSize(_ object: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qualifierSize: UInt32,
    _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>) -> OSStatus {
    MainActor.assertIsolated()
    size.pointee = address.pointee.mSelector == kAudioHardwarePropertyDevices
        ? UInt32(TestHardware.devices.count * MemoryLayout<AudioDeviceID>.size)
        : UInt32(MemoryLayout<AudioBufferList>.size)
    return TestHardware.status
}
private func TestGetPropertyData(_ object: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qualifierSize: UInt32,
    _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutableRawPointer) -> OSStatus {
    MainActor.assertIsolated()
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
private func format(_ rate: Double, _ channels: AVAudioChannelCount) -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
}
// Callback intentionally non-Sendable, as in AVAudioNodeTapBlock in the real SDK.
private final class TestAudioNode: @unchecked Sendable {
    private var callback: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private var oldCallback: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var actualDevice = TestHardware.device
    var hardware = format(48_000, 2)
    var output = TestHardware.invalidFormat ? format(0, 0)
        : (TestHardware.mismatchedFormat ? format(44_100, 1) : format(48_000, 2))
    private var outputReads = 0
    var installedFormat: AVAudioFormat?
    var audioUnit: AudioUnit? { TestHardware.hasAudioUnit ? AudioUnit(bitPattern: 1) : nil }
    func outputFormat(forBus: Int) -> AVAudioFormat {
        MainActor.assertIsolated()
        outputReads += 1
        if outputReads == TestHardware.changeOutputOnRead {
            hardware = format(44_100, 1)
            output = hardware
        }
        return output
    }
    func inputFormat(forBus: Int) -> AVAudioFormat { MainActor.assertIsolated(); return hardware }
    func installTap(onBus: Int, bufferSize: UInt32, format: AVAudioFormat?,
                    block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        MainActor.assertIsolated()
        precondition(callback == nil)
        precondition(format?.sampleRate == hardware.sampleRate && format?.channelCount == hardware.channelCount,
                     "Input node cannot convert hardware rate/channel count")
        installedFormat = format
        callback = block
        oldCallback = block
    }
    func removeTap(onBus: Int) { MainActor.assertIsolated(); callback = nil }
    func deliver(stale: Bool = false, wrongFormat: Bool = false, silent: Bool = false) {
        precondition(!Thread.isMainThread, "Native callback must run off main actor")
        let selected = wrongFormat ? format(32_000, 1) : installedFormat!
        let buffer = AVAudioPCMBuffer(pcmFormat: selected, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for channel in 0..<Int(selected.channelCount) {
            for index in 0..<4_800 { buffer.floatChannelData![channel][index] = silent ? 0 : 0.25 }
        }
        (stale ? oldCallback : callback)?(buffer, AVAudioTime(sampleTime: 0, atRate: selected.sampleRate))
    }
}
private final class TestAudioEngine: NSObject, @unchecked Sendable {
    nonisolated(unsafe) static var latest: TestAudioEngine?
    private let plan: TestHardware.Plan
    var isRunning = false
    let inputNode = TestAudioNode()
    override init() {
        plan = TestHardware.plans.isEmpty ? .init() : TestHardware.plans.removeFirst()
        super.init()
        TestHardware.enginesCreated += 1
        Self.latest = self
    }
    func prepare() { if plan.prepareNotification { notify() } }
    func start() throws {
        MainActor.assertIsolated()
        if plan.throwsOnStart { throw TalklessError.message("Stub engine start failure") }
        TestClock.now += plan.startupSeconds
        isRunning = !plan.stoppedAfterStart
        if plan.changeFormatAtStart { inputNode.output = format(32_000, 1) }
        if plan.startNotification { notify() }
        if plan.deliverDuringStart { deliver() }
    }
    func stop() {
        MainActor.assertIsolated()
        isRunning = false
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: self)
    }
    func native(_ action: @escaping @Sendable () -> Void) {
        let completed = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { action(); completed.signal() }
        precondition(completed.wait(timeout: .now() + 5) == .success,
                     "Native callback must not wait on main actor or deadlock during teardown")
    }
    func notify() { native { [self] in NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: self) } }
    func deliver(stale: Bool = false, wrongFormat: Bool = false, silent: Bool = false) {
        native { [self] in inputNode.deliver(stale: stale, wrongFormat: wrongFormat, silent: silent) }
    }
}
private final class Observations: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func buffer(_ buffer: AVAudioPCMBuffer) {
        precondition(!Thread.isMainThread)
        precondition(buffer.format.sampleRate == 16_000 && buffer.format.channelCount == 1)
        precondition(buffer.frameLength > 0)
        lock.withLock { count += 1 }
    }
    func level(_ level: Float) {
        precondition(!Thread.isMainThread)
        precondition(level.isFinite && (0...1).contains(level))
    }
    var buffers: Int { lock.withLock { count } }
}
extension AudioRecorder {
    @MainActor fileprivate func testMonitor() -> Bool {
        guard let session = lock.withLock({ sessionID }) else { return false }
        return monitor(session: session)
    }
}
@main struct Tests {
    @MainActor static func drain() async {
        // Queue ordering, not wall-clock delays: scheduled handlers get an actor turn.
        for _ in 0..<20 { await Task.yield() }
    }
    @MainActor static func main() async throws {
        let recorder = AudioRecorder()
        let observations = Observations()
        recorder.onBuffer = { observations.buffer($0) }
        recorder.onLevel = { observations.level($0) }
        var errors = 0
        recorder.onError = { _ in MainActor.assertIsolated(); errors += 1 }
        for unavailable in 0..<3 {
            TestHardware.device = unavailable == 0 ? 0 : 42
            TestHardware.channels = unavailable == 1 ? 0 : 2
            TestHardware.status = unavailable == 2 ? -1 : noErr
            do { try recorder.start(); fatalError("Unavailable mic must throw") } catch is TalklessError {}
            precondition(!recorder.isRunning && TestHardware.enginesCreated == 0)
        }
        TestHardware.device = 42; TestHardware.channels = 2; TestHardware.status = noErr
        let listed = try AudioInputDevices.available()
        precondition(listed.map(\.uid) == ["built-in", "usb-mic"])
        precondition(listed.map(\.name) == ["Built-in Microphone", "USB Microphone"])
        print("PASS pre-engine unavailable hardware checks and input-only enumeration")

        let reads = TestHardware.defaultReads
        TestHardware.devices = [42, 100]
        do { try recorder.start(deviceUID: "usb-mic"); fatalError("Explicit mic cannot fall back") }
        catch { precondition(error.localizedDescription.contains("selected microphone is unavailable")) }
        precondition(TestHardware.enginesCreated == 0 && TestHardware.defaultReads == reads)
        TestHardware.selectedID = 77; TestHardware.devices = [42, 77, 100]; TestHardware.device = 0
        try recorder.start(deviceUID: "usb-mic")
        precondition(TestAudioEngine.latest!.inputNode.actualDevice == 77)
        precondition(TestAudioEngine.latest!.inputNode.installedFormat == format(48_000, 2))
        TestAudioEngine.latest!.deliver()
        precondition(!recorder.stop().isEmpty)
        TestHardware.selectedID = 88; TestHardware.devices = [42, 88, 100]
        try recorder.start(deviceUID: "usb-mic")
        precondition(TestAudioEngine.latest!.inputNode.actualDevice == 88)
        recorder.stop()
        precondition(TestHardware.defaultReads == reads)
        TestHardware.device = 42
        print("PASS explicit selection without default, reconnect UID resolution, no fallback")

        TestHardware.selectionStatus = -50
        do { try recorder.start(deviceUID: "usb-mic"); fatalError("Selection should fail") }
        catch { precondition(error.localizedDescription.contains("Core Audio error -50")) }
        TestHardware.selectionStatus = noErr; TestHardware.hasAudioUnit = false
        do { try recorder.start(); fatalError("Missing unit should fail") } catch is TalklessError {}
        TestHardware.hasAudioUnit = true; TestHardware.invalidFormat = true
        do { try recorder.start(); fatalError("Invalid format should fail") } catch is TalklessError {}
        TestHardware.invalidFormat = false
        TestHardware.plans = [.init(throwsOnStart: true)]
        do { try recorder.start(); fatalError("Engine start should fail") } catch is TalklessError {}
        precondition(!recorder.isRunning)
        print("PASS selection, missing unit, invalid format and engine start failures clean up")

        TestHardware.mismatchedFormat = true
        do { try recorder.start(); fatalError("Default input cannot convert mismatched hardware/client formats") }
        catch is TalklessError {}
        TestHardware.mismatchedFormat = false
        TestHardware.changeOutputOnRead = 2
        try recorder.start()
        precondition(TestAudioEngine.latest!.inputNode.installedFormat == format(44_100, 1))
        recorder.stop()
        TestHardware.changeOutputOnRead = 3 // Changes after coherent snapshot, during final preinstall check.
        do { try recorder.start(); fatalError("Do not install a stale pre-negotiation tap format") }
        catch is TalklessError {}
        precondition(!recorder.isRunning && TestAudioEngine.latest!.inputNode.installedFormat == nil)
        TestHardware.changeOutputOnRead = 0
        print("PASS hardware/client compatibility, bounded format reacquisition, stale preinstall format rejected")

        let calls = TestHardware.setCalls
        let beforeBuffers = observations.buffers
        TestHardware.plans = [.init(prepareNotification: true, startNotification: true, deliverDuringStart: true)]
        try recorder.start()
        let defaultEngine = TestAudioEngine.latest!
        precondition(TestHardware.setCalls == calls, "Default must never set CurrentDevice")
        precondition(defaultEngine.inputNode.installedFormat == defaultEngine.inputNode.output, "Preserve default outputFormat")
        await drain()
        precondition(recorder.isRunning && recorder.interruptionError == nil && errors == 0)
        defaultEngine.notify()
        defaultEngine.deliver() // No lost audio while healthy notification awaits main validation.
        await drain()
        defaultEngine.deliver()
        precondition(observations.buffers == beforeBuffers + 3)
        let samples = recorder.stop()
        precondition(!samples.isEmpty && samples.allSatisfy(\.isFinite))
        precondition(AudioRecorder.wavData(from: samples).count == 44 + samples.count * 2)
        print("PASS prepare/start notifications, healthy running notification, no default pinning, real resampling/WAV")

        let count = TestHardware.enginesCreated
        TestHardware.plans = [.init(startNotification: true, stoppedAfterStart: true), .init(startNotification: true)]
        try recorder.start()
        precondition(TestHardware.enginesCreated == count + 2)
        TestAudioEngine.latest!.deliver()
        precondition(!recorder.stop().isEmpty)
        TestHardware.plans = [.init(startNotification: true, changeFormatAtStart: true), .init()]
        try recorder.start()
        precondition(recorder.isRunning)
        recorder.stop()
        let bounded = TestHardware.enginesCreated
        TestHardware.plans = [.init(startNotification: true, stoppedAfterStart: true), .init(startNotification: true, stoppedAfterStart: true)]
        do { try recorder.start(); fatalError("Recovery must be bounded") } catch is TalklessError {}
        precondition(TestHardware.enginesCreated == bounded + 2 && !recorder.isRunning)
        print("PASS stopped/changed startup recovery before audio and strict one-retry bound")

        TestHardware.mismatchedFormat = true // Explicit selection may initially expose stale client output.
        try recorder.start(deviceUID: "usb-mic")
        TestHardware.mismatchedFormat = false
        let explicit = TestAudioEngine.latest!
        explicit.deliver()
        explicit.inputNode.output = format(48_000, 2) // Cached client format catches up with selected hardware.
        explicit.notify()
        await drain()
        precondition(recorder.isRunning && recorder.interruptionError == nil)
        precondition(!recorder.stop().isEmpty)
        print("PASS explicit client output negotiation does not falsely interrupt unchanged tap/hardware")

        try recorder.start()
        let beforeRecovery = TestAudioEngine.latest!
        beforeRecovery.isRunning = false
        beforeRecovery.notify()
        await drain()
        let afterRecovery = TestAudioEngine.latest!
        precondition(beforeRecovery !== afterRecovery && recorder.isRunning)
        let deliveredBeforeStale = observations.buffers
        beforeRecovery.deliver(stale: true)
        precondition(observations.buffers == deliveredBeforeStale, "Old attempt tap cannot use replacement converter")
        afterRecovery.deliver()
        precondition(!recorder.stop().isEmpty)
        print("PASS asynchronous zero-audio recovery and same-session stale attempt tap rejection")

        // A real interruption after ANY delivered audio cannot restart or preserve partial data.
        for kind in 0..<5 {
            try recorder.start(deviceUID: kind == 3 ? "usb-mic" : nil)
            let engine = TestAudioEngine.latest!
            engine.deliver()
            let engines = TestHardware.enginesCreated
            switch kind {
            case 0: engine.inputNode.output = format(32_000, 1)
            case 1: TestHardware.device = 77
            case 2: engine.isRunning = false
            case 3: TestHardware.devices = [42, 100]
            default: engine.inputNode.actualDevice = 77 // Actual route changed despite same system default.
            }
            engine.notify()
            // Deliberately finish before queued validation. Must discard samples and
            // retain interruptionError; queued work must not resurrect recording.
            precondition(recorder.stop().isEmpty && recorder.interruptionError != nil)
            await drain()
            precondition(!recorder.isRunning && TestHardware.enginesCreated == engines)
            TestHardware.device = 42; TestHardware.devices = [42, 88, 100]
        }
        print("PASS format/default/actual-device/disconnect/stopped interruptions caught at stop before queued handler")

        try recorder.start()
        let interrupted = TestAudioEngine.latest!
        interrupted.deliver(); interrupted.isRunning = false; interrupted.notify()
        let previousErrors = errors
        await drain()
        precondition(errors == previousErrors + 1 && recorder.interruptionError != nil)
        precondition(recorder.duration == 0 && !recorder.isRunning)
        interrupted.notify()
        await drain()
        precondition(errors == previousErrors + 1)
        try recorder.start()
        let current = TestAudioEngine.latest!
        let oldCount = observations.buffers
        interrupted.notify(); interrupted.deliver(stale: true)
        await drain()
        precondition(recorder.isRunning && observations.buffers == oldCount)
        current.deliver()
        precondition(observations.buffers == oldCount + 1)
        current.isRunning = false; current.notify()
        recorder.stop()
        try recorder.start()
        await drain()
        precondition(recorder.isRunning && recorder.interruptionError == nil && errors == previousErrors + 1)
        recorder.stop()
        print("PASS one-shot main-actor error, stale notification/tap/deferred teardown session protection")

        try recorder.start()
        let wrong = TestAudioEngine.latest!
        wrong.deliver(); wrong.deliver(wrongFormat: true)
        precondition(recorder.stop().isEmpty && recorder.interruptionError != nil)
        print("PASS incompatible tap buffers rejected before AVAudioConverter and partial samples discarded")

        try recorder.start()
        let stoppedSilently = TestAudioEngine.latest!
        stoppedSilently.deliver(); stoppedSilently.isRunning = false
        precondition(!recorder.testMonitor() && recorder.interruptionError != nil)
        precondition(recorder.stop().isEmpty)
        try recorder.start()
        let firstFormat = TestAudioEngine.latest!
        firstFormat.deliver(wrongFormat: true)
        precondition(recorder.testMonitor() && TestAudioEngine.latest! !== firstFormat)
        TestAudioEngine.latest!.deliver()
        precondition(!recorder.stop().isEmpty)
        print("PASS engine stop without notification and initial incompatible-buffer recovery")

        try recorder.start()
        let late = TestAudioEngine.latest!
        TestClock.now += 3.01
        late.isRunning = false
        precondition(recorder.testMonitor(), "Late recovery must get a fresh first-buffer deadline")
        precondition(TestAudioEngine.latest! !== late && recorder.interruptionError == nil)
        TestClock.now += 2.99
        precondition(recorder.testMonitor())
        TestClock.now += 0.02
        precondition(!recorder.testMonitor() && recorder.interruptionError != nil)
        print("PASS late zero-audio recovery receives its own bounded first-buffer deadline")

        TestHardware.plans = [.init(startupSeconds: 4)]
        try recorder.start()
        precondition(recorder.testMonitor(), "Slow native start must not consume first-buffer allowance")
        TestClock.now += 2.99
        precondition(recorder.testMonitor())
        TestAudioEngine.latest!.deliver()
        precondition(!recorder.stop().isEmpty)
        print("PASS first-buffer deadline begins after successful native startup")

        let operation = UUID()
        try recorder.start(operationID: operation)
        TestClock.now += 2.99
        precondition(recorder.testMonitor())
        TestClock.now += 0.02
        precondition(!recorder.testMonitor() && !recorder.isRunning)
        precondition(recorder.interruptionError!.contains("did not deliver audio"))
        try recorder.start()
        TestAudioEngine.latest!.deliver(silent: true)
        TestClock.now += 10
        precondition(recorder.testMonitor() && recorder.interruptionError == nil, "Silence PCM is still audio")
        recorder.stop()
        print("PASS deterministic initial no-buffer timeout and silent PCM stays healthy")

        // Recovery scheduled by notification must be cancelled by an immediate user stop,
        // even when zero buffers were delivered and restarting would otherwise be allowed.
        try recorder.start()
        let pending = TestAudioEngine.latest!
        pending.isRunning = false; pending.notify()
        let total = TestHardware.enginesCreated
        precondition(recorder.stop().isEmpty && recorder.interruptionError != nil)
        await drain()
        precondition(!recorder.isRunning && TestHardware.enginesCreated == total)
        try recorder.start()
        recorder.stop() // Stub emits its own notification during normal teardown.
        precondition(recorder.interruptionError == nil)
        print("PASS stop cancels pending recovery and normal teardown notifications are harmless")

        try recorder.start()
        TestAudioEngine.latest!.deliver()
        TestHardware.notifyBeforeFreeze = true
        precondition(!recorder.stop().isEmpty && recorder.interruptionError == nil,
                     "Healthy notification between assessment and final lock must be revalidated")
        await drain()
        precondition(!recorder.isRunning)
        print("PASS harmless notification racing stop's final freeze is revalidated, not discarded")

        let logs = Diagnostics.shared.snapshot()
        for event in ["audio_start", "audio_start_configuration", "audio_engine_started", "audio_start_failed",
                      "audio_engine_configuration_change", "audio_first_buffer", "audio_recording_summary",
                      "audio_interruption", "audio_recovery"] {
            precondition(logs.contains { $0.0 == event }, "Missing diagnostic event \(event)")
        }
        precondition(logs.contains { $0.1["operation_id"] == operation.uuidString && $0.1["reason"] == "no_audio_timeout" })
        precondition(logs.contains { $0.1["device_changed"] == "true" })
        precondition(logs.contains { $0.1["format_changed"] == "true" })
        precondition(logs.contains { $0.0 == "audio_first_buffer" && $0.1["first_buffer_ms"] != nil })
        for (_, fields) in logs {
            precondition(UUID(uuidString: fields["operation_id"]!) != nil)
            precondition(fields["elapsed_ms"] != nil && fields["attempt"] != nil)
            precondition(!fields.values.contains { $0.contains("usb-mic") || $0.contains("Built-in") || $0.contains("Microphone") })
        }
        print("PASS diagnostics correlation/timing/formats/device booleans/summary, no identifying content or callback logging")
    }
}
'''


def run(*args):
    subprocess.run(args, check=True, env=ENV)


def tap_sil(source, directory, name):
    swift = directory / (name + ".swift")
    sil = directory / (name + ".sil")
    swift.write_text(source)
    run("xcrun", "swiftc", "-swift-version", "6", "-O", "-emit-sil", str(swift), "-o", str(sil))
    text = sil.read_text()
    matches = re.findall(r"^// closure #\d+ in AudioRecorder\.installAndStart\(session:\)\n.*?^} // end sil function[^\n]*", text, re.M | re.S)
    taps = [body for body in matches if "AVAudioPCMBuffer" in body.split("\nbb0(", 1)[0]]
    assert len(taps) == 1, "Could not identify production audio tap in compiler SIL"
    return taps[0]


ENV = os.environ.copy()
ENV.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
ENV["SDKROOT"] = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=ENV, text=True).strip()
with tempfile.TemporaryDirectory(prefix="talkless-audio-tests-") as work:
    directory = Path(work)
    source = SOURCE.read_text() + "\n" + DEVICES.read_text() + STUBS
    current = tap_sil(source, directory, "current")
    assert "// Isolation: nonisolated" in current
    assert "swift_task_isCurrentExecutor" not in current
    assert "swift_task_reportUnexpectedExecutor" not in current
    print("PASS production tap has no MainActor executor assertion", flush=True)
    original = source.replace("{ @Sendable [weak self] buffer, _ in", "{ [weak self] buffer, _ in")
    assert original != source
    baseline = tap_sil(original, directory, "baseline")
    assert "// Isolation: global_actor. type: MainActor" in baseline
    assert "swift_task_isCurrentExecutor" in baseline
    assert "swift_task_reportUnexpectedExecutor" in baseline
    print("PASS negative control detects original main-actor tap assertion", flush=True)

    runtime = directory / "runtime.swift"
    stubbed = re.sub(r"\bAVAudioEngine\b", "TestAudioEngine", source)
    for native, test in [("AudioObjectGetPropertyDataSize", "TestGetPropertyDataSize"),
                         ("AudioObjectGetPropertyData", "TestGetPropertyData"),
                         ("AudioUnitSetProperty", "TestSetProperty"),
                         ("AudioUnitGetProperty", "TestGetProperty")]:
        stubbed = stubbed.replace(native, test)
    stubbed = stubbed.replace("ProcessInfo.processInfo.systemUptime", "TestClock.now")
    # Inject exactly between stop's snapshot and final freeze; no sleeps or live driver race.
    freeze = "                    let result = lock.withLock { () -> (Bool, String?) in"
    assert freeze in stubbed
    stubbed = stubbed.replace(freeze, """                    if TestHardware.notifyBeforeFreeze {
                        TestHardware.notifyBeforeFreeze = false
                        TestAudioEngine.latest!.notify()
                    }
""" + freeze)
    runtime.write_text(stubbed + HARNESS)
    executable = directory / "audio-tests"
    run("xcrun", "swiftc", "-swift-version", "6", "-O", "-parse-as-library", str(runtime), "-o", str(executable))
    run(str(executable))
