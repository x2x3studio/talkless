import AppKit
import SwiftUI

@MainActor
final class HUDModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening(handsFree: Bool)
        case working
        case error(String)
    }

    @Published var phase: Phase = .hidden
    @Published var isEditMode = false
    @Published var preview = ""
    @Published var levels: [CGFloat] = Array(repeating: 0, count: 28)

    func push(level: Float) {
        // Apply simple smoothing to keep the bars from jittering.
        let last = levels.last ?? 0
        let value = max(CGFloat(level), last * 0.6)
        levels.removeFirst()
        levels.append(value)
    }

    func resetLevels() {
        levels = Array(repeating: 0, count: levels.count)
    }
}

/// A floating capsule at the bottom center of the screen; it neither takes focus nor receives mouse events.
@MainActor
final class HUDController {
    let model = HUDModel()
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func show(_ phase: HUDModel.Phase) {
        guard phase != .hidden else { hide(); return }
        hideTask?.cancel()
        model.phase = phase
        if !panel.isVisible {
            position()
            panel.orderFrontRegardless()
        }
        switch phase {
        case .error:
            hide(after: .seconds(3))
        default:
            break
        }
    }

    func hide(after delay: Duration = .zero) {
        hideTask?.cancel()
        if delay <= .zero {
            dismiss()
            return
        }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.dismiss()
        }
    }

    private func dismiss() {
        panel.orderOut(nil)
        model.phase = .hidden
        model.preview = ""
        model.isEditMode = false
        model.resetLevels()
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 28))
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            if !model.preview.isEmpty, isListeningOrWorking {
                Text(model.preview)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(3)
                    .truncationMode(.head)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 560)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.78)))
                    .transition(.opacity)
            }
            capsule
        }
        .frame(width: 640, height: 200)
        .animation(.easeOut(duration: 0.15), value: model.phase)
        .animation(.easeOut(duration: 0.15), value: model.preview.isEmpty)
    }

    private var isListeningOrWorking: Bool {
        switch model.phase {
        case .listening, .working: return true
        default: return false
        }
    }

    @ViewBuilder
    private var capsule: some View {
        HStack(spacing: 10) {
            icon
            switch model.phase {
            case .listening:
                Waveform(levels: model.levels)
                    .frame(width: 120, height: 22)
            case .working:
                ProgressView().controlSize(.small).tint(.white)
                    .accessibilityLabel("Processing dictation")
            case .error(let text):
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: 420)
            case .hidden:
                EmptyView()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .background(Capsule().fill(.black.opacity(0.85)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
    }

    @ViewBuilder
    private var icon: some View {
        switch model.phase {
        case .listening:
            Image(systemName: model.isEditMode ? "pencil.and.scribble" : "mic.fill")
                .foregroundStyle(model.isEditMode ? .orange : .red)
        case .working:
            EmptyView()
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .hidden:
            EmptyView()
        }
    }
}

struct Waveform: View {
    var levels: [CGFloat]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 2.5, height: max(3, levels[i] * 22))
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }
}

// MARK: - Selected-text translation panel

@MainActor
final class TranslationPanelController {
    private var panel: NSPanel?
    private var clickMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    func show(source: String, result: String?, error: String?, allowsReplacement: Bool = true, onReplace: @escaping (String) -> Void) {
        close()
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 240),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view = TranslationView(
            source: source, result: result, error: error, allowsReplacement: allowsReplacement,
            onCopy: { [weak self] text in TextIO.copyToClipboard(text); self?.close() },
            onReplace: { [weak self] text in self?.close(); onReplace(text) },
            onClose: { [weak self] in self?.close() }
        )
        let hosting = NSHostingView(rootView: view)
        hosting.setFrameSize(hosting.fittingSize)
        panel.contentView = hosting
        panel.setContentSize(hosting.fittingSize)

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) }?.visibleFrame ?? .zero
        var origin = NSPoint(x: mouse.x - 20, y: mouse.y - panel.frame.height - 16)
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - panel.frame.width - 8)
        if origin.y < screen.minY + 8 { origin.y = mouse.y + 16 }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        self.panel = panel

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if !panel.frame.contains(NSEvent.mouseLocation) { self.close() }
            }
        }
    }

    func close() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

struct TranslationView: View {
    let source: String
    let result: String?
    let error: String?
    var allowsReplacement = true
    let onCopy: (String) -> Void
    let onReplace: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(source)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Divider()
            if let result {
                ScrollView {
                    Text(result)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Close", action: onClose)
                    Button("Copy") { onCopy(result) }
                    if allowsReplacement {
                        Button("Replace Original") { onReplace(result) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.small)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                HStack { Spacer(); Button("Close", action: onClose).controlSize(.small) }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Translating…").foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}
