import SwiftUI

/// Value bindings and actions let layout tests render the actual recording controls without
/// starting a recorder, reading credentials or registering global shortcuts.
struct RecordingSettingsSection: View {
    @Binding var mode: RecordingGestureMode
    @Binding var triggerKey: TriggerKey
    var isBusy = false
    let setCaptureActive: (Bool) -> Bool
    let resetKey: () -> String?
    @ObservedObject private var localization = LocalizationSettings.shared

    private var instructions: String {
        mode == .hold
            ? L10n.format("Hold %@ to talk; release to finish.", triggerKey.title)
            : L10n.format("Tap %@ to start talking; press again to finish.", triggerKey.title)
    }

    var body: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Recording mode"))
                    Text(instructions).settingsNote()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Picker(L10n.tr("Recording mode"), selection: $mode) {
                    ForEach(RecordingGestureMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .id(localization.locale.identifier)
                .frame(width: SettingsControlLayout.valueWidth, height: SettingsControlLayout.height)
                .accessibilityIdentifier("recording-mode-value")
                Button(L10n.tr("Reset")) {
                    ShortcutRecorder.cancelCapture()
                    mode = AppSettings.defaultRecordingGestureMode
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .frame(width: SettingsControlLayout.resetWidth, height: SettingsControlLayout.height)
                .disabled(mode == AppSettings.defaultRecordingGestureMode)
                .help(L10n.format("Restore %@. Shortcuts and other settings are unchanged.", AppSettings.defaultRecordingGestureMode.title))
                .accessibilityLabel(L10n.tr("Reset recording mode"))
                .accessibilityIdentifier("recording-mode-reset")
            }
            .padding(.vertical, 4)
            .disabled(isBusy)

            ShortcutRecorder(
                title: L10n.tr("Dictation key"), value: triggerKey.title,
                defaultValue: AppSettings.defaultTriggerKey.title,
                isDefault: triggerKey == AppSettings.defaultTriggerKey,
                setCaptureActive: setCaptureActive,
                onReset: resetKey
            ) { key in
                if let error = ShortcutRecorderRules.primaryError(key) { return error }
                guard let key else { return L10n.tr("The dictation key cannot be cleared.") }
                triggerKey = key
                return nil
            }
            .padding(.vertical, 4)
            .disabled(isBusy)
            .help(L10n.tr("Click to record Fn or a right-side modifier. Release to save; Esc cancels. Single keys only."))
        } header: {
            Text(L10n.tr("Recording"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("Esc cancels."))
                if triggerKey == .fn {
                    Text(L10n.tr("Using Fn? Set the Globe key to Do Nothing in System Settings › Keyboard to prevent the emoji panel."))
                }
            }
            .settingsNote()
        }
    }
}
