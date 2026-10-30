import SwiftUI

struct OverlaySettingsView: View {
    @Binding var appearance: HUDAppearance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var previewStage = HUDPreviewStage.recording
    @State private var previewSample = HUDPreviewSample.short

    var body: some View {
        Form {
            Section("Live preview") {
                Picker("Stage", selection: $previewStage) {
                    ForEach(HUDPreviewStage.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                OverlayPreview(appearance: appearance, stage: previewStage, sample: previewSample)
                Picker("Sample text", selection: $previewSample) {
                    ForEach(HUDPreviewSample.allCases) { Text($0.title).tag($0) }
                }
                .disabled(previewStage != .recording)
                Text("Sample text only. This preview never records audio or runs recognition or AI polish.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Backdrop", selection: $appearance.backdrop) {
                    ForEach(HUDAppearance.Backdrop.allCases) { Text($0.title).tag($0) }
                }
                HStack(spacing: 12) {
                    Text("Background opacity")
                    Slider(value: $appearance.backgroundOpacity, in: HUDAppearance.opacityRange, step: 0.05)
                        .accessibilityLabel("Background opacity")
                        .accessibilityValue(appearance.backgroundOpacity.formatted(.percent.precision(.fractionLength(0))))
                    Text(appearance.effectiveOpacity(reduceTransparency: reduceTransparency), format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
                .disabled(appearance.usesSolidBackdrop(reduceTransparency: reduceTransparency))
                Text("Opacity changes only the translucent background, never the text or indicators. Solid uses an opaque background.")
                    .font(.caption).foregroundStyle(.secondary)
                if reduceTransparency {
                    Text("Reduce Transparency is on in macOS. The backdrop stays solid; your translucent settings are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Motion and interaction") {
                Toggle("Animate status indicators", isOn: $appearance.animationsEnabled)
                if reduceMotion {
                    Text("Reduce Motion is on in macOS. Indicators stay still; your animation preference is kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("The overlay follows your text cursor without taking focus. Clicks pass through to the app underneath. Long dictation shows the latest lines.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Changes apply immediately.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset appearance") { appearance = HUDAppearance() }
                        .disabled(appearance == HUDAppearance())
                }
            }
        }
        .formStyle(.grouped)
    }
}

enum HUDPreviewStage: String, CaseIterable, Identifiable {
    case recording, recognizing, polishing

    var id: Self { self }
    var title: String {
        switch self {
        case .recording: "Recording"
        case .recognizing: "Recognizing"
        case .polishing: "Polishing"
        }
    }

    var phase: HUDModel.Phase {
        switch self {
        case .recording: .listening(handsFree: true)
        case .recognizing: .recognizing
        case .polishing: .polishing
        }
    }
}

enum HUDPreviewSample: String, CaseIterable, Identifiable {
    case short, long

    var id: Self { self }
    var title: String {
        switch self {
        case .short: "Short"
        case .long: "Long"
        }
    }

    var text: String {
        switch self {
        case .short: "Let's meet tomorrow morning."
        case .long:
            "Let's meet tomorrow morning to review the latest draft. "
            + "We can go through the open questions, collect everyone's feedback, and agree on the next steps. "
            + "Please bring your notes from the last conversation so we can make sure nothing gets missed. "
            + "After the meeting, I will share a short summary with the team. "
            + "That summary will include the decisions, the remaining questions, and a clear plan for the week ahead. "
            + "We should leave enough time to check the details before sending the final version. "
            + "These are the latest words."
        }
    }
}

/// An embedded copy of the real HUD, not a panel or a dictation session.
struct OverlayPreview: View {
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
        model.preview = sample.text
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .textBackgroundColor))
            VStack(alignment: .leading, spacing: 12) {
                Text("Draft")
                    .font(.system(size: 12, weight: .medium))
                Text("A little space for your next thought.")
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
        .accessibilityLabel("\(stage.title) overlay preview")
        .onChange(of: appearance) { _, value in model.appearance = value }
        .onChange(of: stage) { _, value in model.phase = value.phase }
        .onChange(of: sample) { _, value in model.preview = value.text }
    }
}
