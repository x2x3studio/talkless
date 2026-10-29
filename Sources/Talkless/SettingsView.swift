import AppKit
import AVFoundation
import Combine
import SwiftUI

struct SettingsView: View {
    @ObservedObject var controller: DictationController
    var updateController: UpdateController? = nil

    var body: some View {
        TabView {
            GeneralTab(controller: controller, updateController: updateController).tabItem { Label("General", systemImage: "gearshape") }
            SpeechTab().tabItem { Label("Speech Recognition", systemImage: "waveform") }
            PolishTab().tabItem { Label("AI Polish", systemImage: "sparkles") }
            DictionaryTab().tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            HistoryTab().tabItem { Label("History", systemImage: "clock") }
        }
        .padding(20)
        .frame(width: 620, height: 520)
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
                    title: "Accessibility", detail: "Monitor shortcuts, read selected text, and paste text into other apps",
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

            Section("Keyboard Shortcuts") {
                Picker("Dictation key", selection: $settings.triggerKey) {
                    ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
                }
                Text("Hold to talk and release to insert. Tap for hands-free mode, then press again to finish. Esc cancels.")
                    .font(.caption).foregroundStyle(.secondary)
                if settings.triggerKey == .fn {
                    Text("For Fn, set the Globe key action to Do Nothing in System Settings › Keyboard to prevent the emoji panel from opening.")
                        .font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Translate selection", value: "⌃⌥T")
            }

            Section("Behavior") {
                Toggle("Use speech to edit selected text (e.g. Make it more formal)", isOn: $settings.voiceEditEnabled)
                Toggle("Adapt tone to the current app (chat, email, code, or documents)", isOn: $settings.appToneEnabled)
                Toggle("Sound effects", isOn: $settings.playSounds)
            }

            if let updateController {
                UpdatesSection(updater: updateController, controller: controller)
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in
            accessibility = DictationController.accessibilityGranted
            microphone = DictationController.microphoneStatus
            if accessibility, !controller.hotkeyActive { controller.activateHotkey() }
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
            Text("Stable includes stable releases only. Beta includes beta and stable releases, whichever is newer. Switching to Stable does not downgrade the installed app.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Check for Updates…") { updater.checkForUpdates(nil) }
                .disabled(controller.state != .idle || !updater.canCheckForUpdates)
            if let status = updater.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if !updater.canChangeChannel {
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
    @ObservedObject var settings = AppSettings.shared
    @State private var locales: [Locale] = []
    @State private var downloadStatus = ""

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
                .pickerStyle(.radioGroup)
            }

            if settings.asrEngine == .qwen {
                Section("Local Qwen Model") {
                    TextField("Model directory", text: $settings.qwenModelDirectory)
                    HStack {
                        Button("Choose Model Folder…") { chooseModelDirectory() }
                        Button("Reset to Default Path") {
                            settings.qwenModelDirectory = AppSettings.defaultQwenModelDirectory
                        }
                    }
                    Text("Choose a downloaded Qwen3-ASR-1.7B MLX model folder containing config.json, a tokenizer, and safetensors weights. Audio stays on this Mac; models are not downloaded automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Default: ~/Library/Application Support/Talkless/Models/Qwen3-ASR-1.7B-4bit. Development builds fall back to an existing experimental model in the project if this folder is unavailable.")
                        .font(.caption).foregroundStyle(.secondary)
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
                    HStack {
                        Button("Download Speech Model") { download() }
                        Text(downloadStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Free and fully offline, with live previews while you speak. Mixed Chinese and English speech may be less accurate than cloud models.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Cloud Recognition (OpenAI /audio/transcriptions compatible)") {
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
        downloadStatus = "Downloading…"
        let locale = Locale(identifier: settings.speechLocale)
        Task {
            do {
                try await AppleSpeechSession.prepareAssets(locale: locale)
                downloadStatus = "Ready ✓"
            } catch {
                downloadStatus = error.localizedDescription
            }
        }
    }
}

// MARK: - AI Polish

private struct PolishTab: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var testResult = ""
    @State private var testing = false

    private let presets: [(String, String, String)] = [
        ("OpenAI", "https://api.openai.com/v1", "gpt-4.1-mini"),
        ("DeepSeek", "https://api.deepseek.com/v1", "deepseek-chat"),
        ("Qwen", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-plus"),
        ("Ollama", "http://localhost:11434/v1", "qwen3:8b"),
    ]

    var body: some View {
        Form {
            Section {
                Toggle("Polish dictation with AI (remove fillers, resolve corrections, add punctuation and lists)", isOn: $settings.polishEnabled)
                Picker("Output language", selection: $settings.outputLanguage) {
                    ForEach(OutputLanguage.allCases) { Text($0.title).tag($0) }
                }
                TextField("Translation target language", text: $settings.translateTarget)
            }

            Section("Language Model (OpenAI Chat Completions compatible)") {
                HStack {
                    Text("Presets")
                    ForEach(presets, id: \.0) { preset in
                        Button(preset.0) {
                            settings.llmBaseURL = preset.1
                            settings.llmModel = preset.2
                        }
                    }
                }
                TextField("API URL", text: $settings.llmBaseURL)
                SecureField("API Key (any value for local Ollama)", text: $settings.llmAPIKey)
                TextField("Model", text: $settings.llmModel)
                HStack {
                    Button("Test") { test() }.disabled(testing || !settings.llmConfigured)
                    if testing { ProgressView().controlSize(.small) }
                }
                if !testResult.isEmpty {
                    Text(testResult).font(.callout).textSelection(.enabled)
                }
            }

            Section("Additional Instructions") {
                TextEditor(text: $settings.customInstructions)
                    .font(.body)
                    .frame(height: 60)
                Text("For example: Always use digits for numbers, or Do not use exclamation marks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func test() {
        testing = true
        testResult = ""
        let sample = "Um, let us meet tomorrow at three, no, four in the afternoon, and uh we need to discuss three things, first the budget, second hiring, and third the Q4 roadmap"
        Task {
            defer { testing = false }
            do {
                let output = try await LLMClient.complete(
                    system: Prompts.polish(context: nil, settings: settings),
                    user: Prompts.polishInput(sample),
                    config: settings.llmConfig
                )
                testResult = "Original: \(sample)\n\nPolished:\n\(output)"
            } catch {
                testResult = "Failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Dictionary

private struct DictionaryTab: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("One term per line: names, products, technical terms, or preferred spellings for mixed Chinese and English text. Used for recognition and polishing.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $settings.dictionary)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
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
