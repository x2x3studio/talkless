import Foundation

@MainActor
func testAlternateFinishKey() -> Int {
    var assertions = 0
    func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        assertions += 1
        precondition(condition(), description)
    }

    // Explicit expectations cover every primary, including Automatic's collision fallback.
    let primaries: [(key: TriggerKey, automatic: TriggerKey)] = [
        (.fn, .rightOption),
        (.rightOption, .rightCommand),
        (.rightCommand, .rightOption),
        (.rightControl, .rightOption),
    ]
    let choices: [(choice: AlternateFinishKey, explicit: TriggerKey?)] = [
        (.automatic, nil), (.disabled, nil), (.fn, .fn),
        (.rightOption, .rightOption), (.rightCommand, .rightCommand), (.rightControl, .rightControl),
    ]
    check(primaries.map(\.key) == TriggerKey.allCases, "Resolution matrix covers every primary key")
    check(choices.map(\.choice) == AlternateFinishKey.allCases, "Resolution matrix covers every alternate choice")

    let fresh = AppSettings(defaults: MemoryDefaults(), credentialStore: MemoryCredentials())
    check(fresh.alternateFinishKey == .automatic, "Fresh alternate finish preference defaults to Automatic")
    check(fresh.effectiveAlternateFinishKey == .rightOption, "Fresh primary resolves Automatic to Right Option")
    check(!fresh.polishEnabled, "Alternate finish default does not enable global polishing")

    for polishEnabled in [false, true] {
        let defaults = MemoryDefaults()
        let credentials = MemoryCredentials()
        defaults.set(polishEnabled, forKey: "polishEnabled")
        let settings = AppSettings(defaults: defaults, credentialStore: credentials)
        for (choice, explicit) in choices {
            settings.alternateFinishKey = choice
            for (primary, automatic) in primaries {
                settings.triggerKey = primary
                let expected: TriggerKey? = choice == .automatic
                    ? automatic : (explicit == primary ? nil : explicit)
                let context = "\(choice.rawValue) with primary \(primary.rawValue), polish \(polishEnabled)"
                check(choice.resolved(for: primary) == expected, "Enum resolves \(context)")
                check(settings.effectiveAlternateFinishKey == expected, "Settings resolve \(context)")
                check(settings.alternateFinishKey == choice, "Collisions and primary changes preserve chosen preference: \(context)")
                check(defaults.string(forKey: "alternateFinishKey") == choice.rawValue,
                      "Chosen preference persists instead of resolved key: \(context)")
                check(settings.polishEnabled == polishEnabled, "Changing finish keys leaves global polishing unchanged: \(context)")
                check(defaults.object(forKey: "polishEnabled") as? Bool == polishEnabled,
                      "Changing finish keys leaves persisted global polishing unchanged: \(context)")

                let restored = AppSettings(defaults: defaults, credentialStore: credentials)
                check(restored.triggerKey == primary, "Primary survives relaunch: \(context)")
                check(restored.alternateFinishKey == choice, "Alternate choice survives relaunch: \(context)")
                check(restored.effectiveAlternateFinishKey == expected, "Resolution survives relaunch: \(context)")
                check(restored.polishEnabled == polishEnabled, "Relaunch leaves global polishing unchanged: \(context)")
            }
        }
    }

    // Missing, unrecognized, and wrong-type stored values all fall back to Automatic.
    let invalidStoredValues: [Any?] = [nil, "", "unknown", "leftOption", "RIGHTOPTION", 17, false]
    for storedValue in invalidStoredValues {
        for (primary, automatic) in primaries {
            for polishEnabled in [false, true] {
                let defaults = MemoryDefaults()
                defaults.set(storedValue, forKey: "alternateFinishKey")
                defaults.set(primary.rawValue, forKey: "triggerKey")
                defaults.set(polishEnabled, forKey: "polishEnabled")
                let settings = AppSettings(defaults: defaults, credentialStore: MemoryCredentials())
                let context = "stored \(String(describing: storedValue)), primary \(primary.rawValue), polish \(polishEnabled)"
                check(settings.alternateFinishKey == .automatic, "Invalid or missing preference falls back: \(context)")
                check(settings.effectiveAlternateFinishKey == automatic, "Fallback still avoids primary collisions: \(context)")
                check(settings.polishEnabled == polishEnabled, "Fallback leaves global polishing unchanged: \(context)")
                check(defaults.object(forKey: "polishEnabled") as? Bool == polishEnabled,
                      "Fallback leaves persisted global polishing unchanged: \(context)")
            }
        }
    }

    print("PASS \(assertions) alternate finish resolution, persistence, fallback, and polish independence assertions")
    return assertions
}
