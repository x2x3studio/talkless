import SwiftUI

/// Speech recognition credentials are independent of the AI polishing provider.
struct DoubaoSettingsSection: View {
    @ObservedObject var settings: AppSettings
    var localModelStatus: String? = nil
    @StateObject private var connection = DoubaoConnectionCheck()

    var body: some View {
        Section(L10n.tr("Doubao online recognition")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.tr("Doubao Speech API key"))
                SecureField(L10n.tr("Doubao Speech API key"), text: $settings.doubaoAPIKey,
                            prompt: Text(L10n.tr("Paste your Doubao Speech API key here")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.tr("Doubao Speech API key"))
                Text(L10n.tr("Stored in your Mac's Keychain. Use a Speech API key from the new Doubao Speech console, not an Ark model key."))
                    .settingsNote()
            }
            if let error = settings.doubaoCredentialError {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if connection.isChecking {
                        ProgressView().controlSize(.small)
                        Text(L10n.tr("Verifying connection…")).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(connection.isChecking ? L10n.tr("Verifying connection…") : L10n.tr("Verify connection")) {
                        connection.start(settings.doubaoConfig)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(connection.isChecking || !settings.doubaoConfigured)
                }
                switch connection.outcome {
                case .success:
                    Label(L10n.tr("Connection verified. Doubao accepted the recognition configuration."), systemImage: "checkmark.circle")
                        .foregroundStyle(.green).font(.caption)
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange).font(.caption)
                case nil:
                    Text(L10n.tr("Not verified. Paste your key, then verify the connection."))
                        .settingsNote()
                }
                Text(L10n.tr("Sends credentials and recognition settings only; no microphone or audio. This does not test recognition accuracy. Provider billing rules still apply."))
                    .settingsNote()
            }
            Text(L10n.tr("Audio is sent directly to Doubao while you speak, with live text previews. Internet access and your own paid speech service are required. Talkless does not relay or save the recording."))
                .settingsNote()
            Text(L10n.tr("This configures speech recognition only. AI polishing uses the separate AI service settings."))
                .settingsNote()
            Toggle(L10n.tr("Use local Qwen if online recognition fails"), isOn: $settings.onlineLocalFallback)
            if settings.onlineLocalFallback {
                Text(L10n.tr("Keeps the downloaded Qwen model loaded in memory. Online failures use the whole recording locally; the next recording still tries Doubao first."))
                    .settingsNote()
                if let localModelStatus { Text(localModelStatus).settingsNote() }
                if (try? settings.resolvedQwenModelDirectory()) == nil {
                    Text(L10n.tr("Download a local Qwen model first. Recording cannot start with local fallback enabled until the model is available."))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(L10n.tr("A stalled connection or upload fails after 10 seconds. After recording ends, the final result has a 15-second deadline. Without local fallback, failure stops this dictation."))
                .settingsNote()
            DisclosureGroup(L10n.tr("Advanced")) {
                Picker(L10n.tr("Doubao ASR resource"), selection: $settings.doubaoResource) {
                    ForEach(DoubaoResource.allCases) { Text($0.title).tag($0) }
                }
                Text(L10n.tr("Choose the ASR 2.0 billing resource enabled in your Doubao Speech console. Configuration complete does not mean the service has been tested."))
                    .settingsNote()
            }
            HStack {
                Spacer()
                Link(L10n.tr("Open Doubao Speech console"), destination: URL(string: "https://console.volcengine.com/speech/app")!)
            }
        }
        .onChange(of: settings.doubaoConfig) { _, _ in connection.invalidate() }
        .onDisappear { connection.invalidate() }
    }
}
