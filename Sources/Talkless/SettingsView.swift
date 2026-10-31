import AppKit
import AVFoundation
import Combine
import SwiftUI

enum SettingsAppearance {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.64, green: 0.69, blue: 1, alpha: 1)
        }
        return NSColor(srgbRed: 86 / 255, green: 103 / 255, blue: 219 / 255, alpha: 1)
    })
}

/// Grouped page list. Separate from SettingsView so it can be previewed without app services.
struct SettingsSidebar: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @Binding var selection: SettingsSection?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Talkless")
                    .font(.system(size: 17, weight: .semibold))
                Text(L10n.tr("Settings"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)

            List(selection: $selection) {
                ForEach(SettingsSection.groups, id: \.title) { group in
                    Section(L10n.tr(group.title)) {
                        ForEach(group.sections) { section in
                            Label {
                                Text(section.title)
                            } icon: {
                                Image(systemName: section.symbol)
                                    .frame(width: 18)
                            }
                            .padding(.vertical, 3)
                            .tag(section)
                        }
                    }
                }
            }
            // Rebuild native rows when their localized titles change; selection stays above the list.
            .id(localization.locale.identifier)
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .frame(width: 196)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct SettingsView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var localization = LocalizationSettings.shared
    var updateController: UpdateController? = nil
    @State private var selection: SettingsSection? = .dictation

    private var currentSection: SettingsSection { selection ?? .dictation }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(currentSection.title)
                        .font(.system(size: 22, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(currentSection.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 4)

                Group {
                    switch currentSection {
                    case .dictation:
                        DictationSettingsTab(controller: controller,
                                             onConfigureAI: { selection = .aiService },
                                             onPermissions: { selection = .system })
                    case .translation:
                        TranslationSettingsView(controller: controller, onConfigureAI: { selection = .aiService })
                    case .system:
                        SystemSettingsTab(controller: controller)
                    case .about:
                        AboutSettingsTab(controller: controller, updateController: updateController)
                    case .overlay:
                        OverlaySettingsView(appearance: $settings.hudAppearance)
                    case .models:
                        SpeechTab(controller: controller)
                    case .aiService:
                        AIServiceSettingsView()
                    case .dictionary:
                        DictionaryTab().padding(28)
                    case .history:
                        HistoryView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .environment(\.locale, localization.locale)
        .tint(SettingsAppearance.accent)
        .frame(minWidth: 800, idealWidth: 900, minHeight: 580, idealHeight: 660)
        .onReceive(NotificationCenter.default.publisher(for: .showSettingsSection)) { notification in
            if let section = notification.object as? SettingsSection { selection = section }
        }
    }
}

// MARK: - Dictation and system

private struct DictationSettingsTab: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @ObservedObject var controller: DictationController
    @ObservedObject var settings = AppSettings.shared
    let onConfigureAI: () -> Void
    let onPermissions: () -> Void
    @ObservedObject private var permissions = PermissionMonitor.shared
    private var microphoneGranted: Bool { permissions.microphoneStatus == .authorized }
    private var accessibilityGranted: Bool { permissions.accessibilityGranted }

    private var permissionMessage: String {
        if !microphoneGranted && !accessibilityGranted {
            return L10n.tr("Allow microphone and Accessibility access to dictate.")
        }
        return microphoneGranted
            ? L10n.tr("Allow Accessibility access for shortcuts and text insertion.")
            : L10n.tr("Allow microphone access to record your voice.")
    }

    var body: some View {
        Form {
            if !microphoneGranted || !accessibilityGranted {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.tr("Permission needed")).font(.headline)
                            Text(permissionMessage)
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Button(L10n.tr("Open permissions")) { onPermissions() }
                            .fixedSize()
                    }
                }
            }
            Section(L10n.tr("Recording")) {
                HStack {
                    Picker(selection: $settings.recordingGestureMode) {
                        ForEach(RecordingGestureMode.allCases) { Text($0.title).tag($0) }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L10n.tr("Recording mode"))
                            Text(L10n.format("Default: %@", AppSettings.defaultRecordingGestureMode.title))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .id(localization.locale.identifier)
                    Button(L10n.tr("Reset")) {
                        ShortcutRecorder.cancelCapture()
                        settings.recordingGestureMode = AppSettings.defaultRecordingGestureMode
                    }
                    .controlSize(.small)
                    .disabled(settings.recordingGestureMode == AppSettings.defaultRecordingGestureMode)
                    .help(L10n.format("Restore %@. Shortcuts and other settings are unchanged.", AppSettings.defaultRecordingGestureMode.title))
                    .accessibilityLabel(L10n.tr("Reset recording mode"))
                }
                .disabled(controller.state != .idle)
                Text((settings.recordingGestureMode == .hold
                      ? L10n.format("Hold %@ to talk; release to finish.", settings.triggerKey.title)
                      : L10n.format("Tap %@ to start talking; press again to finish.", settings.triggerKey.title))
                     + " " + L10n.tr("Esc cancels."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ShortcutRecorder(
                    title: L10n.tr("Dictation key"), value: settings.triggerKey.title,
                    defaultValue: AppSettings.defaultTriggerKey.title,
                    isDefault: settings.isTriggerKeyDefault,
                    setCaptureActive: controller.setShortcutCaptureActive,
                    onReset: settings.resetTriggerKey
                ) { key in
                    if let error = ShortcutRecorderRules.primaryError(key) { return error }
                    guard let key else { return L10n.tr("The dictation key cannot be cleared.") }
                    settings.triggerKey = key
                    return nil
                }
                .disabled(controller.state != .idle)
                .help(L10n.tr("Click to record Fn or a right-side modifier. Release to save; Esc cancels. Single keys only."))
                if settings.triggerKey == .fn {
                    Text(L10n.tr("Using Fn? Set the Globe key to Do Nothing in System Settings › Keyboard to prevent the emoji panel."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            DictationProcessingSettingsView(settings: settings, onConfigureAI: onConfigureAI)

            AudioInputSettingsView(settings: settings)
        }
        .formStyle(.grouped)
    }
}

private struct SystemSettingsTab: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @ObservedObject var controller: DictationController
    @ObservedObject private var permissions = PermissionMonitor.shared
    private var accessibility: Bool { permissions.accessibilityGranted }
    private var microphone: AVAuthorizationStatus { permissions.microphoneStatus }

    var body: some View {
        Form {
            Section(L10n.tr("Language")) {
                Picker(L10n.tr("Interface language"), selection: $localization.interfaceLanguage) {
                    ForEach(InterfaceLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .id(localization.locale.identifier)
                Text(L10n.tr("Changes the interface only, not speech recognition, output, or translation languages."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.tr("Permissions")) {
                PermissionRow(
                    title: L10n.tr("Accessibility"), detail: L10n.tr("Keyboard shortcuts and text insertion"),
                    granted: accessibility && controller.hotkeyActive
                ) {
                    if !DictationController.accessibilityGranted { DictationController.requestAccessibility() }
                    SystemSettingsPane.accessibility.open()
                }
                PermissionRow(title: L10n.tr("Microphone"), detail: L10n.tr("Record your voice"), granted: microphone == .authorized) {
                    // Read again at click time, not the timer's potentially stale snapshot.
                    if DictationController.microphoneStatus == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else if DictationController.microphoneStatus != .authorized {
                        SystemSettingsPane.microphone.open()
                    }
                }
            }

            Section(L10n.tr("Setup guide")) {
                Button(L10n.tr("Setup guide")) {
                    NotificationCenter.default.post(name: .showSetupGuide, object: nil)
                }
                Text(L10n.tr("Review permissions, speech recognition, and optional AI polishing."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LaunchAtLoginSettingsView()

            DiagnosticsSection()
        }
        .formStyle(.grouped)
    }
}

private struct DiagnosticsSection: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @State private var includeCrashReports = false
    @State private var exporting = false

    var body: some View {
        Section(L10n.tr("Diagnostics")) {
            Text(L10n.tr("Logs exclude audio, transcripts, API keys, and request contents. Nothing is uploaded automatically."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.tr("Include recent macOS crash reports"), isOn: $includeCrashReports)
                .disabled(exporting)
                .help(L10n.tr("Include native backtraces from the last 7 days. An unclean exit can also mean Force Quit or power loss."))
            if includeCrashReports {
                Text(L10n.tr("Crash reports from the last 7 days may include personal information and file paths. Review them before sharing."))
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { diagnosticActions }
                VStack(alignment: .leading, spacing: 8) { diagnosticActions }
            }
            Text(L10n.tr("After a crash, relaunch Talkless and export diagnostics."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var diagnosticActions: some View {
        HStack(spacing: 8) {
            Button(exporting ? L10n.tr("Exporting…") : L10n.tr("Export diagnostics…")) {
                exporting = true
                Task { @MainActor in
                    await Diagnostics.shared.exportDiagnostics(includeCrashReports: includeCrashReports)
                    exporting = false
                }
            }
            .disabled(exporting)
            if exporting { ProgressView().controlSize(.small) }
        }
        Button(L10n.tr("Open logs")) { Diagnostics.shared.revealAppLogs() }
            .help(L10n.tr("Local app and recording lifecycle logs rotate automatically, up to 15 MB."))
        Button(L10n.tr("Open crash reports")) { Diagnostics.shared.openCrashReports() }
    }
}

private struct PermissionRow: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .accessibilityLabel(granted ? L10n.tr("Allowed") : L10n.tr("Access needed"))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !granted {
                Button(L10n.tr("Grant access"), action: action)
                    .fixedSize()
                    .accessibilityLabel(L10n.format("Grant %@ access", title))
            }
        }
    }
}

// MARK: - About

private struct AboutSettingsTab: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @ObservedObject var controller: DictationController
    var updateController: UpdateController?

    // Preview/development callers may omit the updater. Read metadata only;
    // opening About must never create another updater or start a check.
    private var installedVersion: String {
        guard let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !version.isEmpty else { return L10n.tr("Development build") }
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !build.isEmpty else { return version }
        return L10n.format("%@ (build %@)", version, build)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 48, height: 48)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Talkless").font(.headline)
                        Text(L10n.tr("Voice input for macOS."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if let updateController {
                // The existing section includes installed version; show it only once.
                UpdateSettingsView(updater: updateController, controller: controller)
            } else {
                Section(L10n.tr("Updates")) {
                    LabeledContent(L10n.tr("Installed version"), value: installedVersion)
                    Text(L10n.tr("Updates are not configured for this build."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(L10n.tr("Project")) {
                LabeledContent(L10n.tr("Website")) {
                    Link("typeless.x2x3.com", destination: URL(string: "https://typeless.x2x3.com")!)
                }
                LabeledContent(L10n.tr("Source code")) {
                    Link("GitHub", destination: URL(string: "https://github.com/x2x3studio/talkless")!)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Speech Recognition

private struct SpeechTab: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject var controller: DictationController
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var modelManager = ModelManager.shared
    @State private var locales: [Locale] = []
    @State private var downloadStatus = ""
    @State private var downloadingAppleModel = false

    private var controlsDisabled: Bool { controller.state != .idle || modelManager.isBusy }

    private let presets: [(String, String, String)] = [
        ("OpenAI", "https://api.openai.com/v1", "gpt-4o-transcribe"),
        ("Groq", "https://api.groq.com/openai/v1", "whisper-large-v3-turbo"),
        ("SiliconFlow", "https://api.siliconflow.cn/v1", "FunAudioLLM/SenseVoiceSmall"),
    ]

    var body: some View {
        Form {
            Section {
                Picker(L10n.tr("Recognition engine"), selection: $settings.asrEngine) {
                    ForEach(ASREngine.allCases) { Text($0.title).tag($0) }
                }
                .id(localization.locale.identifier)
                .disabled(controlsDisabled)
            }

            if settings.asrEngine == .qwen {
                ModelManagementView(controller: controller)

                Section {
                    DisclosureGroup(L10n.tr("Advanced")) {
                        Toggle(L10n.tr("Use a custom model folder"), isOn: $settings.useCustomQwenDirectory)
                        if settings.useCustomQwenDirectory {
                            TextField(L10n.tr("Model folder"), text: $settings.qwenModelDirectory)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                Button(L10n.tr("Choose Folder…")) { chooseModelDirectory() }
                                Button(L10n.tr("Use Downloaded Models")) {
                                    settings.useCustomQwenDirectory = false
                                }
                            }
                            Text(L10n.tr("A Qwen3 ASR MLX folder with its configuration, tokenizer, and safetensors weights. Talkless does not manage or delete this folder."))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(controlsDisabled)
                }
            } else if settings.asrEngine == .apple {
                Section(L10n.tr("Apple On-device Recognition")) {
                    Picker(L10n.tr("Language"), selection: $settings.speechLocale) {
                        if locales.isEmpty {
                            Text(settings.speechLocale).tag(settings.speechLocale)
                        }
                        ForEach(locales, id: \.identifier) { locale in
                            Text(interfaceLocale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                .tag(locale.identifier)
                        }
                    }
                    .id(localization.locale.identifier)
                    .disabled(downloadingAppleModel || controlsDisabled)
                    HStack {
                        Button(L10n.tr("Download Speech Model")) { download() }
                            .disabled(downloadingAppleModel || controlsDisabled)
                        if downloadingAppleModel { ProgressView().controlSize(.small) }
                        Text(downloadStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(L10n.tr("On-device recognition with live previews while you speak."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section(L10n.tr("Cloud recognition")) {
                    HStack {
                        Text(L10n.tr("Presets"))
                        ForEach(presets, id: \.0) { preset in
                            Button(preset.0) {
                                settings.asrBaseURL = preset.1
                                settings.asrModel = preset.2
                            }
                        }
                    }
                    TextField(L10n.tr("API URL"), text: $settings.asrBaseURL)
                    SecureField(L10n.tr("API Key"), text: $settings.asrAPIKey)
                    if let error = settings.asrCredentialError {
                        Text(error).font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    TextField(L10n.tr("Model"), text: $settings.asrModel)
                    Text(L10n.tr("Uploads the full recording for transcription after you finish. Audio is not saved locally."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            let all = await AppleSpeechSession.supportedLocales()
            locales = all.sorted { $0.identifier < $1.identifier }
        }
    }

    private func chooseModelDirectory() {
        let panel = NSOpenPanel()
        panel.title = L10n.tr("Choose a Local Qwen Model Folder")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSString(string: settings.qwenModelDirectory).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            settings.qwenModelDirectory = url.path
        }
    }

    private func download() {
        downloadingAppleModel = true
        downloadStatus = L10n.tr("Downloading…")
        let locale = Locale(identifier: settings.speechLocale)
        Task {
            defer { downloadingAppleModel = false }
            do {
                try await AppleSpeechSession.prepareAssets(locale: locale)
                downloadStatus = L10n.tr("Ready")
            } catch {
                downloadStatus = error.localizedDescription
            }
        }
    }
}

// MARK: - Dictionary

private struct DictionaryTab: View {
    var body: some View {
        DictionaryView()
    }
}

