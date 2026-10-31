import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Production adapter. Rendering and refresh only read status; every permission request,
/// settings jump and preference write is behind a button in SetupGuideView.
struct SetupGuideLiveView: View {
    @ObservedObject var controller: DictationController
    let onComplete: () -> Void
    let onSkip: () -> Void
    let openSettings: (SettingsSection) -> Void
    @ObservedObject private var manager = ModelManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var localization = LocalizationSettings.shared
    @StateObject private var state = SetupGuideState()
    @StateObject private var launchAtLogin: LaunchAtLoginController
    @State private var accessibilityRequested = false
    @State private var microphoneRequestPending = false
    private let refreshTimer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    init(controller: DictationController, onComplete: @escaping () -> Void,
         onSkip: @escaping () -> Void, openSettings: @escaping (SettingsSection) -> Void,
         launchAtLoginService: any LaunchAtLoginService = MainAppLaunchAtLoginService()) {
        self.controller = controller
        self.onComplete = onComplete
        self.onSkip = onSkip
        self.openSettings = openSettings
        _launchAtLogin = StateObject(wrappedValue: LaunchAtLoginController(service: launchAtLoginService))
    }

    var body: some View {
        SetupGuideView(state: state, actions: SetupGuideActions(
            refresh: refresh,
            requestMicrophone: {
                // Recheck at click time; never repeat an outstanding/rejected prompt
                // or open Settings for access granted since the last refresh.
                guard !microphoneRequestPending else { return }
                switch DictationController.microphoneStatus {
                case .authorized: refresh(); return
                case .notDetermined: break
                default: SystemSettingsPane.microphone.open(); refresh(); return
                }
                microphoneRequestPending = true
                refresh()
                AVCaptureDevice.requestAccess(for: .audio) { _ in
                    Task { @MainActor in
                        microphoneRequestPending = false
                        refresh()
                    }
                }
            },
            openMicrophoneSettings: { SystemSettingsPane.microphone.open() },
            requestAccessibility: {
                guard !DictationController.accessibilityGranted else { refresh(); return }
                accessibilityRequested = true
                DictationController.requestAccessibility()
                SystemSettingsPane.accessibility.open()
                refresh()
            },
            openAccessibilitySettings: { SystemSettingsPane.accessibility.open() },
            openSpeechSettings: { openSettings(.models) },
            openAISettings: { openSettings(.aiService) },
            enablePolish: {
                guard settings.llmConfigured else { refresh(); return }
                settings.polishEnabled = true
                refresh()
            },
            finish: onComplete,
            skipSetup: onSkip,
            setLaunchAtLogin: { enabled in
                Task { await launchAtLogin.setEnabled(enabled) }
            },
            openLoginItems: launchAtLogin.openLoginItems
        ), launchAtLogin: LaunchAtLoginPresentation(controller: launchAtLogin))
        .onAppear(perform: refresh)
        .onReceive(refreshTimer) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .interfaceLanguageDidChange)) { _ in refresh() }
    }

    private func refresh() {
        launchAtLogin.refresh()
        let microphone: SetupGuidePermission
        switch DictationController.microphoneStatus {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = microphoneRequestPending ? .requesting : .notDetermined
        case .denied: microphone = .denied
        case .restricted: microphone = .restricted
        @unknown default: microphone = .denied
        }
        let speech = speechStatus
        let snapshot = SetupGuideSnapshot(
            microphone: microphone,
            accessibility: DictationController.accessibilityGranted ? .granted : (accessibilityRequested ? .denied : .notDetermined),
            shortcutsReady: controller.hotkeyActive,
            speechReady: speech.ready,
            speechStatus: speech.detail,
            aiConfigured: settings.llmConfigured,
            polishEnabled: settings.polishEnabled,
            controls: SetupGuideControls(
                dictationKeyTitle: settings.triggerKey.title,
                holdToTalk: settings.recordingGestureMode == .hold,
                translationShortcutTitle: settings.translationShortcut.keyCode == nil ? nil : settings.translationShortcut.title
            )
        )
        if state.snapshot != snapshot { state.snapshot = snapshot }
    }

    /// Read-only and independently testable with synthetic settings/model services.
    var speechStatus: (ready: Bool, detail: String) {
        switch settings.asrEngine {
        case .qwen:
            if settings.useCustomQwenDirectory {
                return (false, L10n.tr("A custom model folder is selected. Review it in Speech recognition settings; this guide does not validate custom models."))
            }
            guard let entry = manager.entry(modelID: manager.activeModelID) else {
                return (false, L10n.tr("Choose a model in Speech recognition settings."))
            }
            let status: String
            let ready: Bool
            switch entry.phase {
            case .installed:
                if manager.isChecking {
                    ready = false
                    status = L10n.tr("Checking model files…")
                } else if manager.isBusy {
                    ready = false
                    status = L10n.tr("Wait for the current model operation to finish.")
                } else if let directory = manager.installedDirectory(entry.id) {
                    switch controller.modelPreparationState(for: directory) {
                    case .unprepared:
                        ready = false
                        status = L10n.tr("Downloaded; waiting for model preparation.")
                    case .preparing:
                        ready = false
                        status = L10n.tr("Preparing model…")
                    case .ready:
                        ready = true
                        status = L10n.tr("Ready · kept in memory")
                    case .failed:
                        ready = false
                        status = L10n.tr("Model preparation failed. Check Speech recognition settings.")
                    }
                } else {
                    ready = false
                    status = L10n.tr("Model needs attention. Open Speech recognition for details.")
                }
            case .checking: ready = false; status = L10n.tr("Checking model files…")
            case .notInstalled: ready = false; status = L10n.tr("Not downloaded")
            case .downloading: ready = false; status = L10n.tr("Downloading…")
            case .verifying: ready = false; status = L10n.tr("Verifying…")
            case .paused: ready = false; status = L10n.tr("Download paused")
            case .failed: ready = false; status = L10n.tr("Model needs attention. Open Speech recognition for details.")
            case .deleting: ready = false; status = L10n.tr("Deleting…")
            }
            return (ready, L10n.format("%@: %@", entry.model.name, status))
        case .apple:
            return (false, L10n.tr("Apple recognition is selected. Language assets are checked when dictation starts; this guide has not verified them."))
        case .openAICompatible:
            return (false, L10n.tr("Cloud recognition is selected. Review its configuration in Speech recognition settings. This guide makes no test requests."))
        }
    }
}
