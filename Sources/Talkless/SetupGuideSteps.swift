import SwiftUI

/// Reuse the real device picker with the same settings as Dictation; discovery is read-only.
struct SetupMicrophoneSetup: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            AudioInputSettingsView(settings: settings)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 180)
    }
}

struct SetupRecordingSetup: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            RecordingSettingsSection(mode: $settings.recordingGestureMode, triggerKey: $settings.triggerKey,
                                     isBusy: controller.state != .idle,
                                     setCaptureActive: controller.setShortcutCaptureActive,
                                     resetKey: settings.resetTriggerKey)
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 280)
        .onDisappear { ShortcutRecorder.cancelCapture() }
    }
}

/// The guide's speech step: choose offline or Doubao, then download the model or enter the key
/// right here. Every download or request still starts only from a button.
struct SetupSpeechSetup: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var manager = ModelManager.shared
    @AppStorage("modelDownloadSourceChoice") private var sourceChoice = "huggingFace"
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RecognitionEngineChooser(engine: $settings.asrEngine)
                .disabled(controller.state != .idle || manager.operationModelID != nil)
            if settings.asrEngine == .qwen {
                Text(L10n.tr("Recommended: download the offline model once (about 713 MB). Dictation then works without internet."))
                    .settingsNote()
                if settings.useCustomQwenDirectory {
                    Button(L10n.tr("Review the custom model folder in Settings"), action: openSettings)
                } else if let entry = manager.entry(modelID: manager.activeModelID) {
                    ModelDownloadCard(entry: entry, isInUse: entry.phase == .installed,
                                      preparationStatus: controller.modelPreparationStatus) {
                        actions(for: entry)
                    }
                    .padding(14)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                }
            } else {
                // Leave room for recognition options, including spoken cleanup.
                Form { DoubaoSettingsSection(settings: settings, localModelStatus: controller.modelPreparationStatus) }
                    .formStyle(.grouped)
                    .frame(height: 380)
                    .disabled(controller.state != .idle)
            }
        }
    }

    /// The source chosen in Settings; a custom mirror is configured there.
    private var source: ModelDownloadSource? {
        switch sourceChoice {
        case "huggingFace": .huggingFace
        case "hfMirror": .hfMirror
        default: nil
        }
    }

    @ViewBuilder private func actions(for entry: ModelEntry) -> some View {
        switch entry.phase {
        case .notInstalled, .paused, .failed:
            if let source {
                Button(entry.phase == .notInstalled ? L10n.tr("Download") : entry.phase == .paused ? L10n.tr("Resume") : L10n.tr("Retry")) {
                    manager.install(modelID: entry.id, source: source)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.state != .idle || manager.isBusy)
            } else {
                Button(L10n.tr("Download in Settings"), action: openSettings)
            }
        case .downloading, .verifying:
            Button(L10n.tr("Cancel")) { manager.cancel() }
                .disabled(manager.operationModelID != entry.id)
        case .installed, .checking, .deleting:
            EmptyView()
        }
    }
}

/// The guide's optional AI-polishing step, separate from recognition and local formatting.
struct SetupAISetup: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var showsAIService = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.tr("AI polishing")).font(.body.weight(.medium))
                    Text(L10n.tr("Requires a separately configured AI service. After recognition finishes, the transcript is sent to it for correction and polishing.")).settingsNote()
                }
                Spacer(minLength: 8)
                Toggle(L10n.tr("AI polishing"), isOn: $settings.polishEnabled)
                    .toggleStyle(.switch).labelsHidden()
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            AIServiceStatusView(settings: settings) { showsAIService = true }
            if !settings.llmConfigured {
                Text(L10n.tr("Set up an AI service to use AI polishing. Until then, dictation skips AI polishing."))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if settings.polishEnabled || showsAIService {
                AIServiceSettingsView(settings: settings)
                    .frame(height: 360)
            }
            if !settings.polishEnabled {
                Text(L10n.tr("You can turn it on later in Settings › Dictation."))
                    .settingsNote()
            }
        }
    }
}
