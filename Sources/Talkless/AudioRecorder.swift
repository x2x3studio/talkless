import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Capture audio from the chosen microphone and convert it to 16 kHz mono Float32.
/// Engine inspection/teardown is main-actor-only. Native callbacks only touch locked
/// capture state; in particular, neither callback logs or tears down a Core Audio object.
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
    /// Call stop() before inspecting this when finalizing a streaming transcript.
    var interruptionError: String? { lock.withLock { recordingError } }
    var isRunning: Bool { lock.withLock { sessionID != nil && recordingError == nil } }
    var duration: TimeInterval { lock.withLock { Double(samples.count) / Self.sampleRate } }

    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var tapFormat: AVAudioFormat?
    private var accepting = false
    private var samples: [Float] = []
    private var bufferCallback: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var levelCallback: (@Sendable (Float) -> Void)?
    private var errorCallback: (@MainActor @Sendable (String) -> Void)?
    private var sessionID: UUID?
    private var attemptID: UUID?
    private var recordingError: String?
    private var captureFailure: String?
    private var configurationRevision = 0
    private var validationScheduled = false
    private var bufferCount = 0
    private var inputFrameCount = 0
    private var frameCount = 0
    private var firstBufferTime: TimeInterval?

    @MainActor private var engine: AVAudioEngine?
    @MainActor private var configurationObserver: NSObjectProtocol?
    @MainActor private var monitorTask: Task<Void, Never>?
    @MainActor private var baseline: Configuration?
    @MainActor private var deviceUID: String?
    @MainActor private var operationID = UUID()
    @MainActor private var startedAt: TimeInterval = 0
    @MainActor private var attemptStartedAt: TimeInterval = 0
    @MainActor private var recoveryCount = 0
    @MainActor private var firstBufferLogged = false

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

    @MainActor init() {}

    private static let interrupted = "Microphone recording was interrupted because the audio device changed or disconnected. Check your microphone and start again."
    private static let noAudio = "The microphone did not deliver audio. Check your microphone and try again."

    @MainActor
    func start(deviceUID: String? = nil, operationID: UUID? = nil) throws {
        stop()
        self.deviceUID = deviceUID
        self.operationID = operationID ?? UUID()
        startedAt = ProcessInfo.processInfo.systemUptime
        recoveryCount = 0
        firstBufferLogged = false
        let session = UUID()
        lock.withLock {
            sessionID = session
            recordingError = nil
            captureFailure = nil
            samples.removeAll(keepingCapacity: true)
            bufferCount = 0
            frameCount = 0
            inputFrameCount = 0
            firstBufferTime = nil
            configurationRevision = 0
            validationScheduled = false
        }
        log("audio_start")
        do {
            try installAndStart(session: session)
            try validateOrRecover(session: session, stage: "startup")
            log("audio_engine_started", fields: ["startup_ms": milliseconds(since: startedAt)])
            // A timer, rather than a task/log enqueue from the realtime tap, observes
            // counters and conversion failures. It also bounds a silent startup.
            monitorTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                    guard self?.monitor(session: session) == true else { return }
                }
            }
        } catch {
            log("audio_start_failed", fields: ["reason": "start_failed"])
            lock.withLock { recordingError = error.localizedDescription; accepting = false }
            stop()
            throw error
        }
    }

    @MainActor
    private func installAndStart(session: UUID) throws {
        // Validate hardware before accessing inputNode, which can otherwise advertise
        // a fictitious format and make installTap raise an Objective-C exception.
        var device: AudioDeviceID
        do { device = try AudioInputDevices.resolve(uid: deviceUID) }
        catch {
            log("audio_start_failed", fields: ["reason": "device_unavailable", "resolved_device_available": "false"])
            throw error
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else {
            throw TalklessError.message(L10n.tr("Cannot configure the microphone audio input"))
        }
        // Preserve the working system-default route: setting CurrentDevice here causes
        // unnecessary HAL reconfiguration during prepare/start on some microphones.
        if deviceUID != nil {
            let status = AudioUnitSetProperty(
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
        // Bounded reacquisition handles negotiation between reads without a time delay.
        var configuration = snapshot(engine: engine)
        var startupReason: String?
        for _ in 0..<3 {
            let next = snapshot(engine: engine)
            startupReason = next.startupFailure(requested: device, previous: configuration)
            configuration = next
            if startupReason == nil { break }
        }
        if let startupReason {
            log("audio_start_failed", configuration: configuration, fields: ["reason": startupReason])
            throw startupError(reason: startupReason)
        }
        let format = configuration.tap
        guard let converter = AVAudioConverter(from: format, to: Self.format) else {
            throw TalklessError.message(L10n.tr("Cannot convert the microphone audio format"))
        }
        self.engine = engine
        baseline = configuration
        let attempt = UUID()
        lock.withLock {
            self.converter = converter
            tapFormat = format
            attemptID = attempt
            captureFailure = nil
            accepting = true
            validationScheduled = false
        }
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
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable [weak self] buffer, _ in
            self?.process(buffer, session: session, attempt: attempt)
        }
        engine.prepare()
        try engine.start()
        attemptStartedAt = ProcessInfo.processInfo.systemUptime
    }

    @MainActor
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
        let schedule = lock.withLock {
            guard sessionID == session, attemptID == attempt, recordingError == nil else { return false }
            configurationRevision += 1
            guard !validationScheduled else { return false }
            validationScheduled = true
            return true
        }
        guard schedule else { return }
        // Notifications are evidence to validate, not proof of interruption. Do not
        // query HAL or stop/release the engine on its notification callback thread.
        Task { @MainActor [weak self] in
            guard let self, self.lock.withLock({ self.sessionID == session && self.attemptID == attempt }) else { return }
            do { try self.validateOrRecover(session: session, stage: "recording") }
            catch { self.interrupt(session: session, reason: "configuration_change", message: error.localizedDescription) }
        }
    }

    @MainActor
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

    @MainActor
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
    @MainActor
    private func assessment() -> (Configuration, String?, Int) {
        let engine = self.engine!
        var configuration = snapshot(engine: engine)
        for _ in 0..<3 {
            let revision = lock.withLock { configurationRevision }
            configuration = snapshot(engine: engine)
            let reason = failure(for: configuration)
            if lock.withLock({ configurationRevision == revision }) { return (configuration, reason, revision) }
        }
        return (configuration, "configuration_race", lock.withLock { configurationRevision })
    }

    @MainActor
    private func validateOrRecover(session: UUID, stage: String) throws {
        guard lock.withLock({ sessionID == session }), engine != nil else { return }
        let (configuration, reason, revision) = assessment()
        log("audio_engine_configuration_change", configuration: configuration, fields: [
            "stage": stage, "reason": reason ?? "unchanged",
        ])
        guard let reason else {
            baseline = configuration
            lock.withLock {
                if configurationRevision == revision { validationScheduled = false }
            }
            return
        }
        // Never stitch a replacement route onto audio already sent to recognition.
        // Closing the gate under the conversion lock makes this decision atomic.
        let canRecover = lock.withLock {
            accepting = false
            return bufferCount == 0 && recoveryCount == 0 && reason != "conversion_failed"
        }
        guard canRecover else {
            log("audio_interruption", configuration: configuration, fields: ["reason": reason, "stage": stage])
            throw TalklessError.message(L10n.tr(Self.interrupted))
        }
        recoveryCount += 1
        log("audio_recovery", configuration: configuration, fields: ["reason": reason, "recovered": "false"])
        tearDownAttempt()
        try installAndStart(session: session)
        let (after, afterReason, afterRevision) = assessment()
        guard afterReason == nil else {
            log("audio_interruption", configuration: after, fields: ["reason": "recovery_exhausted", "stage": stage])
            throw TalklessError.message(L10n.tr(Self.interrupted))
        }
        log("audio_recovery", configuration: after, fields: ["reason": "unchanged", "recovered": "true"])
        baseline = after
        lock.withLock {
            if configurationRevision == afterRevision { validationScheduled = false }
        }
    }

    @MainActor
    private func monitor(session: UUID) -> Bool {
        guard lock.withLock({ sessionID == session }) else { return false }
        logFirstBuffer()
        let state = lock.withLock { (captureFailure, validationScheduled) }
        if state.0 != nil || state.1 || engine?.isRunning == false {
            do { try validateOrRecover(session: session, stage: "recording") }
            catch { interrupt(session: session, reason: state.0 ?? "engine_stopped", message: error.localizedDescription); return false }
        }
        if lock.withLock({ firstBufferTime == nil }) && ProcessInfo.processInfo.systemUptime - attemptStartedAt >= 3 {
            interrupt(session: session, reason: "no_audio_timeout", message: L10n.tr(Self.noAudio))
            return false
        }
        return true
    }

    @MainActor
    private func interrupt(session: UUID, reason: String, message: String) {
        let current = lock.withLock {
            guard sessionID == session, recordingError == nil else { return false }
            recordingError = message
            accepting = false
            samples.removeAll(keepingCapacity: true)
            return true
        }
        guard current else { return }
        log("audio_interruption", fields: ["reason": reason, "stage": "recording"])
        stop()
        onError?(message)
    }

    @MainActor
    @discardableResult
    func stop() -> [Float] {
        let active = lock.withLock {
            // Wait for any conversion/callback before freezing the final sample list.
            accepting = false
            return sessionID != nil
        }
        if active {
            // A key release may beat the queued configuration handler. Inspect native
            // state now, before normal teardown itself stops the engine and notifies.
            if engine != nil, lock.withLock({ recordingError == nil }) {
                // A notification racing the final lock is not itself an interruption.
                // Reassess, then freeze only a matching revision; continuous churn is
                // bounded and fails closed rather than returning potentially partial audio.
                for attempt in 0..<3 {
                    let (configuration, assessedReason, revision) = assessment()
                    let result = lock.withLock { () -> (Bool, String?) in
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
                sessionID = nil
                if recordingError != nil { samples.removeAll(keepingCapacity: true) }
            }
            logFirstBuffer()
            log("audio_recording_summary", fields: ["stage": "shutdown"], asynchronous: true)
        }
        tearDownAttempt()
        monitorTask?.cancel()
        monitorTask = nil
        return lock.withLock { samples }
    }

    @MainActor
    private func tearDownAttempt() {
        lock.withLock { accepting = false; attemptID = nil; validationScheduled = false }
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        baseline = nil
        lock.withLock { converter = nil; tapFormat = nil }
    }

    private func process(_ buffer: AVAudioPCMBuffer, session: UUID, attempt: UUID) {
        lock.withLock {
            guard accepting, sessionID == session, attemptID == attempt, let converter else { return }
            // The converter must never see a newly negotiated, incompatible format.
            guard buffer.format == tapFormat else {
                captureFailure = "format_changed"; accepting = false; return
            }
            guard buffer.frameLength > 0 else { return }
            inputFrameCount += Int(buffer.frameLength)
            let ratio = Self.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity) else {
                captureFailure = "conversion_failed"; accepting = false; return
            }
            var consumed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if consumed { status.pointee = .noDataNow; return nil }
                consumed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil else { captureFailure = "conversion_failed"; accepting = false; return }
            guard out.frameLength > 0, let data = out.floatChannelData?[0] else { return }
            if firstBufferTime == nil { firstBufferTime = ProcessInfo.processInfo.systemUptime }
            bufferCount += 1
            frameCount += Int(out.frameLength)
            let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
            samples.append(contentsOf: chunk)
            let sum = chunk.reduce(Float(0)) { $0 + $1 * $1 }
            let db = 20 * log10(max(sqrt(sum / Float(chunk.count)), 1e-6))
            levelCallback?(max(0, min(1, (db + 50) / 40)))
            bufferCallback?(out)
        }
    }

    @MainActor
    private func logFirstBuffer() {
        guard !firstBufferLogged, let time = lock.withLock({ firstBufferTime }) else { return }
        firstBufferLogged = true
        log("audio_first_buffer", fields: ["first_buffer_ms": String(Int(max(0, time - startedAt) * 1_000))], asynchronous: true)
    }

    @MainActor
    private func milliseconds(since time: TimeInterval) -> String {
        String(Int(max(0, ProcessInfo.processInfo.systemUptime - time) * 1_000))
    }

    @MainActor
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
        metadata["attempt"] = String(recoveryCount + 1)
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
