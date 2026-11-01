import AppKit

@MainActor
enum MenuBarIcon {
    enum State: CaseIterable {
        /// Listening shows "?", recognition "!", and AI work, both polishing and voice editing, "@".
        case idle, recording, processing, aiProcessing

        var accessibilityDescription: String {
            switch self {
            case .idle: "Talkless"
            case .recording: L10n.tr("Talkless — Recording")
            case .processing: L10n.tr("Talkless — Processing")
            case .aiProcessing: L10n.tr("Talkless — AI processing")
            }
        }

        var badge: String? {
            switch self {
            case .idle: nil
            case .recording: "?"
            case .processing: "!"
            case .aiProcessing: "@"
            }
        }
    }

    /// The original Pip canvas: marks shrink to fit beside Pip instead of widening the icon,
    /// so the menu bar item never changes width or shifts its neighbors.
    static let size = NSSize(width: 25, height: 18)

    private static func mark(_ badge: String) -> NSAttributedString {
        // "@" is much wider than "?" and "!", so it is set smaller to share the column.
        NSAttributedString(string: badge, attributes: [
            .font: NSFont.systemFont(ofSize: badge == "@" ? 5.5 : 8.5, weight: .heavy),
            .foregroundColor: NSColor.black,
        ])
    }

    private static func markInk(_ mark: NSAttributedString) -> NSRect {
        mark.boundingRect(with: NSSize(width: 20, height: 20), options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
    }

    /// Pip's ink spans x 1.75–17 in the unshifted layout, a mark 18.3 onward. The whole group,
    /// Pip alone or Pip with its mark, is centered in the slot so no state leans left. Whole
    /// points keep Pip crisp at 1x.
    static func offset(for state: State) -> CGFloat {
        let pip: ClosedRange<CGFloat> = {
            let box = PipArtwork.path(small: true).boundingBoxOfPath
            return (9.5 + (box.minX - 512) * 0.027)...(9.5 + (box.maxX - 512) * 0.027)
        }()
        let right = state.badge.map { 18.3 + markInk(mark($0)).width } ?? pip.upperBound
        return ((size.width - (right - pip.lowerBound)) / 2 - pip.lowerBound).rounded()
    }

    static func image(for state: State) -> NSImage {
        let shift = offset(for: state)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: shift, y: 0)
            context.saveGState()
            // A 15-point silhouette in the 19-point mark slot leaves a clear
            // transparent gutter before the state badge.
            context.translateBy(x: 9.5, y: 9)
            context.scaleBy(x: 0.027, y: 0.027)
            context.translateBy(x: -512, y: -512)
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(PipArtwork.path(small: true))
            context.fillPath(using: .evenOdd)
            context.restoreGState()
            if let badge = state.badge {
                let mark = mark(badge)
                // In the mark's rows (y 1.5–8.5) Pip's ink ends by x 16.75, at the cheek;
                // starting the mark's ink at 18.3 keeps a clear pixel even at 1x, so the pair
                // reads as one compact icon.
                let ink = markInk(mark)
                mark.draw(at: NSPoint(x: 18.3 - ink.minX, y: badge == "@" ? 1.5 : 0))
            }
            return true
        }
        // AppKit supplies the foreground in light, dark, and selected menu bars.
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityDescription
        return image
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
