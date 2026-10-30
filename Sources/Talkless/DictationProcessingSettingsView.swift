import SwiftUI

/// Sections for the Dictation form. AI setup and selected-text translation live on their own pages.
@MainActor
struct DictationProcessingSettingsView: View {
    @ObservedObject private var settings: AppSettings
    private let onConfigureAI: () -> Void

    init(settings: AppSettings = .shared, onConfigureAI: @escaping () -> Void) {
        self.settings = settings
        self.onConfigureAI = onConfigureAI
    }

    var body: some View {
        Section("AI processing") {
            Toggle("Polish dictation with AI", isOn: $settings.polishEnabled)
            Text("Clean up the transcript after recognition; turn off for unprocessed dictation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            AIServiceStatusView(settings: settings, onConfigureAI: onConfigureAI)

            Picker("Output language", selection: $settings.outputLanguage) {
                ForEach(OutputLanguage.allCases) { Text($0.title).tag($0) }
            }
            Text("Used by AI polish, including alternate finish—not selected-text translation.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Adapt tone to the current app", isOn: $settings.appToneEnabled)
                .help("Match polished dictation to chat, email, code, or documents")

            DisclosureGroup("Additional instructions") {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $settings.customInstructions)
                        .font(.body)
                        .frame(minHeight: 70, idealHeight: 90)
                        .accessibilityLabel("Additional instructions")
                    Text("For AI polish, e.g. Always use digits for numbers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            DisclosureGroup("Data sent to AI") {
                Text("Polish sends your transcript, dictionary, and writing instructions, plus app context when tone adaptation is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Voice editing sends the selection, spoken instruction, and dictionary to the same provider.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section("Voice editing") {
            Toggle("Edit selected text with your voice", isOn: $settings.voiceEditEnabled)
            Text("Select text and speak an instruction, even with dictation polish off.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
