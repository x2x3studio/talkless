import AppKit
import ApplicationServices

/// Read-only, best-effort insertion-point geometry. Never requests permission or reads text.
@MainActor
enum CaretPosition {
    private static let timeout: Float = 0.03
    private static let queryBudget: TimeInterval = 0.09

    private static func prepare(_ element: AXUIElement, deadline: TimeInterval) -> Bool {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0.001 else { return false }
        AXUIElementSetMessagingTimeout(element, min(timeout, Float(remaining)))
        return true
    }

    static func current() -> CGRect? {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication,
              let primaryFrame = NSScreen.screens.first?.frame else { return nil }
        let deadline = ProcessInfo.processInfo.systemUptime + queryBudget
        let app = AXUIElementCreateApplication(application.processIdentifier)
        guard prepare(app, deadline: deadline) else { return nil }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        guard prepare(element, deadline: deadline) else { return nil }

        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selected) == .success,
              let selected, CFGetTypeID(selected) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(selected as! AXValue, .cfRange, &range),
              range.location >= 0, range.length >= 0,
              range.location <= Int.max - range.length else { return nil }
        // AX does not expose selection direction. Use its end, never the whole selection's bounds.
        let index = range.location + range.length
        let caret: CGRect?
        if let bounds = bounds(for: CFRange(location: index, length: 0), in: element, deadline: deadline),
           bounds.width <= max(4, bounds.height / 2) {
            caret = bounds
        } else if index > 0,
                  let previous = bounds(for: CFRange(location: index - 1, length: 1), in: element, deadline: deadline),
                  previous.width > 0, previous.width <= previous.height * 2 {
            // Some controls only implement nonempty ranges. Infer the trailing character edge.
            caret = CGRect(x: previous.maxX, y: previous.minY, width: 0, height: previous.height)
        } else if index < Int.max,
                  let next = bounds(for: CFRange(location: index, length: 1), in: element, deadline: deadline),
                  next.width <= next.height * 2 {
            caret = CGRect(x: next.minX, y: next.minY, width: 0, height: next.height)
        } else {
            caret = nil
        }
        guard let caret,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else { return nil }
        let converted = appKitRect(fromAX: caret, primaryFrame: primaryFrame)
        // Reject stale/off-display geometry instead of following an invisible insertion point.
        guard NSScreen.screens.contains(where: { $0.frame.intersects(converted.insetBy(dx: -0.5, dy: 0)) }) else { return nil }
        return converted
    }

    /// AX uses global top-left coordinates, anchored to the first (menu-bar) display, not NSScreen.main.
    nonisolated static func appKitRect(fromAX rect: CGRect, primaryFrame: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func bounds(for range: CFRange, in element: AXUIElement, deadline: TimeInterval) -> CGRect? {
        guard prepare(element, deadline: deadline) else { return nil }
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         parameter, &result) == .success,
              let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var rect = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &rect),
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              (1...80).contains(rect.height), (0...300).contains(rect.width) else { return nil }
        return rect
    }
}

/// Pure HUD placement in AppKit coordinates. Pass screen visible frames (excluding Dock/menu bar).
enum CaretPlacement {
    static func frame(size: CGSize, caret: CGRect?, screens: [CGRect], fallbackPoint: CGPoint) -> CGRect {
        let screens = screens.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        let anchor = caret.map { CGPoint(x: $0.midX, y: $0.midY) } ?? fallbackPoint
        guard let screen = screens.min(by: { distanceSquared(anchor, to: $0) < distanceSquared(anchor, to: $1) }) else {
            return CGRect(origin: fallbackPoint, size: size)
        }
        let gap: CGFloat = 8
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, screen.minX), max(screen.minX, screen.maxX - size.width)) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, screen.minY), max(screen.minY, screen.maxY - size.height)) }
        func rect(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x, y: y, width: size.width, height: size.height) }
        let fallback = rect(clampX(screen.midX - size.width / 2), clampY(screen.minY + 28))
        guard let caret else { return fallback }
        let x = clampX(caret.minX)
        let below = rect(x, caret.minY - gap - size.height)
        let above = rect(x, caret.maxY + gap)
        if screen.contains(below) { return below }
        if screen.contains(above) { return above }

        // Never vertically clamp a near-caret candidate: that could move it over the text.
        let y = clampY(caret.midY - size.height / 2)
        let right = rect(caret.maxX + gap, y)
        let left = rect(caret.minX - gap - size.width, y)
        if screen.contains(right) { return right }
        if screen.contains(left) { return left }

        // An unusually small display/large HUD may not allow the normal gap. Prefer a clear edge.
        let candidates = [fallback,
                          rect(clampX(screen.minX), clampY(screen.minY)),
                          rect(clampX(screen.maxX - size.width), clampY(screen.minY)),
                          rect(clampX(screen.minX), clampY(screen.maxY - size.height)),
                          rect(clampX(screen.maxX - size.width), clampY(screen.maxY - size.height))]
        let protectedCaret = caret.insetBy(dx: -gap, dy: -gap)
        if let clear = candidates.first(where: { !$0.intersects(protectedCaret) }) { return clear }
        let actualCaret = caret.insetBy(dx: -0.5, dy: 0)
        if let clear = candidates.first(where: { !$0.intersects(actualCaret) }) { return clear }
        // Overlap is geometrically unavoidable; choose the edge with the smallest covered area.
        return candidates.min { overlap($0, actualCaret) < overlap($1, actualCaret) } ?? fallback
    }

    private static func distanceSquared(_ point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    private static func overlap(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
