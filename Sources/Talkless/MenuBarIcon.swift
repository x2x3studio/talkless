import AppKit

@MainActor
enum MenuBarIcon {
    enum State: CaseIterable {
        /// Idle shows Pip; recording live sound bars; recognition pulsing dots; AI work sparkles.
        case idle, recording, processing, aiProcessing

        var accessibilityDescription: String {
            switch self {
            case .idle: "Talkless"
            case .recording: L10n.tr("Talkless — Recording")
            case .processing: L10n.tr("Talkless — Processing")
            case .aiProcessing: L10n.tr("Talkless — AI processing")
            }
        }

        var animates: Bool { self != .idle }
    }

    /// One slot for every state: Pip's width with even margins, so neither the icon nor the
    /// menu bar items beside it ever shift, and no empty strip sits beside the glyph.
    static let size = NSSize(width: 19, height: 18)
    /// Animation frames per second while recording or processing.
    static let framesPerSecond: Double = 15

    /// `time` drives the animation (seconds, any origin); `level` is the smoothed input level 0…1.
    static func image(for state: State, time: TimeInterval = 0, level: Double = 0) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            switch state {
            case .idle: drawPip(context)
            case .recording: drawSoundBars(context, time: time, level: level)
            case .processing: drawDots(context, time: time)
            case .aiProcessing: drawSparkles(context, time: time)
            }
            return true
        }
        // AppKit supplies the foreground in light, dark, and selected menu bars.
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityDescription
        return image
    }

    private static func drawPip(_ context: CGContext) {
        context.saveGState()
        // A 15-point silhouette centered in the slot.
        context.translateBy(x: 9.5, y: 9)
        context.scaleBy(x: 0.027, y: 0.027)
        context.translateBy(x: -512, y: -512)
        context.addPath(PipArtwork.path(small: true))
        context.fillPath(using: .evenOdd)
        context.restoreGState()
    }

    /// Five bars around the center that follow the voice; a gentle ripple keeps them alive in silence.
    private static func drawSoundBars(_ context: CGContext, time: TimeInterval, level: Double) {
        let width: CGFloat = 2.2, gap: CGFloat = 1.3
        let envelope: [CGFloat] = [0.55, 0.8, 1, 0.8, 0.55]
        let total = CGFloat(envelope.count) * width + CGFloat(envelope.count - 1) * gap
        let loudness = 0.22 + 0.78 * CGFloat(max(0, min(1, level)))
        for (index, weight) in envelope.enumerated() {
            let ripple = 0.78 + 0.22 * CGFloat(sin(time * 9 + Double(index) * 1.3))
            let height = max(2.6, 14 * loudness * weight * ripple)
            let rect = CGRect(x: (size.width - total) / 2 + CGFloat(index) * (width + gap),
                              y: (size.height - height) / 2, width: width, height: height)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
        }
        context.fillPath()
    }

    /// Three dots pulse in turn while speech is recognized.
    private static func drawDots(_ context: CGContext, time: TimeInterval) {
        let diameter: CGFloat = 3.4
        for index in 0..<3 {
            let pulse = (sin(2 * .pi * (time * 0.9 - Double(index) / 3)) + 1) / 2
            context.setAlpha(0.3 + 0.7 * CGFloat(pulse))
            let center = CGPoint(x: size.width / 2 + CGFloat(index - 1) * 5, y: size.height / 2)
            context.fillEllipse(in: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                           width: diameter, height: diameter))
        }
        context.setAlpha(1)
    }

    /// Sparkles, as in the overlay's polishing icon, breathe while AI polishes or edits.
    private static func drawSparkles(_ context: CGContext, time: TimeInterval) {
        guard let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold)) else { return }
        let breathe = (sin(2 * .pi * time * 0.9) + 1) / 2
        let fit = min(16 / symbol.size.width, 15 / symbol.size.height, 1)
        let drawn = NSSize(width: symbol.size.width * fit, height: symbol.size.height * fit)
        // The symbol's ink sits left of its bounds' center; nudge it so its margins match.
        symbol.draw(in: NSRect(x: (size.width - drawn.width) / 2 + 0.75, y: (size.height - drawn.height) / 2,
                               width: drawn.width, height: drawn.height),
                    from: .zero, operation: .sourceOver, fraction: 0.5 + 0.5 * breathe,
                    respectFlipped: true, hints: nil)
    }
}

// BEGIN PIP ARTWORK — generator/menu parity is enforced by native tests.
// Pip silhouette in 1024-unit coordinates.
// Eyes and smile are negative space, never white paint or pupils.
enum PipArtwork {
    static func bodyPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 292, y: 715))
        p.addCurve(to: CGPoint(x: 260, y: 410), control1: CGPoint(x: 218, y: 645), control2: CGPoint(x: 214, y: 503))
        p.addLine(to: CGPoint(x: 292, y: 271))
        p.addCurve(to: CGPoint(x: 345, y: 267), control1: CGPoint(x: 299, y: 239), control2: CGPoint(x: 323, y: 237))
        p.addLine(to: CGPoint(x: 405, y: 348))
        p.addCurve(to: CGPoint(x: 583, y: 344), control1: CGPoint(x: 463, y: 327), control2: CGPoint(x: 521, y: 326))
        p.addLine(to: CGPoint(x: 679, y: 260))
        p.addCurve(to: CGPoint(x: 730, y: 282), control1: CGPoint(x: 705, y: 237), control2: CGPoint(x: 729, y: 250))
        p.addLine(to: CGPoint(x: 730, y: 430))
        p.addCurve(to: CGPoint(x: 754, y: 690), control1: CGPoint(x: 789, y: 497), control2: CGPoint(x: 800, y: 616))
        p.addCurve(to: CGPoint(x: 580, y: 771), control1: CGPoint(x: 716, y: 752), control2: CGPoint(x: 648, y: 778))
        p.addCurve(to: CGPoint(x: 438, y: 782), control1: CGPoint(x: 533, y: 766), control2: CGPoint(x: 485, y: 790))
        p.addCurve(to: CGPoint(x: 339, y: 740), control1: CGPoint(x: 397, y: 775), control2: CGPoint(x: 368, y: 744))
        p.addCurve(to: CGPoint(x: 292, y: 715), control1: CGPoint(x: 322, y: 738), control2: CGPoint(x: 305, y: 728))
        p.closeSubpath()
        return p
    }

    private static func eyePath(x: CGFloat, y: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let w: CGFloat = 122, h: CGFloat = 166, r: CGFloat = 61, k: CGFloat = 0.55228475
        p.move(to: CGPoint(x: x + r, y: y))
        p.addLine(to: CGPoint(x: x + w - r, y: y))
        p.addCurve(to: CGPoint(x: x + w, y: y + r), control1: CGPoint(x: x + w - r + r * k, y: y), control2: CGPoint(x: x + w, y: y + r - r * k))
        p.addLine(to: CGPoint(x: x + w, y: y + h - r))
        p.addCurve(to: CGPoint(x: x + w - r, y: y + h), control1: CGPoint(x: x + w, y: y + h - r + r * k), control2: CGPoint(x: x + w - r + r * k, y: y + h))
        p.addLine(to: CGPoint(x: x + r, y: y + h))
        p.addCurve(to: CGPoint(x: x, y: y + h - r), control1: CGPoint(x: x + r - r * k, y: y + h), control2: CGPoint(x: x, y: y + h - r + r * k))
        p.addLine(to: CGPoint(x: x, y: y + r))
        p.addCurve(to: CGPoint(x: x + r, y: y), control1: CGPoint(x: x, y: y + r - r * k), control2: CGPoint(x: x + r - r * k, y: y))
        p.closeSubpath()
        return p
    }

    static func path(small: Bool) -> CGPath {
        let p = CGMutablePath()
        p.addPath(bodyPath())
        p.addPath(eyePath(x: 357, y: 449))
        p.addPath(eyePath(x: 528, y: 433))
        let smile = CGMutablePath()
        smile.move(to: CGPoint(x: 471, y: 633))
        smile.addCurve(to: CGPoint(x: 539, y: 631), control1: CGPoint(x: 489, y: 657), control2: CGPoint(x: 517, y: 655))
        // A slightly wider smile keeps its negative space legible at small sizes.
        p.addPath(smile.copy(strokingWithWidth: small ? 28 : 20, lineCap: .round, lineJoin: .round, miterLimit: 10))
        return p
    }
}
// END PIP ARTWORK
