import SwiftUI

@MainActor
struct TranslationSettingsView: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @ObservedObject private var controller: DictationController
    @ObservedObject private var settings: AppSettings
    private let onConfigureAI: () -> Void
    @State private var showingPreferredLanguages = false

    init(controller: DictationController, settings: AppSettings = .shared,
         onConfigureAI: @escaping () -> Void) {
        self.controller = controller
        self.settings = settings
        self.onConfigureAI = onConfigureAI
    }

    var body: some View {
        Form {
            Section(L10n.tr("Selected-text translation")) {
                languageRow("Source language", selection: $settings.translationLanguages.source,
                            automaticLabel: L10n.tr("Auto · Detect language"))
                languageRow("Target language", selection: $settings.translationLanguages.target,
                            automaticLabel: L10n.tr("Auto · Primary or secondary"), allowCustom: true)
                Text(L10n.tr("These choices are shared with the translation window. Changing them there also updates these defaults."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.tr("Select text, press the shortcut, then copy the translation or replace the selection."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.tr("Automatic translation")) {
                languageRow("Primary language", selection: $settings.translationLanguages.primary,
                            automaticLabel: L10n.format("Auto · %@", automaticPrimaryLanguage.displayName))
                languageRow("Secondary language", selection: $settings.translationLanguages.secondary,
                            automaticLabel: L10n.format("Auto · %@", automaticSecondaryLanguage.displayName))
                Text(L10n.format("Auto translates into %@, or into %@ when the source is already %@.",
                                 primaryLanguage.displayName, secondaryLanguage.displayName, primaryLanguage.displayName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.tr("Primary Auto follows the first supported macOS language, or English. Secondary Auto uses English, or Simplified Chinese when primary is English. Uncertain source detection uses the primary language."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if hasDuplicateLanguages {
                    Text(L10n.format("Primary and secondary are the same. Auto uses %@ as the alternate language.", secondaryLanguage.displayName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.tr("Language menus")) {
                HStack {
                    Text(L10n.tr("Preferred languages"))
                    Spacer()
                    Button(L10n.tr("Manage languages…")) { showingPreferredLanguages = true }
                }
                Text(L10n.tr("Choose the languages shown first. More languages are always available; translation quality depends on your AI model."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.tr("Keyboard shortcut")) {
                ShortcutRecorder(
                    title: L10n.tr("Translate selection"), value: settings.translationShortcut.title,
                    defaultValue: AppSettings.defaultTranslationShortcut.title,
                    isDefault: settings.isTranslationShortcutDefault,
                    allowsClearing: true, setCaptureActive: controller.setShortcutCaptureActive,
                    onReset: { settings.resetTranslationShortcut(); return nil },
                    onTranslationRecord: { shortcut in
                        if let error = shortcut.validationError { return error }
                        settings.translationShortcut = shortcut
                        return nil
                    }, onRecord: { _ in nil }
                )
                .disabled(controller.state != .idle)
                if let error = controller.translationShortcutError {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(L10n.tr("AI service")) {
                AIServiceStatusView(settings: settings, onConfigureAI: onConfigureAI)
                DisclosureGroup(L10n.tr("Data sent to AI")) {
                    Text(L10n.tr("Sends selected text and the target language to your provider; no voice recording."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingPreferredLanguages) {
            PreferredTranslationLanguagesView(preferredLanguageIDs: settings.translationLanguages.preferredLanguageIDs) {
                settings.translationLanguages.preferredLanguageIDs = $0
            }
        }
    }

    private var primaryLanguage: TranslationLanguage {
        TranslationLanguages.resolvedPrimary(preferences: settings.translationLanguages)
    }

    private var secondaryLanguage: TranslationLanguage {
        TranslationLanguages.resolvedSecondary(preferences: settings.translationLanguages)
    }

    private var automaticPrimaryLanguage: TranslationLanguage {
        var preferences = settings.translationLanguages
        preferences.primary = .auto
        return TranslationLanguages.resolvedPrimary(preferences: preferences)
    }

    private var automaticSecondaryLanguage: TranslationLanguage {
        var preferences = settings.translationLanguages
        preferences.secondary = .auto
        return TranslationLanguages.resolvedSecondary(preferences: preferences)
    }

    private var hasDuplicateLanguages: Bool {
        guard case .languageID(let id) = settings.translationLanguages.secondary else { return false }
        return TranslationLanguages.sameLanguageFamily(id, primaryLanguage.id)
    }

    private func languageRow(_ title: String, selection: Binding<TranslationLanguageSelection>,
                             automaticLabel: String, allowCustom: Bool = false) -> some View {
        LabeledContent(L10n.tr(title)) {
            LanguagePickerView(title: L10n.tr(title), selection: selection,
                               preferences: settings.translationLanguages,
                               automaticLabel: automaticLabel, allowCustom: allowCustom,
                               onManageLanguages: { showingPreferredLanguages = true })
        }
    }
}
