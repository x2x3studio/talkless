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
                Text(L10n.tr("AI polishing"))
                Text(L10n.tr("Requires a separately configured AI service. After recognition finishes, the transcript is sent to it for correction and polishing."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AIServiceStatusView(settings: settings, onConfigureAI: onConfigureAI)
            if !settings.llmConfigured {
                Text(L10n.tr("Set up an AI service to use AI polishing. Until then, dictation skips AI polishing."))
                    .settingsNote()
            }

            DisclosureGroup(L10n.tr("AI polishing preferences")) {
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
            Picker(L10n.tr("Punctuation"), selection: $settings.punctuationStyle) {
                ForEach(PunctuationStyle.allCases) { Text($0.title).tag($0) }
            }
            .id("punctuation-\(localization.locale.identifier)")
            Picker(L10n.tr("Spaces around numbers and English"), selection: $settings.latinSpacing) {
                ForEach(LatinSpacing.allCases) { Text($0.title).tag($0) }
            }
            .id("spacing-\(localization.locale.identifier)")
        } header: {
            Text(L10n.tr("Text formatting"))
        } footer: {
            Text(L10n.tr("Text formatting runs on this Mac for every dictation, independently of AI polishing. No AI service is needed."))
                .settingsNote()
        }

        Section {
            Toggle(isOn: $settings.voiceEditEnabled) {
                Text(L10n.tr("Edit text by voice"))
                Text(L10n.format("Select text, hold %@ + %@, and say how to change it. For example, “make it shorter”.",
                                 settings.triggerKey.title, settings.triggerKey.editModifierTitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            DisclosureGroup(L10n.tr("How it works")) {
                Text(L10n.format("Only %@ + %@ edits a selection; the dictation key alone always types, replacing any selection like typing does. While editing, the overlay shows a pencil. You can also press %@ after you start speaking. Without a selection, your words are typed as usual. This works whether AI polishing is on or off.",
                                 settings.triggerKey.title, settings.triggerKey.editModifierTitle, settings.triggerKey.editModifierTitle))
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
