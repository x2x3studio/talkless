import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Per-attempt SPSC storage. Only the tap writes slots; only `processing` reads them.
/// Gate CAS also rejects overlapping producers rather than blocking a realtime thread.
private final class AudioCaptureQueue: @unchecked Sendable {
    static let slotCount = 96
    // A 1024-frame tap request can deliver 4800 frames at 48 kHz. Leave bounded
    // headroom instead of treating that normal AVAudioEngine batching as failure.
    static let frameCapacity: AVAudioFrameCount = 8192
    private static let closed: UInt = 1
    private static let writing: UInt = 2
    private static let cancelled: UInt = 4

    enum Failure: Int {
        case overflow = 1, oversized, formatChanged, overlappingCallback, conversion
        var reason: String {
            switch self {
            case .overflow: "capture_queue_overflow"
            case .oversized: "capture_buffer_too_large"
            case .formatChanged: "format_changed"
            case .overlappingCallback: "capture_overlapping_callback"
            case .conversion: "conversion_failed"
            }
        }
    }

    let converter: AVAudioConverter
    // Confined to processing; never read, cleared or grown under the facade state lock.
    var samples: [Float] = []
    private let slots: [AVAudioPCMBuffer]
    private let description: AudioStreamBasicDescription
    private let gate = Atomic<UInt>(0)
    private let written = Atomic<UInt>(0)
    private let read = Atomic<UInt>(0)
    private let failure = Atomic<Int>(0)
    private let firstReceived = Atomic<UInt64>(0)
    private let lastReceived = Atomic<UInt64>(0)
    private let processing = DispatchQueue(label: "talkless.audio.processing", qos: .userInitiated)
    private let wake: DispatchSourceUserDataAdd
    private let consume: @Sendable (AVAudioPCMBuffer, AudioCaptureQueue) -> Void

    init(format: AVAudioFormat, converter: AVAudioConverter,
         consume: @escaping @Sendable (AVAudioPCMBuffer, AudioCaptureQueue) -> Void) throws {
        self.converter = converter
        self.consume = consume
        description = format.streamDescription.pointee
        var storage: [AVAudioPCMBuffer] = []
        storage.reserveCapacity(Self.slotCount)
        for _ in 0..<Self.slotCount {
            guard let slot = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.frameCapacity) else {
                throw TalklessError.message(L10n.tr("Cannot convert the microphone audio format"))
            }
            // Touch backing memory before installing the tap, not on first capture.
            slot.frameLength = Self.frameCapacity
            for plane in UnsafeMutableAudioBufferListPointer(slot.mutableAudioBufferList) {
                if let data = plane.mData { memset(data, 0, Int(plane.mDataByteSize)) }
            }
            slot.frameLength = 0
            storage.append(slot)
        }
        slots = storage
        wake = DispatchSource.makeUserDataAddSource(queue: processing)
        wake.setEventHandler { [weak self] in self?.drain() }
        wake.resume()
    }

    deinit { wake.cancel() }

    var failureReason: String? { Failure(rawValue: failure.load(ordering: .acquiring))?.reason }
    var firstBufferTime: TimeInterval? { time(firstReceived.load(ordering: .acquiring)) }
    var lastBufferTime: TimeInterval? { time(lastReceived.load(ordering: .acquiring)) }
    private func time(_ value: UInt64) -> TimeInterval? { value == 0 ? nil : Double(value) / 1_000_000_000 }

    func close() { gate.bitwiseOr(Self.closed, ordering: .acquiringAndReleasing) }
    func cancel() { gate.bitwiseOr(Self.closed | Self.cancelled, ordering: .acquiringAndReleasing) }

    func fail(_ reason: Failure) {
        _ = failure.compareExchange(expected: 0, desired: reason.rawValue, ordering: .acquiringAndReleasing)
        close()
        wake.add(data: 1)
    }

    /// An in-flight copy gets another monitor tick. Queued/processing audio never
    /// moves the reception timestamp. Once closed, this attempt never reopens.
    func closeIfStale(now: TimeInterval, startedAt: TimeInterval) -> Bool {
        let state = gate.load(ordering: .acquiring)
        guard state & (Self.closed | Self.writing | Self.cancelled) == 0, now - (lastBufferTime ?? startedAt) >= 3 else { return false }
        return gate.compareExchange(expected: state, desired: state | Self.closed, ordering: .acquiringAndReleasing).exchanged
    }

    /// Realtime path: no allocation, native state lock, conversion, or client callback.
    /// The dispatch source merges wakeups; it never creates one queued task per buffer.
    func enqueue(_ buffer: AVAudioPCMBuffer) {
        let state = gate.load(ordering: .acquiring)
        guard state & Self.closed == 0 else { return }
        guard state & Self.writing == 0,
              gate.compareExchange(expected: state, desired: state | Self.writing, ordering: .acquiringAndReleasing).exchanged else {
            if gate.load(ordering: .acquiring) & Self.closed == 0 { fail(.overlappingCallback) }
            return
        }
        defer {
            // Advance a version as well as releasing the writer bit. A watchdog
            // cannot close from a stale timestamp after a complete intervening copy.
            gate.wrappingAdd(16, ordering: .relaxed)
            gate.bitwiseAnd(~Self.writing, ordering: .releasing)
            wake.add(data: 1)
        }
        let frames = buffer.frameLength
        guard frames > 0 else { return }
        guard frames <= Self.frameCapacity else { fail(.oversized); return }
        let actual = buffer.format.streamDescription.pointee
        guard actual.mSampleRate == description.mSampleRate,
              actual.mFormatID == description.mFormatID, actual.mFormatFlags == description.mFormatFlags,
              actual.mBytesPerPacket == description.mBytesPerPacket, actual.mFramesPerPacket == description.mFramesPerPacket,
              actual.mBytesPerFrame == description.mBytesPerFrame, actual.mChannelsPerFrame == description.mChannelsPerFrame,
              actual.mBitsPerChannel == description.mBitsPerChannel else { fail(.formatChanged); return }
        let next = written.load(ordering: .relaxed)
        guard next &- read.load(ordering: .acquiring) < UInt(Self.slotCount) else { fail(.overflow); return }
        let slot = slots[Int(next % UInt(Self.slotCount))]
        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let output = UnsafeMutableAudioBufferListPointer(slot.mutableAudioBufferList)
        let bytes = Int(frames) * Int(description.mBytesPerFrame)
        guard input.count == output.count, bytes > 0 else { fail(.formatChanged); return }
        // ASBD bytes-per-frame includes all channels for interleaved PCM and one
        // channel for planar PCM. Copy every ABL plane, including integer formats.
        for index in 0..<input.count {
            guard input[index].mNumberChannels == output[index].mNumberChannels,
                  Int(input[index].mDataByteSize) >= bytes,
                  input[index].mData != nil, output[index].mData != nil else { fail(.formatChanged); return }
        }
        slot.frameLength = frames
        for index in 0..<input.count { memcpy(output[index].mData!, input[index].mData!, bytes) }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if firstReceived.load(ordering: .relaxed) == 0 { firstReceived.store(now, ordering: .releasing) }
        lastReceived.store(now, ordering: .releasing)
        written.store(next &+ 1, ordering: .releasing)
    }

    private func drain() {
        for _ in 0..<Self.slotCount {
            let next = read.load(ordering: .relaxed)
            guard next != written.load(ordering: .acquiring) else { return }
            if gate.load(ordering: .acquiring) & Self.cancelled == 0, failure.load(ordering: .acquiring) == 0 {
                consume(slots[Int(next % UInt(Self.slotCount))], self)
            }
            // A consumer owns the slot through conversion and feed, so an overflow
            // cannot overwrite even the buffer whose callback is currently blocked.
            read.store(next &+ 1, ordering: .releasing)
        }
        if read.load(ordering: .relaxed) != written.load(ordering: .acquiring) { wake.add(data: 1) }
    }

    /// Native lifecycle worker ONLY, never MainActor or processing. Closing admission
    /// precedes this fence; wait for an admitted copy, then include its final wakeup.
    func drainAndWait() {
        close()
        while gate.load(ordering: .acquiring) & Self.writing != 0 { Thread.sleep(forTimeInterval: 0.001) }
        processing.sync { drain() }
    }

    func collectedSamples() -> [Float] { processing.sync { samples } }
}

/// Main-actor-facing lifecycle; no native engine/HAL operation happens on this actor.
final class AudioRecorder: @unchecked Sendable {
    static let sampleRate: Double = 16_000
    static let format = NativeAudioRecorder.format
    private let operations = AudioOperationQueue()
    private let native = NativeAudioRecorder()
    @MainActor private var session: UUID?
    @MainActor private var operationID = UUID()
    @MainActor private var monitorTask: Task<Void, Never>?

    var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { native.onBuffer }
        set { native.onBuffer = newValue }
    }
    var onLevel: (@Sendable (Float) -> Void)? {
        get { native.onLevel }
        set { native.onLevel = newValue }
    }
    var onError: (@MainActor @Sendable (String) -> Void)? {
        get { native.onError }
        set { native.onError = newValue }
    }
    var interruptionError: String? { native.interruptionError }
    var isRunning: Bool { native.isRunning }
    var duration: TimeInterval { native.duration }

    @MainActor init() {}

    @MainActor
    func start(deviceUID: String? = nil, operationID: UUID? = nil) async throws {
        if session != nil { cancel() }
        let session = native.reserveSession()
        let operation = operationID ?? UUID()
        self.session = session
        self.operationID = operation
        do {
            try await perform(timeout: 5, stage: "startup", session: session, operation: operation) { native in
                try native.start(session: session, deviceUID: deviceUID, operationID: operation)
            }
            guard self.session == session else { throw CancellationError() }
            monitorTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard let self, self.session == session else { return }
                    do {
                        let keepMonitoring = try await self.perform(timeout: 3, stage: "recording", session: session, operation: operation) {
                            $0.monitor(session: session)
                        }
                        if !keepMonitoring { return }
                    } catch { return }
                }
            }
        } catch {
            if self.session == session {
                native.invalidate(session: session, message: error is CancellationError ? nil : error.localizedDescription)
                self.session = nil
                queueCleanup(session: session, operation: operation)
            }
            throw error
        }
    }

    /// Close only the current capture gate, including an in-flight startup. Keep
    /// accepted buffers for stop(); all native validation/teardown stays on its worker.
    /// False means startup has not reserved a session, so there is nothing to finish.
    @MainActor
    @discardableResult
    func beginFinalization() -> Bool {
        guard session != nil else { return false }
        native.beginFinalization()
        monitorTask?.cancel()
        monitorTask = nil
        return true
    }

    @MainActor
    func stop() async throws -> [Float] {
        guard let session else {
            if let error = interruptionError { throw TalklessError.message(error) }
            return []
        }
        // Closing capture never waits for processing; final HAL validation precedes engine.stop.
        beginFinalization()
        do {
            let samples = try await perform(timeout: 3, stage: "shutdown", session: session, operation: operationID) {
                try $0.stop(session: session)
            }
            guard self.session == session else { throw CancellationError() }
            self.session = nil
            return samples
        } catch {
            if self.session == session {
                native.invalidate(session: session, message: error is CancellationError ? nil : error.localizedDescription)
                self.session = nil
                queueCleanup(session: session, operation: operationID)
            }
            throw error
        }
    }

    @MainActor
    func cancel() {
        monitorTask?.cancel()
        monitorTask = nil
        let cancelledSession = session
        session = nil
        native.invalidate()
        queueCleanup(session: cancelledSession, operation: operationID)
    }

    @MainActor
    private func perform<Value: Sendable>(timeout: TimeInterval, stage: String, session: UUID, operation: UUID,
                                         work: @escaping @Sendable (NativeAudioRecorder) throws -> Value) async throws -> Value {
        let native = native
        return try await withTaskCancellationHandler {
            try await operations.run(timeout: timeout, onTimeout: { [weak self] in
                let shouldNotify = native.invalidate(session: session, message: L10n.tr(AudioOperationQueue.unresponsive))
                Self.logTimeout(stage: stage, operation: operation)
                guard shouldNotify else { return }
                Task { @MainActor in
                    guard let self, self.session == session else { return }
                    if stage == "recording" { self.onError?(L10n.tr(AudioOperationQueue.unresponsive)) }
                }
            }) { try work(native) }
        } onCancel: {
            if stage != "recording" { native.invalidate(session: session) }
        }
    }

    private func queueCleanup(session: UUID?, operation: UUID) {
        let native = native
        operations.cancel(cleanup: { native.tearDownAttempt() }, onTimeout: {
            // A cancelled operation can time out after the next turn is reserved.
            // Its deadline poisons the worker, but must not mutate that new capture.
            if let session { native.invalidate(session: session, message: L10n.tr(AudioOperationQueue.unresponsive)) }
            Self.logTimeout(stage: "cleanup", operation: operation)
        })
    }

    private static func logTimeout(stage: String, operation: UUID) {
        Diagnostics.shared.recordAsync(event: "audio_operation_timeout", metadata: [
            "operation_id": operation.uuidString, "stage": stage, "reason": "native_operation_timeout",
        ])
    }

    deinit {
        // NativeAudioRecorder may outlive this facade indefinitely if HAL is hung.
        // A healthy teardown clears all native references before its eventual deinit.
        let native = native
        native.invalidate()
        operations.cancel(cleanup: { native.tearDownAttempt() }, onTimeout: {})
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

/// Capture audio from the chosen microphone and convert it to 16 kHz mono Float32.
/// Engine inspection/teardown is confined to AudioOperationQueue. Native callbacks
/// enqueue into bounded storage; neither callback logs or tears down native objects.
private final class NativeAudioRecorder: @unchecked Sendable {
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
    /// Call stop() before inspecting this when finalizing a streaming transcript.
    var interruptionError: String? { lock.withLock { recordingError } }
    var isRunning: Bool { lock.withLock { sessionID != nil && recordingError == nil } }
    var duration: TimeInterval { lock.withLock { Double(frameCount) / Self.sampleRate } }

    private let lock = NSLock()
    // Only short metadata operations hold this MainActor-facing lock.
    private var capture: AudioCaptureQueue?
    private var finalizing = false
    private var bufferCallback: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var levelCallback: (@Sendable (Float) -> Void)?
    private var errorCallback: (@MainActor @Sendable (String) -> Void)?
    private var sessionID: UUID?
    private var attemptID: UUID?
    private var recordingError: String?
    private var captureFailure: String? { capture?.failureReason }
    private var configurationRevision = 0
    private var validationScheduled = false
    private var bufferCount = 0
    private var inputFrameCount = 0
    private var frameCount = 0
    private var firstBufferTime: TimeInterval? { capture?.firstBufferTime }
    private var lastBufferTime: TimeInterval? { capture?.lastBufferTime }

    fileprivate var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var baseline: Configuration?
    private var deviceUID: String?
    private var operationID = UUID()
    private var startedAt: TimeInterval = 0
    private var attemptStartedAt: TimeInterval = 0
    private var configuredUID: String?
    private var tapInstalled = false
    private var firstBufferLogged = false

    private struct Configuration {
        let device: AudioDeviceID
        let actualDevice: AudioDeviceID
        let resolvedAvailable: Bool
        let currentDeviceStatus: OSStatus
        let routeMatchesRequested: Bool
        let routeKind: String
        let running: Bool
        let tap: AVAudioFormat
        let hardware: AVAudioFormat

        var available: Bool {
            resolvedAvailable && currentDeviceStatus == noErr && actualDevice != kAudioObjectUnknown
        }
        var valid: Bool {
            [tap, hardware].allSatisfy {
                $0.sampleRate.isFinite && $0.sampleRate > 0 && $0.channelCount > 0
            }
        }
        var formatsCompatible: Bool {
            valid && tap.sampleRate == hardware.sampleRate && tap.channelCount == hardware.channelCount
        }
        func sameFormats(as other: Configuration) -> Bool {
            // Explicit input uses the hardware format. A stale client output format
            // catching up after selection is not a change to the installed tap.
            tap == other.tap && hardware == other.hardware
        }
        func sameRoute(as other: Configuration) -> Bool {
            device == other.device && actualDevice == other.actualDevice
        }
        func startupFailure(requested: AudioDeviceID, previous: Configuration) -> String? {
            if !resolvedAvailable { return "device_unavailable" }
            if !available { return "route_unavailable" }
            if device != requested { return "device_changed" }
            if !routeMatchesRequested { return "route_mismatch" }
            if !formatsCompatible { return "invalid_format" }
            if !previous.available || !sameRoute(as: previous) || !sameFormats(as: previous) {
                return "configuration_race"
            }
            return nil
        }
    }

    init() {}

    private static let interrupted = "Microphone recording was interrupted because the audio device changed or disconnected. Check your microphone and start again."
    private static let noAudio = "The microphone did not deliver audio. Check your microphone and try again."
    private static var now: TimeInterval { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000 }

    /// Only the facade reserves/invalidates a session. A cancelled queued startup
    /// must never recreate it when the native worker eventually returns.
    func beginFinalization() {
        lock.withLock { finalizing = true; capture?.close() }
    }

    func reserveSession() -> UUID {
        let session = UUID()
        lock.withLock {
            capture?.cancel()
            sessionID = session
            finalizing = false
            recordingError = nil
            frameCount = 0
        }
        return session
    }

    @discardableResult
    func invalidate(session: UUID? = nil, message: String? = nil) -> Bool {
        lock.withLock {
            if let session, sessionID != session { return false }
            // Preserve a pending interruption notification if cleanup hits its own
            // deadline before the MainActor has delivered that original failure.
            if message != nil, recordingError != nil { return false }
            let wasHealthy = recordingError == nil
            capture?.cancel()
            sessionID = nil
            attemptID = nil
            if wasHealthy, let message { recordingError = message }
            frameCount = 0
            return wasHealthy
        }
    }

    func checkSession(_ session: UUID) throws {
        guard lock.withLock({ sessionID == session }) else { throw CancellationError() }
    }

    func start(session: UUID, deviceUID: String?, operationID: UUID) throws {
        try checkSession(session)
        self.deviceUID = deviceUID
        self.operationID = operationID
        startedAt = Self.now
        firstBufferLogged = false
        lock.withLock {
            bufferCount = 0
            frameCount = 0
            inputFrameCount = 0
            configurationRevision = 0
            validationScheduled = false
        }
        log("audio_start")
        do {
            try installAndStart(session: session)
            try checkSession(session)
            if let reason = validationFailure(session: session, stage: "startup") {
                log("audio_interruption", fields: ["reason": reason, "stage": "startup"])
                throw TalklessError.message(L10n.tr(Self.interrupted))
            }
            try checkSession(session)
            log("audio_engine_started", fields: ["startup_ms": milliseconds(since: startedAt)])
        } catch {
            log("audio_start_failed", fields: ["reason": "start_failed"])
            lock.withLock {
                if sessionID == session { recordingError = error.localizedDescription; capture?.cancel() }
            }
            tearDownAttempt()
            throw error
        }
    }

    private func installAndStart(session: UUID) throws {
        // Validate hardware before accessing inputNode, which can otherwise advertise
        // a fictitious format and make installTap raise an Objective-C exception.
        var device: AudioDeviceID
        do { device = try AudioInputDevices.resolve(uid: deviceUID) }
        catch {
            log("audio_start_failed", fields: ["reason": "device_unavailable", "resolved_device_available": "false"])
            throw error
        }
        try checkSession(session)
        if let engine, let baseline {
            let current = snapshot(engine: engine)
            if configuredUID != deviceUID {
                // A user-selected input change starts a fresh route, never a fallback.
                tearDownAttempt()
            } else if let reason = current.startupFailure(requested: device, previous: baseline) {
                log("audio_start_failed", configuration: current, fields: ["reason": reason])
                throw startupError(reason: reason)
            }
        }
        let reused = self.engine != nil
        let engine = self.engine ?? AVAudioEngine()
        self.engine = engine // Ownership, including failure/deinit, stays on native queue.
        let input = engine.inputNode
        try checkSession(session)
        guard let audioUnit = input.audioUnit else {
            throw TalklessError.message(L10n.tr("Cannot configure the microphone audio input"))
        }
        // Preserve the working system-default route: setting CurrentDevice here causes
        // unnecessary HAL reconfiguration during prepare/start on some microphones.
        if deviceUID != nil, !reused {
            var actual = AudioDeviceID(kAudioObjectUnknown)
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            let readStatus = AudioUnitGetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                                 kAudioUnitScope_Global, 0, &actual, &size)
            let status = readStatus == noErr && actual == device ? noErr : AudioUnitSetProperty(
                audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &device, UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                log("audio_start_failed", fields: ["reason": "unavailable", "error_code": String(status)])
                throw TalklessError.message(L10n.format("Cannot use the selected microphone (Core Audio error %d). Reconnect it or choose another microphone in Settings › Dictation › Audio.", status))
            }
        }
        // Default input keeps the original node output format. Explicit selection uses
        // hardware input format because the node's client output can still be cached.
        // Derive the converter and tap from ONE coherent snapshot, not an earlier read.
        // A changing route fails this attempt; only the user starts another one.
        let previous = snapshot(engine: engine)
        let configuration = snapshot(engine: engine)
        if let startupReason = configuration.startupFailure(requested: device, previous: previous) {
            log("audio_start_failed", configuration: configuration, fields: ["reason": startupReason])
            throw startupError(reason: startupReason)
        }
        let format = configuration.tap
        guard let converter = AVAudioConverter(from: format, to: Self.format) else {
            throw TalklessError.message(L10n.tr("Cannot convert the microphone audio format"))
        }
        configuredUID = deviceUID
        baseline = configuration
        if reused { log("audio_engine_reused", configuration: configuration, fields: ["stage": "startup"]) }
        try checkSession(session)
        let attempt = UUID()
        let capture = try AudioCaptureQueue(format: format, converter: converter) { [weak self] buffer, capture in
            self?.process(buffer, capture: capture, session: session, attempt: attempt)
        }
        // Releasing the previous recording can free a large sample array. Retain
        // it across the swap so destruction cannot happen under the state lock.
        let previousCapture = lock.withLock { self.capture }
        lock.withLock {
            guard sessionID == session else { capture.cancel(); return }
            self.capture = capture
            attemptID = attempt
            // Pending startup must not reopen capture after the key-release boundary.
            if finalizing { capture.close() }
            validationScheduled = false
        }
        withExtendedLifetime(previousCapture) {}
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { @Sendable [weak self] _ in
            self?.configurationChanged(session: session, attempt: attempt)
        }
        log("audio_start_configuration", configuration: configuration, fields: ["stage": "startup"])
        // Check again after observer registration/logging, immediately before native
        // installation. HAL may still race any read; no Swift guard catches NSException.
        let current = snapshot(engine: engine)
        if let reason = current.startupFailure(requested: device, previous: configuration) {
            log("audio_start_failed", configuration: current, fields: ["reason": reason])
            // No tap exists yet; detach state so outer cleanup cannot remove a missing tap.
            if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
            configurationObserver = nil
            self.engine = nil
            throw startupError(reason: reason)
        }
        // AVAudioNodeTapBlock is non-Sendable: explicitly opt out of inherited MainActor isolation.
        try checkSession(session)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            capture.enqueue(buffer)
        }
        tapInstalled = true
        try checkSession(session)
        engine.prepare()
        try checkSession(session)
        try engine.start()
        try checkSession(session)
        attemptStartedAt = Self.now
    }

    private func startupError(reason: String) -> TalklessError {
        let message: String
        switch reason {
        case "device_unavailable":
            message = deviceUID == nil
                ? "No available microphone found. Connect a microphone and select it in System Settings › Sound › Input."
                : "The selected microphone is unavailable. Reconnect it or choose another microphone in Settings › Dictation › Audio."
        case "route_unavailable":
            message = "Cannot read the microphone audio input. Check your microphone and try again."
        case "route_mismatch":
            message = "The audio input did not switch to the selected microphone. Choose it again in Settings › Dictation › Audio and try again."
        case "invalid_format":
            message = "The microphone audio format is not ready. Check your microphone and try again."
        default:
            message = "The microphone configuration changed while recording was starting. Try again."
        }
        return .message(L10n.tr(message))
    }

    private func configurationChanged(session: UUID, attempt: UUID) {
        // No HAL, task creation, logging, or teardown on the notification thread.
        lock.withLock {
            guard sessionID == session, attemptID == attempt, recordingError == nil else { return }
            configurationRevision += 1
            validationScheduled = true
        }
    }

    private func snapshot(engine: AVAudioEngine) -> Configuration {
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        let output = input.outputFormat(forBus: 0)
        let resolved = try? AudioInputDevices.resolve(uid: deviceUID)
        var actual = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status: OSStatus
        if let unit = input.audioUnit {
            status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &actual, &size)
        } else { status = -1 }
        let routeAvailable = resolved != nil && status == noErr && actual != kAudioObjectUnknown
        // AVAudioEngine may wrap the system default in a private aggregate. Do not pin
        // that default or require aggregate membership metadata: capture its actual ID
        // as the baseline, then compare BOTH IDs on every subsequent validation.
        // Explicit selection is different: a successful setter must read back that device.
        let routeMatches = routeAvailable && (deviceUID == nil || actual == resolved)
        return Configuration(device: resolved ?? AudioDeviceID(kAudioObjectUnknown), actualDevice: actual,
                             resolvedAvailable: resolved != nil, currentDeviceStatus: status,
                             routeMatchesRequested: routeMatches,
                             routeKind: status == noErr
                                ? AudioInputDevices.routeKind(actual: actual, requested: resolved ?? AudioDeviceID(kAudioObjectUnknown))
                                : "unknown",
                             running: engine.isRunning, tap: deviceUID == nil ? output : hardware,
                             hardware: hardware)
    }

    private func failure(for configuration: Configuration) -> String? {
        guard let baseline else { return "invalid_format" }
        if !configuration.resolvedAvailable { return "device_unavailable" }
        if !configuration.available { return "route_unavailable" }
        if !configuration.sameRoute(as: baseline) { return "device_changed" }
        if !configuration.routeMatchesRequested { return "route_mismatch" }
        if !configuration.formatsCompatible || !configuration.sameFormats(as: baseline) { return "format_changed" }
        if !configuration.running { return "engine_stopped" }
        return lock.withLock { captureFailure }
    }

    /// Read native state outside our lock, then verify no notification raced the read.
    /// Bounded retries avoid spinning when a driver continually changes configuration.
    private func assessment() -> (Configuration, String?, Int) {
        let engine = self.engine!
        var configuration = snapshot(engine: engine)
        for _ in 0..<3 {
            let revision = lock.withLock { configurationRevision }
            configuration = snapshot(engine: engine)
            let reason = failure(for: configuration)
            if reason != nil || lock.withLock({ configurationRevision == revision }) { return (configuration, reason, revision) }
        }
        return (configuration, "configuration_race", lock.withLock { configurationRevision })
    }

    private func validationFailure(session: UUID, stage: String) -> String? {
        guard lock.withLock({ sessionID == session }), engine != nil else { return nil }
        let (configuration, reason, revision) = assessment()
        log("audio_engine_configuration_change", configuration: configuration, fields: [
            "stage": stage, "reason": reason ?? "unchanged",
        ])
        if reason == nil {
            lock.withLock {
                if sessionID == session && configurationRevision == revision { validationScheduled = false }
            }
        }
        return reason
    }

    fileprivate func monitor(session: UUID) -> Bool {
        guard lock.withLock({ sessionID == session && !finalizing }) else { return false }
        logFirstBuffer()
        let state = lock.withLock { (captureFailure, validationScheduled) }
        if state.0 != nil || state.1 || engine?.isRunning == false {
            if let reason = validationFailure(session: session, stage: "recording") {
                interrupt(session: session, reason: reason, message: L10n.tr(Self.interrupted))
                return false
            }
        }
        let lastBuffer = lock.withLock { lastBufferTime }
        if Self.now - (lastBuffer ?? attemptStartedAt) >= 3 {
            return !interrupt(session: session, reason: lastBuffer == nil ? "no_audio_timeout" : "audio_stalled_timeout",
                              message: L10n.tr(Self.noAudio), audioTimeout: true)
        }
        return true
    }

    @discardableResult
    private func interrupt(session: UUID, reason: String, message: String, audioTimeout: Bool = false) -> Bool {
        let current = lock.withLock {
            guard sessionID == session, !finalizing, recordingError == nil else { return false }
            // A buffer may have arrived after monitor's snapshot. Commit the timeout
            // only if the atomic admission version still matches its receive time.
            if audioTimeout {
                guard capture?.closeIfStale(now: Self.now, startedAt: attemptStartedAt) == true else { return false }
            }
            recordingError = message
            capture?.cancel()
            attemptID = nil
            frameCount = 0
            return true
        }
        guard current else { return false }
        // Notify before any HAL teardown: engine.stop/removeTap can hang. The
        // owning operation keeps its independent deadline while cleanup runs here.
        Task { @MainActor [weak self] in
            guard let self, self.lock.withLock({ self.sessionID == session && self.recordingError == message }) else { return }
            self.onError?(message)
        }
        log("audio_interruption", fields: ["reason": reason, "stage": "recording"])
        tearDownAttempt()
        return true
    }

    func stop(session: UUID) throws -> [Float] {
        try checkSession(session)
        let active = lock.withLock {
            // Close the admission gate immediately; native teardown later drains any
            // in-flight conversion/callback without holding this state lock.
            capture?.close()
            return sessionID != nil
        }
        if active {
            // A buffer admitted before key release owns its final conversion and
            // feed callback. Drain it on the worker before freezing the sample list.
            let capture = lock.withLock { self.capture }
            capture?.drainAndWait()
            try checkSession(session)
            // A key release may beat the queued configuration handler. Inspect native
            // state now, before normal teardown itself stops the engine and notifies.
            if engine != nil, lock.withLock({ recordingError == nil }) {
                // A notification racing the final lock is not itself an interruption.
                // Reassess, then freeze only a matching revision; continuous churn is
                // bounded and fails closed rather than returning potentially partial audio.
                for attempt in 0..<3 {
                    let (configuration, assessedReason, revision) = assessment()
                    let result = lock.withLock { () -> (Bool, String?) in
                        guard sessionID == session else { return (true, "cancelled") }
                        if configurationRevision != revision && attempt < 2 { return (false, nil) }
                        let reason = configurationRevision == revision ? assessedReason : "configuration_race"
                        if reason != nil { recordingError = L10n.tr(Self.interrupted) }
                        sessionID = nil
                        return (true, reason)
                    }
                    guard result.0 else { continue }
                    if let reason = result.1 {
                        log("audio_interruption", configuration: configuration, fields: ["stage": "shutdown", "reason": reason])
                    }
                    break
                }
            }
            lock.withLock {
                guard sessionID == session || sessionID == nil else { return }
                sessionID = nil
                if recordingError != nil { frameCount = 0 }
            }
            logFirstBuffer()
            log("audio_recording_summary", fields: ["stage": "shutdown"], asynchronous: true)
        }
        let failed = lock.withLock { recordingError }
        if failed != nil { tearDownAttempt() }
        else { finishCapture() }
        if let failed { throw TalklessError.message(failed) }
        return lock.withLock { capture }?.collectedSamples() ?? []
    }

    /// Stop the microphone between turns, but preserve the negotiated engine route.
    /// The converter and tap are per-recording, so neither resampler state nor late
    /// callbacks can contaminate a new utterance on this reused engine.
    private func finishCapture() {
        let capture = lock.withLock {
            attemptID = nil; validationScheduled = false
            self.capture?.cancel()
            return self.capture
        }
        // Only the native worker waits; never hold the state lock across a drain.
        capture?.drainAndWait()
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0); tapInstalled = false }
        // The per-attempt queue remains alive through any stale tap closure. Its gate
        // stays cancelled; the next attempt gets new slots and a new converter.
    }

    fileprivate func tearDownAttempt() {
        finishCapture()
        engine = nil
        baseline = nil
        configuredUID = nil
    }

    private func process(_ buffer: AVAudioPCMBuffer, capture: AudioCaptureQueue, session: UUID, attempt: UUID) {
        func captureIsCurrent() -> Bool {
            sessionID == session && attemptID == attempt && recordingError == nil && capture.failureReason == nil
        }
        // Admission was decided on the tap. Finalization preserves every queued tail
        // buffer; cancellation invalidates even the currently converting generation.
        guard lock.withLock({ captureIsCurrent() }) else { return }
        let ratio = Self.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else {
            capture.fail(.conversion); return
        }
        var consumed = false
        var error: NSError?
        let converter = capture.converter
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil else { capture.fail(.conversion); return }
        guard out.frameLength > 0, let data = out.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        let sum = chunk.reduce(Float(0)) { $0 + $1 * $1 }
        let db = 20 * log10(max(sqrt(sum / Float(chunk.count)), 1e-6))
        // Growing a full-recording sample array can allocate/copy. Keep that work
        // entirely off the metadata lock used by MainActor cancellation and meters.
        capture.samples.append(contentsOf: chunk)
        let committed = lock.withLock {
            guard captureIsCurrent() else { return false }
            inputFrameCount += Int(buffer.frameLength)
            bufferCount += 1
            frameCount += Int(out.frameLength)
            return true
        }
        guard committed else { return }
        let level = lock.withLock { captureIsCurrent() ? levelCallback : nil }
        level?(max(0, min(1, (db + 50) / 40)))
        let callback = lock.withLock { captureIsCurrent() ? bufferCallback : nil }
        callback?(out)
    }

    private func logFirstBuffer() {
        guard !firstBufferLogged, let time = lock.withLock({ firstBufferTime }) else { return }
        firstBufferLogged = true
        log("audio_first_buffer", fields: ["first_buffer_ms": String(Int(max(0, time - startedAt) * 1_000))], asynchronous: true)
    }

    private func milliseconds(since time: TimeInterval) -> String {
        String(Int(max(0, Self.now - time) * 1_000))
    }

    private func log(_ event: String, configuration: Configuration? = nil,
                     fields: [String: String] = [:], asynchronous: Bool = false) {
        var metadata = lock.withLock { [
            "buffer_count": String(bufferCount), "frame_count": String(frameCount),
            "input_frame_count": String(inputFrameCount), "notification_count": String(configurationRevision),
            "audio_delivered": String(bufferCount > 0),
            "duration_ms": String(Int(Double(frameCount) / Self.sampleRate * 1_000)),
        ] }
        metadata["operation_id"] = operationID.uuidString
        metadata["elapsed_ms"] = milliseconds(since: startedAt)
        metadata["attempt"] = "1"
        metadata["explicit_device"] = String(deviceUID != nil)
        if let configuration {
            metadata["engine_running"] = String(configuration.running)
            metadata["sample_rate"] = String(configuration.tap.sampleRate)
            metadata["channel_count"] = String(configuration.tap.channelCount)
            metadata["common_format"] = String(configuration.tap.commonFormat.rawValue)
            metadata["interleaved"] = String(configuration.tap.isInterleaved)
            metadata["hardware_sample_rate"] = String(configuration.hardware.sampleRate)
            metadata["hardware_channel_count"] = String(configuration.hardware.channelCount)
            metadata["device_available"] = String(configuration.available)
            metadata["resolved_device_available"] = String(configuration.resolvedAvailable)
            metadata["current_device_status"] = String(configuration.currentDeviceStatus)
            metadata["route_matches_requested"] = String(configuration.routeMatchesRequested)
            metadata["route_kind"] = configuration.routeKind
            metadata["formats_compatible"] = String(configuration.formatsCompatible)
            if let baseline {
                metadata["before_sample_rate"] = String(baseline.tap.sampleRate)
                metadata["before_channel_count"] = String(baseline.tap.channelCount)
                metadata["before_common_format"] = String(baseline.tap.commonFormat.rawValue)
                metadata["before_interleaved"] = String(baseline.tap.isInterleaved)
                metadata["before_hardware_sample_rate"] = String(baseline.hardware.sampleRate)
                metadata["before_hardware_channel_count"] = String(baseline.hardware.channelCount)
                metadata["before_engine_running"] = String(baseline.running)
                metadata["format_changed"] = String(!configuration.sameFormats(as: baseline))
                metadata["device_changed"] = String(!configuration.sameRoute(as: baseline))
                metadata["selected_device_changed"] = String(configuration.device != baseline.device)
                metadata["actual_device_changed"] = String(configuration.actualDevice != baseline.actualDevice)
            }
        }
        metadata.merge(fields) { _, value in value }
        if asynchronous { Diagnostics.shared.recordAsync(event: event, metadata: metadata) }
        else { Diagnostics.shared.record(event: event, metadata: metadata) }
    }

}

enum TalklessError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
