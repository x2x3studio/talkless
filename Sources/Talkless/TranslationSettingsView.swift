import SwiftUI

@MainActor
struct TranslationSettingsView: View {
    @ObservedObject private var controller: DictationController
    @ObservedObject private var settings: AppSettings
    private let onConfigureAI: () -> Void

    init(controller: DictationController, settings: AppSettings = .shared,
         onConfigureAI: @escaping () -> Void) {
        self.controller = controller
        self.settings = settings
        self.onConfigureAI = onConfigureAI
    }

    var body: some View {
        Form {
            Section("Selected-text translation") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Target language", text: $settings.translateTarget,
                              prompt: Text("English or Japanese"))
                    Text("Select text, press the shortcut, then copy the translation or replace the selection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Keyboard shortcut") {
                ShortcutRecorder(
                    title: "Translate selection", value: settings.translationShortcut.title,
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

            Section("AI service") {
                AIServiceStatusView(settings: settings, onConfigureAI: onConfigureAI)
                DisclosureGroup("Data sent to AI") {
                    Text("Sends selected text and the target language to your provider; no voice recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}
