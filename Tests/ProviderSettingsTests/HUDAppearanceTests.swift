import Foundation
import Combine

@MainActor
func testHUDAppearance() throws -> Int {
    var assertions = 0
    func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        assertions += 1
        precondition(condition(), description)
    }
    let initial = HUDAppearance()
    check(initial.backdrop == .translucent, "Fresh HUD uses a translucent backdrop")
    check(initial.backgroundOpacity == 0.9, "Fresh HUD stays legible")
    check(initial.animationsEnabled, "Fresh HUD enables status motion")
    for (value, expected) in [(Double.nan, 0.9), (.infinity, 0.9), (-.infinity, 0.9),
                              (-1, 0.2), (0, 0.2), (2, 1), (0.55, 0.55)] {
        var appearance = HUDAppearance(backgroundOpacity: value)
        check(appearance.backgroundOpacity == expected, "Initializer validates opacity")
        appearance.backgroundOpacity = value
        check(appearance.backgroundOpacity == expected, "Edits validate opacity")
    }
    for backdrop in HUDAppearance.Backdrop.allCases {
        for reduceTransparency in [false, true] {
            let appearance = HUDAppearance(backdrop: backdrop, backgroundOpacity: 0.4)
            let solid = backdrop == .solid || reduceTransparency
            check(appearance.usesSolidBackdrop(reduceTransparency: reduceTransparency) == solid,
                  "Accessibility overrides translucent style")
            check(appearance.effectiveOpacity(reduceTransparency: reduceTransparency) == (solid ? 1 : 0.4),
                  "Solid and Reduce Transparency always stay opaque")
            check(appearance.backgroundOpacity == 0.4, "Accessibility never rewrites user choices")
        }
    }
    for enabled in [false, true] {
        for reduceMotion in [false, true] {
            check(HUDAppearance(animationsEnabled: enabled).animates(reduceMotion: reduceMotion)
                  == (enabled && !reduceMotion), "Both user and accessibility can disable motion")
        }
    }
    let decoder = JSONDecoder()
    func decode(_ string: String) throws -> HUDAppearance {
        try decoder.decode(HUDAppearance.self, from: Data(string.utf8))
    }
    let missing = try decode("{}")
    let malformed = try decode(#"{"backdrop":"unknown","backgroundOpacity":"bad","animationsEnabled":17}"#)
    let clampedHigh = try decode(#"{"backdrop":"solid","backgroundOpacity":9,"animationsEnabled":false}"#)
    let clampedLow = try decode(#"{"backgroundOpacity":-4}"#)
    check(missing == initial, "Missing fields restore sensible defaults")
    check(malformed == initial, "Malformed fields restore defaults independently")
    check(clampedHigh == HUDAppearance(backdrop: .solid, backgroundOpacity: 1, animationsEnabled: false),
          "Valid fields survive and decoded opacity clamps")
    check(clampedLow.backgroundOpacity == 0.2, "Decoded low opacity clamps")

    let defaults = MemoryDefaults()
    let credentials = MemoryCredentials()
    let settings = AppSettings(defaults: defaults, credentialStore: credentials)
    check(settings.hudAppearance == initial, "Fresh app settings use HUD defaults")
    var updates: [HUDAppearance] = []
    let subscription = settings.$hudAppearance.sink { updates.append($0) }
    settings.hudAppearance.backgroundOpacity = 0.45
    settings.hudAppearance.backdrop = .solid
    settings.hudAppearance.animationsEnabled = false
    let edited = HUDAppearance(backdrop: .solid, backgroundOpacity: 0.45, animationsEnabled: false)
    check(settings.hudAppearance == edited, "Nested bindings update shared appearance")
    check(updates.last == edited && updates.count == 4, "Every edit publishes for immediate HUD updates")
    let restored = AppSettings(defaults: defaults, credentialStore: credentials)
    check(restored.hudAppearance == edited, "Appearance survives relaunch")
    restored.hudAppearance.backdrop = .translucent
    check(restored.hudAppearance.backgroundOpacity == 0.45, "Switching from solid restores translucent opacity")
    restored.hudAppearance = HUDAppearance()
    check(AppSettings(defaults: defaults, credentialStore: credentials).hudAppearance == initial,
          "Reset appearance persists")
    for malformed in ["not JSON", "[]", "null"] {
        defaults.set(Data(malformed.utf8), forKey: "hudAppearance.v1")
        check(AppSettings(defaults: defaults, credentialStore: credentials).hudAppearance == initial,
              "Unreadable saved appearance falls back safely")
    }
    withExtendedLifetime(subscription) {}
    print("PASS \(assertions) HUD appearance validation, accessibility, publication, and persistence assertions")
    return assertions
}
