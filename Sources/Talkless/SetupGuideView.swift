import SwiftUI

/// Value-only inputs keep previews and UI tests away from permissions, Keychain and downloads.
enum SetupGuidePermission: Equatable {
    case notDetermined, requesting, granted, denied, restricted
}

/// The current shortcuts, not hard-coded defaults: reopening the guide is useful after customization.
struct SetupGuideControls: Equatable {
    var dictationKeyTitle = L10n.tr("Fn / Globe")
    var holdToTalk = true
    var alternateFinishKeyTitle: String?
    var polishEnabled = false
    var translationShortcutTitle: String?

    var dictationInstruction: String {
        holdToTalk
            ? L10n.format("Hold %@ to talk; release to finish.", dictationKeyTitle)
            : L10n.format("Tap %@ to start; tap again to finish.", dictationKeyTitle)
    }
}

struct SetupGuideSnapshot: Equatable {
    var microphone: SetupGuidePermission = .notDetermined
    var accessibility: SetupGuidePermission = .notDetermined
    /// AX trust does not guarantee that the global keyboard event tap started.
    var shortcutsReady = false
    var speechReady = false
    /// Localized, read-only status from the selected recognition engine.
    var speechStatus = ""
    var aiConfigured = false
    var polishEnabled = false
    var controls = SetupGuideControls()

    var dictationReady: Bool {
        microphone == .granted && accessibility == .granted && shortcutsReady && speechReady
    }
}

@MainActor
final class SetupGuideState: ObservableObject {
    @Published var snapshot: SetupGuideSnapshot

    init(snapshot: SetupGuideSnapshot = .init()) {
        self.snapshot = snapshot
    }
}

struct SetupGuideActions {
    var refresh: () -> Void
    var requestMicrophone: () -> Void
    var openMicrophoneSettings: () -> Void
    var requestAccessibility: () -> Void
    var openAccessibilitySettings: () -> Void
    var openSpeechSettings: () -> Void
    var openAISettings: () -> Void
    var enablePolish: () -> Void
    var finish: () -> Void
    var skipSetup: () -> Void

    func allow(_ permission: SetupGuidePermission, microphone: Bool) {
        guard permission != .granted, permission != .requesting else { return }
        if microphone {
            if permission == .notDetermined { requestMicrophone() }
            else { openMicrophoneSettings() }
        } else {
            if permission == .notDetermined { requestAccessibility() }
            else { openAccessibilitySettings() }
        }
    }

    func enablePolishIfConfigured(_ snapshot: SetupGuideSnapshot) {
        guard snapshot.aiConfigured, !snapshot.polishEnabled else { return }
        enablePolish()
    }
}

enum SetupGuideStep: Int, CaseIterable {
    case welcome, controls, microphone, accessibility, speech, ai, done

    var next: Self { Self(rawValue: rawValue + 1) ?? self }
    var previous: Self { Self(rawValue: rawValue - 1) ?? self }

    var title: String {
        switch self {
        case .welcome: L10n.tr("Welcome to Talkless")
        case .controls: L10n.tr("How to dictate")
        case .microphone: L10n.tr("Microphone")
        case .accessibility: L10n.tr("Accessibility")
        case .speech: L10n.tr("Speech recognition")
        case .ai: L10n.tr("AI polishing · optional")
        case .done: L10n.tr("Setup summary")
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "waveform"
        case .controls: "keyboard"
        case .microphone: "mic"
        case .accessibility: "keyboard"
        case .speech: "arrow.down.circle"
        case .ai: "text.badge.checkmark"
        case .done: "checklist"
        }
    }
}

/// The guide has no automatic actions. Only buttons invoke the injected callbacks.
struct SetupGuideView: View {
    @ObservedObject var state: SetupGuideState
    let actions: SetupGuideActions
    @ObservedObject private var localization: LocalizationSettings
    @State private var step: SetupGuideStep
    @FocusState private var continueFocused: Bool

    init(state: SetupGuideState, actions: SetupGuideActions,
         localization: LocalizationSettings = .shared, initialStep: SetupGuideStep = .welcome) {
        self.state = state
        self.actions = actions
        self.localization = localization
        _step = State(initialValue: initialStep)
    }

    private var snapshot: SetupGuideSnapshot { state.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text(L10n.tr("Setup guide"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L10n.format("Step %d of %d", step.rawValue + 1, SetupGuideStep.allCases.count))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L10n.format("Step %d of %d", step.rawValue + 1, SetupGuideStep.allCases.count))
            }
            .padding(.bottom, 13)

            HStack(spacing: 5) {
                ForEach(SetupGuideStep.allCases, id: \.rawValue) { item in
                    Capsule().fill(item.rawValue <= step.rawValue ? SettingsAppearance.accent : Color.secondary.opacity(0.16))
                        .frame(height: 3)
                }
            }
            .accessibilityHidden(true)
            .padding(.bottom, 24)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        Image(systemName: step.symbol)
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(SettingsAppearance.accent)
                            .frame(width: 48, height: 48)
                            .background(SettingsAppearance.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                            .accessibilityHidden(true)
                        Text(step.title)
                            .font(.system(size: 25, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                    }
                    stepContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
            }
            .scrollBounceBehavior(.basedOnSize)

            Divider().padding(.top, 14).padding(.bottom, 16)
            HStack(spacing: 12) {
                Button(L10n.tr("Back")) { step = step.previous }
                    .disabled(step == .welcome)
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                if step != .done {
                    Button(L10n.tr("Skip setup"), action: actions.skipSetup)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer(minLength: 0)
                Button(step == .done ? L10n.tr("Done") : L10n.tr("Continue")) {
                    if step == .done { actions.finish() }
                    else { step = step.next }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .focused($continueFocused)
                .accessibilityHint(step == .done
                    ? L10n.tr("Close the guide. Unfinished items can be completed in Settings.")
                    : L10n.tr("Go to the next step. You can finish this step later."))
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(minWidth: 600, minHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(SettingsAppearance.accent)
        .environment(\.locale, localization.locale)
        .onChange(of: step) { _, _ in continueFocused = true }
    }

    @ViewBuilder private var stepContent: some View {
        switch step {
        case .welcome:
            explanation("Speak naturally. Put your words into the app you’re using.")
            VStack(alignment: .leading, spacing: 13) {
                SetupGuideRow(symbol: "lock.shield", title: L10n.tr("You’re in control"),
                              detail: L10n.tr("Permissions are requested only when you choose to allow them."))
                SetupGuideRow(symbol: "desktopcomputer", title: L10n.tr("Start with local dictation"),
                              detail: L10n.tr("Choose a speech model. AI polishing is optional."))
                SetupGuideRow(symbol: "arrow.uturn.backward", title: L10n.tr("Finish at your own pace"),
                              detail: L10n.tr("Skip any step. Reopen this guide in Settings › System."))
            }
        case .controls:
            explanation("Click a text field in another app, then use your dictation key. Talkless inserts the result there.")
            VStack(alignment: .leading, spacing: 14) {
                shortcutRow(snapshot.controls.dictationKeyTitle, title: L10n.tr("Dictation"),
                            detail: snapshot.controls.dictationInstruction)
                shortcutRow("Esc", title: L10n.tr("Cancel"),
                            detail: L10n.tr("Cancel recording or processing without inserting text."))
                if let key = snapshot.controls.alternateFinishKeyTitle {
                    shortcutRow(key, title: L10n.tr("Alternate finish"), detail: snapshot.controls.polishEnabled
                        ? L10n.tr("AI is currently on by default, so alternate finish skips AI.")
                        : L10n.tr("AI is currently off by default, so alternate finish uses AI."))
                }
                if let key = snapshot.controls.translationShortcutTitle {
                    shortcutRow(key, title: L10n.tr("Translate selection"),
                                detail: L10n.tr("Select text in another app, then use this shortcut. An AI service is required."))
                }
            }
            explanation("These are your current shortcuts. Change them in Settings; the menu bar also shows a quick reference.", small: true)
        case .microphone:
            explanation("Allow Talkless to record your voice when you start dictation.")
            permissionContent(snapshot.microphone, isMicrophone: true)
        case .accessibility:
            explanation("Allow Talkless to use global shortcuts and insert text into other apps.")
            permissionContent(snapshot.accessibility, isMicrophone: false)
            if snapshot.accessibility == .granted && !snapshot.shortcutsReady {
                SetupGuideRow(symbol: "keyboard", title: L10n.tr("Dictation shortcuts need attention"),
                              detail: L10n.tr("Accessibility is allowed, but the dictation shortcut is not active. Finish editing shortcuts in Settings, then check again. If it stays inactive, quit and reopen Talkless."))
                Button(L10n.tr("Check again"), action: actions.refresh)
            }
        case .speech:
            explanation("Choose speech recognition in Settings. Local Qwen models need a one-time download; this guide never starts one.")
            SetupGuideRow(symbol: snapshot.speechReady ? "checkmark.circle.fill" : "arrow.down.circle",
                          title: snapshot.speechReady ? L10n.tr("Speech recognition available") : L10n.tr("Speech recognition needs attention"),
                          detail: snapshot.speechStatus, complete: snapshot.speechReady)
            HStack {
                Button(L10n.tr("Open Speech recognition"), action: actions.openSpeechSettings)
                Button(L10n.tr("Check again"), action: actions.refresh)
            }
            explanation("This guide stays open. Return here after choosing or downloading a model, or continue and finish later.", small: true)
        case .ai:
            explanation("AI can clean up your transcript. It is not required for dictation, and your provider may charge for use.")
            SetupGuideRow(symbol: snapshot.polishEnabled && snapshot.aiConfigured ? "checkmark.circle.fill" : "slider.horizontal.3",
                          title: snapshot.polishEnabled && snapshot.aiConfigured ? L10n.tr("AI polishing is enabled") : L10n.tr("AI polishing is optional"),
                          detail: snapshot.aiConfigured ? L10n.tr("Service configured. No connection test has been run by this guide.") : L10n.tr("Configure a service before enabling polishing."),
                          complete: snapshot.polishEnabled && snapshot.aiConfigured)
            HStack {
                Button(L10n.tr("Open AI service"), action: actions.openAISettings)
                if !snapshot.polishEnabled {
                    Button(L10n.tr("Enable polishing")) {
                        actions.enablePolishIfConfigured(snapshot)
                    }
                    .disabled(!snapshot.aiConfigured)
                }
                Button(L10n.tr("Check again"), action: actions.refresh)
            }
            explanation("Continue without changing anything, or explicitly enable polishing above. No audio or text is sent by this guide.", small: true)
        case .done:
            explanation(snapshot.dictationReady
                ? "The essentials for dictation are in place. You can adjust them anytime in Settings."
                : "Some essentials still need attention. You can close this guide and finish them later in Settings.")
            VStack(alignment: .leading, spacing: 10) {
                summaryRow("Microphone", ready: snapshot.microphone == .granted)
                summaryRow("Accessibility", ready: snapshot.accessibility == .granted)
                summaryRow("Dictation shortcuts", ready: snapshot.shortcutsReady)
                summaryRow("Speech recognition", ready: snapshot.speechReady)
                HStack {
                    Text(L10n.tr("AI polishing · optional"))
                    Spacer()
                    Text(snapshot.polishEnabled && snapshot.aiConfigured ? L10n.tr("Enabled") : L10n.tr("Not enabled"))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            if !snapshot.dictationReady {
                Button(L10n.tr("Check again"), action: actions.refresh)
            }
        }
    }

    @ViewBuilder private func permissionContent(_ permission: SetupGuidePermission, isMicrophone: Bool) -> some View {
        if permission == .requesting {
            SetupGuideRow(symbol: "ellipsis", title: L10n.tr("Waiting for your choice"),
                          detail: L10n.tr("Respond to the macOS permission dialog. You can continue here without waiting."))
        } else if permission == .granted {
            SetupGuideRow(symbol: "checkmark.circle.fill", title: L10n.tr("Access granted"),
                          detail: L10n.tr("This permission is already allowed. Continue to the next step."), complete: true)
        } else {
            SetupGuideRow(symbol: "lock", title: permission == .notDetermined ? L10n.tr("Your permission is needed") : L10n.tr("Access is not allowed"),
                          detail: isMicrophone
                            ? L10n.tr("System Settings › Privacy & Security › Microphone")
                            : L10n.tr("System Settings › Privacy & Security › Accessibility"))
            HStack {
                Button(permission == .notDetermined ? L10n.tr("Allow access") : L10n.tr("Open System Settings")) {
                    actions.allow(permission, microphone: isMicrophone)
                }
                Button(L10n.tr("Check again"), action: actions.refresh)
            }
            explanation(permission == .restricted
                ? "This permission may be restricted by your Mac’s administrator. You can continue and finish later."
                : permission == .denied
                    ? "Access is off. Enable Talkless in System Settings, then return here. If macOS asks you to quit and reopen Talkless, do so. You can reopen this guide in Settings › System."
                    : "After allowing access, return here and check again. You can also continue and finish later.", small: true)
        }
    }

    private func shortcutRow(_ key: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(key)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(minWidth: 96)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func explanation(_ key: String, small: Bool = false) -> some View {
        Text(L10n.tr(key))
            .font(small ? .caption : .body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func summaryRow(_ title: String, ready: Bool) -> some View {
        HStack {
            Text(L10n.tr(title))
            Spacer()
            Label(ready ? L10n.tr("Available") : L10n.tr("Needs attention"),
                  systemImage: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? Color.green : Color.secondary)
        }
        .font(.callout)
    }
}

/// A compact status/description row shared by the guide steps.
private struct SetupGuideRow: View {
    let symbol: String
    let title: String
    let detail: String
    var complete = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(complete ? Color.green : SettingsAppearance.accent)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if !detail.isEmpty {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}
