import AppKit

@MainActor
enum MenuBarIcon {
    enum State: CaseIterable {
        case idle, recording, processing

        var accessibilityDescription: String {
            switch self {
            case .idle: "Talkless"
            case .recording: "Talkless — Recording"
            case .processing: "Talkless — Processing"
            }
        }
    }

    static func image(for state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 25, height: 18), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.translateBy(x: 1, y: 2)
            context.scaleBy(x: 0.032, y: 0.032)
            context.translateBy(x: -204, y: -300)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(56)
            context.addPath(voicePath())
            context.strokePath()
            context.setLineWidth(43)
            context.addPath(caretPath())
            context.strokePath()
            context.restoreGState()
            let badge = CGRect(x: 21, y: 2, width: 3, height: 3)
            switch state {
            case .idle:
                break
            case .recording:
                context.setFillColor(NSColor.black.cgColor)
                context.fillEllipse(in: badge)
            case .processing:
                context.setStrokeColor(NSColor.black.cgColor)
                context.setLineWidth(0.8)
                context.strokeEllipse(in: badge.insetBy(dx: 0.4, dy: 0.4))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = state.accessibilityDescription
        return image
    }

    private static func voicePath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 232, y: 518))
        p.addLine(to: CGPoint(x: 251, y: 518))
        p.addCurve(to: CGPoint(x: 286, y: 456), control1: CGPoint(x: 272, y: 518), control2: CGPoint(x: 268, y: 456))
        p.addCurve(to: CGPoint(x: 332, y: 589), control1: CGPoint(x: 313, y: 456), control2: CGPoint(x: 303, y: 589))
        p.addCurve(to: CGPoint(x: 397, y: 345), control1: CGPoint(x: 371, y: 589), control2: CGPoint(x: 359, y: 345))
        p.addCurve(to: CGPoint(x: 463, y: 665), control1: CGPoint(x: 442, y: 345), control2: CGPoint(x: 423, y: 665))
        p.addCurve(to: CGPoint(x: 526, y: 478), control1: CGPoint(x: 501, y: 665), control2: CGPoint(x: 491, y: 478))
        p.addCurve(to: CGPoint(x: 576, y: 518), control1: CGPoint(x: 552, y: 478), control2: CGPoint(x: 548, y: 518))
        p.addLine(to: CGPoint(x: 657, y: 518))
        return p
    }

    private static func caretPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 754, y: 391))
        p.addLine(to: CGPoint(x: 754, y: 635))
        p.move(to: CGPoint(x: 727, y: 391))
        p.addLine(to: CGPoint(x: 781, y: 391))
        p.move(to: CGPoint(x: 727, y: 635))
        p.addLine(to: CGPoint(x: 781, y: 635))
        return p
    }
}
