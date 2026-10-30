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

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, overlay, models, polish, dictionary, history

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .overlay: "Overlay"
        case .models: "Models"
        case .polish: "AI polish"
        case .dictionary: "Dictionary"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .overlay: "rectangle.on.rectangle"
        case .models: "square.stack.3d.up"
        case .polish: "sparkles"
        case .dictionary: "character.book.closed"
        case .history: "clock"
        }
    }

    var subtitle: String {
        switch self {
        case .general: "Make Talkless feel at home on your Mac."
        case .overlay: "Tune the quiet companion to your dictation."
        case .models: "Choose how Talkless transcribes your voice."
        case .polish: "Turn your transcript into finished text."
        case .dictionary: "Names, terms, and spellings that matter to you."
        case .history: "Your recent dictations, edits, and translations."
        }
    }
}

struct SettingsView: View {
    @ObservedObject var controller: DictationController
    @ObservedObject private var settings = AppSettings.shared
    var updateController: UpdateController? = nil
    @State private var selection: SettingsSection? = .general

    private var currentSection: SettingsSection { selection ?? .general }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Talkless")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text("Settings")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 26)

                List(SettingsSection.allCases, selection: $selection) { section in
                    Label {
                        Text(section.title)
                    } icon: {
                        Image(systemName: section.symbol)
                            .frame(width: 18)
                    }
                    .padding(.vertical, 5)
                    .tag(section)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .frame(width: 196)
            .background(.regularMaterial)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(currentSection.title)
                        .font(.system(size: 25, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text(currentSection.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 8)

                Group {
                    switch currentSection {
                    case .general:
                        GeneralTab(controller: controller, updateController: updateController)
                    case .overlay:
                        OverlaySettingsView(appearance: $settings.hudAppearance)
                    case .models:
                        SpeechTab(controller: controller)
                    case .polish:
                        PolishSettingsView()
                    case .dictionary:
                        DictionaryTab().padding(28)
                    case .history:
                        HistoryTab().padding(28)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(SettingsAppearance.accent)
        .frame(minWidth: 800, idealWidth: 900, minHeight: 580, idealHeight: 660)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("TalklessShowModels"))) { _ in
            selection = .models
        }
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var controller: DictationController
    var updateController: UpdateController?
    @ObservedObject var settings = AppSettings.shared
    @State private var accessibility = DictationController.accessibilityGranted
    @State private var microphone = DictationController.microphoneStatus
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Permissions") {
                PermissionRow(
                    title: "Accessibility", detail: "Keyboard shortcuts and text insertion",
                    granted: accessibility && controller.hotkeyActive
                ) {
                    DictationController.requestAccessibility()
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
                PermissionRow(title: "Microphone", detail: "Record your voice", granted: microphone == .authorized) {
                    if microphone == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                    }
                }
            }

            AudioInputSettingsView(settings: settings)

            Section("Keyboard shortcuts") {
                ShortcutRecorder(
                    title: "Dictation key", value: settings.triggerKey.title,
                    defaultValue: AppSettings.defaultTriggerKey.title,
                    isDefault: settings.isTriggerKeyDefault,
                    setCaptureActive: controller.setShortcutCaptureActive,
                    onReset: settings.resetTriggerKey
                ) { key in
                    if let error = ShortcutRecorderRules.primaryError(key, alternate: settings.alternateFinishKey) {
                        return error
                    }
                    guard let key else { return "The dictation key cannot be cleared." }
                    settings.triggerKey = key
                    return nil
                }
                .disabled(controller.state != .idle)
                Text("Click a shortcut. Press Fn or a right-side modifier. Release to save; Esc cancels. Single keys only.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.triggerKey == .fn || settings.effectiveAlternateFinishKey == .fn {
                    Text("For Fn, set the Globe key action to Do Nothing in System Settings › Keyboard to prevent the emoji panel from opening.")
                        .font(.caption).foregroundStyle(.orange)
                }
                ShortcutRecorder(
                    title: "Alternate finish key",
                    value: settings.alternateFinishKey.title(for: settings.triggerKey),
                    defaultValue: settings.defaultAlternateFinishKeyTitle,
                    isDefault: settings.isAlternateFinishKeyDefault,
                    allowsClearing: true, setCaptureActive: controller.setShortcutCaptureActive,
                    onReset: settings.resetAlternateFinishKey
                ) { key in
                    if let error = ShortcutRecorderRules.alternateError(key, primary: settings.triggerKey) {
                        return error
                    }
                    if let key {
                        guard let alternate = AlternateFinishKey(rawValue: key.rawValue) else {
                            return "That key is not supported for alternate finish."
                        }
                        settings.alternateFinishKey = alternate
                    } else {
                        settings.alternateFinishKey = .disabled
                    }
                    return nil
                }
                .disabled(controller.state != .idle)
                Text("During recording, alternate finish immediately ends dictation with the opposite AI setting for this session only. It never starts recording and does not apply to selected-text editing. Click its shortcut and press Delete or Backspace to disable it.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.effectiveAlternateFinishKey == nil && settings.alternateFinishKey != .disabled {
                    Text("Record a different key from the dictation key. Alternate finish is disabled while they match.")
                        .font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Translate selection", value: "⌃⌥T")
                HStack {
                    Spacer()
                    Button("Restore defaults") {
                        ShortcutRecorder.cancelCapture()
                        settings.restoreShortcutDefaults()
                    }
                    .disabled(settings.areShortcutsDefault || controller.state != .idle)
                    .help("Restore the dictation key to Fn / Globe and alternate finish to Automatic. Other settings are unchanged.")
                }
            }

            Section("Behavior") {
                HStack {
                    Picker("Recording mode", selection: $settings.recordingGestureMode) {
                        ForEach(RecordingGestureMode.allCases) { Text($0.title).tag($0) }
                    }
                    Button("Reset") {
                        ShortcutRecorder.cancelCapture()
                        settings.recordingGestureMode = AppSettings.defaultRecordingGestureMode
                    }
                    .disabled(settings.recordingGestureMode == AppSettings.defaultRecordingGestureMode)
                    .accessibilityLabel("Reset recording mode")
                }
                .disabled(controller.state != .idle)
                Text("Default: Automatic. Hold ends when you release; Toggle ends on the next press. Automatic supports both. Escape cancels. Changes apply to the next recording.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Edit selected text with your voice", isOn: $settings.voiceEditEnabled)
                    .help("Select text, then dictate an instruction such as Make it more formal")
                Toggle("Adapt tone to the current app", isOn: $settings.appToneEnabled)
                    .help("Match your writing to chat, email, code, or documents")
            }

            if let updateController {
                UpdatesSection(updater: updateController, controller: controller)
            }

            DiagnosticsSection()
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in
            accessibility = DictationController.accessibilityGranted
            microphone = DictationController.microphoneStatus
            if accessibility, !controller.hotkeyActive { controller.activateHotkey() }
        }
    }
}

private struct DiagnosticsSection: View {
    @State private var includeCrashReports = false
    @State private var exporting = false

    var body: some View {
        Section("Diagnostics") {
            Text("Local debug logs record app and recording lifecycle events, not audio, transcripts, API keys, or request contents. Logs rotate automatically (up to 15 MB). Nothing is uploaded automatically.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Include recent macOS crash reports", isOn: $includeCrashReports)
                .disabled(exporting)
            if includeCrashReports {
                Text("Original Talkless crash reports from the last 7 days include native backtraces and may contain personal information and file paths. Review them before sharing.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button(exporting ? "Exporting…" : "Export Diagnostics…") {
                    exporting = true
                    Task { @MainActor in
                        await Diagnostics.shared.exportDiagnostics(includeCrashReports: includeCrashReports)
                        exporting = false
                    }
                }
                .disabled(exporting)
                if exporting { ProgressView().controlSize(.small) }
                Button("Open Logs") { Diagnostics.shared.revealAppLogs() }
                Button("Open Crash Reports") { Diagnostics.shared.openCrashReports() }
            }
            Text("After a crash, relaunch Talkless and export diagnostics. Enable crash reports to include the macOS backtrace; a previous unclean exit can also mean Force Quit or power loss.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct UpdatesSection: View {
    @ObservedObject var updater: UpdateController
    @ObservedObject var controller: DictationController

    var body: some View {
        Section("Updates") {
            Picker("Update channel", selection: Binding(get: { updater.channel }, set: { updater.selectChannel($0) })) {
                ForEach(UpdateChannel.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!updater.canChangeChannel)
            Text("Beta includes prereleases. Returning to Stable does not downgrade Talkless.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Automatically check for updates", isOn: Binding(
                get: { updater.automaticallyChecksForUpdates },
                set: { updater.setAutomaticallyChecksForUpdates($0) }
            ))
            .disabled(!updater.canChangeAutomaticChecks)
            Text("Checks every 30 minutes while Talkless is running; checks during dictation wait until the next interval. You choose when to download and install; updates never install silently. Turning this off does not cancel an update already in progress.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Check for Updates…") { updater.checkForUpdates(nil) }
                .disabled(controller.state != .idle || !updater.canCheckForUpdates)
            if let status = updater.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if updater.canChangeAutomaticChecks && !updater.canChangeChannel {
                Text("Finish or dismiss the current update before changing channels.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Grant Access", action: action) }
        }
    }
}

// MARK: - Speech Recognition

private struct SpeechTab: View {
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
                Picker("Recognition engine", selection: $settings.asrEngine) {
                    ForEach(ASREngine.allCases) { Text($0.title).tag($0) }
                }
                .disabled(controlsDisabled)
            }

            if settings.asrEngine == .qwen {
                ModelManagementView(controller: controller)

                Section {
                    DisclosureGroup("Advanced") {
                        Toggle("Use a custom model folder", isOn: $settings.useCustomQwenDirectory)
                        if settings.useCustomQwenDirectory {
                            TextField("Model folder", text: $settings.qwenModelDirectory)
                                .textFieldStyle(.roundedBorder)
                            HStack {
                                Button("Choose Folder…") { chooseModelDirectory() }
                                Button("Use Downloaded Models") {
                                    settings.useCustomQwenDirectory = false
                                }
                            }
                            Text("A Qwen3 ASR MLX folder with its configuration, tokenizer, and safetensors weights. Talkless does not manage or delete this folder.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(controlsDisabled)
                }
            } else if settings.asrEngine == .apple {
                Section("Apple On-device Recognition") {
                    Picker("Language", selection: $settings.speechLocale) {
                        if locales.isEmpty {
                            Text(settings.speechLocale).tag(settings.speechLocale)
                        }
                        ForEach(locales, id: \.identifier) { locale in
                            Text(Locale(identifier: "en").localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                .tag(locale.identifier)
                        }
                    }
                    .disabled(downloadingAppleModel || controlsDisabled)
                    HStack {
                        Button("Download Speech Model") { download() }
                            .disabled(downloadingAppleModel || controlsDisabled)
                        if downloadingAppleModel { ProgressView().controlSize(.small) }
                        Text(downloadStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("On-device recognition with live previews while you speak.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Cloud recognition") {
                    HStack {
                        Text("Presets")
                        ForEach(presets, id: \.0) { preset in
                            Button(preset.0) {
                                settings.asrBaseURL = preset.1
                                settings.asrModel = preset.2
                            }
                        }
                    }
                    TextField("API URL", text: $settings.asrBaseURL)
                    SecureField("API Key", text: $settings.asrAPIKey)
                    TextField("Model", text: $settings.asrModel)
                    Text("Uploads the full recording for transcription after you finish. Audio is not saved locally.")
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
        panel.title = "Choose a Local Qwen Model Folder"
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
        downloadStatus = "Downloading…"
        let locale = Locale(identifier: settings.speechLocale)
        Task {
            defer { downloadingAppleModel = false }
            do {
                try await AppleSpeechSession.prepareAssets(locale: locale)
                downloadStatus = "Ready"
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

// MARK: - History

private struct HistoryTab: View {
    @ObservedObject var history = HistoryStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(history.entries.count) entries · \(history.totalCharacters) characters · \(Int(history.totalDuration / 60)) min recorded")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { history.clear() }.disabled(history.entries.isEmpty)
            }
            List(history.entries) { entry in
                HistoryRow(entry: entry)
                    .contextMenu {
                        Button("Copy Result") { TextIO.copyToClipboard(entry.output) }
                        Button("Copy Raw Transcript") { TextIO.copyToClipboard(entry.raw) }
                        Divider()
                        Button("Delete") { history.delete(entry) }
                    }
            }
            .overlay {
                if history.entries.isEmpty {
                    Text("No history yet").foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(kindTitle).font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                Text(entry.app).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(entry.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(entry.output).lineLimit(4).textSelection(.enabled)
            if entry.raw != entry.output, entry.kind == .dictation {
                Text(entry.raw).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    private var kindTitle: String {
        switch entry.kind {
        case .dictation: return "Dictation"
        case .edit: return "Voice Edit"
        case .translation: return "Translation"
        }
    }
}
