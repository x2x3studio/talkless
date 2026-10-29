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
    static let maximumWidth: CGFloat = 340
    static let maximumHeight: CGFloat = 82
}

/// A floating capsule at the bottom center of the screen; it neither takes focus nor receives mouse events.
@MainActor
final class HUDController {
    let model = HUDModel()
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?
    private var trackingTask: Task<Void, Never>?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: HUDModel.maximumWidth, height: HUDModel.maximumHeight),
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
            beginTracking()
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
        trackingTask?.cancel()
        trackingTask = nil
        panel.orderOut(nil)
        model.phase = .hidden
        model.preview = ""
        model.isEditMode = false
    }

    private func beginTracking() {
        trackingTask?.cancel()
        trackingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.panel.isVisible else { return }
                self.position()
            }
        }
    }

    private func position() {
        let frame = CaretPlacement.frame(
            size: panel.frame.size,
            caret: CaretPosition.current(),
            screens: NSScreen.screens.map(\.visibleFrame),
            fallbackPoint: NSEvent.mouseLocation
        )
        if panel.frame.origin != frame.origin { panel.setFrameOrigin(frame.origin) }
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel

    var body: some View {
        Group {
            if model.phase != .hidden {
                HStack(spacing: 9) {
                    indicator
                    if case .error(let message) = model.phase {
                        Text(message)
                            .lineLimit(3)
                            .truncationMode(.tail)
                    } else if !model.preview.isEmpty {
                        Text(model.preview)
                            .lineLimit(2)
                            .truncationMode(.head)
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .frame(maxWidth: HUDModel.maximumWidth - 8)
                .fixedSize(horizontal: true, vertical: true)
                .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.82)))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.10)))
            }
        }
        .frame(width: HUDModel.maximumWidth, height: HUDModel.maximumHeight, alignment: .bottom)
    }

    @ViewBuilder
    private var indicator: some View {
        switch model.phase {
        case .listening:
            Circle()
                .fill(model.isEditMode ? Color.orange : Color.red)
                .frame(width: 6, height: 6)
                .accessibilityLabel("Recording")
        case .working:
            ProgressView()
                .controlSize(.mini)
                .tint(.white)
                .accessibilityLabel("Processing dictation")
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .hidden:
            EmptyView()
        }
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
