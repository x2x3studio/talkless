import AppKit

@MainActor
enum MenuBarIcon {
    enum State: CaseIterable {
        case idle, recording, processing

        var accessibilityDescription: String {
            switch self {
            case .idle: "Talkless"
            case .recording: L10n.tr("Talkless — Recording")
            case .processing: L10n.tr("Talkless — Processing")
            }
        }
    }

    /// The badge column is wide enough for a legible glyph next to Pip.
    static let size = NSSize(width: 28, height: 18)

    static func image(for state: State) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
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
            switch state {
            case .idle:
                break
            case .recording:
                // Listening: a solid dot at Pip's ear.
                context.setFillColor(NSColor.black.cgColor)
                context.fillEllipse(in: CGRect(x: 21.5, y: 1.5, width: 5, height: 5))
            case .processing:
                // Thinking: Pip wonders what you said.
                let mark = NSAttributedString(string: "?", attributes: [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .heavy),
                    .foregroundColor: NSColor.black,
                ])
                // Center the glyph's ink, not its line box, in the 6-point badge column;
                // antialiasing needs about half a point of clearance on each side.
                let ink = mark.boundingRect(with: NSSize(width: 20, height: 20),
                                            options: [.usesLineFragmentOrigin, .usesDeviceMetrics])
                mark.draw(at: NSPoint(x: 24.2 - ink.width / 2 - ink.minX, y: 1))
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
