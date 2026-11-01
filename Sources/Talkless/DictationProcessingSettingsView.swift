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
        Section {
            Toggle(isOn: $settings.polishEnabled) {
                Text(L10n.tr("Smart text cleanup"))
                Text(L10n.tr("Automatically fix spelling and punctuation after you speak."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.polishEnabled, !settings.llmConfigured {
                HStack {
                    Text(L10n.tr("Set up an AI service to use text cleanup.")).settingsNote()
                    Spacer()
                    Button(L10n.tr("Set up…"), action: onConfigureAI)
                }
            }

            DisclosureGroup(L10n.tr("Cleanup preferences")) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker(L10n.tr("Output language"), selection: $settings.outputLanguage) {
                        ForEach(OutputLanguage.allCases) { Text($0.title).tag($0) }
                    }
                    .id(localization.locale.identifier)
                    Text(L10n.tr("Applies when you use AI polishing. Translation has its own language."))
                        .settingsNote()
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
                Text(L10n.tr("Polish sends your transcript, dictionary, and writing instructions, plus app context when tone adaptation is on."))
                    .settingsNote()
            }
        }

        Section {
            Toggle(isOn: $settings.voiceEditEnabled) {
                Text(L10n.tr("Edit text by voice"))
                Text(L10n.tr("Select text, then say how to change it. For example, “make it shorter”."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(L10n.tr("How it works")) {
                Text(L10n.tr("When text is selected, the overlay shows a pencil instead of a waveform. Press Esc if you only meant to dictate. This works whether AI polishing is on or off."))
                    .settingsNote()
                Text(L10n.tr("Voice editing sends the selection, spoken instruction, and dictionary to the same provider."))
                    .settingsNote()
            }
            if settings.voiceEditEnabled, !settings.llmConfigured {
                Text(L10n.tr("Set up an AI service first; until then, dictation with a selection is ordinary dictation."))
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
