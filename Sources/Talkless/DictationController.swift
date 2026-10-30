import AppKit
import AVFoundation
import Combine

/// Core dictation flow: key press → recording → transcription → language model cleanup → insertion into the frontmost app.
@MainActor
final class DictationController: ObservableObject {
    enum State { case idle, recording, processing }

    @Published private(set) var state: State = .idle
    @Published private(set) var hotkeyActive = false

    private let settings = AppSettings.shared
    private let history = HistoryStore.shared
    private let hud = HUDController()
    private let translationPanel = TranslationPanelController()
    private let hotkeys = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private var translateHotKey: GlobalHotKey?

    private var session: TranscriptionSession?
    private var processingTask: Task<Void, Never>?
    /// Incremented on each start/cancel to discard stale asynchronous results.
    private var generation = 0
    private var pressedAt: CGEventTimestamp?
    private var handsFree = false
    private var editSelection: String?
    private var targetApp: NSRunningApplication?
    @Published private(set) var lastTranscript = ""
    @Published private(set) var previewText = ""
    private var context: AppContext?
    var onModelSetupRequested: (() -> Void)?
    private var changingModel = false
    @Published private(set) var modelPreparationStatus: String?
    private var modelPreparationTask: Task<Void, Never>?
    private var preparedModelDirectory: URL?
    private var preparingModelDirectory: URL?
    private var preparationGeneration = 0

    func prepareSelectedModel() {
        guard settings.asrEngine == .qwen, state == .idle, !changingModel,
              !ModelManager.shared.isBusy,
              let directory = try? settings.resolvedQwenModelDirectory() else { return }
        let normalized = directory.standardizedFileURL
        guard preparedModelDirectory != normalized, preparingModelDirectory != normalized else { return }
        modelPreparationTask?.cancel()
        preparationGeneration += 1
        let token = preparationGeneration
        preparingModelDirectory = normalized
        modelPreparationStatus = "Preparing model…"
        modelPreparationTask = Task { [weak self] in
            do {
                try await QwenTranscriptionSession.prepareAssets(modelDirectory: normalized)
                guard let self, !Task.isCancelled, self.preparationGeneration == token else { return }
                self.preparedModelDirectory = normalized
                self.preparingModelDirectory = nil
                self.modelPreparationStatus = "Ready · kept in memory"
                self.modelPreparationTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.preparationGeneration == token else { return }
                self.preparingModelDirectory = nil
                self.modelPreparationStatus = "Model preparation failed. Check Models settings."
                self.modelPreparationTask = nil
                Diagnostics.shared.record(event: "model_error", metadata: ["error_code": String((error as NSError).code)])
            }
        }
    }

    func prepareForModelChange() async throws {
        guard state == .idle, !changingModel else {
            throw TalklessError.message("Finish dictation before changing or deleting a model.")
        }
        preparationGeneration += 1
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        preparedModelDirectory = nil
        preparingModelDirectory = nil
        modelPreparationStatus = nil
        changingModel = true
        defer { changingModel = false }
        await QwenTranscriptionSession.unloadModel()
    }

    /// Physical event timestamps exclude microphone setup and main-thread dispatch delays.
    private let tapThreshold: CGEventTimestamp = 300_000_000

    init() {
        hotkeys.onPress = { [weak self] timestamp in self?.triggerPressed(at: timestamp) }
        hotkeys.onRelease = { [weak self] timestamp in self?.triggerReleased(at: timestamp) }
        hotkeys.onComboKey = { [weak self] timestamp in self?.comboKeyPressed(at: timestamp) }
        hotkeys.onEscape = { [weak self] in self?.escapePressed() ?? false }
        translateHotKey = GlobalHotKey { [weak self] in
            Task { await self?.translateSelection() }
        }
    }

    // MARK: - Permissions and hotkeys

    /// Try to start key monitoring; return false without Accessibility permission.
    @discardableResult
    func activateHotkey() -> Bool {
        hotkeys.triggerKey = settings.triggerKey
        hotkeyActive = hotkeys.start()
        return hotkeyActive
    }

    func updateTriggerKey() {
        hotkeys.triggerKey = settings.triggerKey
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static func requestAccessibility() {
        let key = "AXTrustedCheckOptionPrompt"
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static var microphoneStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    // MARK: - Key events

    private func triggerPressed(at timestamp: CGEventTimestamp) {
        Diagnostics.shared.record(event: "hotkey_press")
        switch state {
        case .idle:
            pressedAt = timestamp
            startRecording()
            if state != .recording { pressedAt = nil }
        case .recording where handsFree:
            stopAndProcess()
        default:
            break
        }
    }

    private func triggerReleased(at timestamp: CGEventTimestamp) {
        guard let start = pressedAt, timestamp >= start else { return }
        pressedAt = nil
        let duration = timestamp - start
        Diagnostics.shared.record(event: "hotkey_release", metadata: ["duration_ms": String(duration / 1_000_000)])
        guard state == .recording, !handsFree else { return }
        if duration < tapThreshold {
            handsFree = true
            hud.show(.listening(handsFree: true))
        } else {
            stopAndProcess()
        }
    }

    private func comboKeyPressed(at timestamp: CGEventTimestamp) {
        // The user is holding the trigger for a shortcut (such as Fn+arrow), not dictation.
        guard let start = pressedAt, timestamp >= start else { return }
        if state == .recording, !handsFree, timestamp - start < 1_000_000_000 {
            cancel()
        }
    }

    private func escapePressed() -> Bool {
        if translationPanel.isVisible {
            translationPanel.close()
            return true
        }
        if state != .idle {
            cancel()
            return true
        }
        return false
    }

    /// The menu bar Start/Stop Dictation action.
    func toggleFromMenu() {
        switch state {
        case .idle:
            pressedAt = nil
            startRecording()
            handsFree = true
            if state == .recording { hud.show(.listening(handsFree: true)) }
        case .recording:
            stopAndProcess()
        case .processing:
            break
        }
    }

    // MARK: - Recording

    private func startRecording() {
        Diagnostics.shared.record(event: "recording_start", metadata: ["engine": settings.asrEngine.rawValue])
        guard !changingModel else { return }
        if settings.asrEngine == .qwen, ModelManager.shared.operationModelID != nil {
            hud.show(.error("Wait for the model operation to finish before starting dictation."))
            return
        }
        var qwenDirectory: URL?
        if settings.asrEngine == .qwen {
            do { qwenDirectory = try settings.resolvedQwenModelDirectory() }
            catch {
                hud.show(.error(error.localizedDescription))
                onModelSetupRequested?()
                return
            }
        }
        switch Self.microphoneStatus {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        case .denied, .restricted:
            hud.show(.error("Allow Talkless in System Settings › Privacy & Security › Microphone"))
            return
        default:
            break
        }

        generation += 1
        handsFree = false
        targetApp = NSWorkspace.shared.frontmostApplication
        previewText = ""
        context = targetApp.map {
            AppContext(name: $0.localizedName ?? "", bundleID: $0.bundleIdentifier ?? "")
        }
        editSelection = nil
        if settings.voiceEditEnabled, settings.llmConfigured {
            editSelection = TextIO.selectedTextViaAX()
        }

        let generation = self.generation
        let session: any TranscriptionSession
        switch settings.asrEngine {
        case .qwen:
            guard let qwenDirectory else { return }
            session = QwenTranscriptionSession(
                modelDirectory: qwenDirectory,
                language: nil,
                onStatus: { [weak self] _ in
                    guard let self, self.generation == generation else { return }
                    self.hud.show(.working)
                },
                onError: { [weak self] message in
                    guard let self, self.generation == generation else { return }
                    self.cancel()
                    self.hud.show(.error(message))
                }
            )
        case .apple:
            session = AppleSpeechSession(
                locale: Locale(identifier: settings.speechLocale),
                contextualStrings: settings.dictionaryTerms,
                onStatus: { [weak self] _ in
                    guard let self, self.generation == generation else { return }
                    self.hud.show(.working)
                }
            )
        case .openAICompatible:
            guard !settings.asrAPIKey.isEmpty else {
                hud.show(.error("Enter a speech recognition API key in Settings first"))
                return
            }
            let terms = settings.dictionaryTerms
            session = CloudTranscriptionSession(config: .init(
                baseURL: settings.asrBaseURL,
                apiKey: settings.asrAPIKey,
                model: settings.asrModel,
                language: nil,
                prompt: terms.isEmpty ? nil : terms.joined(separator: ", ")
            ))
        }
        session.onPartial = { [weak self] text in
            guard let self, self.generation == generation,
                  self.state == .recording || self.state == .processing else { return }
            self.previewText = text
            self.hud.model.preview = text
            if self.state == .recording { self.hud.show(.listening(handsFree: self.handsFree)) }
        }
        self.session = session

        recorder.onBuffer = { [weak session] buffer in session?.feed(buffer) }
        do {
            try recorder.start()
            Diagnostics.shared.record(event: "recording_started")
        } catch {
            Diagnostics.shared.record(event: "recording_error", metadata: ["error_code": String((error as NSError).code)])
            session.cancel()
            self.session = nil
            hud.show(.error("Cannot start recording: \(error.localizedDescription)"))
            return
        }

        state = .recording
        hud.model.isEditMode = editSelection != nil
        hud.model.preview = ""
        hud.show(.listening(handsFree: false))
    }

    private func stopAndProcess() {
        guard state == .recording, let session else { return }
        Diagnostics.shared.record(event: "recording_stop")
        let samples = recorder.stop()
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        state = .processing
        hud.show(.recognizing)

        let generation = self.generation
        let editSelection = self.editSelection
        let context = self.context

        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                Diagnostics.shared.record(event: "recognition_finish", metadata: ["num_samples": String(samples.count)])
                let raw = try await session.finish(samples: samples)
                Diagnostics.shared.record(event: "recognition_complete")
                guard generation == self.generation else { return }
                guard !raw.isEmpty else {
                    self.finish(.hidden)
                    return
                }

                var output = raw
                var kind = HistoryEntry.Kind.dictation
                var polishFailed = false
                if let selection = editSelection {
                    kind = .edit
                    self.hud.show(.editing)
                    output = try await LLMClient.complete(
                        system: Prompts.voiceEdit(settings: self.settings),
                        user: Prompts.voiceEditInput(selection: selection, instruction: raw),
                        config: self.settings.llmConfig
                    )
                } else if self.settings.polishEnabled, self.settings.llmConfigured {
                    self.hud.show(.polishing)
                    do {
                        output = try await LLMClient.complete(
                            system: Prompts.polish(context: context, settings: self.settings),
                            user: Prompts.polishInput(raw),
                            config: self.settings.llmConfig,
                            timeout: 15
                        )
                        if output.isEmpty { output = raw }
                        output = try PolishValidation.validate(source: raw, output: output)
                    } catch {
                        // A cleanup failure must not lose the user's words; fall back to the raw transcript.
                        output = raw
                        polishFailed = true
                    }
                }
                guard generation == self.generation, !Task.isCancelled else { return }

                self.lastTranscript = output
                Diagnostics.shared.record(event: "paste_attempt")
                await TextIO.insert(output)
                guard generation == self.generation else { return }
                self.history.add(HistoryEntry(
                    kind: kind, app: context?.name ?? "", raw: raw, output: output, duration: duration
                ))
                self.finish(polishFailed ? .error("Polishing failed; using the original transcript.") : .hidden)
            } catch is CancellationError {
                return
            } catch {
                guard generation == self.generation else { return }
                self.finish(.error(error.localizedDescription))
            }
        }
    }

    private func finish(_ phase: HUDModel.Phase) {
        state = .idle
        session = nil
        processingTask = nil
        hud.show(phase)
    }

    func cancel() {
        Diagnostics.shared.record(event: "dictation_cancel")
        pressedAt = nil
        generation += 1
        recorder.stop()
        session?.cancel()
        session = nil
        processingTask?.cancel()
        processingTask = nil
        state = .idle
        hud.hide()
    }

    private func paste(_ text: String, into app: NSRunningApplication?) async {
        guard let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            lastTranscript = text
            hud.show(.error("Target app changed; result saved"))
            return
        }
        await TextIO.insert(text)
    }

    func runAudioTest(url: URL) async throws -> String {
        guard state == .idle, !changingModel else { throw TalklessError.message("Dictation or a model change is already in progress") }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == AudioRecorder.sampleRate,
              file.processingFormat.channelCount == 1, file.length > 0,
              file.length < Int64(UInt32.max),
              let audio = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TalklessError.message("Test audio must be 16 kHz mono PCM")
        }
        try file.read(into: audio)
        guard let source = audio.floatChannelData?[0] else { throw TalklessError.message("Cannot read test audio") }
        let samples = Array(UnsafeBufferPointer(start: source, count: Int(audio.frameLength)))
        while ModelManager.shared.isChecking {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard ModelManager.shared.operationModelID == nil else {
            throw TalklessError.message("Wait for the model operation to finish before testing dictation.")
        }
        let modelDirectory = try settings.resolvedQwenModelDirectory()
        generation += 1
        let generation = self.generation
        previewText = ""
        hud.model.preview = ""
        state = .recording
        let session = QwenTranscriptionSession(
            modelDirectory: modelDirectory,
            language: nil,
            onStatus: { [weak self] _ in
                guard let self, self.generation == generation else { return }
                self.hud.show(.working)
            }
        )
        self.session = session
        session.onPartial = { [weak self] text in
            guard let self, self.generation == generation else { return }
            self.previewText = text
            self.hud.model.preview = text
            if self.state == .recording { self.hud.show(.listening(handsFree: false)) }
        }
        hud.show(.listening(handsFree: false))
        do {
            let clock = ContinuousClock()
            let started = clock.now
            for offset in stride(from: 0, to: samples.count, by: 800) {
                try Task.checkCancellation()
                guard self.generation == generation else { throw CancellationError() }
                let count = min(800, samples.count - offset)
                let deadline = started.advanced(by: .seconds(Double(offset + count) / AudioRecorder.sampleRate))
                try await clock.sleep(until: deadline)
                guard let frame = AVAudioPCMBuffer(pcmFormat: AudioRecorder.format, frameCapacity: AVAudioFrameCount(count)),
                      let target = frame.floatChannelData?[0] else { throw TalklessError.message("Cannot allocate a test audio buffer") }
                frame.frameLength = AVAudioFrameCount(count)
                for index in 0..<count { target[index] = samples[offset + index] }
                session.feed(frame)
            }
            state = .processing
            hud.show(.recognizing)
            let text = try await session.finish(samples: [])
            guard self.generation == generation else { throw CancellationError() }
            lastTranscript = text
            previewText = text
            finish(.hidden)
            return text
        } catch {
            session.cancel()
            if self.generation == generation { finish(.error(error.localizedDescription)) }
            throw error
        }
    }

    // MARK: - Selected-text translation

    func translateSelection() async {
        guard settings.llmConfigured else {
            hud.show(.error("Configure a language model in Settings to translate selected text"))
            return
        }
        guard let text = await TextIO.selectedText() else {
            hud.show(.error("Could not read any selected text"))
            return
        }
        let targetApp = NSWorkspace.shared.frontmostApplication
        let onReplace: (String) -> Void = { [weak self] translated in
            Task { await self?.paste(translated, into: targetApp) }
        }
        translationPanel.show(source: text, result: nil, error: nil, onReplace: onReplace)
        do {
            let result = try await LLMClient.complete(
                system: Prompts.translate(target: settings.translateTarget),
                user: Prompts.translateInput(text),
                config: settings.llmConfig
            )
            translationPanel.show(source: text, result: result, error: nil, onReplace: onReplace)
            history.add(HistoryEntry(
                kind: .translation, app: targetApp?.localizedName ?? "", raw: text, output: result, duration: 0
            ))
        } catch {
            translationPanel.show(source: text, result: nil, error: error.localizedDescription, onReplace: onReplace)
        }
    }

}
