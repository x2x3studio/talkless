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
    check(settings.isTriggerKeyDefault && settings.isAlternateFinishKeyDefault
          && settings.areRecordingShortcutsDefault && settings.areShortcutsDefault,
          "Fresh shortcuts disable both row resets and Restore defaults")
    let freshValues = defaults.values as NSDictionary
    check(settings.resetTriggerKey() == nil, "Resetting the default primary is a no-op")
    check(settings.resetAlternateFinishKey() == nil, "Resetting the default alternate is a no-op")
    settings.restoreRecordingShortcutDefaults()
    settings.restoreShortcutDefaults()
    check(freshValues.isEqual(to: defaults.values), "Already-default resets do not write preferences")

    // Keep custom settings and synthetic credentials in place throughout every reset.
    settings.recordingGestureMode = .toggle
    settings.audioInputDeviceUID = "synthetic-input-uid"
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
    func unrelatedSettingsValues() -> [String: Any] {
        var values = defaults.values.filter { $0.key != "triggerKey" && $0.key != "alternateFinishKey" }
        // Reloading re-encodes provider JSON with unspecified key order. Compare its
        // complete decoded structure while retaining every other preference check.
        if let providerData = values["polishProviderSettings.v1"] as? Data {
            values["polishProviderSettings.v1"] = try! JSONSerialization.jsonObject(with: providerData)
        }
        return values
    }
    let unrelatedValues = unrelatedSettingsValues() as NSDictionary
    let credentialValues = credentials.values
    let appearance = settings.hudAppearance
    func checkUnrelatedSettings(_ context: String, expectedValues: NSDictionary? = nil) {
        check((expectedValues ?? unrelatedValues).isEqual(to: unrelatedSettingsValues()),
              "\(context) only writes shortcut preferences")
        check(credentials.values == credentialValues, "\(context) leaves every provider credential unchanged")
        check(settings.polishEnabled && settings.outputLanguage == .japanese && settings.voiceEditEnabled,
              "\(context) leaves live AI behavior unchanged")
        check(settings.hudAppearance == appearance, "\(context) leaves live appearance unchanged")
        check(settings.recordingGestureMode == .toggle && settings.audioInputDeviceUID == "synthetic-input-uid",
              "\(context) leaves recording mode and microphone unchanged")
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
    let customTranslation = TranslationShortcut(keyCode: 9, modifiers: [.command, .option])
    check(settings.translationShortcut == .default && settings.isTranslationShortcutDefault,
          "Missing translation preference retains existing Control Option T")
    for shortcut in [customTranslation, .disabled, .default] {
        settings.translationShortcut = shortcut
        let expectedUnrelatedValues = unrelatedSettingsValues() as NSDictionary
        for primary in TriggerKey.allCases {
            for alternate in AlternateFinishKey.allCases {
                settings.triggerKey = primary
                settings.alternateFinishKey = alternate
                let context = "Recording reset: \(primary.rawValue) / \(alternate.rawValue), translation \(shortcut)"
                check(settings.areRecordingShortcutsDefault == (primary == .fn && alternate == .automatic),
                      "\(context) reset availability ignores translation")
                let beforeReset = defaults.values as NSDictionary
                settings.restoreRecordingShortcutDefaults()
                check(settings.areRecordingShortcutsDefault && settings.triggerKey == .fn
                      && settings.alternateFinishKey == .automatic && settings.effectiveAlternateFinishKey == .rightOption,
                      "\(context) restores both recording shortcuts even from an explicit Fn alternate")
                check(settings.translationShortcut == shortcut,
                      "\(context) leaves the translation shortcut unchanged")
                check(settings.areShortcutsDefault == (shortcut == .default),
                      "\(context) all-shortcut default state still includes translation")
                if primary == .fn && alternate == .automatic {
                    check(beforeReset.isEqual(to: defaults.values), "\(context) already-default recording reset writes nothing")
                }
                let restored = AppSettings(defaults: defaults, credentialStore: credentials)
                check(restored.areRecordingShortcutsDefault && restored.translationShortcut == shortcut,
                      "\(context) recording defaults and unchanged translation survive relaunch")
                checkUnrelatedSettings(context, expectedValues: expectedUnrelatedValues)
            }
        }
        let reloaded = AppSettings(defaults: defaults, credentialStore: credentials)
        check(reloaded.translationShortcut == shortcut, "Custom and disabled translation survive relaunch")
        check(settings.isTranslationShortcutDefault == (shortcut == .default), "Translation reset reflects preference")
        check(settings.areShortcutsDefault == (shortcut == .default), "Restore defaults includes translation")
    }
    settings.triggerKey = .rightControl
    settings.alternateFinishKey = .disabled
    settings.translationShortcut = customTranslation
    settings.resetTranslationShortcut()
    check(settings.translationShortcut == .default && settings.triggerKey == .rightControl && settings.alternateFinishKey == .disabled,
          "Translation row reset leaves dictation and alternate unchanged")
    settings.translationShortcut = .disabled
    _ = settings.resetTriggerKey()
    _ = settings.resetAlternateFinishKey()
    check(settings.translationShortcut == .disabled, "Dictation resets leave disabled translation unchanged")
    settings.restoreShortcutDefaults()
    check(settings.areShortcutsDefault && settings.translationShortcut == .default, "All shortcuts reset restores disabled translation")
    for invalid: Any in ["not data", Data("{}".utf8),
                         try! JSONEncoder().encode(TranslationShortcut(keyCode: 17, modifiers: [])),
                         try! JSONEncoder().encode(TranslationShortcut(keyCode: 63, modifiers: .command)),
                         try! JSONEncoder().encode(TranslationShortcut(keyCode: 49, modifiers: .command))] {
        defaults.set(invalid, forKey: "translationShortcut.v1")
        let reloaded = AppSettings(defaults: defaults, credentialStore: credentials)
        check(reloaded.translationShortcut == .default, "Malformed and reserved saved chords safely fall back")
    }
    defaults.values.removeValue(forKey: "translationShortcut.v1")
    checkUnrelatedSettings("Translation resets and fallback")
    print("PASS \(assertions) shortcut reset defaults, conflict, persistence, and isolation assertions")
    return assertions
}
