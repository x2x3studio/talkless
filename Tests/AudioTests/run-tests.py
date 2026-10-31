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
OPERATIONS = ROOT / "Sources/Talkless/AudioOperationQueue.swift"
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
        precondition(!TestContext.inCallback, "No diagnostics on the realtime audio callback")
        lock.withLock { entries.append((event, metadata)) }
    }
    func recordAsync(event: String, metadata: [String: String] = [:]) {
        record(event: event, metadata: metadata)
    }
    func snapshot() -> [(String, [String: String])] { lock.withLock { entries } }
}
'''

HARNESS = r'''
private enum TestContext {
    static var inCallback: Bool { Thread.current.threadDictionary["audioCallback"] as? Bool == true }
}
private enum TestClock {
    nonisolated(unsafe) static var now: TimeInterval = 10
}
private enum TestHardware {
    nonisolated(unsafe) static var device: AudioDeviceID = 42
    nonisolated(unsafe) static var channels: UInt32 = 2
    nonisolated(unsafe) static var status: OSStatus = noErr
    nonisolated(unsafe) static var enginesCreated = 0
    nonisolated(unsafe) static var enginesDestroyed = 0
    nonisolated(unsafe) static var defaultReads = 0
    nonisolated(unsafe) static var setCalls = 0
    nonisolated(unsafe) static var selectionStatus: OSStatus = noErr
    nonisolated(unsafe) static var hasAudioUnit = true
    nonisolated(unsafe) static var actualDevice: AudioDeviceID?
    nonisolated(unsafe) static var currentDeviceStatus: OSStatus = noErr
    nonisolated(unsafe) static var currentDeviceReads = 0
    nonisolated(unsafe) static var changeActualOnRead = 0
    nonisolated(unsafe) static var changeActualEveryRead = false
    nonisolated(unsafe) static var ignoresSelection = false
    nonisolated(unsafe) static var aggregateClass = false
    nonisolated(unsafe) static var classStatus: OSStatus = noErr
    nonisolated(unsafe) static var devices: [AudioDeviceID] = [42, 99, 100]
    nonisolated(unsafe) static var selectedID: AudioDeviceID = 99
    nonisolated(unsafe) static var invalidFormat = false
    nonisolated(unsafe) static var mismatchedFormat = false
    nonisolated(unsafe) static var changeOutputOnRead = 0
    nonisolated(unsafe) static var notifyBeforeFreeze = false
    nonisolated(unsafe) static var plans: [Plan] = []
    nonisolated(unsafe) static var block: String?
    static let entered = DispatchSemaphore(value: 0)
    static let release = DispatchSemaphore(value: 0)
    static func checkpoint(_ stage: String) {
        precondition(!Thread.isMainThread, "Native lifecycle must never run on main")
        if block == stage { entered.signal(); release.wait() }
    }
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
    TestHardware.checkpoint("setter")
    TestHardware.setCalls += 1
    if !TestHardware.ignoresSelection {
        TestAudioEngine.latest!.inputNode.actualDevice = data.assumingMemoryBound(to: AudioDeviceID.self).pointee
    }
    return TestHardware.selectionStatus
}
private func TestGetProperty(_ unit: AudioUnit, _ property: AudioUnitPropertyID,
    _ scope: AudioUnitScope, _ element: AudioUnitElement, _ data: UnsafeMutableRawPointer,
    _ size: UnsafeMutablePointer<UInt32>) -> OSStatus {
    precondition(!Thread.isMainThread, "HAL must not run on main")
    TestHardware.currentDeviceReads += 1
    if TestHardware.changeActualEveryRead || TestHardware.currentDeviceReads == TestHardware.changeActualOnRead {
        TestAudioEngine.latest!.inputNode.actualDevice += 1
    }
    data.assumingMemoryBound(to: AudioDeviceID.self).pointee = TestAudioEngine.latest!.inputNode.actualDevice
    return TestHardware.currentDeviceStatus
}
private func TestGetPropertyDataSize(_ object: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qualifierSize: UInt32,
    _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>) -> OSStatus {
    precondition(!Thread.isMainThread, "HAL must not run on main")
    size.pointee = address.pointee.mSelector == kAudioHardwarePropertyDevices
        ? UInt32(TestHardware.devices.count * MemoryLayout<AudioDeviceID>.size)
        : UInt32(MemoryLayout<AudioBufferList>.size)
    return TestHardware.status
}
private func TestGetPropertyData(_ object: AudioObjectID,
    _ address: UnsafePointer<AudioObjectPropertyAddress>, _ qualifierSize: UInt32,
    _ qualifier: UnsafeRawPointer?, _ size: UnsafeMutablePointer<UInt32>,
    _ data: UnsafeMutableRawPointer) -> OSStatus {
    precondition(!Thread.isMainThread, "HAL must not run on main")
    guard TestHardware.status == noErr else { return TestHardware.status }
    switch address.pointee.mSelector {
    case kAudioObjectPropertyClass:
        guard TestHardware.classStatus == noErr else { return TestHardware.classStatus }
        data.assumingMemoryBound(to: AudioClassID.self).pointee = TestHardware.aggregateClass
            ? kAudioAggregateDeviceClassID : kAudioDeviceClassID
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
    var oldCallback: ((AVAudioPCMBuffer, AVAudioTime) -> Void)?
    var actualDevice = TestHardware.actualDevice ?? TestHardware.device
    var hardware = format(48_000, 2)
    var output = TestHardware.invalidFormat ? format(0, 0)
        : (TestHardware.mismatchedFormat ? format(44_100, 1) : format(48_000, 2))
    private var outputReads = 0
    var installedFormat: AVAudioFormat?
    var audioUnit: AudioUnit? { TestHardware.hasAudioUnit ? AudioUnit(bitPattern: 1) : nil }
    func outputFormat(forBus: Int) -> AVAudioFormat {
        precondition(!Thread.isMainThread, "HAL must not run on main")
        outputReads += 1
        if outputReads == TestHardware.changeOutputOnRead {
            hardware = format(44_100, 1)
            output = hardware
        }
        return output
    }
    func inputFormat(forBus: Int) -> AVAudioFormat { precondition(!Thread.isMainThread, "HAL must not run on main"); return hardware }
    func installTap(onBus: Int, bufferSize: UInt32, format: AVAudioFormat?,
                    block: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) {
        precondition(!Thread.isMainThread, "HAL must not run on main")
        precondition(callback == nil)
        precondition(format?.sampleRate == hardware.sampleRate && format?.channelCount == hardware.channelCount,
                     "Input node cannot convert hardware rate/channel count")
        installedFormat = format
        oldCallback = callback ?? oldCallback
        callback = block
    }
    func removeTap(onBus: Int) { precondition(!Thread.isMainThread, "HAL must not run on main"); oldCallback = callback; callback = nil }
    func deliver(stale: Bool = false, wrongFormat: Bool = false, silent: Bool = false) {
        precondition(!Thread.isMainThread, "Native callback must run off main actor")
        let selected = wrongFormat ? format(32_000, 1) : installedFormat!
        let buffer = AVAudioPCMBuffer(pcmFormat: selected, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for channel in 0..<Int(selected.channelCount) {
            for index in 0..<4_800 { buffer.floatChannelData![channel][index] = silent ? 0 : 0.25 }
        }
        Thread.current.threadDictionary["audioCallback"] = true
        defer { Thread.current.threadDictionary["audioCallback"] = false }
        (stale ? oldCallback : callback)?(buffer, AVAudioTime(sampleTime: 0, atRate: selected.sampleRate))
    }
}
private final class TestAudioEngine: NSObject, @unchecked Sendable {
    nonisolated(unsafe) static weak var latest: TestAudioEngine?
    private let plan: TestHardware.Plan
    var isRunning = false
    private let node = TestAudioNode()
    var inputNode: TestAudioNode { TestHardware.checkpoint("inputNode"); return node }
    override init() {
        plan = TestHardware.plans.isEmpty ? .init() : TestHardware.plans.removeFirst()
        TestHardware.checkpoint("init")
        super.init()
        TestHardware.enginesCreated += 1
        Self.latest = self
    }
    deinit {
        precondition(!Thread.isMainThread, "Native engine destruction must stay on audio worker")
        TestHardware.enginesDestroyed += 1
    }
    func prepare() { TestHardware.checkpoint("prepare"); if plan.prepareNotification { notify() } }
    func start() throws {
        TestHardware.checkpoint("start")
        precondition(!Thread.isMainThread, "HAL must not run on main")
        if plan.throwsOnStart { throw TalklessError.message("Stub engine start failure") }
        TestClock.now += plan.startupSeconds
        isRunning = !plan.stoppedAfterStart
        if plan.changeFormatAtStart { inputNode.output = format(32_000, 1) }
        if plan.startNotification { notify() }
        if plan.deliverDuringStart { deliver() }
    }
    func stop() {
        TestHardware.checkpoint("stop")
        precondition(!Thread.isMainThread, "HAL must not run on main")
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
    @MainActor fileprivate func testBeginFinalization() { native.beginFinalization() }
    @MainActor fileprivate func testNative(_ action: @escaping @Sendable (TestAudioEngine) -> Void) async throws {
        try await operations.run(timeout: 1, onTimeout: {}) { [native] in
            if let engine = native.engine { action(engine) }
        }
    }
    @MainActor fileprivate func testMonitor() async throws -> Bool {
        guard let session else { return false }
        return try await operations.run(timeout: 1, onTimeout: {}) { [native] in native.monitor(session: session) }
    }
    @MainActor fileprivate func testDrain() async throws {
        try await operations.run(timeout: 1, onTimeout: {}) {}
    }
}
@main struct Tests {
    @MainActor static func drain() async {
        for _ in 0..<20 { await Task.yield() }
    }
    @MainActor static func expectFailure(_ fragment: String, _ action: () async throws -> Void) async {
        do { try await action(); fatalError("Expected failure: \(fragment)") }
        catch { precondition(error.localizedDescription.contains(fragment), "Unexpected error: \(error)") }
    }
    static func nativeEntered() -> Bool { TestHardware.entered.wait(timeout: .now()) == .success }
    @MainActor static func waitForNative() async throws {
        for _ in 0..<1000 {
            if nativeEntered() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        fatalError("Native operation did not enter blocking stub")
    }
    @MainActor static func main() async throws {
        let observations = Observations()
        let recorder = AudioRecorder()
        recorder.onBuffer = { observations.buffer($0) }
        recorder.onLevel = { observations.level($0) }
        for unavailable in 0..<3 {
            TestHardware.device = unavailable == 0 ? 0 : 42
            TestHardware.channels = unavailable == 1 ? 0 : 2
            TestHardware.status = unavailable == 2 ? -1 : noErr
            do { try await recorder.start(); fatalError("Unavailable mic must throw") } catch is TalklessError {}
            try await recorder.testDrain()
            precondition(!recorder.isRunning && TestHardware.enginesCreated == 0)
        }
        TestHardware.device = 42; TestHardware.channels = 2; TestHardware.status = noErr
        let reads = TestHardware.defaultReads
        TestHardware.devices = [42, 100]
        await expectFailure("selected microphone is unavailable") { try await recorder.start(deviceUID: "usb-mic") }
        try await recorder.testDrain()
        precondition(TestHardware.defaultReads == reads && TestHardware.enginesCreated == 0)
        TestHardware.devices = [42, 99, 100]
        let creations = TestHardware.enginesCreated, setters = TestHardware.setCalls
        for turn in 0..<20 {
            try await recorder.start(deviceUID: "usb-mic")
            let before = observations.buffers
            try await recorder.testNative { engine in
                if turn > 0 { engine.deliver(stale: true) }
                engine.deliver()
            }
            precondition(observations.buffers == before + 1, "Stale tap from previous turn must be rejected")
            let samples = try await recorder.stop()
            precondition(!samples.isEmpty && samples.count < 2000, "Each utterance has isolated samples/converter")
            precondition(samples.allSatisfy(\.isFinite))
            precondition(AudioRecorder.wavData(from: samples).count == 44 + 2 * samples.count)
            try await recorder.testNative { precondition(!$0.isRunning, "Idle microphone must be stopped") }
        }
        precondition(TestHardware.enginesCreated == creations + 1 && TestHardware.setCalls == setters + 1)
        print("PASS 20 turns reuse one engine/one setter, stopped while idle, stale per-turn tap rejected, converter/WAV isolation")
        recorder.cancel(); try await recorder.testDrain()

        TestHardware.actualDevice = 99
        let alreadyBound = TestHardware.setCalls
        try await recorder.start(deviceUID: "usb-mic"); _ = try await recorder.stop()
        precondition(TestHardware.setCalls == alreadyBound, "Already-bound explicit input must skip setter")
        recorder.cancel(); try await recorder.testDrain()
        TestHardware.actualDevice = nil
        TestHardware.selectionStatus = 1852797029
        await expectFailure("Cannot use the selected microphone") { try await recorder.start(deviceUID: "usb-mic") }
        try await recorder.testDrain()
        TestHardware.selectionStatus = noErr
        print("PASS explicit no-fallback selection, preengine checks, already-bound setter skip and real nope error")

        for classStatus: OSStatus in [noErr, -50] {
            TestHardware.actualDevice = 314; TestHardware.aggregateClass = true; TestHardware.classStatus = classStatus
            let calls = TestHardware.setCalls
            try await recorder.start()
            for _ in 0..<20 {
                try await recorder.testNative { $0.deliver(); $0.notify() }
                let monitored = try await recorder.testMonitor(); precondition(monitored)
            }
            let aggregateSamples = try await recorder.stop()
            precondition(!aggregateSamples.isEmpty && TestHardware.setCalls == calls)
            recorder.cancel(); try await recorder.testDrain()
        }
        TestHardware.ignoresSelection = true
        await expectFailure("did not switch to the selected microphone") { try await recorder.start(deviceUID: "usb-mic") }
        try await recorder.testDrain()
        TestHardware.ignoresSelection = false; TestHardware.actualDevice = nil
        TestHardware.aggregateClass = false; TestHardware.classStatus = noErr
        print("PASS sustained default aggregate, unreadable class tolerated, explicit aggregate mismatch rejected")

        for test in 0..<4 {
            if test == 0 { TestHardware.currentDeviceStatus = -50 }
            if test == 1 { TestHardware.actualDevice = 0 }
            if test == 2 { TestHardware.changeActualEveryRead = true }
            if test == 3 { TestHardware.invalidFormat = true }
            do { try await recorder.start(); fatalError("Invalid route must fail") } catch is TalklessError {}
            try await recorder.testDrain()
            TestHardware.currentDeviceStatus = noErr; TestHardware.actualDevice = nil
            TestHardware.changeActualEveryRead = false; TestHardware.invalidFormat = false
        }
        TestHardware.plans = [.init(startNotification: true, stoppedAfterStart: true), .init()]
        try await recorder.start()
        try await recorder.testNative { $0.deliver() }
        _ = try await recorder.stop()
        recorder.cancel(); try await recorder.testDrain()
        TestHardware.plans = [.init(stoppedAfterStart: true), .init(stoppedAfterStart: true)]
        let bounded = TestHardware.enginesCreated
        do { try await recorder.start(); fatalError("Recovery must be bounded") } catch is TalklessError {}
        try await recorder.testDrain()
        precondition(TestHardware.enginesCreated == bounded + 2)
        print("PASS invalid/unreadable/unstable formats/routes fail, startup recovery is strictly bounded")

        TestHardware.mismatchedFormat = true
        await expectFailure("audio format is not ready") { try await recorder.start() }
        try await recorder.testDrain()
        try await recorder.start(deviceUID: "usb-mic")
        try await recorder.testNative { engine in
            engine.deliver()
            engine.inputNode.output = format(48_000, 2)
            engine.notify()
        }
        let explicitNegotiated = try await recorder.testMonitor()
        precondition(explicitNegotiated)
        _ = try await recorder.stop()
        recorder.cancel(); try await recorder.testDrain()
        TestHardware.mismatchedFormat = false
        TestHardware.changeOutputOnRead = 2
        try await recorder.start()
        try await recorder.testNative { precondition($0.inputNode.installedFormat == format(44_100, 1)) }
        _ = try await recorder.stop()
        recorder.cancel(); try await recorder.testDrain()
        TestHardware.changeOutputOnRead = 3
        do { try await recorder.start(); fatalError("Stale preinstall format must fail") } catch is TalklessError {}
        try await recorder.testDrain()
        TestHardware.changeOutputOnRead = 0
        print("PASS coherent negotiated converter format, explicit stale client format tolerated, preinstall race rejected")

        try await recorder.start()
        try await recorder.testNative { $0.deliver() }
        TestHardware.notifyBeforeFreeze = true
        let healthyRaceSamples = try await recorder.stop()
        precondition(!healthyRaceSamples.isEmpty && recorder.interruptionError == nil)
        recorder.cancel(); try await recorder.testDrain()
        TestHardware.plans = [.init(prepareNotification: true, startNotification: true, deliverDuringStart: true)]
        try await recorder.start()
        let notifiedSamples = try await recorder.stop()
        precondition(!notifiedSamples.isEmpty && recorder.interruptionError == nil)
        recorder.cancel(); try await recorder.testDrain()
        print("PASS harmless prepare/start/final-freeze notifications do not discard valid audio")

        for kind in 0..<5 {
            try await recorder.start()
            try await recorder.testNative { engine in
                engine.deliver()
                switch kind {
                case 0: engine.inputNode.output = format(32_000, 1)
                case 1: TestHardware.device = 77
                case 2: engine.isRunning = false
                case 3: engine.inputNode.actualDevice = 77
                default: engine.deliver(wrongFormat: true)
                }
                engine.notify()
            }
            await expectFailure("interrupted") { _ = try await recorder.stop() }
            try await recorder.testDrain()
            precondition(recorder.duration == 0 && !recorder.isRunning)
            TestHardware.device = 42
        }
        print("PASS finalization validates route/format/device/stopped/conversion before returning partial transcript samples")

        var errors = 0
        recorder.onError = { _ in MainActor.assertIsolated(); errors += 1 }
        try await recorder.start()
        try await recorder.testNative { $0.deliver(); $0.isRunning = false; $0.notify() }
        let monitored = try await recorder.testMonitor(); precondition(!monitored)
        await drain()
        precondition(errors == 1)
        recorder.cancel(); try await recorder.testDrain()
        try await recorder.start()
        TestClock.now += 3.01
        let noAudioMonitored = try await recorder.testMonitor(); precondition(!noAudioMonitored)
        await drain()
        precondition(recorder.interruptionError!.contains("did not deliver audio"))
        recorder.cancel(); try await recorder.testDrain()
        try await recorder.start()
        try await recorder.testNative { $0.deliver(silent: true) }
        TestClock.now += 10
        let silentMonitored = try await recorder.testMonitor(); precondition(silentMonitored)
        _ = try await recorder.stop()
        recorder.cancel(); try await recorder.testDrain()
        print("PASS one-shot MainActor error, bounded no-buffer watchdog, silent PCM accepted")

        try await recorder.start()
        try await recorder.testNative { $0.isRunning = false; $0.notify() }
        TestHardware.plans = [.init(deliverDuringStart: true)]
        TestHardware.block = "init"
        let recovering = Task { @MainActor in try await recorder.testMonitor() }
        try await waitForNative() // Recovery decision was made before finalization.
        let beforeFinish = observations.buffers
        recorder.testBeginFinalization()
        TestHardware.block = nil; TestHardware.release.signal()
        _ = try await recovering.value
        precondition(observations.buffers == beforeFinish && recorder.duration == 0,
                     "Already-running recovery must not reopen capture after finalization")
        let finishedDuringRecovery = try await recorder.stop()
        precondition(finishedDuringRecovery.isEmpty)
        recorder.cancel(); try await recorder.testDrain()
        print("PASS finalization racing already-running recovery never admits post-finish audio")

        // A HAL call is intentionally blocked; the MainActor must keep scheduling
        // heartbeats, cancellation must resolve immediately, and timeout must poison
        // the SAME serial worker even though the native call cannot be interrupted.
        for stage in ["inputNode", "start", "stop"] {
            let hung = AudioRecorder()
            if stage == "stop" { try await hung.start() }
            TestHardware.block = stage
            let pending = Task { @MainActor in
                if stage == "stop" { _ = try await hung.stop() }
                else { try await hung.start() }
            }
            try await waitForNative()
            var heartbeat = 0
            for _ in 0..<10 { await Task.yield(); heartbeat += 1 }
            precondition(heartbeat == 10, "MainActor heartbeat blocked by HAL")
            await expectFailure("Quit and reopen Talkless") { try await pending.value }
            let total = TestHardware.enginesCreated
            await expectFailure("Quit and reopen Talkless") { try await hung.start() }
            precondition(TestHardware.enginesCreated == total)
            TestHardware.block = nil; TestHardware.release.signal()
            await drain()
        }
        print("PASS inputNode/start/stop hangs time out independently, UI heartbeat runs, poisoned worker cannot restart")

        for stage in ["inputNode", "start", "stop"] {
            let cancelled = AudioRecorder()
            if stage == "stop" { try await cancelled.start() }
            TestHardware.block = stage
            let pending = Task { @MainActor in
                if stage == "stop" { _ = try await cancelled.stop() }
                else { try await cancelled.start() }
            }
            try await waitForNative()
            cancelled.cancel()
            do { try await pending.value; fatalError("Cancel must throw immediately") } catch is CancellationError {}
            precondition(!cancelled.isRunning)
            TestHardware.block = nil; TestHardware.release.signal()
            try await cancelled.testDrain()
            try await cancelled.start()
            try await cancelled.testNative { $0.deliver() }
            let recoveredSamples = try await cancelled.stop(); precondition(!recoveredSamples.isEmpty)
            cancelled.cancel(); try await cancelled.testDrain()
        }
        print("PASS immediate cancellation during blocked inputNode/start/stop; eventual cleanup and healthy restart on same worker")

        for stage in ["inputNode", "start", "stop"] {
            let rapid = AudioRecorder()
            if stage == "stop" { try await rapid.start() }
            TestHardware.block = stage
            let old = Task { @MainActor in
                if stage == "stop" { _ = try await rapid.stop() }
                else { try await rapid.start() }
            }
            try await waitForNative()
            rapid.cancel()
            let new = Task { @MainActor in try await rapid.start(deviceUID: "usb-mic") }
            await drain() // Reserve the new generation BEFORE old native work returns.
            old.cancel() // Its late task cancellation must not invalidate the new session.
            TestHardware.block = nil; TestHardware.release.signal()
            do { try await old.value; fatalError("Old generation must be cancelled") } catch is CancellationError {}
            try await new.value
            precondition(rapid.isRunning && rapid.interruptionError == nil)
            try await rapid.testNative { $0.deliver(stale: true); $0.deliver() }
            let freshSamples = try await rapid.stop()
            precondition(!freshSamples.isEmpty && freshSamples.count < 2000)
            rapid.cancel(); try await rapid.testDrain()
        }
        print("PASS immediate cancel-to-new-start survives late old task cancellation and native completion")

        var disposable: AudioRecorder? = AudioRecorder()
        try await disposable!.start()
        _ = try await disposable!.stop()
        let destroyed = TestHardware.enginesDestroyed
        weak let weakRecorder = disposable
        disposable = nil
        for _ in 0..<100 {
            if TestHardware.enginesDestroyed > destroyed { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        precondition(weakRecorder == nil && TestHardware.enginesDestroyed > destroyed)
        print("PASS dropping recorder schedules native teardown/destruction off MainActor")

        let stuck = AudioRecorder()
        TestHardware.block = "start"
        let pending = Task { @MainActor in try await stuck.start() }
        try await waitForNative()
        pending.cancel()
        do { try await pending.value; fatalError("Task cancellation must resolve") } catch is CancellationError {}
        try await Task.sleep(for: .milliseconds(300))
        await expectFailure("Quit and reopen Talkless") { try await stuck.start() }
        TestHardware.block = nil; TestHardware.release.signal()
        print("PASS cancelled-but-still-hung native operation keeps deadline and poisons recorder")

        let logs = Diagnostics.shared.snapshot()
        for event in ["audio_start", "audio_start_configuration", "audio_engine_started", "audio_start_failed",
                      "audio_engine_configuration_change", "audio_first_buffer", "audio_recording_summary",
                      "audio_interruption", "audio_recovery", "audio_operation_timeout", "audio_engine_reused"] {
            precondition(logs.contains { $0.0 == event }, "Missing event \(event)")
        }
        for (_, fields) in logs {
            precondition(UUID(uuidString: fields["operation_id"]!) != nil)
            precondition(!fields.values.contains { $0.contains("usb-mic") || $0.contains("Built-in") || $0.contains("Microphone") })
        }
        print("PASS privacy-safe diagnostics, no HAL/engine work on main, no diagnostics on realtime callback")
    }
}
'''


def run(*args):
    subprocess.run(args, check=True, env=ENV)


ENV = os.environ.copy()
ENV.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer")
ENV["SDKROOT"] = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], env=ENV, text=True).strip()
with tempfile.TemporaryDirectory(prefix="talkless-audio-tests-") as work:
    directory = Path(work)
    source = SOURCE.read_text() + "\n" + OPERATIONS.read_text() + "\n" + DEVICES.read_text() + STUBS
    # Typecheck the unmodified production native APIs separately from stubbed runtime.
    production = directory / "production.swift"
    production.write_text(source.replace('precondition(!TestContext.inCallback, "No diagnostics on the realtime audio callback")', ''))
    run("xcrun", "swiftc", "-swift-version", "6", "-typecheck", str(production))
    sil = directory / "production.sil"
    run("xcrun", "swiftc", "-swift-version", "6", "-O", "-emit-sil", str(production), "-o", str(sil))
    closures = re.findall(r"^// closure #\d+ in NativeAudioRecorder\.installAndStart\(session:\)\n.*?^} // end sil function[^\n]*", sil.read_text(), re.M | re.S)
    taps = [body for body in closures if "AVAudioPCMBuffer" in body.split("\nbb0(", 1)[0]]
    assert len(taps) == 1 and "// Isolation: nonisolated" in taps[0]
    assert "swift_task_isCurrentExecutor" not in taps[0]
    assert "swift_task_reportUnexpectedExecutor" not in taps[0]
    print("PASS production tap has no MainActor executor assertion", flush=True)
    stubbed = re.sub(r"\bAVAudioEngine\b", "TestAudioEngine", source)
    for native, test in [("AudioObjectGetPropertyDataSize", "TestGetPropertyDataSize"),
                         ("AudioObjectGetPropertyData", "TestGetPropertyData"),
                         ("AudioUnitSetProperty", "TestSetProperty"),
                         ("AudioUnitGetProperty", "TestGetProperty")]:
        stubbed = stubbed.replace(native, test)
    stubbed = stubbed.replace("ProcessInfo.processInfo.systemUptime", "TestClock.now")
    # Same independent timer path, shortened only for deterministic blocked-HAL tests.
    stubbed = stubbed.replace(".now() + seconds", ".now() + min(seconds, 0.2)")
    freeze = "                    let result = lock.withLock { () -> (Bool, String?) in"
    assert freeze in stubbed
    stubbed = stubbed.replace(freeze, """                    if TestHardware.notifyBeforeFreeze {
                        TestHardware.notifyBeforeFreeze = false
                        TestAudioEngine.latest!.notify()
                    }
""" + freeze)
    runtime = directory / "runtime.swift"
    runtime.write_text(stubbed + HARNESS)
    executable = directory / "audio-tests"
    run("xcrun", "swiftc", "-swift-version", "6", "-O", "-parse-as-library", str(runtime), "-o", str(executable))
    run(str(executable))
