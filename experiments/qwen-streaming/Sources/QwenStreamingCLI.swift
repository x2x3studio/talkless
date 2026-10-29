import Foundation
import AVFoundation
import Darwin
import MLX
import MLXAudioSTT

private func uptime() -> Double { ProcessInfo.processInfo.systemUptime }
private func peakRSS() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss) // Darwin reports bytes, not Linux kilobytes.
}

/// Writes through the original stdout descriptor; dependency print() goes to stderr.
private final class Timeline: @unchecked Sendable {
    let start = uptime()
    private let lock = NSLock()
    private let output: FileHandle
    private var firstFrame: Double?
    private var firstText: Double?
    private var stopped: Double?
    private var queued = 0
    private var maxQueued = 0
    private var maxFeedMs = 0.0
    private var maxCaptureLatenessMs = 0.0
    private var sessionIndex = 0

    func beginSession(_ index: Int) {
        lock.lock(); defer { lock.unlock() }
        sessionIndex = index
        firstFrame = nil; firstText = nil; stopped = nil
        queued = 0; maxQueued = 0; maxFeedMs = 0; maxCaptureLatenessMs = 0
    }

    init() {
        output = FileHandle(fileDescriptor: dup(STDOUT_FILENO), closeOnDealloc: true)
        fflush(nil)
        dup2(STDERR_FILENO, STDOUT_FILENO)
    }
    func emit(_ event: String, _ fields: [String: Any] = [:]) {
        lock.lock(); defer { lock.unlock() }
        emitLocked(event, fields)
    }
    private func emitLocked(_ event: String, _ fields: [String: Any]) {
        let now = uptime()
        var row = fields
        row["event"] = event
        row["sessionIndex"] = sessionIndex
        row["elapsedMs"] = (now - start) * 1000
        row["sinceFirstFrameMs"] = firstFrame.map { (now - $0) * 1000 } ?? NSNull() as Any
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]) {
            output.write(data); output.write(Data([10]))
        }
    }
    func captured(index: Int, count: Int, latenessMs: Double) {
        lock.lock(); defer { lock.unlock() }
        if firstFrame == nil { firstFrame = uptime() }
        queued += 1; maxQueued = max(maxQueued, queued)
        maxCaptureLatenessMs = max(maxCaptureLatenessMs, latenessMs)
        emitLocked("audio_frame", ["index": index, "samples": count, "queuedFrames": queued, "captureLatenessMs": latenessMs])
    }
    func fed(index: Int, milliseconds: Double, queueWaitMs: Double) {
        lock.lock(); defer { lock.unlock() }
        queued -= 1; maxFeedMs = max(maxFeedMs, milliseconds)
        emitLocked("audio_fed", ["index": index, "feedCallMs": milliseconds, "queueWaitMs": queueWaitMs, "queuedFrames": queued])
    }
    func inputStopped() {
        lock.lock(); defer { lock.unlock() }
        stopped = uptime()
        emitLocked("input_stopped", ["queuedFrames": queued])
    }
    func text(_ event: String, confirmed: String, provisional: String) {
        lock.lock(); defer { lock.unlock() }
        let full = confirmed.isEmpty ? provisional : (provisional.isEmpty ? confirmed : confirmed + " " + provisional)
        if firstText == nil && !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { firstText = uptime() }
        emitLocked(event, ["confirmedText": confirmed, "provisionalText": provisional, "fullText": full])
    }
    func ended(fullText: String, loadSeconds: Double, audioSeconds: Double, modelDir: String, download: Any) {
        lock.lock(); defer { lock.unlock() }
        let now = uptime()
        let finalDelay: Any = stopped.map { (now - $0) * 1000 } ?? NSNull() as Any
        let firstDelay: Any = firstText.flatMap { text in firstFrame.map { (text - $0) * 1000 } } ?? NSNull() as Any
        emitLocked("ended", ["fullText": fullText, "stopToFinalMs": finalDelay])
        emitLocked("summary", [
            "fullText": fullText, "firstTextMs": firstDelay, "stopToFinalMs": finalDelay,
            "loadSeconds": loadSeconds, "download": download,
            "audioDurationSeconds": audioSeconds, "feedWallSeconds": stopped.flatMap { end in firstFrame.map { end - $0 } } ?? 0,
            "peakRSSBytes": peakRSS(), "peakMLXBytes": Memory.peakMemory,
            "maxQueuedFrames": maxQueued, "maxFeedCallMs": maxFeedMs,
            "maxCaptureLatenessMs": maxCaptureLatenessMs,
            "modelDirectory": modelDir, "upstreamRevision": "fe2c182f4da8115fe2b6b99c9a4d2048fbf9b1e6"
        ])
    }
}

private struct Options {
    var audio = ""
    var model = ""
    var frameMs = 50
    var language: String? = "Chinese"
    var interval = 1.0
    var help = false
    var repetitions = 1
    init() throws {
        // The binary stays in .build/{arm64-apple-macosx/}release; derive experiment directory.
        var directory = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.deletingLastPathComponent()
        while directory.path != "/" && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("download_model.py").path) {
            directory.deleteLastPathComponent()
        }
        model = directory.appendingPathComponent("model").path
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let key = args.removeFirst()
            if key == "--help" { help = true; continue }
            guard !args.isEmpty else { throw CLIError.message("Missing value for \(key)") }
            let value = args.removeFirst()
            switch key {
            case "--audio": audio = value
            case "--repetitions": guard let n = Int(value), (1...5).contains(n) else { throw CLIError.message("repetitions must be 1...5") }; repetitions = n
            case "--model-dir": model = value
            case "--frame-ms": guard let n = Int(value), (20...100).contains(n) else { throw CLIError.message("frame-ms must be 20...100") }; frameMs = n
            case "--language": language = value == "auto" ? nil : value
            case "--decode-interval": guard let n = Double(value), n >= 0.05 else { throw CLIError.message("decode-interval must be >= 0.05") }; interval = n
            default: throw CLIError.message("Unknown option \(key)")
            }
        }
        if !help && audio.isEmpty { throw CLIError.message("Required: --audio /absolute/path.wav") }
    }
}
private enum CLIError: Error { case message(String) }

private func readAudio(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
    guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1 else {
        throw CLIError.message("Audio must be 16 kHz mono. Convert before invoking this measurement CLI.")
    }
    guard file.length > 0, file.length < Int64(UInt32.max),
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { throw CLIError.message("Empty or oversized audio") }
    try file.read(into: buffer)
    guard let samples = buffer.floatChannelData?[0] else { throw CLIError.message("Unable to read PCM floats") }
    return Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)))
}

@main
struct QwenStreamingCLI {
    static func main() async {
        let timeline = Timeline()
        do {
            let options = try Options()
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Measure real-time paced audio transcription")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            if options.help {
                timeline.emit("help", ["usage": "qwen-streaming --audio PATH [--model-dir PATH] [--frame-ms 50] [--language Chinese|English|auto] [--decode-interval 1.0]", "audioFormat": "16000 Hz mono; JSONL stdout, diagnostics stderr"])
                return
            }
            let samples = try readAudio(options.audio)
            let audioSeconds = Double(samples.count) / 16000
            let modelURL = URL(fileURLWithPath: options.model)
            let receiptURL = modelURL.deletingLastPathComponent().appendingPathComponent("download-receipt.json")
            let receipt: Any = (try? Data(contentsOf: receiptURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
            timeline.emit("model_loading", ["modelDirectory": options.model, "download": receipt])
            let loadStart = uptime()
            let model = try await Qwen3ASRModel.fromModelDirectory(modelURL)
            let loadSeconds = uptime() - loadStart
            timeline.emit("model_loaded", ["loadSeconds": loadSeconds, "peakRSSBytes": peakRSS(), "peakMLXBytes": Memory.peakMemory])
            for repetition in 1...options.repetitions {
            timeline.beginSession(repetition)
            let config = StreamingConfig(decodeIntervalSeconds: options.interval, language: options.language)
            let session = StreamingInferenceSession(model: model, config: config)
            timeline.emit("audio_start", ["audioPath": options.audio, "audioDurationSeconds": audioSeconds, "sampleRate": 16000, "frameMs": options.frameMs, "decodeIntervalSeconds": options.interval, "language": options.language ?? "auto", "finalizeCompletedWindows": config.finalizeCompletedWindows, "note": "Real-time paced frames; no preview recognizer or second model; upstream may re-decode completed windows using the same model."])
            let feedQueue = DispatchQueue(label: "qwen-streaming.serial-feed", qos: .userInitiated)
            let frameSamples = options.frameMs * 16
            let watchdog = Task.detached {
                do { try await Task.sleep(for: .seconds(audioSeconds + 90)) }
                catch { return }
                timeline.emit("error", ["message": "Timed out waiting for .ended after audio duration + 90 seconds", "peakRSSBytes": peakRSS()])
                // Do not block process termination if upstream cancel itself waits on a wedged lock.
                DispatchQueue.global().async { session.cancel() }
                exit(2)
            }
            defer { watchdog.cancel() }
            Thread.detachNewThread {
                var offset = 0
                var index = 0
                let captureStart = uptime()
                let tickStart = mach_absolute_time()
                var timebase = mach_timebase_info_data_t()
                mach_timebase_info(&timebase)
                let ticksPerSecond = 1_000_000_000.0 * Double(timebase.denom) / Double(timebase.numer)
                while offset < samples.count {
                    // Fixed media clock: lateness never accumulates into a slower simulated source.
                    let mediaTime = Double(min(offset + frameSamples, samples.count)) / 16000
                    let deadline = captureStart + mediaTime
                    mach_wait_until(tickStart + UInt64(mediaTime * ticksPerSecond))
                    let captured = uptime()
                    if captured - deadline > Double(options.frameMs) / 1000 {
                        timeline.emit("error", ["message": "Capture missed a full frame deadline; aborting rather than bursting queued future audio", "captureLatenessMs": (captured - deadline) * 1000])
                        exit(3)
                    }
                    let end = min(offset + frameSamples, samples.count)
                    let frame = Array(samples[offset..<end])
                    timeline.captured(index: index, count: frame.count, latenessMs: max(0, captured - deadline) * 1000)
                    let frameIndex = index
                    feedQueue.async {
                        let before = uptime()
                        session.feedAudio(samples: frame)
                        timeline.fed(index: frameIndex, milliseconds: (uptime() - before) * 1000, queueWaitMs: (before - captured) * 1000)
                    }
                    offset = end; index += 1
                }
                mach_wait_until(tickStart + UInt64(audioSeconds * ticksPerSecond))
                timeline.inputStopped()
                feedQueue.async {
                    timeline.emit("stop_called")
                    session.stop()
                }
            }
            var gotFinal = false
            for await event in session.events {
                switch event {
                case .displayUpdate(let confirmed, let provisional):
                    timeline.text("displayUpdate", confirmed: confirmed, provisional: provisional)
                case .confirmed(let text): timeline.emit("confirmed", ["text": text])
                case .provisional(let text): timeline.emit("provisional", ["text": text])
                case .stats(let stats):
                    timeline.emit("stats", ["encodedWindowCount": stats.encodedWindowCount, "totalAudioSeconds": stats.totalAudioSeconds, "tokensPerSecond": stats.tokensPerSecond, "realTimeFactor": stats.realTimeFactor, "peakMemoryGB": stats.peakMemoryGB, "peakRSSBytes": peakRSS()])
                case .ended(let fullText):
                    gotFinal = true
                    timeline.ended(fullText: fullText, loadSeconds: loadSeconds, audioSeconds: audioSeconds, modelDir: options.model, download: receipt)
                }
            }
            if !gotFinal { throw CLIError.message("Session closed without .ended") }
            // Let upstream finishStop release encoder/session state before another session shares the model.
            if repetition < options.repetitions { try await Task.sleep(for: .seconds(1)) }
            }
        } catch {
            timeline.emit("error", ["message": String(describing: error), "peakRSSBytes": peakRSS()])
            exit(1)
        }
    }
}
