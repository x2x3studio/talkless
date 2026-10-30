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
            Toggle(isOn: $settings.polishEnabled) {
                Text("Polish dictation with AI")
                Text("Clean up your transcript after recognition.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AIServiceStatusView(settings: settings, onConfigureAI: onConfigureAI)

            VStack(alignment: .leading, spacing: 6) {
                Picker("Output language", selection: $settings.outputLanguage) {
                    ForEach(OutputLanguage.allCases) { Text($0.title).tag($0) }
                }
                Text("For AI polish and alternate finish. Translation has its own language.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
            Toggle(isOn: $settings.voiceEditEnabled) {
                Text("Edit selected text with your voice")
                Text("Select text and speak an instruction. Works with polish off.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
