import Foundation

@MainActor
func testShortcutSettings() -> Int {
    var assertions = 0
    func check(_ condition: @autoclosure () -> Bool, _ description: String) {
        assertions += 1
        precondition(condition(), description)
    }

    let defaults = MemoryDefaults()
    let credentials = MemoryCredentials()
    let settings = AppSettings(defaults: defaults, credentialStore: credentials)
    check(settings.isTriggerKeyDefault && settings.areShortcutsDefault, "Fresh shortcuts are the defaults")
    let freshValues = defaults.values as NSDictionary
    check(settings.resetTriggerKey() == nil, "Resetting the default dictation key is a no-op")
    settings.restoreShortcutDefaults()
    check(freshValues.isEqual(to: defaults.values), "Already-default resets do not write preferences")

    // The retired per-dictation polishing shortcut leaves no stored preference behind.
    defaults.set("rightOption", forKey: "alternateFinishKey")
    _ = AppSettings(defaults: defaults, credentialStore: credentials)
    check(defaults.object(forKey: "alternateFinishKey") == nil, "Retired AI polishing shortcut preference is removed")

    // Polishing follows only the global switch; changing keys never touches it.
    settings.polishEnabled = true
    settings.dictionary = "Talkless"
    for key in TriggerKey.allCases {
        settings.triggerKey = key
        check(defaults.string(forKey: "triggerKey") == key.rawValue, "Dictation key persists: \(key)")
        let restored = AppSettings(defaults: defaults, credentialStore: credentials)
        check(restored.triggerKey == key && restored.polishEnabled, "Dictation key survives relaunch without changing polish: \(key)")
        check(settings.isTriggerKeyDefault == (key == .fn), "Default state reflects the key: \(key)")
        check(settings.resetTriggerKey() == nil && settings.triggerKey == .fn, "Dictation key reset always succeeds: \(key)")
        check(settings.polishEnabled && settings.dictionary == "Talkless", "Resetting the key leaves other settings unchanged: \(key)")
    }

    let customTranslation = TranslationShortcut(keyCode: 15, modifiers: [.control, .option])
    for shortcut in [customTranslation, .disabled] {
        settings.translationShortcut = shortcut
        let reloaded = AppSettings(defaults: defaults, credentialStore: credentials)
        check(reloaded.translationShortcut == shortcut, "Custom and disabled translation survive relaunch")
        check(settings.isTranslationShortcutDefault == (shortcut == .default), "Translation reset reflects preference")
        check(!settings.areShortcutsDefault, "Restore defaults includes translation")
    }
    settings.triggerKey = .rightControl
    settings.translationShortcut = customTranslation
    settings.resetTranslationShortcut()
    check(settings.translationShortcut == .default && settings.triggerKey == .rightControl,
          "Translation reset leaves the dictation key unchanged")
    settings.translationShortcut = .disabled
    _ = settings.resetTriggerKey()
    check(settings.translationShortcut == .disabled, "Dictation reset leaves disabled translation unchanged")
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
    print("PASS \(assertions) dictation key and translation shortcut persistence, reset and isolation assertions")
    return assertions
}
