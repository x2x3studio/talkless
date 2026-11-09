import AppKit
import AVFoundation
import Combine

/// Values owned by one recording, never a live settings object. Build only the prompts
/// that recording can use (voice editing may still be requested after capture starts).
struct DictationConfiguration {
    let llmConfig: LLMClient.Config
    let llmConfigured: Bool
    let voiceEditEnabled: Bool
    let originalLanguage: Bool
    let punctuationStyle: PunctuationStyle
    let latinSpacing: LatinSpacing
    let polishPrompt: String?
    let enhancedPrompt: String?
    let voiceEditPrompt: String?

    @MainActor
    init(settings: AppSettings, context: AppContext?, polishEnabled: Bool,
         enhanced: Bool, alternatives: Bool) {
        llmConfig = settings.llmConfig
        llmConfigured = settings.llmConfigured
        voiceEditEnabled = settings.voiceEditEnabled
        originalLanguage = settings.outputLanguage == .original
        punctuationStyle = settings.punctuationStyle
        latinSpacing = settings.latinSpacing
        let usesPolish = polishEnabled && llmConfigured
        let usesEnhanced = usesPolish && (enhanced || alternatives)
        polishPrompt = usesPolish && !usesEnhanced ? Prompts.polish(context: context, settings: settings) : nil
        enhancedPrompt = usesEnhanced
            ? EnhancedPolish.systemPrompt(context: context, settings: settings, alternatives: alternatives) : nil
        voiceEditPrompt = voiceEditEnabled && llmConfigured ? Prompts.voiceEdit(settings: settings) : nil
    }
}

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
    /// `.recording` includes asynchronous device startup so every existing busy guard applies.
    /// Hold release cancels this task; explicit finish waits for it exactly once.
    private var startupTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    /// Late recognizer previews/status must not overwrite final raw or inserted output.
    private var acceptsRecognitionHUDUpdates = false
    /// Incremented on each start/cancel to discard stale asynchronous results.
    private var generation = 0
    private var diagnosticOperation: DictationOperation?
    private var recordingModelDirectory: URL?
    private var recordingPreparationGeneration = 0
    private var pressedAt: CGEventTimestamp?
    private var handsFree = false
    /// The edit modifier was held with the dictation key: edit the selection instead of typing.
    private var editIntent = false
    /// Snapshotted before setup so a settings change only affects the next recording.
    private var recordingGestureMode: RecordingGestureMode = .hold
    /// Per-recording default; changing Settings never changes an in-flight dictation.
    private var recordingPolishEnabled = false
    private var recordingConfiguration: DictationConfiguration?
    private var recordingCandidatesEnabled = false
    private var recordingCandidateWait: TimeInterval = 5
    private let sentencePanel = SentenceCandidatesPanel()
    /// Per-recording snapshot of explicit "heard as" fixes, like the dictionary hints.
    private var recordingReplacements: [DictionaryReplacement] = []
    private var languageSubscription: AnyCancellable?
    private var editSelection: String?
    /// The ⌘C selection fallback for apps without an Accessibility selection; stop awaits it.
    private var selectionTask: Task<Void, Never>?
    private var targetApp: NSRunningApplication?
    @Published private(set) var lastTranscript = ""
    /// True while polishing or voice editing waits on the AI service (menu bar shows "@").
    @Published private(set) var aiInProgress = false
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
        guard state == .idle, !changingModel, !ModelManager.shared.isBusy else { return }
        guard settings.needsLocalModel else {
            // Cancel prewarming before queuing unload on the sole model runtime. Keeping the
            // change guard until unload finishes prevents a newer session from racing teardown.
            guard preparedModelDirectory != nil || preparingModelDirectory != nil || failedModelDirectory != nil else { return }
            preparationGeneration += 1
            modelPreparationTask?.cancel()
            preparedModelDirectory = nil
            preparingModelDirectory = nil
            failedModelDirectory = nil
            modelPreparationStatusKey = nil
            changingModel = true
            modelPreparationTask = Task { [weak self] in
                await QwenTranscriptionSession.unloadModel()
                guard let self else { return }
                self.changingModel = false
                self.modelPreparationTask = nil
                self.prepareSelectedModel() // Settings may have changed again during unload.
            }
            return
        }
        guard let directory = try? settings.resolvedQwenModelDirectory() else { return }
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
                guard self.settings.needsLocalModel else {
                    self.modelPreparationTask = nil
                    self.prepareSelectedModel()
                    return
                }
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
        hotkeys.onEscape = { [weak self] in self?.escapePressed() ?? false }
        hotkeys.onEditModifier = { [weak self] in self?.editModifierPressed() }
        translateHotKey = GlobalHotKey { [weak self] in
            Task { await self?.translateSelection() }
        }
        updateTranslationShortcut(settings.translationShortcut)
        languageSubscription = NotificationCenter.default.publisher(for: .interfaceLanguageDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
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
            editIntent = hotkeys.editModifierHeld
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
        // A short hold may end before the device opens. Do not record after key-up
        // or submit empty/late audio just because native startup eventually returns.
        if startupTask != nil {
            cancel(reason: "startup_release")
        } else {
            stopAndProcess()
        }
    }

    /// Pressing the edit modifier while recording turns this recording into voice editing.
    private func editModifierPressed() {
        guard state == .recording, !editIntent else { return }
        editIntent = true
        captureEditSelection()
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
            editIntent = false
            startRecording()
        case .recording:
            stopAndProcess()
        case .processing:
            break
        }
    }

    // MARK: - Recording

    private func startRecording() {
        guard !shortcutCaptureActive, state == .idle else { return }
        let audioInputDeviceUID = settings.audioInputDeviceUID
        // One term snapshot (My terms plus learned terms) for this recognizer and its live HUD;
        // later Settings edits and newly learned fixes wait until next time.
        settings.expireLearnedFixes()
        let dictionaryTerms = settings.recognitionTerms
        let replacements = settings.recognitionReplacements
        recordingReplacements = replacements
        hud.model.setDictionaryTerms([])
        hud.model.revisionOriginal = nil
        hud.model.notice = nil
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
        let enhanced = settings.enhancedRecognition && !editIntent
        if enhanced && (!settings.doubaoConfigured || !settings.llmConfigured) {
            hud.show(.error(L10n.tr("Enhanced recognition needs a local model, Doubao, and an AI service.")))
            return
        }
        let localSelected = settings.asrEngine == .qwen
        let modelBusy = ModelManager.shared.operationModelID != nil
        if localSelected || enhanced, modelBusy {
            operation.record("recording_blocked", ["reason": "model_busy", "stage": "startup"])
            hud.show(.error(L10n.tr("Wait for the model operation to finish before starting dictation.")))
            return
        }
        var qwenDirectory: URL?
        if localSelected || enhanced {
            do { qwenDirectory = try settings.resolvedQwenModelDirectory() }
            catch {
                operation.record("recording_blocked", ["reason": "model_unavailable", "stage": "startup"])
                hud.show(.error(error.localizedDescription))
                onModelSetupRequested?()
                return
            }
        } else if settings.onlineLocalFallback, !modelBusy {
            // Fallback is a safety net: without a usable local model, online still works alone.
            qwenDirectory = try? settings.resolvedQwenModelDirectory()
        }
        let fallbackEnabled = settings.asrEngine == .doubao && settings.onlineLocalFallback && qwenDirectory != nil
        switch Self.microphoneStatus {
        case .notDetermined:
            operation.record("permission_blocked", ["permission": "microphone", "reason": "not_determined", "stage": "startup"])
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        case .denied, .restricted:
            operation.record("permission_blocked", ["permission": "microphone",
                "reason": Self.microphoneStatus == .denied ? "denied" : "restricted", "stage": "startup"])
            hud.show(.error(L10n.tr("Allow Talkless in System Settings › Privacy & Security › Microphone")))
            // A managed (restricted) Mac cannot change this, so only open the pane when the user can.
            if Self.microphoneStatus == .denied { openPermissionSettings(.microphone) }
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

        operation.mode = editSelection == nil ? "dictation" : "edit"
        diagnosticOperation = operation
        let generation = self.generation
        acceptsRecognitionHUDUpdates = true
        func localSession(_ directory: URL) -> any TranscriptionSession {
            QwenTranscriptionSession(
                modelDirectory: directory,
                language: nil,
                contextualStrings: dictionaryTerms,
                onStatus: { [weak self] _ in
                    guard let self, self.isCurrentRecognition(generation) else { return }
                    self.hud.show(.working)
                },
                onError: { [weak self] message in
                    guard let self, self.isCurrentRecognition(generation) else { return }
                    self.diagnosticOperation?.record("recognition_error", ["stage": "recognition", "reason": "recognition_error"])
                    self.cancel(reason: "recognition_error")
                    self.hud.show(.error(message))
                }
            )
        }
        let session: any TranscriptionSession
        var usesLocalSession = localSelected
        if enhanced, let qwenDirectory {
            do {
                let relay = EnhancedFailureRelay()
                let online = try DoubaoTranscriptionSession(config: settings.doubaoConfig, onError: { [weak self] message in
                    relay.session?.onlineFailed(TalklessError.message(message))
                    guard let self, self.isCurrentRecognition(generation) else { return }
                    self.diagnosticOperation?.record("recognition_fallback", ["engine": "qwen", "reason": "recognition_error"])
                })
                let local = QwenTranscriptionSession(modelDirectory: qwenDirectory, language: nil, contextualStrings: dictionaryTerms,
                    onError: { [weak self] message in
                        relay.session?.localFailed(TalklessError.message(message))
                        guard let self, self.isCurrentRecognition(generation) else { return }
                        self.diagnosticOperation?.record("recognition_fallback", ["engine": "doubao", "reason": "recognition_error"])
                    })
                let combined = EnhancedTranscriptionSession(online: online, local: local, operationID: operation.id.uuidString,
                    diagnostics: { Diagnostics.shared.recordAsync(event: "asr_timing", metadata: $0) })
                relay.session = combined
                session = combined
                // A successful online result does not prove that the local model loaded.
                usesLocalSession = false
            } catch {
                hud.show(.error(error.localizedDescription))
                return
            }
        } else {
            switch settings.asrEngine {
            case .qwen:
                guard let qwenDirectory else { return }
                session = localSession(qwenDirectory)
            case .doubao:
                do {
                    let online = try DoubaoTranscriptionSession(config: settings.doubaoConfig, onError: { [weak self] message in
                        guard let self, self.isCurrentRecognition(generation) else { return }
                        if fallbackEnabled {
                            // Keep recording the whole utterance for local replay when the key is released.
                            self.hud.model.notice = L10n.tr("Doubao failed. Offline recognition will finish this recording.")
                        } else {
                            self.cancel(reason: "recognition_error")
                            self.hud.show(.error(message))
                        }
                    })
                    if fallbackEnabled, let directory = qwenDirectory {
                        session = FallbackTranscriptionSession(online: online, makeLocal: {
                            QwenTranscriptionSession(modelDirectory: directory, language: nil, contextualStrings: dictionaryTerms)
                        }, onFallback: { [weak self] in
                            guard let self, self.isCurrentRecognition(generation) else { return }
                            self.diagnosticOperation?.record("recognition_fallback", ["fallback": "true"])
                            self.hud.model.preview = ""
                            self.hud.model.notice = L10n.tr("Doubao failed. Using offline recognition for this recording.")
                            self.hud.show(.recognizing)
                        })
                    } else { session = online }
                } catch {
                    guard fallbackEnabled, let qwenDirectory else {
                        operation.record("recording_blocked", ["reason": "not_configured", "stage": "startup"])
                        hud.show(.error(error.localizedDescription))
                        onModelSetupRequested?()
                        return
                    }
                    // Online cannot start (for example, no key yet): record locally instead.
                    operation.record("recognition_fallback", ["fallback": "true", "stage": "startup"])
                    hud.model.notice = L10n.tr("Doubao is not set up. Using offline recognition for this recording.")
                    session = localSession(qwenDirectory)
                    usesLocalSession = true
                }
            }
        }
        session.onPartial = { [weak self] partial in
            guard let self, self.isCurrentRecognition(generation) else { return }
            // Show the same dictionary fixes live that the final text will get.
            let text = DictionaryReplacements.apply(replacements, to: partial).text
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
        recordingModelDirectory = usesLocalSession ? qwenDirectory?.standardizedFileURL : nil
        recordingPreparationGeneration = preparationGeneration

        recorder.onBuffer = { [weak session] buffer in session?.feed(buffer) }
        recorder.onError = { [weak self] _ in
            guard let self, self.generation == generation,
                  self.state == .recording || self.state == .processing else { return }
            self.cancel(reason: "recorder_interruption")
        }
        // Publish busy state and capture the finish choice before yielding. Event-tap
        // callbacks must never wait for engine/input-node/HAL startup or teardown.
        state = .recording
        // Snapshotted so a Settings change only affects the next recording.
        recordingPolishEnabled = settings.polishEnabled || enhanced
        recordingCandidatesEnabled = settings.sentenceCandidates
        recordingCandidateWait = TimeInterval(min(15, max(2, settings.candidateWaitSeconds)))
        let configuration = DictationConfiguration(settings: settings, context: context,
                                                  polishEnabled: recordingPolishEnabled, enhanced: enhanced,
                                                  alternatives: recordingCandidatesEnabled)
        recordingConfiguration = configuration
        // Overlap the AI service handshake with speech instead of paying it after recognition.
        if recordingPolishEnabled && configuration.llmConfigured {
            LLMAPITransport.preconnect(baseURL: configuration.llmConfig.baseURL, apiProtocol: configuration.llmConfig.apiProtocol)
        }
        hud.model.isEditMode = editSelection != nil
        hud.model.preview = ""
        hud.model.setDictionaryTerms(editSelection == nil ? dictionaryTerms : [])
        hud.show(.listening(handsFree: handsFree))
        // Only an explicit edit gesture reads the selection. Plain dictation never does, so a
        // field that selects its contents on focus (an address bar) is simply typed over.
        if editIntent { captureEditSelection() }
        startupTask = Task { [weak self] in
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            do {
                try await self.recorder.start(deviceUID: audioInputDeviceUID, operationID: operation.id)
                guard self.generation == generation, !Task.isCancelled else { return }
                self.startupTask = nil
                operation.record("recording_started", ["startup_ms": DictationOperation.milliseconds(since: operation.startedAt)])
                // An explicit finish may already be awaiting this task in .processing.
                // Do not restore listening UI or recapture settings after the await.
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                operation.record("recording_error", ["error_code": String((error as NSError).code), "reason": "start_failed", "stage": "startup"])
                self.cancel(reason: "startup_failed")
                // Cleanup hides the HUD; only actionable startup failures should reveal it again.
                if !(error is CancellationError) { self.hud.show(.error(error.localizedDescription)) }
            }
        }
    }

    /// Read the selection for voice editing: Accessibility first, then the app's Copy in the
    /// background when the app cannot report it. Without a selection, the words are dictated.
    private func captureEditSelection() {
        guard let configuration = recordingConfiguration,
              configuration.voiceEditEnabled, configuration.llmConfigured, editSelection == nil, selectionTask == nil,
              !acquiringTranslationSelection,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let generation = self.generation
        acquiringTranslationSelection = true // Keep the same owner through AX and Copy awaits.
        selectionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.acquiringTranslationSelection = false }
            let reading = await TextIO.selectionViaAX(targetPID: pid)
            guard !Task.isCancelled, self.generation == generation,
                  self.state == .recording || self.state == .processing,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            switch reading {
            case .text(let text):
                self.adoptEditSelection(text)
            case .empty:
                self.hud.model.notice = L10n.tr("No text is selected, so this will be typed as dictation.")
            case .unavailable:
                let selection = await TextIO.selectedTextViaCopy(targetPID: pid)
                guard !Task.isCancelled, self.generation == generation,
                      self.state == .recording || self.state == .processing,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                if let selection { self.adoptEditSelection(selection) }
                else { self.hud.model.notice = L10n.tr("No text is selected, so this will be typed as dictation.") }
            }
        }
    }

    /// A selection found for an edit gesture switches this recording to voice editing.
    private func adoptEditSelection(_ selection: String) {
        guard let configuration = recordingConfiguration,
              configuration.voiceEditEnabled, configuration.llmConfigured else { return }
        editSelection = selection
        diagnosticOperation?.mode = "edit"
        hud.model.isEditMode = true
        hud.model.setDictionaryTerms([])
        if state == .recording { hud.show(.listening(handsFree: handsFree)) }
        LLMAPITransport.preconnect(baseURL: configuration.llmConfig.baseURL, apiProtocol: configuration.llmConfig.apiProtocol)
    }

    /// Recognizer callbacks arrive asynchronously; only the active recording may touch the HUD.
    private func isCurrentRecognition(_ generation: Int) -> Bool {
        self.generation == generation && acceptsRecognitionHUDUpdates && (state == .recording || state == .processing)
    }

    private func stopAndProcess() {
        guard state == .recording, let session, let configuration = recordingConfiguration else { return }
        // Freeze audio before diagnostics, HUD work, or any startup/selection await.
        guard recorder.beginFinalization() else {
            // Startup has not run yet; do not let it open capture after finish.
            cancel(reason: "finish_before_start")
            return
        }
        let shouldPolish = recordingPolishEnabled
        let showCandidates = recordingCandidatesEnabled
        let candidateWait = recordingCandidateWait
        pressedAt = nil
        let operation = diagnosticOperation
        let processingStarted = DispatchTime.now().uptimeNanoseconds
        operation?.record("recording_stop", ["polish_enabled": String(shouldPolish)])
        let startupTask = self.startupTask
        // Stop requests become busy immediately; repeated presses/releases cannot
        // start another stop, even while native startup or teardown is pending.
        state = .processing
        hud.show(.recognizing)

        let generation = self.generation
        let selectionTask = self.selectionTask
        let context = self.context
        let targetApp = self.targetApp
        let modelDirectory = recordingModelDirectory
        let modelPreparation = recordingPreparationGeneration
        let replacements = recordingReplacements

        processingTask = Task { [weak self] in
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            // Edit or dictation is decided only after a pending ⌘C selection read finishes.
            await selectionTask?.value
            guard generation == self.generation, !Task.isCancelled else { return }
            let editSelection = self.editSelection
            var stage = "stop"
            var stageStarted = DispatchTime.now().uptimeNanoseconds
            do {
                await startupTask?.value
                guard generation == self.generation, !Task.isCancelled else { return }
                let samples = try await self.recorder.stop()
                guard generation == self.generation, !Task.isCancelled else { return }
                let duration = Double(samples.count) / AudioRecorder.sampleRate
                operation?.record("recording_stopped", ["num_samples": String(samples.count),
                    "duration_ms": String(Int(duration * 1_000)), "sample_rate": String(AudioRecorder.sampleRate)])
                if samples.isEmpty { operation?.record("recording_empty", ["reason": "empty_audio"]) }
                operation?.record("processing_start")
                stage = "recognition"
                stageStarted = DispatchTime.now().uptimeNanoseconds
                operation?.record("recognition_finish", ["num_samples": String(samples.count)])
                let recognized = try await session.finish(samples: samples)
                // Explicit dictionary fixes run before polish, so they also work with polish off.
                let fixed = DictionaryReplacements.applyTracking(replacements, to: recognized)
                let raw = fixed.text
                operation?.record("recognition_complete", ["duration_ms": DictationOperation.milliseconds(since: stageStarted),
                    "empty": String(raw.isEmpty), "replacement_count": String(fixed.count)])
                guard generation == self.generation, !Task.isCancelled else { return }
                self.acceptsRecognitionHUDUpdates = false
                self.hud.model.notice = nil
                self.hud.model.preview = raw
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
                var polishFallback = false
                var polished = false
                var candidateReviewUsed = false
                var explicitlyChosen = false
                if let selection = editSelection, let prompt = configuration.voiceEditPrompt {
                    kind = .edit
                    stage = "edit"
                    stageStarted = DispatchTime.now().uptimeNanoseconds
                    operation?.record("edit_start", ["stage": stage])
                    self.aiInProgress = true
                    self.hud.show(.editing)
                    output = try await LLMClient.complete(
                        system: prompt,
                        user: Prompts.voiceEditInput(selection: selection, instruction: raw),
                        config: configuration.llmConfig
                    )
                    operation?.record("edit_complete", ["duration_ms": DictationOperation.milliseconds(since: stageStarted), "empty": String(output.isEmpty)])
                } else if shouldPolish, configuration.llmConfigured {
                    stage = "polish"
                    stageStarted = DispatchTime.now().uptimeNanoseconds
                    operation?.record("polish_start", ["stage": stage])
                    self.aiInProgress = true
                    self.hud.show(.polishing)
                    do {
                        if let prompt = configuration.enhancedPrompt {
                            let secondary = (session as? EnhancedTranscriptionSession)?.secondaryTranscript
                            let choices = try await EnhancedPolish.run(primary: raw, secondary: secondary,
                                                                       system: prompt, config: configuration.llmConfig,
                                                                       alternatives: showCandidates)
                            guard generation == self.generation, !Task.isCancelled else { return }
                            operation?.record("polish_response", ["duration_ms": DictationOperation.milliseconds(since: stageStarted), "count": String(choices.count)])
                            output = choices[0]
                            if showCandidates, choices.count > 1 {
                                candidateReviewUsed = true
                                self.hud.show(.hidden)
                                let choiceStarted = DispatchTime.now().uptimeNanoseconds
                                operation?.record("candidate_wait_start", ["count": String(choices.count)])
                                guard let selection = await self.sentencePanel.choose(candidates: choices, timeout: candidateWait) else {
                                    throw CancellationError()
                                }
                                guard generation == self.generation, !Task.isCancelled else { return }
                                output = selection.text
                                explicitlyChosen = selection.explicit
                                operation?.record("candidate_wait_complete", ["duration_ms": DictationOperation.milliseconds(since: choiceStarted), "explicit_choice": String(selection.explicit)])
                            }
                        } else if let prompt = configuration.polishPrompt {
                            output = try await LLMClient.complete(
                                system: prompt,
                                user: Prompts.polishInput(raw),
                                config: configuration.llmConfig,
                                timeout: 5
                            )
                        }
                        let emptyOutput = output.isEmpty
                        if emptyOutput { output = raw }
                        output = try PolishValidation.validate(source: raw, output: output)
                        polished = !emptyOutput
                        operation?.record("polish_complete", ["duration_ms": DictationOperation.milliseconds(since: stageStarted),
                            "empty": String(emptyOutput), "fallback": String(emptyOutput)])
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        operation?.record("polish_error", ["stage": stage, "error_code": String((error as NSError).code),
                            "duration_ms": DictationOperation.milliseconds(since: stageStarted), "fallback": "true"])
                        // A cleanup failure must not lose the user's words; fall back to the raw transcript.
                        output = raw
                        polishFallback = true
                        if (error as? LLMClient.ClientError) != .timedOut {
                            polishError = L10n.tr("Polishing failed; using the original transcript.")
                        }
                    }
                }
                guard generation == self.generation, !Task.isCancelled else { return }
                if kind == .dictation {
                    // Same-language polish is evidence of how the recognizer mishears this user.
                    let sameLanguage = polished && configuration.originalLanguage
                        && (!candidateReviewUsed || explicitlyChosen)
                    self.settings.learnFromDictation(raw: raw, output: sameLanguage ? output : raw, fired: fixed.fired)
                    // The user's punctuation and spacing choices apply last, to every dictation.
                    output = TextFormatting.apply(output, punctuation: configuration.punctuationStyle,
                                                  spacing: configuration.latinSpacing)
                }

                self.lastTranscript = output
                // Never lose the words when they cannot be pasted where dictation started.
                if let blocker = self.insertionBlocker(for: targetApp) {
                    operation?.record("paste_skipped", ["reason": blocker.reason])
                    if blocker.reason == "permission" { self.openPermissionSettings(.accessibility) }
                    self.history.add(HistoryEntry(
                        kind: kind, app: context?.name ?? "", raw: raw, output: output, duration: duration
                    ))
                    operation?.record("processing_complete", ["duration_ms": DictationOperation.milliseconds(since: processingStarted),
                        "fallback": String(polishFallback), "empty": String(output.isEmpty)])
                    self.finish(.error(blocker.message))
                    return
                }
                stage = "insertion"
                stageStarted = DispatchTime.now().uptimeNanoseconds
                operation?.record("paste_attempt", TextIO.insertionContext().merging(["empty": String(output.isEmpty)]) { $1 })
                // Show the final words during the existing insertion await without
                // delaying input or claiming that cleanup is still running.
                // Compare against the recognizer's words so dictionary fixes are visible too.
                self.hud.model.revisionOriginal = editSelection == nil ? recognized : nil
                self.hud.model.preview = output
                self.hud.show(.inserting)
                let pasted = await TextIO.insert(output, targetPID: targetApp?.processIdentifier)
                guard generation == self.generation, !Task.isCancelled else { return }
                guard pasted == .submitted else {
                    operation?.record("paste_skipped", ["reason": pasted.diagnosticReason])
                    self.history.add(HistoryEntry(
                        kind: kind, app: context?.name ?? "", raw: raw, output: output, duration: duration
                    ))
                    operation?.record("processing_complete", ["duration_ms": DictationOperation.milliseconds(since: processingStarted), "empty": "false"])
                    self.finish(pasted.isSilent ? .hidden : .error(pasted.message))
                    return
                }
                operation?.record("paste_returned", ["duration_ms": DictationOperation.milliseconds(since: stageStarted),
                                                   "reason": pasted.diagnosticReason])
                self.history.add(HistoryEntry(
                    kind: kind, app: context?.name ?? "", raw: raw, output: output, duration: duration
                ))
                operation?.record("processing_complete", ["duration_ms": DictationOperation.milliseconds(since: processingStarted),
                    "fallback": String(polishFallback), "empty": String(output.isEmpty)])
                self.finish(polishError.map { .error($0) } ?? .completed)
            } catch is CancellationError {
                operation?.record("processing_cancelled", ["stage": stage, "reason": "cancelled",
                    "duration_ms": DictationOperation.milliseconds(since: processingStarted)])
                if generation == self.generation {
                    session.cancel()
                    self.finish(.hidden)
                }
            } catch {
                if stage == "stop" {
                    operation?.record("recording_error", ["stage": stage, "reason": "stop_failed",
                        "error_code": String((error as NSError).code)])
                    guard generation == self.generation, !Task.isCancelled else { return }
                    // Never finish recognition or paste a partial after failed teardown.
                    self.cancel(reason: "stop_interruption")
                    return
                }
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
        hud.model.notice = nil
        acceptsRecognitionHUDUpdates = false
        aiInProgress = false
        selectionTask = nil
        recordingModelDirectory = nil
        recordingConfiguration = nil
        diagnosticOperation = nil
        state = .idle
        session = nil
        startupTask = nil
        processingTask = nil
        pressedAt = nil
        if phase != .completed { hud.model.setDictionaryTerms([]) }
        updateTriggerKey()
        hud.show(phase)
    }

    func cancel(reason: String = "user") {
        sentencePanel.cancel()
        hud.model.notice = nil
        acceptsRecognitionHUDUpdates = false
        aiInProgress = false
        selectionTask?.cancel()
        selectionTask = nil
        let fields = ["reason": reason, "state": String(describing: state)]
        if let diagnosticOperation {
            diagnosticOperation.record("dictation_cancel", fields)
        } else {
            Diagnostics.shared.record(event: "dictation_cancel", metadata: fields)
        }
        diagnosticOperation = nil
        recordingModelDirectory = nil
        recordingConfiguration = nil
        pressedAt = nil
        generation += 1
        startupTask?.cancel()
        startupTask = nil
        recorder.cancel()
        session?.cancel()
        session = nil
        processingTask?.cancel()
        processingTask = nil
        state = .idle
        hud.model.setDictionaryTerms([])
        updateTriggerKey()
        hud.hide()
    }

    /// Opens the exact System Settings pane after a blocked user action. This never triggers
    /// a permission prompt; prompts stay in the setup guide and Settings.
    private func openPermissionSettings(_ pane: SystemSettingsPane) {
        pane.open()
    }

    /// Pasting needs Accessibility (to post ⌘V) and the app dictation started in.
    private func insertionBlocker(for app: NSRunningApplication?) -> (reason: String, message: String)? {
        if !Self.accessibilityGranted {
            return ("permission", L10n.tr("Talkless needs Accessibility permission to type into other apps. The result is saved in History."))
        }
        if let app, NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
            return ("target_changed", L10n.tr("The app changed before the text was ready. The result is saved in History."))
        }
        return nil
    }

    private func paste(_ text: String, into app: NSRunningApplication?) async {
        guard let app, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            lastTranscript = text
            if state == .idle {
                hud.show(.error(L10n.tr("Target app changed; result saved")))
            }
            return
        }
        let pasted = await TextIO.insert(text, targetPID: app.processIdentifier)
        guard !Task.isCancelled else { return }
        if pasted != .submitted {
            Diagnostics.shared.record(event: "paste_skipped", metadata: ["reason": pasted.diagnosticReason])
            lastTranscript = text
            if state == .idle, !pasted.isSilent { hud.show(.error(pasted.message)) }
        }
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
        let pollingGeneration = generation
        while ModelManager.shared.isChecking {
            try await Task.sleep(for: .milliseconds(50))
            guard generation == pollingGeneration, state == .idle, !changingModel else { throw CancellationError() }
        }
        try Task.checkCancellation()
        guard generation == pollingGeneration, state == .idle, !changingModel else { throw CancellationError() }
        guard ModelManager.shared.operationModelID == nil else {
            throw TalklessError.message(L10n.tr("Wait for the model operation to finish before testing dictation."))
        }
        let modelDirectory = try settings.resolvedQwenModelDirectory()
        generation += 1
        let generation = self.generation
        let modelPreparation = preparationGeneration
        let dictionaryTerms = settings.recognitionTerms
        previewText = ""
        hud.model.preview = ""
        hud.model.isEditMode = false
        hud.model.setDictionaryTerms(dictionaryTerms)
        state = .recording
        acceptsRecognitionHUDUpdates = true
        let session = QwenTranscriptionSession(
            modelDirectory: modelDirectory,
            language: nil,
            contextualStrings: dictionaryTerms,
            onStatus: { [weak self] _ in
                guard let self, self.isCurrentRecognition(generation) else { return }
                self.hud.show(.working)
            }
        )
        self.session = session
        session.onPartial = { [weak self] text in
            guard let self, self.isCurrentRecognition(generation) else { return }
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
                guard self.generation == generation, !Task.isCancelled else { throw CancellationError() }
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
            if state == .idle {
                hud.show(.error(L10n.tr("Configure an AI service in Settings to translate selected text")))
            }
            return
        }
        // Open the AI connection while the selection is read; the request follows immediately.
        LLMAPITransport.preconnect(baseURL: settings.llmBaseURL, apiProtocol: settings.llmProtocol)
        // Capture the destination before the clipboard fallback can suspend.
        let targetApp = NSWorkspace.shared.frontmostApplication
        acquiringTranslationSelection = true
        defer { acquiringTranslationSelection = false }
        let selected = await TextIO.selectedText(targetPID: targetApp?.processIdentifier)
        guard token == translationGeneration, !Task.isCancelled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetApp?.processIdentifier else { return }
        guard let text = selected, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if state == .idle {
                hud.show(.error(Self.accessibilityGranted
                    ? L10n.tr("Could not read any selected text")
                    : L10n.tr("Talkless needs Accessibility permission to read selected text. Allow it in System Settings › Privacy & Security › Accessibility.")))
                if !Self.accessibilityGranted { openPermissionSettings(.accessibility) }
            }
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
