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
                TextField("Target language", text: $settings.translateTarget,
                          prompt: Text("For example: English or Japanese"))
                Text("Select text, press the shortcut, then copy the translation or replace the selection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Works with dictation polish off. Requires AI service.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("Click to record a combination; Esc cancels, Delete or Backspace disables.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = controller.translationShortcutError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
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
