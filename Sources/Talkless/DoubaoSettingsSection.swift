import SwiftUI

/// Speech recognition credentials are independent of the AI polishing provider.
struct DoubaoSettingsSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section(L10n.tr("Doubao online recognition")) {
            SecureField(L10n.tr("Doubao Speech API key"), text: $settings.doubaoAPIKey)
                .help(L10n.tr("Stored in your Mac's Keychain. Use a Speech API key from the new Doubao Speech console, not an Ark model key."))
            if let error = settings.doubaoCredentialError {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(settings.doubaoConfigured ? L10n.tr("Configuration complete") : L10n.tr("Setup needed"),
                  systemImage: settings.doubaoConfigured ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(.secondary)
            Text(L10n.tr("Audio is sent directly to Doubao while you speak, with live text previews. Internet access and your own paid speech service are required. Talkless does not relay or save the recording."))
                .settingsNote()
            Text(L10n.tr("This configures speech recognition only. AI polishing uses the separate AI service settings."))
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
    }
}
