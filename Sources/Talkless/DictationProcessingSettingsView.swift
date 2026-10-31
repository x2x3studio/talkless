import SwiftUI

/// Sections for the Dictation form. AI setup and selected-text translation live on their own pages.
@MainActor
struct DictationProcessingSettingsView: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @ObservedObject private var settings: AppSettings
    private let onConfigureAI: () -> Void

    init(settings: AppSettings = .shared, onConfigureAI: @escaping () -> Void) {
        self.settings = settings
        self.onConfigureAI = onConfigureAI
    }

    var body: some View {
        Section(L10n.tr("AI processing")) {
            Toggle(isOn: $settings.polishEnabled) {
                Text(L10n.tr("Polish dictation with AI"))
                Text(L10n.tr("Clean up your transcript after recognition."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AIServiceStatusView(settings: settings, onConfigureAI: onConfigureAI)

            VStack(alignment: .leading, spacing: 6) {
                Picker(L10n.tr("Output language"), selection: $settings.outputLanguage) {
                    ForEach(OutputLanguage.allCases) { Text($0.title).tag($0) }
                }
                .id(localization.locale.identifier)
                Text(L10n.tr("Applies when you use AI polishing. Translation has its own language."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(L10n.tr("Adapt tone to the current app"), isOn: $settings.appToneEnabled)
                .help(L10n.tr("Match polished dictation to chat, email, code, or documents"))

            DisclosureGroup(L10n.tr("Additional instructions")) {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $settings.customInstructions)
                        .font(.body)
                        .frame(minHeight: 70, idealHeight: 90)
                        .accessibilityLabel(L10n.tr("Additional instructions"))
                    Text(L10n.tr("For AI polish, e.g. Always use digits for numbers."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            DisclosureGroup(L10n.tr("Data sent to AI")) {
                Text(L10n.tr("Polish sends your transcript, dictionary, and writing instructions, plus app context when tone adaptation is on."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(L10n.tr("Voice editing sends the selection, spoken instruction, and dictionary to the same provider."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section(L10n.tr("Voice editing")) {
            Toggle(isOn: $settings.voiceEditEnabled) {
                Text(L10n.tr("Change selected text by voice"))
                Text(L10n.tr("Select text in any app, press the dictation key, and say how to change it, such as “make it shorter” or “translate into English”. AI replaces the selection with the result."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.tr("When text is selected, the overlay shows a pencil instead of a waveform. Press Esc if you only meant to dictate. This works whether AI polishing is on or off."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.voiceEditEnabled, !settings.llmConfigured {
                Text(L10n.tr("Set up an AI service first; until then, dictation with a selection is ordinary dictation."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
