import Foundation

/// Shared by the real overlay and its settings preview; no app or device access.
struct HUDAppearance: Equatable, Codable, Sendable {
    enum Backdrop: String, CaseIterable, Identifiable, Codable, Sendable {
        case translucent, solid

        var id: Self { self }
        var title: String {
            switch self {
            case .translucent: L10n.tr("Translucent")
            case .solid: L10n.tr("Solid")
            }
        }
    }

    static let opacityRange = 0.2...1.0
    static let defaultOpacity = 0.9

    var backdrop: Backdrop
    private var storedOpacity: Double
    var animationsEnabled: Bool

    /// Keep every value valid, including programmatic edits and malformed saved data.
    var backgroundOpacity: Double {
        get { storedOpacity }
        set { storedOpacity = Self.validatedOpacity(newValue) }
    }

    init(backdrop: Backdrop = .translucent, backgroundOpacity: Double = defaultOpacity,
         animationsEnabled: Bool = true) {
        self.backdrop = backdrop
        storedOpacity = Self.validatedOpacity(backgroundOpacity)
        self.animationsEnabled = animationsEnabled
    }

    func usesSolidBackdrop(reduceTransparency: Bool) -> Bool {
        reduceTransparency || backdrop == .solid
    }

    func effectiveOpacity(reduceTransparency: Bool) -> Double {
        usesSolidBackdrop(reduceTransparency: reduceTransparency) ? 1 : backgroundOpacity
    }

    func animates(reduceMotion: Bool) -> Bool {
        animationsEnabled && !reduceMotion
    }

    private static func validatedOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return defaultOpacity }
        return min(opacityRange.upperBound, max(opacityRange.lowerBound, value))
    }

    private enum CodingKeys: String, CodingKey {
        case backdrop, backgroundOpacity, animationsEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            backdrop: (try? values.decode(Backdrop.self, forKey: .backdrop)) ?? .translucent,
            backgroundOpacity: (try? values.decode(Double.self, forKey: .backgroundOpacity)) ?? Self.defaultOpacity,
            animationsEnabled: (try? values.decode(Bool.self, forKey: .animationsEnabled)) ?? true
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(backdrop, forKey: .backdrop)
        try values.encode(backgroundOpacity, forKey: .backgroundOpacity)
        try values.encode(animationsEnabled, forKey: .animationsEnabled)
    }
}
