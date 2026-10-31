import AppKit
import Combine
import SwiftUI

@MainActor
final class HUDModel: ObservableObject {
    enum Phase: Equatable {
        case hidden
        case listening(handsFree: Bool)
        case working
        case recognizing
        case polishing
        case editing
        case inserting
        case completed
        case error(String)

        var statusText: String? {
            switch self {
            case .working: L10n.tr("Preparing recognition")
            case .polishing: L10n.tr("Polishing")
            case .editing: L10n.tr("Editing")
            case .inserting: L10n.tr("Inserting")
            case .completed: L10n.tr("Completed")
            case .hidden, .listening, .recognizing, .error: nil
            }
        }

        var accessibilityLabel: String {
            switch self {
            // Capture and final recognition are one continuous user-facing activity.
            // Keep the engine phases distinct for controller sequencing and diagnostics.
            case .listening, .recognizing: L10n.tr("Dictating")
            case .error(let message): message
            default: statusText ?? ""
            }
        }
    }

    @Published var phase: Phase = .hidden {
        didSet {
            switch phase {
            case .hidden, .error:
                setDictionaryTerms([])
                revisionOriginal = nil
            default: break
            }
        }
    }
    @Published var isEditMode = false
    @Published var preview = ""
    /// Only a finalized ASR transcript, never successive provisional partials.
    @Published var revisionOriginal: String?
    @Published var recordingHint: String?
    @Published var appearance: HUDAppearance
    @Published private(set) var dictionaryTerms: [String] = []
    private var dictionaryMatcher = DictionaryHighlightMatcher(terms: [])

    /// Supplied once from the same confirmed-term snapshot used by recognition.
    /// Presence is not evidence that the recognizer used a hint to correct anything.
    func setDictionaryTerms(_ terms: [String]) {
        guard terms != dictionaryTerms else { return }
        dictionaryMatcher = DictionaryHighlightMatcher(terms: terms)
        dictionaryTerms = terms
    }

    /// The panel clips to the latest lines. Bound matching work independently of
    /// recording length, without truncating the actual transcript or its layout.
    static let maximumDictionaryHighlightCharacters = 1_024

    static func dictionaryHighlightInput(in text: String) -> (text: String, contextLength: Int, utf16Offset: Int) {
        let start = text.index(text.endIndex, offsetBy: -maximumDictionaryHighlightCharacters,
                               limitedBy: text.startIndex) ?? text.startIndex
        // Two preceding graphemes preserve word boundaries such as pre-OpenAI.
        let contextStart = text.index(start, offsetBy: -2, limitedBy: text.startIndex) ?? text.startIndex
        return (
            String(text[contextStart...]),
            text.distance(from: contextStart, to: start),
            text.utf16.distance(from: text.startIndex, to: contextStart)
        )
    }

    func attributedDisplayText(increasedContrast: Bool = false) -> AttributedString {
        let text = displayText
        var attributed = AttributedString(text)
        guard !isEditMode, !preview.isEmpty else { return attributed }
        switch phase {
        case .hidden, .error, .editing: return attributed
        default: break
        }
        // The HUD intentionally keeps its dark surface in both system appearances.
        // A pale blue wash and a separate underline remain visible without changing
        // the font, text color, or line metrics; contrast mode strengthens both.
        let accent = Color(red: 0.58, green: 0.82, blue: 1)
        let input = Self.dictionaryHighlightInput(in: text)
        let firstHighlight = input.text.index(input.text.startIndex, offsetBy: input.contextLength)
        for range in dictionaryMatcher.ranges(in: input.text) {
            // Do not invent a term at the cropped edge or mark a partially seen phrase.
            guard range.lowerBound >= firstHighlight else { continue }
            let localRange = NSRange(range, in: input.text)
            let fullRange = NSRange(location: input.utf16Offset + localRange.location, length: localRange.length)
            guard let original = Range(fullRange, in: text),
                  let start = AttributedString.Index(original.lowerBound, within: attributed),
                  let end = AttributedString.Index(original.upperBound, within: attributed) else { continue }
            attributed[start..<end].backgroundColor = accent.opacity(increasedContrast ? 0.28 : 0.16)
            attributed[start..<end].underlineStyle = Text.LineStyle(
                pattern: .solid, color: accent.opacity(increasedContrast ? 1 : 0.85)
            )
        }
        // Factual additions/replacements only. Amber fill can coexist with the blue
        // dictionary underline; neither decoration changes glyphs or line metrics.
        if (phase == .inserting || phase == .completed), let revisionOriginal {
            let revision = Color(red: 1, green: 0.77, blue: 0.38)
            for range in TextRevisionHighlight.ranges(original: revisionOriginal, revised: text) {
                guard let start = AttributedString.Index(range.lowerBound, within: attributed),
                      let end = AttributedString.Index(range.upperBound, within: attributed) else { continue }
                attributed[start..<end].backgroundColor = revision.opacity(increasedContrast ? 0.34 : 0.22)
            }
        }
        return attributed
    }

    init(appearance: HUDAppearance = HUDAppearance()) {
        self.appearance = appearance
    }

    var displayText: String {
        switch phase {
        case .hidden: ""
        case .error(let message): message
        default: preview.isEmpty ? (phase.statusText ?? "") : preview
        }
    }

    static let maximumWidth: CGFloat = 380
    static let maximumHeight: CGFloat = 174
    static let horizontalPadding: CGFloat = 14
    static let verticalPadding: CGFloat = 11
    static let indicatorWidth: CGFloat = 16
    static let spacing: CGFloat = 10

    var textSize: CGSize {
        guard !displayText.isEmpty else { return .zero }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .paragraphStyle: paragraph,
        ]
        let text = displayText as NSString
        let availableWidth = Self.maximumWidth - Self.horizontalPadding * 2 - Self.indicatorWidth - Self.spacing
        let width = min(availableWidth, ceil(text.size(withAttributes: attributes).width) + 2)
        let bounds = text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes
        )
        return CGSize(width: width, height: max(18, ceil(bounds.height) + 3))
    }

    // Shortcut state is retained for the controller, but never adds visible HUD chrome.
    var contentSize: CGSize {
        let text = textSize
        return CGSize(
            width: min(Self.maximumWidth,
                Self.horizontalPadding * 2 + Self.indicatorWidth + (text.width > 0 ? Self.spacing + text.width : 0)),
            height: min(Self.maximumHeight, max(18, text.height) + Self.verticalPadding * 2)
        )
    }

    /// Keep the same latest lines in view throughout recognition and cleanup.
    var textAlignment: Alignment {
        if case .error = phase { return .topLeading }
        return .bottomLeading
    }
}

/// A nonactivating, click-through panel, fixed on screen unless caret following is enabled.
@MainActor
final class HUDController {
    let model: HUDModel
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?
    private var trackingTask: Task<Void, Never>?
    private var layoutSubscription: AnyCancellable?
    private var appearanceSubscription: AnyCancellable?
    private var languageSubscription: AnyCancellable?
    private var cachedCaret: CGRect?
    private var cachedScreens: [CGRect] = []
    private var cachedFallbackPoint = CGPoint.zero
    private let caretProvider: () -> CGRect?
    private let screenFramesProvider: () -> [CGRect]
    private let pointerProvider: () -> CGPoint

    var frame: NSRect { panel.frame }
    var isClickThrough: Bool { panel.ignoresMouseEvents }
    var isNonactivating: Bool { panel.styleMask.contains(.nonactivatingPanel) }

    init(appearance: HUDAppearance = HUDAppearance(),
         appearanceUpdates: AnyPublisher<HUDAppearance, Never>? = nil,
         caretProvider: @escaping () -> CGRect? = { CaretPosition.current() },
         screenFramesProvider: @escaping () -> [CGRect] = { NSScreen.screens.map(\.visibleFrame) },
         pointerProvider: @escaping () -> CGPoint = { NSEvent.mouseLocation }) {
        model = HUDModel(appearance: appearance)
        self.caretProvider = caretProvider
        self.screenFramesProvider = screenFramesProvider
        self.pointerProvider = pointerProvider
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: model.contentSize),
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
        // Layout uses the cached anchor; only opt-in tracking queries the caret.
        layoutSubscription = Publishers.CombineLatest(
            model.$phase.removeDuplicates(), model.$preview.removeDuplicates()
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLayout() }
        appearanceSubscription = appearanceUpdates?
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.applyAppearance($0) }
        languageSubscription = NotificationCenter.default.publisher(for: .interfaceLanguageDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.model.objectWillChange.send()
                self?.updateLayout()
            }
    }

    private func applyAppearance(_ appearance: HUDAppearance) {
        let placementChanged = model.appearance.followsCaret != appearance.followsCaret
        model.appearance = appearance
        guard placementChanged else { return }
        trackingTask?.cancel()
        trackingTask = nil
        cachedCaret = nil
        guard panel.isVisible else { return }
        position()
        beginTracking()
    }

    private func updateLayout() {
        guard model.phase != .hidden else { return }
        let size = model.contentSize
        guard panel.frame.size != size else { return }
        panel.setContentSize(size)
        if panel.isVisible { position(refreshAnchor: false) }
    }

    func show(_ phase: HUDModel.Phase) {
        guard phase != .hidden else { hide(); return }
        hideTask?.cancel()
        // A result or error keeps the panel visible, but the next recording must
        // sample its own active display rather than reuse the previous session's.
        let startsAfterResult: Bool
        if case .listening = phase {
            switch model.phase {
            case .completed, .error: startsAfterResult = true
            default: startsAfterResult = false
            }
        } else { startsAfterResult = false }
        model.phase = phase
        updateLayout()
        if startsAfterResult && panel.isVisible { position() }
        if !panel.isVisible {
            position()
            panel.orderFrontRegardless()
            beginTracking()
        }
        switch phase {
        case .error:
            hide(after: .seconds(3))
        case .completed:
            // Review time is nonblocking: insertion is already finished and the
            // next recording replaces this result and cancels its dismissal.
            hide(after: .seconds(2))
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
        model.recordingHint = nil
        model.isEditMode = false
    }

    private func beginTracking() {
        trackingTask?.cancel()
        trackingTask = nil
        guard model.appearance.followsCaret else { return }
        trackingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.panel.isVisible,
                      self.model.appearance.followsCaret else { return }
                self.position()
            }
        }
    }

    private func position(refreshAnchor: Bool = true) {
        if refreshAnchor {
            // Fixed placement samples the active display only on show or mode change.
            // Resizing and stage changes keep that display, even if the pointer moves.
            cachedScreens = screenFramesProvider()
            cachedFallbackPoint = pointerProvider()
            cachedCaret = model.appearance.followsCaret ? caretProvider() : nil
        }
        let frame = CaretPlacement.frame(
            size: panel.frame.size,
            caret: model.appearance.followsCaret ? cachedCaret : nil,
            screens: cachedScreens,
            fallbackPoint: cachedFallbackPoint
        )
        if panel.frame.origin != frame.origin { panel.setFrameOrigin(frame.origin) }
    }
}

struct HUDView: View {
    @ObservedObject var model: HUDModel
    var materialBlending: NSVisualEffectView.BlendingMode = .behindWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let size = model.contentSize
        let textSize = model.textSize
        let visibleTextHeight = size.height - HUDModel.verticalPadding * 2
        Group {
            if model.phase != .hidden {
                HStack(alignment: .top, spacing: HUDModel.spacing) {
                    indicator
                        .frame(width: HUDModel.indicatorWidth, height: 18)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(model.phase.accessibilityLabel)
                        .help(model.phase.accessibilityLabel)
                    if !model.displayText.isEmpty {
                        Text(model.attributedDisplayText(increasedContrast: contrast == .increased))
                            .lineSpacing(3)
                            .frame(width: textSize.width, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: textSize.width, height: visibleTextHeight, alignment: model.textAlignment)
                            .clipped()
                            .accessibilityHint(model.isEditMode ? "" : L10n.tr("Underlined: dictionary match. Highlighted: changed by AI."))
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.95))
                .padding(.horizontal, HUDModel.horizontalPadding)
                .padding(.vertical, HUDModel.verticalPadding)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background {
                    if model.appearance.usesSolidBackdrop(reduceTransparency: reduceTransparency) {
                        RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.12))
                    } else {
                        HUDMaterial(blendingMode: materialBlending)
                            .overlay(.black.opacity(0.30))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            // Only the backdrop fades; text, indicators, and border stay legible.
                            .opacity(model.appearance.effectiveOpacity(reduceTransparency: reduceTransparency))
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
                .environment(\.colorScheme, .dark)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var animates: Bool { model.appearance.animates(reduceMotion: reduceMotion) }

    @ViewBuilder
    private var indicator: some View {
        switch model.phase {
        case .listening, .working, .recognizing:
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .medium))
                .symbolEffect(.pulse, options: .repeating, isActive: animates)
        case .polishing:
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color(red: 0.35, green: 0.77, blue: 1))
                .symbolEffect(.pulse, options: .repeating, isActive: animates)
        case .editing:
            Image(systemName: "pencil.line")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(red: 0.35, green: 0.77, blue: 1))
                .symbolEffect(.pulse, options: .repeating, isActive: animates)
        case .inserting:
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 13, weight: .medium))
        case .completed:
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .medium))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .hidden:
            EmptyView()
        }
    }
}

private struct HUDMaterial: NSViewRepresentable {
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = blendingMode
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.blendingMode = blendingMode
    }
}

// MARK: - Selected-text translation panel

@MainActor
final class TranslationPanelController {
    private var panel: NSPanel?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var menuTracking = false
    private var onClose: (() -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }
    var isClickThrough: Bool { panel?.ignoresMouseEvents ?? false }
    var isNonactivating: Bool { panel?.styleMask.contains(.nonactivatingPanel) ?? false }

    func show(source: String, result: String?, error: String?,
              preferences: TranslationLanguagePreferences, resolution: TranslationLanguageResolution,
              allowsReplacement: Bool = true,
              onLanguagesChanged: @escaping (TranslationLanguageSelection, TranslationLanguageSelection) -> Void,
              onReplace: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        self.onClose = onClose
        let view = TranslationView(
            source: source, result: result, error: error,
            preferences: preferences, resolution: resolution, allowsReplacement: allowsReplacement,
            onLanguagesChanged: onLanguagesChanged,
            onCopy: { [weak self] text in TextIO.copyToClipboard(text); self?.close() },
            onReplace: { [weak self] text in self?.close(); onReplace(text) },
            onClose: { [weak self] in self?.close() }
        )
        // Refresh in place: a result or language change must not reposition or reactivate the panel.
        if let panel, let hosting = panel.contentView as? NSHostingView<TranslationView> {
            let top = panel.frame.maxY
            hosting.rootView = view
            panel.setContentSize(hosting.fittingSize)
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
            return
        }
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
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
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

        menuObservers = [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.menuTracking = name == NSMenu.didBeginTrackingNotification }
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel else { return }
                if !self.menuTracking, !panel.frame.contains(NSEvent.mouseLocation) { self.close() }
            }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleLocalClick(in: event.window) }
            return event
        }
    }

    func handleLocalClick(in window: NSWindow?) {
        guard let panel, !menuTracking else { return }
        // Menus and sheets use separate windows outside the popup's frame. Let them
        // finish their interaction instead of treating a language choice as dismissal.
        guard window !== panel, window?.sheetParent !== panel, window?.parent !== panel,
              window?.level != .popUpMenu else { return }
        close()
    }

    func close() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        clickMonitor = nil
        localClickMonitor = nil
        menuObservers.forEach { NotificationCenter.default.removeObserver($0) }
        menuObservers = []
        menuTracking = false
        panel?.orderOut(nil)
        panel = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}

struct TranslationView: View {
    @ObservedObject private var localization = LocalizationSettings.shared
    let source: String
    let result: String?
    let error: String?
    let preferences: TranslationLanguagePreferences
    let resolution: TranslationLanguageResolution
    var allowsReplacement = true
    let onLanguagesChanged: (TranslationLanguageSelection, TranslationLanguageSelection) -> Void
    let onCopy: (String) -> Void
    let onReplace: (String) -> Void
    let onClose: () -> Void

    var sourceSelection: Binding<TranslationLanguageSelection> {
        Binding(get: { preferences.source }, set: { onLanguagesChanged($0, preferences.target) })
    }

    var targetSelection: Binding<TranslationLanguageSelection> {
        Binding(get: { preferences.target }, set: { onLanguagesChanged(preferences.source, $0) })
    }

    var automaticSourceLabel: String { L10n.tr("Auto") }

    var automaticTargetLabel: String { L10n.tr("Auto") }

    var canSwap: Bool {
        guard let sourceID = resolution.sourceLanguageID,
              TranslationLanguages.language(id: sourceID) != nil,
              case .languageID(let targetID) = resolution.target,
              TranslationLanguages.language(id: targetID) != nil else { return false }
        return sourceID != targetID
    }

    func swapLanguages() {
        guard canSwap, let sourceID = resolution.sourceLanguageID else { return }
        // Swap only the language choices, never the source text or replacement destination.
        onLanguagesChanged(resolution.target, .languageID(sourceID))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Source language")).font(.caption).foregroundStyle(.secondary)
                    LanguagePickerView(title: L10n.tr("Source language"), selection: sourceSelection,
                                       preferences: preferences, automaticLabel: automaticSourceLabel)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: swapLanguages) {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .disabled(!canSwap)
                .help(L10n.tr("Swap languages"))
                .accessibilityLabel(L10n.tr("Swap languages"))
                .padding(.bottom, 4)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.tr("Target language")).font(.caption).foregroundStyle(.secondary)
                    LanguagePickerView(title: L10n.tr("Target language"), selection: targetSelection,
                                       preferences: preferences, automaticLabel: automaticTargetLabel, allowCustom: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .controlSize(.small)
            Text(L10n.tr("Changing a language translates the original selection again using your AI service."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    Button(L10n.tr("Close"), action: onClose)
                    Button(L10n.tr("Copy")) { onCopy(result) }
                    if allowsReplacement {
                        Button(L10n.tr("Replace Original")) { onReplace(result) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .controlSize(.small)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                HStack { Spacer(); Button(L10n.tr("Close"), action: onClose).controlSize(.small) }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.tr("Translating…")).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.tr("Close"), action: onClose).controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
}
