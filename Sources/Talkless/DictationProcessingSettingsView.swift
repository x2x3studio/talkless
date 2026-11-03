import SwiftUI

/// AI processing sections embedded in the same form as the provider configuration.
@MainActor
struct DictationProcessingSettingsView: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @ObservedObject private var settings: AppSettings
    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    var body: some View {
        Section {
            Toggle(isOn: $settings.polishEnabled) {
                Text(L10n.tr("AI polishing"))
                Text(L10n.tr("Requires a separately configured AI service. After recognition finishes, the transcript is sent to it for correction and polishing."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            AIServiceStatusView(settings: settings)
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

/// Experimental options use their existing preferences without coupling their switches.
@MainActor
struct LabsSettingsView: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @ObservedObject private var settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.enhancedRecognition) {
                    Text(L10n.tr("Enhanced recognition"))
                    Text(L10n.tr("Runs local recognition and Doubao together, then compares both transcripts with AI."))
                        .settingsNote()
                }
                Text(L10n.tr("Requires a local model, Doubao, and an AI service. Uses more memory and may take longer."))
                    .settingsNote()
                Text(L10n.tr("If one recognizer fails, dictation continues with the other."))
                    .settingsNote()
                if settings.enhancedRecognition, !settings.doubaoConfigured || !settings.llmConfigured {
                    Text(L10n.tr("Enhanced recognition needs a local model, Doubao, and an AI service."))
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                Toggle(isOn: $settings.sentenceCandidates) {
                    Text(L10n.tr("Sentence alternatives"))
                    Text(L10n.tr("When AI finds ambiguity, click one complete sentence. Hover to pause; the default is used when time runs out."))
                        .settingsNote()
                }
                Text(L10n.tr("Requires AI polishing or enhanced recognition, plus an AI service."))
                    .settingsNote()
                if settings.sentenceCandidates {
                    Stepper(L10n.format("Candidate wait: %lld seconds", Int64(settings.candidateWaitSeconds)),
                            value: $settings.candidateWaitSeconds, in: 2...15)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Local formatting remains independent of AI settings and never needs a provider.
@MainActor
struct TextFormattingSettingsView: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @ObservedObject private var settings: AppSettings

    init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    var body: some View {
        Form {
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
        }
        .formStyle(.grouped)
    }
}
