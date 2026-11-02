import SwiftUI

/// Speech recognition credentials are independent of the AI polishing provider.
struct DoubaoSettingsSection: View {
    @ObservedObject var settings: AppSettings
    var localModelStatus: String? = nil
    @StateObject private var connection = DoubaoConnectionCheck()

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    SecureField(L10n.tr("Doubao Speech API key"), text: $settings.doubaoAPIKey,
                                prompt: Text(L10n.tr("Paste your Doubao Speech API key here")))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.tr("Doubao Speech API key"))
                    Button(connection.isChecking ? L10n.tr("Testing…") : L10n.tr("Test")) {
                        connection.start(settings.doubaoConfig)
                    }
                    .disabled(connection.isChecking || !settings.doubaoConfigured)
                    .help(L10n.tr("Sends credentials and recognition settings only; no microphone or audio. This does not test recognition accuracy. Provider billing rules still apply."))
                }
                switch connection.outcome {
                case .success:
                    Label(L10n.tr("The key works."), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green).font(.caption)
                case .failure(let message):
                    Label(message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange).font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                case nil:
                    Text(L10n.tr("Create one in the Doubao Speech console. Saved in your Keychain."))
                        .settingsNote()
                }
                if let error = settings.doubaoCredentialError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Picker(L10n.tr("Speech input language"), selection: $settings.doubaoInputLanguage) {
                    ForEach(DoubaoInputLanguage.allCases) { Text($0.title).tag($0) }
                }
                if settings.doubaoInputLanguage == .automatic {
                    Text(L10n.tr("Supports Chinese, English, Shanghainese, Southern Min, Sichuan, Shaanxi, Cantonese, Jilu, Lanyin and Jianghuai dialects."))
                        .settingsNote()
                }
            }

            Toggle(isOn: $settings.onlineLocalFallback) {
                Text(L10n.tr("Allow falling back to offline recognition"))
                Text(L10n.tr("When Doubao fails or is not set up, this recording uses the offline model instead. Needs the offline model downloaded."))
                    .settingsNote()
            }
            .help(L10n.tr("A stalled connection or upload fails after 10 seconds. After recording ends, the final result has a 15-second deadline. Without local fallback, failure stops this dictation."))
            if settings.onlineLocalFallback {
                if (try? settings.resolvedQwenModelDirectory()) == nil {
                    Text(L10n.tr("No offline model yet, so there is nothing to fall back to. Switch to Offline once to download it."))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let localModelStatus {
                    Text(localModelStatus).settingsNote()
                }
            }

            DisclosureGroup(L10n.tr("More options")) {
                Picker(L10n.tr("Doubao ASR resource"), selection: $settings.doubaoResource) {
                    ForEach(DoubaoResource.allCases) { Text($0.title).tag($0) }
                }
                Text(L10n.tr("Match the plan enabled in your Doubao Speech console."))
                    .settingsNote()
                Text(L10n.tr("Audio goes straight to Doubao. Talkless doesn't relay or save it. Doubao bills you directly."))
                    .settingsNote()
            }
        } header: {
            HStack {
                Text(L10n.tr("Doubao API key"))
                Spacer()
                Link(L10n.tr("Get a key"), destination: URL(string: "https://console.volcengine.com/speech/app")!)
                    .font(.callout)
            }
        }
        .onChange(of: settings.doubaoConfig) { _, _ in connection.invalidate() }
        .onDisappear { connection.invalidate() }
    }
}
