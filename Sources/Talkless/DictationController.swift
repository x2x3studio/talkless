import AppKit
import AVFoundation
import Combine

/// Immutable correlation context captured by asynchronous work so stale completions cannot
/// be attributed to a newer recording. Contains technical metadata only, never user content.
private struct DictationOperation {
    let id = UUID()
    let generation: Int
    let engine: String
    let recordingMode: String
    let handsFree: Bool
    var mode = "dictation"
    let startedAt = DispatchTime.now().uptimeNanoseconds

    static func milliseconds(since start: UInt64) -> String {
        String((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }

    func record(_ event: String, _ metadata: [String: String] = [:]) {
        var fields = [
            "operation_id": id.uuidString, "generation": String(generation), "engine": engine,
            "recording_mode": recordingMode, "hands_free": String(handsFree), "mode": mode,
            "operation_ms": Self.milliseconds(since: startedAt),
        ]
        fields.merge(metadata) { _, value in value }
        Diagnostics.shared.record(event: event, metadata: fields)
    }
}

/// Core dictation flow: key press → recording → transcription → language model cleanup → insertion into the frontmost app.
@MainActor
final class DictationController: ObservableObject {
    enum State { case idle, recording, processing }

    @Published private(set) var state: State = .idle
    @Published private(set) var hotkeyActive = false
    private var shortcutCaptureActive = false
    private var resumeHotkeyAfterCapture = false

    private let settings = AppSettings.shared
    private let history = HistoryStore.shared
    private let hud = HUDController(
        appearance: AppSettings.shared.hudAppearance,
        appearanceUpdates: AppSettings.shared.$hudAppearance.eraseToAnyPublisher()
    )
    private let translationPanel = TranslationPanelController()
    private let hotkeys = HotkeyMonitor()
    private let recorder = AudioRecorder()
    private var translateHotKey: GlobalHotKey?
    private var configuredTranslationShortcut: TranslationShortcut = .default
    @Published private(set) var translationShortcutActive = false
    @Published private(set) var translationShortcutError: String?

    private var session: TranscriptionSession?
    private var processingTask: Task<Void, Never>?
    /// Incremented on each start/cancel to discard stale asynchronous results.
    private var generation = 0
    private var diagnosticOperation: DictationOperation?
    private var recordingModelDirectory: URL?
    private var recordingPreparationGeneration = 0
    private var pressedAt: CGEventTimestamp?
    private var handsFree = false
    /// Snapshotted before setup so a settings change only affects the next recording.
    private var recordingGestureMode: RecordingGestureMode = .hold
    /// Per-recording default; changing Settings never changes an in-flight dictation.
    private var recordingPolishEnabled = false
    private var recordingAlternateFinishKey: TriggerKey?
    private var languageSubscription: AnyCancellable?
    private var editSelection: String?
    private var targetApp: NSRunningApplication?
    @Published private(set) var lastTranscript = ""
    @Published private(set) var previewText = ""
    private var context: AppContext?
    var onModelSetupRequested: (() -> Void)?
    private var changingModel = false
    @Published private var modelPreparationStatusKey: String?
    var modelPreparationStatus: String? { modelPreparationStatusKey.map { L10n.tr($0) } }
    private var modelPreparationTask: Task<Void, Never>?
    private var preparedModelDirectory: URL?
    private var preparingModelDirectory: URL?
    private var failedModelDirectory: URL?
    private var preparationGeneration = 0

    enum ModelPreparationState { case unprepared, preparing, ready, failed }

    /// Selection-specific readiness: a previously warmed model never marks another model ready.
    func modelPreparationState(for directory: URL) -> ModelPreparationState {
        let normalized = directory.standardizedFileURL
        if preparingModelDirectory == normalized { return .preparing }
        if preparedModelDirectory == normalized { return .ready }
        if failedModelDirectory == normalized { return .failed }
        return .unprepared
    }

    /// A successful current session is stronger evidence than an earlier failed prewarm.
    /// Keep the captured model identity: Settings may now select a different directory.
    private func markModelReadyAfterRecognition(directory: URL?, generation: Int, preparation: Int) {
        guard let directory, generation == self.generation, preparation == preparationGeneration else { return }
        preparationGeneration += 1
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        preparedModelDirectory = directory.standardizedFileURL
        preparingModelDirectory = nil
        failedModelDirectory = nil
        modelPreparationStatusKey = "Ready · kept in memory"
    }

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
        preparedModelDirectory = nil
        failedModelDirectory = nil
        modelPreparationStatusKey = "Preparing model…"
        modelPreparationTask = Task { [weak self] in
            do {
                try await QwenTranscriptionSession.prepareAssets(modelDirectory: normalized)
                guard let self, !Task.isCancelled, self.preparationGeneration == token else { return }
                self.preparedModelDirectory = normalized
                self.preparingModelDirectory = nil
                self.modelPreparationStatusKey = "Ready · kept in memory"
                self.modelPreparationTask = nil
            } catch {
                guard let self, !Task.isCancelled, self.preparationGeneration == token else { return }
                self.preparingModelDirectory = nil
                self.failedModelDirectory = normalized
                self.modelPreparationStatusKey = "Model preparation failed. Check Speech recognition settings."
                self.modelPreparationTask = nil
                Diagnostics.shared.record(event: "model_error", metadata: ["error_code": String((error as NSError).code)])
            }
        }
    }

    func prepareForModelChange() async throws {
        guard state == .idle, !changingModel else {
            throw TalklessError.message(L10n.tr("Finish dictation before changing or deleting a model."))
        }
        preparationGeneration += 1
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        preparedModelDirectory = nil
        preparingModelDirectory = nil
        failedModelDirectory = nil
        modelPreparationStatusKey = nil
        changingModel = true
        defer { changingModel = false }
        await QwenTranscriptionSession.unloadModel()
    }

    init() {
        hotkeys.onPress = { [weak self] timestamp in self?.triggerPressed(at: timestamp) }
        hotkeys.onRelease = { [weak self] timestamp in self?.triggerReleased(at: timestamp) }
        hotkeys.onComboKey = { [weak self] timestamp in self?.comboKeyPressed(at: timestamp) }
        hotkeys.onAlternateFinish = { [weak self] timestamp in self?.alternateFinishPressed(at: timestamp) }
        hotkeys.onEscape = { [weak self] in self?.escapePressed() ?? false }
        translateHotKey = GlobalHotKey { [weak self] in
            Task { await self?.translateSelection() }
        }
        updateTranslationShortcut(settings.translationShortcut)
        languageSubscription = NotificationCenter.default.publisher(for: .interfaceLanguageDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                if self.state == .recording { self.refreshRecordingHint() }
                self.objectWillChange.send()
            }
    }

    // MARK: - Permissions and hotkeys

    /// Try to start key monitoring; return false without Accessibility permission.
    @discardableResult
    func activateHotkey() -> Bool {
        guard !shortcutCaptureActive else { return false }
        hotkeys.triggerKey = settings.triggerKey
        hotkeyActive = hotkeys.start()
        if !hotkeyActive, !Self.accessibilityGranted {
            Diagnostics.shared.record(event: "permission_blocked", metadata: [
                "permission": "accessibility", "stage": "startup", "reason": "denied",
            ])
        }
        return hotkeyActive
    }

    /// Shortcut recording owns key events temporarily; never interrupt an existing dictation.
    @discardableResult
    func setShortcutCaptureActive(_ active: Bool) -> Bool {
        if active == shortcutCaptureActive { return true }
        if active {
            guard state == .idle else { return false }
            shortcutCaptureActive = true
            resumeHotkeyAfterCapture = hotkeyActive
            pressedAt = nil
            hotkeys.stop()
            hotkeyActive = false
            translateHotKey?.stop()
            translationShortcutActive = false
        } else {
            shortcutCaptureActive = false
            let shouldResume = resumeHotkeyAfterCapture
            resumeHotkeyAfterCapture = false
            if shouldResume { activateHotkey() }
            updateTranslationShortcut(configuredTranslationShortcut)
        }
        return true
    }

    /// Use the publisher's emitted value: @Published sends before the stored setting changes.
    func updateTranslationShortcut(_ shortcut: TranslationShortcut) {
        configuredTranslationShortcut = shortcut
        guard !shortcutCaptureActive else { return }
        translateHotKey?.update(shortcut)
        translationShortcutActive = translateHotKey?.isActive ?? false
        translationShortcutError = translateHotKey?.error
    }

    func updateTriggerKey() {
        // Keep physical press/release matching and the advertised finish key stable until this session ends.
        guard state == .idle else { return }
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
        guard !shortcutCaptureActive else { return }
        if let diagnosticOperation {
            diagnosticOperation.record("hotkey_press", ["state": String(describing: state)])
        } else {
            Diagnostics.shared.record(event: "hotkey_press", metadata: ["state": String(describing: state)])
        }
        switch state {
        case .idle:
            pressedAt = timestamp
            recordingGestureMode = settings.recordingGestureMode
            handsFree = recordingGestureMode == .toggle
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
        diagnosticOperation?.record("hotkey_release", ["duration_ms": String(duration / 1_000_000)])
        guard state == .recording, !handsFree else { return }
        stopAndProcess()
    }

    private func alternateFinishPressed(at timestamp: CGEventTimestamp) {
        guard !shortcutCaptureActive, state == .recording, editSelection == nil else { return }
        if let pressedAt, timestamp < pressedAt { return }
        stopAndProcess(useOppositePolish: true)
    }

    private func comboKeyPressed(at timestamp: CGEventTimestamp) {
        // The user is holding the trigger for a shortcut (such as Fn+arrow), not dictation.
        guard let start = pressedAt, timestamp >= start else { return }
        // Toggle is hands-free from the start, but its initial held press can still be a shortcut.
        if state == .recording, timestamp - start < 1_000_000_000 {
            cancel(reason: "combo")
        }
    }

    private func escapePressed() -> Bool {
        if translationPanel.isVisible {
            translationPanel.close()
            return true
        }
        if state != .idle {
            cancel(reason: "escape")
            return true
        }
        return false
    }

    /// The menu bar Start/Stop Dictation action.
    func toggleFromMenu() {
        guard !shortcutCaptureActive else { return }
        switch state {
        case .idle:
            pressedAt = nil
            recordingGestureMode = settings.recordingGestureMode
            handsFree = true
            startRecording()
        case .recording:
            stopAndProcess()
        case .processing:
            break
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard !shortcutCaptureActive else { return }
        let audioInputDeviceUID = settings.audioInputDeviceUID
        // One confirmed-term snapshot for this recognizer and its live HUD. Pending
        // suggestions are not in dictionaryTerms; later Settings edits wait until next time.
        let dictionaryTerms = settings.dictionaryTerms
        hud.model.setDictionaryTerms([])
        generation += 1
        var operation = DictationOperation(generation: generation, engine: settings.asrEngine.rawValue,
                                           recordingMode: recordingGestureMode.rawValue, handsFree: handsFree)
        diagnosticOperation = operation
        operation.record("recording_start")
        // Failed/blocked attempts must not leak their UUID into unrelated idle key events.
        defer { if state != .recording { diagnosticOperation = nil } }
        guard !changingModel else {
            operation.record("recording_blocked", ["reason": "model_busy", "stage": "startup"])
            return
        }
        if settings.asrEngine == .qwen, ModelManager.shared.operationModelID != nil {
            operation.record("recording_blocked", ["reason": "model_busy", "stage": "startup"])
            hud.show(.error(L10n.tr("Wait for the model operation to finish before starting dictation.")))
            return
        }
        var qwenDirectory: URL?
        if settings.asrEngine == .qwen {
            do { qwenDirectory = try settings.resolvedQwenModelDirectory() }
            catch {
                operation.record("recording_blocked", ["reason": "model_unavailable", "stage": "startup"])
                hud.show(.error(error.localizedDescription))
                onModelSetupRequested?()
                return
            }
        }
        switch Self.microphoneStatus {
        case .notDetermined:
            operation.record("permission_blocked", ["permission": "microphone", "reason": "not_determined", "stage": "startup"])
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        case .denied, .restricted:
            operation.record("permission_blocked", ["permission": "microphone",
                "reason": Self.microphoneStatus == .denied ? "denied" : "restricted", "stage": "startup"])
            hud.show(.error(L10n.tr("Allow Talkless in System Settings › Privacy & Security › Microphone")))
            return
        default:
            break
        }

        targetApp = NSWorkspace.shared.frontmostApplication
        previewText = ""
        context = targetApp.map {
            AppContext(name: $0.localizedName ?? "", bundleID: $0.bundleIdentifier ?? "")
        }
        editSelection = nil
        if settings.voiceEditEnabled, settings.llmConfigured {
            editSelection = TextIO.selectedTextViaAX()
        }

        operation.mode = editSelection == nil ? "dictation" : "edit"
        diagnosticOperation = operation
        let generation = self.generation
        let session: any TranscriptionSession
        switch settings.asrEngine {
        case .qwen:
            guard let qwenDirectory else { return }
            session = QwenTranscriptionSession(
                modelDirectory: qwenDirectory,
                language: nil,
                contextualStrings: dictionaryTerms,
                onStatus: { [weak self] _ in
                    guard let self, self.generation == generation,
                          self.state == .recording || self.state == .processing else { return }
                    self.hud.show(.working)
                },
                onError: { [weak self] message in
                    guard let self, self.generation == generation,
                          self.state == .recording || self.state == .processing else { return }
                    self.diagnosticOperation?.record("recognition_error", ["stage": "recognition", "reason": "recognition_error"])
                    self.cancel(reason: "recognition_error")
                    self.hud.show(.error(message))
                }
            )
        case .apple:
            session = AppleSpeechSession(
                locale: Locale(identifier: settings.speechLocale),
                contextualStrings: dictionaryTerms,
                onStatus: { [weak self] _ in
                    guard let self, self.generation == generation,
                          self.state == .recording || self.state == .processing else { return }
                    self.hud.show(.working)
                }
            )
        case .openAICompatible:
            guard !settings.asrAPIKey.isEmpty else {
                operation.record("recording_blocked", ["reason": "not_configured", "stage": "startup"])
                hud.show(.error(L10n.tr("Enter a speech recognition API key in Settings first")))
                return
            }
            session = CloudTranscriptionSession(config: .init(
                baseURL: settings.asrBaseURL,
                apiKey: settings.asrAPIKey,
                model: settings.asrModel,
                language: nil,
                prompt: dictionaryTerms.isEmpty ? nil : dictionaryTerms.joined(separator: ", ")
            ))
        }
        session.onPartial = { [weak self] text in
            guard let self, self.generation == generation,
                  self.state == .recording || self.state == .processing else { return }
            self.previewText = text
            self.hud.model.preview = text
            if self.state == .recording {
                // An unrelated translation error can temporarily replace/hide the
                // shared HUD. Resume with this recording's snapshot, never Settings.
                self.hud.model.isEditMode = self.editSelection != nil
                self.hud.model.setDictionaryTerms(self.editSelection == nil ? dictionaryTerms : [])
                self.hud.show(.listening(handsFree: self.handsFree))
            }
        }
        self.session = session
        recordingModelDirectory = qwenDirectory?.standardizedFileURL
        recordingPreparationGeneration = preparationGeneration

        recorder.onBuffer = { [weak session] buffer in session?.feed(buffer) }
        recorder.onError = { [weak self] message in
            guard let self, self.generation == generation, self.state == .recording else { return }
            self.cancel(reason: "recorder_interruption")
            self.hud.show(.error(message))
        }
        do {
            try recorder.start(deviceUID: audioInputDeviceUID, operationID: operation.id)
            operation.record("recording_started", ["startup_ms": DictationOperation.milliseconds(since: operation.startedAt)])
        } catch {
            operation.record("recording_error", ["error_code": String((error as NSError).code), "reason": "start_failed", "stage": "startup"])
            session.cancel()
            self.session = nil
            hud.show(.error(L10n.format("Cannot start recording: %@", error.localizedDescription)))
            return
        }

        state = .recording
        configureRecordingFinish()
        hud.model.isEditMode = editSelection != nil
        hud.model.preview = ""
        hud.model.setDictionaryTerms(editSelection == nil ? dictionaryTerms : [])
        hud.show(.listening(handsFree: handsFree))
    }

    private func configureRecordingFinish() {
        recordingPolishEnabled = settings.polishEnabled
        let alternate = editSelection == nil ? settings.effectiveAlternateFinishKey : nil
        hotkeys.armAlternateFinish(alternate)
        recordingAlternateFinishKey = alternate
        refreshRecordingHint()
    }

    /// Relabel only: never resnapshot preferences or rearm a shortcut during recording.
    private func refreshRecordingHint() {
        if editSelection != nil {
            hud.model.recordingHint = nil
        } else {
            let mode = recordingPolishEnabled ? L10n.tr("Default: Use AI polishing") : L10n.tr("Default: Skip AI polishing")
            let action = recordingPolishEnabled ? L10n.tr("Skip AI polishing") : L10n.tr("Use AI polishing")
            hud.model.recordingHint = recordingAlternateFinishKey.map { L10n.format("%@ · %@: %@", mode, $0.title, action) } ?? mode
        }
    }

    private func stopAndProcess(useOppositePolish: Bool = false) {
        guard state == .recording, let session else { return }
        let opposite = useOppositePolish && editSelection == nil
        let shouldPolish = opposite ? !recordingPolishEnabled : recordingPolishEnabled
        pressedAt = nil
        hotkeys.armAlternateFinish(nil)
        let operation = diagnosticOperation
        let processingStarted = DispatchTime.now().uptimeNanoseconds
        operation?.record("recording_stop", ["opposite_finish": String(opposite), "polish_enabled": String(shouldPolish)])
        let samples = recorder.stop()
        if let interruption = recorder.interruptionError {
            cancel(reason: "stop_interruption")
            hud.show(.error(interruption))
            return
        }
        let duration = Double(samples.count) / AudioRecorder.sampleRate
        operation?.record("recording_stopped", ["num_samples": String(samples.count),
            "duration_ms": String(Int(duration * 1_000)), "sample_rate": String(AudioRecorder.sampleRate)])
        if samples.isEmpty { operation?.record("recording_empty", ["reason": "empty_audio"]) }
        operation?.record("processing_start")
        state = .processing
        hud.show(.recognizing)

        let generation = self.generation
        let editSelection = self.editSelection
        let context = self.context
        let modelDirectory = recordingModelDirectory
        let modelPreparation = recordingPreparationGeneration

        processingTask = Task { [weak self] in
            guard let self else { return }
            var stage = "recognition"
            var stageStarted = DispatchTime.now().uptimeNanoseconds
            do {
                operation?.record("recognition_finish", ["num_samples": String(samples.count)])
                let raw = try await session.finish(samples: samples)
                operation?.record("recognition_complete", ["duration_ms": DictationOperation.milliseconds(since: stageStarted), "empty": String(raw.isEmpty)])
                guard generation == self.generation, !Task.isCancelled else { return }
                self.markModelReadyAfterRecognition(directory: modelDirectory, generation: generation, preparation: modelPreparation)
                guard !raw.isEmpty else {
                    operation?.record("recognition_empty", ["reason": "empty_result"])
                    operation?.record("paste_skipped", ["reason": "empty_result"])
                    operation?.record("processing_complete", ["duration_ms": DictationOperation.milliseconds(since: processingStarted), "empty": "true"])
                    self.finish(.hidden)
                    return
                }

                var output = raw
                var kind = HistoryEntry.Kind.dictation
                var polishError: String?
                if let selection = editSelection {
                    kind = .edit
                    stage = "edit"
                    stageStarted = DispatchTime.now().uptimeNanoseconds
                    operation?.record("edit_start", ["stage": stage])
                    self.hud.show(.editing)
                    output = try await LLMClient.complete(
                        system: Prompts.voiceEdit(settings: self.settings),
                        user: Prompts.voiceEditInput(selection: selection, instruction: raw),
                        config: self.settings.llmConfig
                    )
                    operation?.record("edit_complete", ["duration_ms": DictationOperation.milliseconds(since: stageStarted), "empty": String(output.isEmpty)])
                } else if shouldPolish, self.settings.llmConfigured {
                    stage = "polish"
                    stageStarted = DispatchTime.now().uptimeNanoseconds
                    operation?.record("polish_start", ["stage": stage])
                    self.hud.show(.polishing)
                    do {
                        output = try await LLMClient.complete(
                            system: Prompts.polish(context: context, settings: self.settings),
                            user: Prompts.polishInput(raw),
                            config: self.settings.llmConfig,
                            timeout: 15
                        )
                        let emptyOutput = output.isEmpty
                        if emptyOutput { output = raw }
                        output = try PolishValidation.validate(source: raw, output: output)
                        operation?.record("polish_complete", ["duration_ms": DictationOperation.milliseconds(since: stageStarted),
                            "empty": String(emptyOutput), "fallback": String(emptyOutput)])
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        operation?.record("polish_error", ["stage": stage, "error_code": String((error as NSError).code),
                            "duration_ms": DictationOperation.milliseconds(since: stageStarted), "fallback": "true"])
                        // A cleanup failure must not lose the user's words; fall back to the raw transcript.
                        output = raw
                        polishError = L10n.tr("Polishing failed; using the original transcript.")
                    }
                } else if shouldPolish, opposite {
                    operation?.record("polish_error", ["stage": "polish", "reason": "not_configured", "fallback": "true"])
                    polishError = L10n.tr("Configure an AI service in Settings to polish. Using the original transcript.")
                }
                guard generation == self.generation, !Task.isCancelled else { return }

                self.lastTranscript = output
                stage = "insertion"
                stageStarted = DispatchTime.now().uptimeNanoseconds
                operation?.record("paste_attempt", ["empty": String(output.isEmpty)])
                await TextIO.insert(output)
                operation?.record("paste_returned", ["duration_ms": DictationOperation.milliseconds(since: stageStarted)])
                guard generation == self.generation, !Task.isCancelled else { return }
                self.history.add(HistoryEntry(
                    kind: kind, app: context?.name ?? "", raw: raw, output: output, duration: duration
                ))
                operation?.record("processing_complete", ["duration_ms": DictationOperation.milliseconds(since: processingStarted),
                    "fallback": String(polishError != nil), "empty": String(output.isEmpty)])
                self.finish(polishError.map { .error($0) } ?? .hidden)
            } catch is CancellationError {
                operation?.record("processing_cancelled", ["stage": stage, "reason": "cancelled",
                    "duration_ms": DictationOperation.milliseconds(since: processingStarted)])
                if generation == self.generation { self.finish(.hidden) }
            } catch {
                operation?.record(stage == "recognition" ? "recognition_error" : "edit_error", ["stage": stage,
                    "error_code": String((error as NSError).code), "duration_ms": DictationOperation.milliseconds(since: stageStarted)])
                operation?.record("processing_error", ["stage": stage, "error_code": String((error as NSError).code),
                    "duration_ms": DictationOperation.milliseconds(since: processingStarted)])
                guard generation == self.generation else { return }
                self.finish(.error(error.localizedDescription))
            }
        }
    }

    private func finish(_ phase: HUDModel.Phase) {
        recordingModelDirectory = nil
        diagnosticOperation = nil
        state = .idle
        session = nil
        processingTask = nil
        pressedAt = nil
        hotkeys.armAlternateFinish(nil)
        hud.model.recordingHint = nil
        hud.model.setDictionaryTerms([])
        updateTriggerKey()
        hud.show(phase)
    }

    func cancel(reason: String = "user") {
        let fields = ["reason": reason, "state": String(describing: state)]
        if let diagnosticOperation {
            diagnosticOperation.record("dictation_cancel", fields)
        } else {
            Diagnostics.shared.record(event: "dictation_cancel", metadata: fields)
        }
        diagnosticOperation = nil
        recordingModelDirectory = nil
        pressedAt = nil
        generation += 1
        recorder.stop()
        session?.cancel()
        session = nil
        processingTask?.cancel()
        processingTask = nil
        state = .idle
        hotkeys.armAlternateFinish(nil)
        hud.model.recordingHint = nil
        hud.model.setDictionaryTerms([])
        updateTriggerKey()
        hud.hide()
    }

    private func paste(_ text: String, into app: NSRunningApplication?) async {
        guard let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            lastTranscript = text
            hud.show(.error(L10n.tr("Target app changed; result saved")))
            return
        }
        await TextIO.insert(text)
    }

    func runAudioTest(url: URL) async throws -> String {
        guard state == .idle, !changingModel else { throw TalklessError.message(L10n.tr("Dictation or a model change is already in progress")) }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == AudioRecorder.sampleRate,
              file.processingFormat.channelCount == 1, file.length > 0,
              file.length < Int64(UInt32.max),
              let audio = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TalklessError.message(L10n.tr("Test audio must be 16 kHz mono PCM"))
        }
        try file.read(into: audio)
        guard let source = audio.floatChannelData?[0] else { throw TalklessError.message(L10n.tr("Cannot read test audio")) }
        let samples = Array(UnsafeBufferPointer(start: source, count: Int(audio.frameLength)))
        while ModelManager.shared.isChecking {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard ModelManager.shared.operationModelID == nil else {
            throw TalklessError.message(L10n.tr("Wait for the model operation to finish before testing dictation."))
        }
        let modelDirectory = try settings.resolvedQwenModelDirectory()
        generation += 1
        let generation = self.generation
        let modelPreparation = preparationGeneration
        let dictionaryTerms = settings.dictionaryTerms
        previewText = ""
        hud.model.preview = ""
        hud.model.isEditMode = false
        hud.model.setDictionaryTerms(dictionaryTerms)
        state = .recording
        let session = QwenTranscriptionSession(
            modelDirectory: modelDirectory,
            language: nil,
            contextualStrings: dictionaryTerms,
            onStatus: { [weak self] _ in
                guard let self, self.generation == generation,
                      self.state == .recording || self.state == .processing else { return }
                self.hud.show(.working)
            }
        )
        self.session = session
        session.onPartial = { [weak self] text in
            guard let self, self.generation == generation,
                  self.state == .recording || self.state == .processing else { return }
            self.previewText = text
            self.hud.model.preview = text
            if self.state == .recording {
                self.hud.model.isEditMode = false
                self.hud.model.setDictionaryTerms(dictionaryTerms)
                self.hud.show(.listening(handsFree: false))
            }
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
                      let target = frame.floatChannelData?[0] else { throw TalklessError.message(L10n.tr("Cannot allocate a test audio buffer")) }
                frame.frameLength = AVAudioFrameCount(count)
                for index in 0..<count { target[index] = samples[offset + index] }
                session.feed(frame)
            }
            state = .processing
            hud.show(.recognizing)
            let text = try await session.finish(samples: [])
            guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
            markModelReadyAfterRecognition(directory: modelDirectory, generation: generation, preparation: modelPreparation)
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

    private var translationTask: Task<Void, Never>?
    private var translationGeneration = 0
    private var translationSource: String?
    private var translationTargetApp: NSRunningApplication?
    private var acquiringTranslationSelection = false

    func translateSelection() async {
        // Clipboard fallback temporarily owns the pasteboard; never overlap two acquisitions.
        guard !shortcutCaptureActive, !acquiringTranslationSelection else { return }
        translationPanel.close()
        cancelTranslation()
        let token = translationGeneration
        guard settings.llmConfigured else {
            hud.show(.error(L10n.tr("Configure an AI service in Settings to translate selected text")))
            return
        }
        // Capture the destination before the clipboard fallback can suspend.
        let targetApp = NSWorkspace.shared.frontmostApplication
        acquiringTranslationSelection = true
        defer { acquiringTranslationSelection = false }
        let selected = await TextIO.selectedText()
        guard token == translationGeneration, !Task.isCancelled else { return }
        guard let text = selected, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            hud.show(.error(L10n.tr("Could not read any selected text")))
            return
        }
        translationSource = text
        translationTargetApp = targetApp
        requestTranslation()
    }

    private func cancelTranslation() {
        translationGeneration += 1
        translationTask?.cancel()
        translationTask = nil
        translationSource = nil
        translationTargetApp = nil
    }

    private func changeTranslationLanguages(source: TranslationLanguageSelection, target: TranslationLanguageSelection,
                                            displayedPreferences: TranslationLanguagePreferences) {
        guard translationSource != nil else { return }
        var preferences = settings.translationLanguages
        // The popup is a snapshot. Change only the fields the user actually edited,
        // preserving any newer choice made in Settings while this popup was open.
        if source != displayedPreferences.source { preferences.source = source }
        if target != displayedPreferences.target { preferences.target = target }
        guard preferences != settings.translationLanguages else { return }
        settings.translationLanguages = preferences
        requestTranslation()
    }

    private func requestTranslation() {
        guard let text = translationSource else { return }
        translationTask?.cancel()
        translationTask = nil
        translationGeneration += 1
        let token = translationGeneration
        let targetApp = translationTargetApp
        let preferences = settings.translationLanguages
        let resolution = TranslationLanguages.resolve(text: text, preferences: preferences)
        let onReplace: (String) -> Void = { [weak self] translated in
            Task { await self?.paste(translated, into: targetApp) }
        }
        let show: (String?, String?) -> Void = { [weak self] result, error in
            guard let self, self.translationGeneration == token else { return }
            self.translationPanel.show(
                source: text, result: result, error: error,
                preferences: preferences, resolution: resolution,
                allowsReplacement: targetApp != nil,
                onLanguagesChanged: { [weak self] source, target in
                    self?.changeTranslationLanguages(source: source, target: target, displayedPreferences: preferences)
                },
                onReplace: onReplace,
                onClose: { [weak self] in self?.cancelTranslation() }
            )
        }
        guard settings.llmConfigured else {
            show(nil, L10n.tr("Configure an AI service in Settings to translate selected text"))
            return
        }
        // A genuine script conversion (for example zh-Hans → zh-Hant) still calls the service.
        if !resolution.isSourceAutomatic,
           case .languageID(let targetID) = resolution.target,
           let sourceID = resolution.sourceLanguageID,
           TranslationLanguages.canonicalID(sourceID) == TranslationLanguages.canonicalID(targetID) {
            show(text, nil)
            return
        }
        show(nil, nil)
        let config = settings.llmConfig
        translationTask = Task { [weak self] in
            guard !Task.isCancelled, self?.translationGeneration == token else { return }
            do {
                let result = try await LLMClient.complete(
                    system: Prompts.translate(target: resolution.targetPromptName, source: resolution.sourcePromptName),
                    user: Prompts.translateInput(text),
                    config: config
                )
                guard let self, !Task.isCancelled, self.translationGeneration == token else { return }
                self.translationTask = nil
                show(result, nil)
                self.history.add(HistoryEntry(
                    kind: .translation, app: targetApp?.localizedName ?? "", raw: text, output: result, duration: 0
                ))
            } catch {
                guard let self, !Task.isCancelled, self.translationGeneration == token else { return }
                self.translationTask = nil
                show(nil, error.localizedDescription)
            }
        }
    }

}
