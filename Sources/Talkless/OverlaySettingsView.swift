import SwiftUI

struct OverlaySettingsView: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    @Binding var appearance: HUDAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var previewStage = HUDPreviewStage.dictating
    @State private var previewSample = HUDPreviewSample.dictionary

    var body: some View {
        Form {
            Section(L10n.tr("Live preview")) {
                Picker(L10n.tr("Stage"), selection: $previewStage) {
                    ForEach(HUDPreviewStage.allCases) { Text($0.title).tag($0) }
                }
                .id("stage-\(localization.locale.identifier)")
                .pickerStyle(.segmented)
                OverlayPreview(appearance: appearance, stage: previewStage, sample: previewSample)
                Picker(L10n.tr("Sample text"), selection: $previewSample) {
                    ForEach(HUDPreviewSample.allCases) { Text($0.title).tag($0) }
                }
                .id("sample-\(localization.locale.identifier)")
                Text(L10n.tr("Underlined: dictionary match. Highlighted: changed by AI."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.tr("Sample text only. No audio recording or AI requests."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section(L10n.tr("Appearance")) {
                Picker(L10n.tr("Backdrop"), selection: $appearance.backdrop) {
                    ForEach(HUDAppearance.Backdrop.allCases) { Text($0.title).tag($0) }
                }
                .id("backdrop-\(localization.locale.identifier)")
                HStack(spacing: 12) {
                    Text(L10n.tr("Background opacity"))
                    Slider(value: $appearance.backgroundOpacity, in: HUDAppearance.opacityRange, step: 0.05)
                        .accessibilityLabel(L10n.tr("Background opacity"))
                        .accessibilityValue(appearance.backgroundOpacity.formatted(.percent.precision(.fractionLength(0))))
                    Text(appearance.effectiveOpacity(reduceTransparency: reduceTransparency), format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
                .disabled(appearance.usesSolidBackdrop(reduceTransparency: reduceTransparency))
                Text(L10n.tr("Opacity affects the translucent backdrop only. Text stays opaque."))
                    .font(.caption).foregroundStyle(.secondary)
                    .help(L10n.tr("Solid backdrops are always opaque, so the opacity slider is unavailable."))
                if reduceTransparency {
                    Text(L10n.tr("macOS Reduce Transparency keeps the backdrop solid. Your preference is saved."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section(L10n.tr("Motion and interaction")) {
                Toggle(L10n.tr("Animate status indicators"), isOn: $appearance.animationsEnabled)
                if reduceMotion {
                    Text(L10n.tr("macOS Reduce Motion keeps indicators still. Your preference is saved."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle(L10n.tr("Follow text cursor"), isOn: $appearance.followsCaret)
                Text(appearance.followsCaret
                     ? L10n.tr("Follows your text cursor when available; otherwise stays at the bottom of the screen. Never takes focus. Clicks pass through.")
                     : L10n.tr("Stays at the bottom center of the active display without taking focus. Clicks pass through."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(L10n.tr("Long dictation shows the latest lines. Choose the Long sample above to preview it."))
                HStack {
                    Text(L10n.tr("Changes apply immediately."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("Reset appearance")) { appearance = HUDAppearance() }
                        .disabled(appearance == HUDAppearance())
                }
            }
        }
        .formStyle(.grouped)
    }
}

enum HUDPreviewStage: String, CaseIterable, Identifiable {
    case dictating, polishing, editing, completed

    var id: Self { self }
    var title: String {
        switch self {
        case .dictating: L10n.tr("Dictating")
        case .polishing: L10n.tr("Polishing")
        case .editing: L10n.tr("Editing")
        case .completed: L10n.tr("Completed")
        }
    }

    var phase: HUDModel.Phase {
        switch self {
        case .dictating: .listening(handsFree: true)
        case .polishing: .polishing
        case .editing: .editing
        case .completed: .completed
        }
    }
}

enum HUDPreviewSample: String, CaseIterable, Identifiable {
    case short, long, dictionary

    var id: Self { self }
    var title: String {
        switch self {
        case .short: L10n.tr("Short")
        case .long: L10n.tr("Long")
        case .dictionary: L10n.tr("Dictionary match")
        }
    }

    /// Synthetic final output, never a claimed grammar check or live AI request.
    var finalText: String {
        switch self {
        case .dictionary: L10n.tr("Let's review Talkless tomorrow morning.")
        case .short: L10n.tr("Let's meet tomorrow morning to review the draft.")
        case .long: text
        }
    }

    var text: String {
        switch self {
        case .short: L10n.tr("Let's meet tomorrow morning.")
        case .dictionary: L10n.tr("Let's review Talkless tomorrow.")
        case .long:
            L10n.tr("Let's meet tomorrow morning to review the latest draft. We can go through the open questions, collect everyone's feedback, and agree on the next steps. Please bring your notes from the last conversation so we can make sure nothing gets missed. After the meeting, I will share a short summary with the team. That summary will include the decisions, the remaining questions, and a clear plan for the week ahead. We should leave enough time to check the details before sending the final version. These are the latest words.")
        }
    }
}

/// An embedded copy of the real HUD, not a panel or a dictation session.
struct OverlayPreview: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    let appearance: HUDAppearance
    let stage: HUDPreviewStage
    let sample: HUDPreviewSample
    @StateObject private var model: HUDModel

    init(appearance: HUDAppearance, stage: HUDPreviewStage, sample: HUDPreviewSample) {
        self.appearance = appearance
        self.stage = stage
        self.sample = sample
        let model = HUDModel(appearance: appearance)
        model.phase = stage.phase
        model.preview = stage == .completed ? sample.finalText : sample.text
        model.isEditMode = stage == .editing
        model.revisionOriginal = stage == .completed ? sample.text : nil
        // A fixed demo term, never the user's dictionary or recognition session.
        model.setDictionaryTerms(["Talkless"])
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .textBackgroundColor))
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.tr("Draft"))
                    .font(.system(size: 12, weight: .medium))
                Text(L10n.tr("A little space for your next thought."))
                    .font(.system(size: 15))
                Spacer()
            }
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            // Within-window blending previews the sample surface, not the desktop.
            HUDView(model: model, materialBlending: .withinWindow)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 214)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.format("%@ overlay preview", stage.title))
        .onChange(of: appearance) { _, value in model.appearance = value }
        .onChange(of: stage) { _, value in
            model.phase = value.phase
            model.isEditMode = value == .editing
            model.preview = value == .completed ? sample.finalText : sample.text
            model.revisionOriginal = value == .completed ? sample.text : nil
        }
        .onChange(of: sample.text) { _, value in
            model.preview = stage == .completed ? sample.finalText : value
            model.revisionOriginal = stage == .completed ? value : nil
        }
    }
}
