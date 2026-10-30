import AVFoundation
import Speech

/// One recognition session per dictation: call `feed` while recording, then `finish` for the full transcript.
protocol TranscriptionSession: AnyObject, Sendable {
    /// Live preview (on-device recognition only), delivered on the main thread.
    var onPartial: (@MainActor @Sendable (String) -> Void)? { get set }
    /// Called on the audio thread.
    func feed(_ buffer: AVAudioPCMBuffer)
    func finish(samples: [Float]) async throws -> String
    func cancel()
}

// MARK: - On-device SpeechAnalyzer

final class AppleSpeechSession: TranscriptionSession, @unchecked Sendable {
    var onPartial: (@MainActor @Sendable (String) -> Void)? {
        get { lock.withLock { partialCallback } }
        set { lock.withLock { partialCallback = newValue } }
    }
    private var partialCallback: (@MainActor @Sendable (String) -> Void)?

    private let lock = NSLock()
    private var pending: [AVAudioPCMBuffer] = []
    private var ready = false
    private var finished = false
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    private let stream: AsyncStream<AnalyzerInput>
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Error>?
    private var setupTask: Task<Void, Error>?

    private var finalized = ""
    private var volatile = ""

    /// Return immediately; load the model in the background and buffer audio in the meantime.
    init(locale: Locale, contextualStrings: [String], onStatus: @escaping @MainActor @Sendable (String) -> Void) {
        (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        setupTask = Task { [weak self] in
            try await self?.setUp(locale: locale, contextualStrings: contextualStrings, onStatus: onStatus)
        }
    }

    private func setUp(locale: Locale, contextualStrings: [String], onStatus: @escaping @MainActor @Sendable (String) -> Void) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TalklessError.message(L10n.format("Apple on-device recognition does not support %@", locale.identifier))
        }
        let transcriber = SpeechTranscriber(
            locale: supported,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
        let modules: [any SpeechModule] = [transcriber]

        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            await onStatus("Downloading the speech model…")
            try await request.downloadAndInstall()
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw TalklessError.message(L10n.tr("Cannot determine the audio format required for recognition"))
        }

        let analyzer = SpeechAnalyzer(modules: modules)
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try? await analyzer.setContext(context)
        }
        self.analyzer = analyzer

        resultsTask = Task { [weak self] in
            for try await result in transcriber.results {
                guard let self else { return }
                let text = String(result.text.characters)
                let preview: String = self.lock.withLock {
                    if result.isFinal {
                        self.finalized += text
                        self.volatile = ""
                    } else {
                        self.volatile = text
                    }
                    return self.finalized + self.volatile
                }
                let callback = self.onPartial
                await MainActor.run { callback?(preview) }
            }
        }

        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)

        // Feed audio buffered during model loading, then switch to live streaming.
        // Hold the lock so buffered audio always precedes newly captured audio.
        lock.withLock {
            analyzerFormat = format
            if format != AudioRecorder.format {
                converter = AVAudioConverter(from: AudioRecorder.format, to: format)
            }
            ready = true
            for buffer in pending { yieldLocked(buffer) }
            pending.removeAll()
        }
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            if finished { return }
            if ready { yieldLocked(buffer) } else { pending.append(buffer) }
        }
    }

    private func yieldLocked(_ buffer: AVAudioPCMBuffer) {
        guard let converted = convert(buffer) else { return }
        continuation.yield(AnalyzerInput(buffer: converted))
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter, let analyzerFormat else { return buffer }
        let ratio = analyzerFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil ? out : nil
    }

    func finish(samples: [Float]) async throws -> String {
        // If setup is still running, wait until it has fed the buffered audio.
        try await setupTask?.value
        lock.withLock { finished = true }
        continuation.finish()
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        try await resultsTask?.value
        return lock.withLock { (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func cancel() {
        lock.withLock { finished = true }
        continuation.finish()
        setupTask?.cancel()
        resultsTask?.cancel()
        if let analyzer {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// Download the model in advance to avoid delaying the first dictation.
    static func prepareAssets(locale: Locale) async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw TalklessError.message(L10n.format("Apple on-device recognition does not support %@", locale.identifier))
        }
        let transcriber = SpeechTranscriber(locale: supported, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
    }

    static func supportedLocales() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
    }
}

// MARK: - OpenAI-compatible cloud recognition

final class CloudTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var partialCallback: (@MainActor @Sendable (String) -> Void)?
    var onPartial: (@MainActor @Sendable (String) -> Void)? {
        get { lock.withLock { partialCallback } }
        set { lock.withLock { partialCallback = newValue } }
    }

    struct Config {
        var baseURL: String
        var apiKey: String
        var model: String
        /// ISO-639-1, such as zh or en; nil enables automatic detection.
        var language: String?
        /// A prompt to improve recognition of proper nouns.
        var prompt: String?
    }

    private let config: Config
    private var task: Task<String, Error>?

    init(config: Config) {
        self.config = config
    }

    func feed(_ buffer: AVAudioPCMBuffer) {}

    func finish(samples: [Float]) async throws -> String {
        let task = Task { try await Self.transcribe(samples: samples, config: config) }
        lock.withLock {
            self.task = task
            if cancelled { task.cancel() }
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            task?.cancel()
        }
    }

    /// Session injection keeps transport tests offline; production retains the shared session.
    static func transcribe(samples: [Float], config: Config, session: URLSession = .shared) async throws -> String {
        guard let url = URL(string: config.baseURL.trimmingCharacters(in: .whitespaces))?
            .appendingPathComponent("audio/transcriptions") else {
            throw TalklessError.message(L10n.tr("Invalid speech recognition API URL"))
        }
        let boundary = "talkless-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("model", config.model)
        field("response_format", "json")
        if let language = config.language, !language.isEmpty { field("language", language) }
        if let prompt = config.prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(AudioRecorder.wavData(from: samples))
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue(LLMAPITransport.userAgent(), forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try HTTP.check(response, data)
        struct Reply: Decodable { let text: String }
        return try JSONDecoder().decode(Reply.self, from: data).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum HTTP {
    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw TalklessError.message(L10n.format("HTTP %d: %@", http.statusCode, body))
        }
    }
}
