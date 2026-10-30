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

@MainActor
func testShortcutDefaults() -> Int {
    var assertions = 0
    func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        assertions += 1
        precondition(condition(), description)
    }

    let defaults = MemoryDefaults()
    let credentials = MemoryCredentials()
    let settings = AppSettings(defaults: defaults, credentialStore: credentials)
    check(settings.isTriggerKeyDefault && settings.isAlternateFinishKeyDefault && settings.areShortcutsDefault,
          "Fresh shortcuts disable both row resets and Restore defaults")
    let freshValues = defaults.values as NSDictionary
    check(settings.resetTriggerKey() == nil, "Resetting the default primary is a no-op")
    check(settings.resetAlternateFinishKey() == nil, "Resetting the default alternate is a no-op")
    settings.restoreShortcutDefaults()
    check(freshValues.isEqual(to: defaults.values), "Already-default resets do not write preferences")

    // Keep custom settings and synthetic credentials in place throughout every reset.
    settings.polishEnabled = true
    settings.outputLanguage = .japanese
    settings.voiceEditEnabled = true
    settings.appToneEnabled = false
    settings.translateTarget = "French"
    settings.dictionary = "Talkless\nCustom term"
    settings.dictionaryReviewEnabled = true
    settings.customInstructions = "Preserve my wording."
    settings.hudAppearance = HUDAppearance(backdrop: .solid, backgroundOpacity: 0.45, animationsEnabled: false)
    settings.asrEngine = .openAICompatible
    settings.asrBaseURL = "https://speech.invalid/v1"
    settings.asrAPIKey = "synthetic-speech-key"
    settings.asrModel = "synthetic-speech-model"
    for provider in [PolishProvider.deepSeek, .custom] {
        settings.selectPolishProvider(provider)
        settings.llmBaseURL = "https://\(provider.rawValue).invalid/v1"
        settings.llmModel = "synthetic-\(provider.rawValue)-model"
        settings.llmAPIKey = "synthetic-\(provider.rawValue)-key"
    }
    let unrelatedValues = defaults.values as NSDictionary
    let credentialValues = credentials.values
    let appearance = settings.hudAppearance
    func checkUnrelatedSettings(_ context: String) {
        let otherValues = defaults.values.filter { $0.key != "triggerKey" && $0.key != "alternateFinishKey" }
        check(unrelatedValues.isEqual(to: otherValues), "\(context) only writes shortcut preferences")
        check(credentials.values == credentialValues, "\(context) leaves every provider credential unchanged")
        check(settings.polishEnabled && settings.outputLanguage == .japanese && settings.voiceEditEnabled,
              "\(context) leaves live AI behavior unchanged")
        check(settings.hudAppearance == appearance, "\(context) leaves live appearance unchanged")
        check(settings.selectedPolishProvider == .custom && settings.llmAPIKey == credentialValues[.custom],
              "\(context) leaves selected provider and live credential unchanged")
    }
    func checkPersisted(_ primary: TriggerKey, _ alternate: AlternateFinishKey, _ context: String) {
        let reloadedDefaults = MemoryDefaults()
        reloadedDefaults.values = defaults.values
        let restored = AppSettings(defaults: reloadedDefaults, credentialStore: credentials)
        check(restored.triggerKey == primary && restored.alternateFinishKey == alternate,
              "\(context) preserves shortcut preferences across relaunch")
    }

    for primary in TriggerKey.allCases {
        let automatic: TriggerKey = primary == .rightOption ? .rightCommand : .rightOption
        for alternate in AlternateFinishKey.allCases {
            let context = "\(primary.rawValue) / \(alternate.rawValue)"
            settings.triggerKey = primary
            settings.alternateFinishKey = alternate
            check(settings.isTriggerKeyDefault == (primary == .fn), "Primary reset reflects stored preference: \(context)")
            check(settings.isAlternateFinishKeyDefault == (alternate == .automatic),
                  "Alternate reset distinguishes Automatic from an explicit equivalent key: \(context)")
            check(settings.areShortcutsDefault == (primary == .fn && alternate == .automatic),
                  "Restore defaults requires both stored preferences to match: \(context)")
            check(settings.defaultAlternateFinishKeyTitle == "Automatic (\(automatic.title))",
                  "Default hint resolves Automatic against the current primary: \(context)")
            check(alternate.title(for: primary) == (alternate == .automatic ? "Automatic (\(automatic.title))" : alternate.title),
                  "Displayed choice preserves explicit versus automatic semantics: \(context)")

            let beforeReset = defaults.values as NSDictionary
            let error = settings.resetTriggerKey()
            let conflicts = primary != .fn && alternate == .fn
            check((error != nil) == conflicts, "Primary reset refuses an explicit Fn alternate: \(context)")
            if conflicts {
                check(error?.contains("Restore defaults") == true, "Conflict explains how to reset both shortcuts")
                check(beforeReset.isEqual(to: defaults.values), "Rejected primary reset writes nothing")
            }
            let expectedPrimary: TriggerKey = conflicts ? primary : .fn
            check(settings.triggerKey == expectedPrimary, "Primary reset changes only valid primary bindings: \(context)")
            check(settings.alternateFinishKey == alternate, "Primary reset never rewrites the other binding: \(context)")
            checkPersisted(expectedPrimary, alternate, "Primary reset: \(context)")
            checkUnrelatedSettings("Primary reset: \(context)")

            settings.triggerKey = primary
            settings.alternateFinishKey = alternate
            check(settings.resetAlternateFinishKey() == nil, "Automatic alternate reset cannot conflict: \(context)")
            check(settings.triggerKey == primary, "Alternate reset leaves the primary unchanged: \(context)")
            check(settings.alternateFinishKey == .automatic && settings.effectiveAlternateFinishKey == automatic,
                  "Alternate reset restores adaptive Automatic, including disabled and explicit choices: \(context)")
            checkPersisted(primary, .automatic, "Alternate reset: \(context)")
            checkUnrelatedSettings("Alternate reset: \(context)")

            settings.triggerKey = primary
            settings.alternateFinishKey = alternate
            settings.restoreShortcutDefaults()
            check(settings.triggerKey == .fn && settings.alternateFinishKey == .automatic,
                  "Restore defaults recovers both bindings even from conflicts: \(context)")
            check(settings.areShortcutsDefault && settings.effectiveAlternateFinishKey == .rightOption,
                  "Restore defaults returns to the initial effective shortcut pair: \(context)")
            checkPersisted(.fn, .automatic, "Restore defaults: \(context)")
            checkUnrelatedSettings("Restore defaults: \(context)")
        }
    }
    print("PASS \(assertions) shortcut reset defaults, conflict, persistence, and isolation assertions")
    return assertions
}
