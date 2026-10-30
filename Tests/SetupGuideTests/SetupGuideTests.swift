import Foundation

@main
struct SetupGuideTests {
    @MainActor static func main() throws {
        try withStore { defaults, support in
            let before = defaults.dictionaryRepresentation() as NSDictionary
            let guide = SetupGuideController(defaults: defaults, supportDirectory: support)
            precondition(guide.shouldPresentOnLaunch && guide.completion == nil && !guide.isPresented)
            precondition(before.isEqual(to: defaults.dictionaryRepresentation()), "Detection must not write preferences")
            precondition(!FileManager.default.fileExists(atPath: support.path), "Detection must not create directories")
            guide.present()
            precondition(guide.isPresented && defaults.object(forKey: SetupGuideController.completionKey) == nil)
            precondition(before.isEqual(to: defaults.dictionaryRepresentation()), "Presentation is not completion")
            guide.beginFirstLaunchIfNeeded()
            precondition(defaults.bool(forKey: SetupGuideController.enrollmentKey))
            precondition(defaults.object(forKey: SetupGuideController.completionKey) == nil)
            // Simulate AppSettings' eager defaults migration after enrollment.
            defaults.set(Data("default provider configuration".utf8), forKey: "polishProviderSettings.v1")
            let interrupted = SetupGuideController(defaults: defaults, supportDirectory: support)
            precondition(interrupted.shouldPresentOnLaunch, "Crash/quit before dismissal must resume onboarding")
            interrupted.complete()
            precondition(interrupted.completion == .completed && !interrupted.shouldPresentOnLaunch && !interrupted.isPresented)
            let relaunched = SetupGuideController(defaults: defaults, supportDirectory: support)
            precondition(!relaunched.shouldPresentOnLaunch && relaunched.completion == .completed)
            let completedPreferences = defaults.dictionaryRepresentation() as NSDictionary
            relaunched.present()
            precondition(relaunched.isPresented && !relaunched.shouldPresentOnLaunch)
            precondition(completedPreferences.isEqual(to: defaults.dictionaryRepresentation()), "Manual reopen does not reset anything")
            relaunched.skip()
            precondition(relaunched.completion == .completed, "Closing a reopened completed guide does not downgrade completion")
            precondition(completedPreferences.isEqual(to: defaults.dictionaryRepresentation()))
        }
        print("PASS fresh install, read-only detection, crash resume, completion, relaunch and manual reopen")

        try withStore { defaults, support in
            defaults.set("preserve", forKey: "unrelatedPreference")
            let guide = SetupGuideController(defaults: defaults, supportDirectory: support)
            guide.beginFirstLaunchIfNeeded()
            guide.present()
            guide.skip()
            precondition(!guide.shouldPresentOnLaunch && !guide.isPresented && guide.completion == .dismissed)
            let relaunched = SetupGuideController(defaults: defaults, supportDirectory: support)
            precondition(!relaunched.shouldPresentOnLaunch && relaunched.completion == .dismissed)
            relaunched.present()
            precondition(relaunched.completion == .dismissed)
            relaunched.complete()
            precondition(relaunched.completion == .completed)
            precondition(defaults.string(forKey: "unrelatedPreference") == "preserve")
        }
        print("PASS explicit skip/window dismissal persists and later completion is allowed")

        for marker in [SetupGuideController.Completion.completed, .dismissed] {
            try withStore { defaults, support in
                defaults.set(marker.rawValue, forKey: SetupGuideController.completionKey)
                let before = defaults.dictionaryRepresentation() as NSDictionary
                let guide = SetupGuideController(defaults: defaults, supportDirectory: support)
                guide.beginFirstLaunchIfNeeded()
                precondition(!guide.shouldPresentOnLaunch && guide.completion == marker,
                             "Completion/skip alone survives absent legacy preferences and enrollment")
                precondition(before.isEqual(to: defaults.dictionaryRepresentation()))
            }
        }
        try withStore { defaults, support in
            defaults.set("future-or-corrupt-value", forKey: SetupGuideController.completionKey)
            defaults.set(true, forKey: SetupGuideController.enrollmentKey)
            defaults.set(false, forKey: "polishEnabled")
            let guide = SetupGuideController(defaults: defaults, supportDirectory: support)
            precondition(guide.shouldPresentOnLaunch, "Unknown completion must not strand enrolled first-run setup")
        }
        print("PASS standalone completion/skip markers and interrupted migration recovery")

        for key in ["polishProviderSettings.v1", "translationLanguages.v1", "triggerKey", "asrEngine", "managedModelID", "interfaceLanguage"] {
            try withStore { defaults, support in
                defaults.set("existing value", forKey: key)
                defaults.set("secret sentinel", forKey: "llmAPIKey")
                let before = defaults.dictionaryRepresentation() as NSDictionary
                let guide = SetupGuideController(defaults: defaults, supportDirectory: support)
                precondition(!guide.shouldPresentOnLaunch, "Legacy preference must suppress onboarding: \(key)")
                guide.beginFirstLaunchIfNeeded()
                guide.present()
                precondition(before.isEqual(to: defaults.dictionaryRepresentation()), "Legacy detection/reopen must preserve settings")
                precondition(guide.completion == nil)
            }
        }
        try withStore { defaults, support in
            defaults.set(false, forKey: "polishEnabled")
            precondition(!SetupGuideController(defaults: defaults, supportDirectory: support).shouldPresentOnLaunch,
                         "An explicitly stored false is still evidence of an existing installation")
        }
        try withStore { defaults, support in
            defaults.set(["en"], forKey: "AppleLanguages")
            defaults.set(true, forKey: "SUHasLaunchedBefore")
            precondition(SetupGuideController(defaults: defaults, supportDirectory: support).shouldPresentOnLaunch,
                         "System/Sparkle preferences alone do not prove prior Talkless setup")
        }
        print("PASS legacy preference detection preserves user settings and ignores unrelated defaults")

        for path in ["history.json", "activity.json", "Models/test-model/config.json", "Models/.test-model.staging/model.part"] {
            try withStore { defaults, support in
                let file = support.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                let sentinel = Data("not parsed or changed".utf8)
                try sentinel.write(to: file)
                let guide = SetupGuideController(defaults: defaults, supportDirectory: support)
                precondition(!guide.shouldPresentOnLaunch, "Existing local history/model state must suppress onboarding: \(path)")
                guide.present()
                let after = try Data(contentsOf: file)
                precondition(after == sentinel)
                precondition(defaults.object(forKey: SetupGuideController.completionKey) == nil)
            }
        }
        try withStore { defaults, support in
            let models = support.appendingPathComponent("Models")
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            try Data().write(to: models.appendingPathComponent(".DS_Store"))
            precondition(SetupGuideController(defaults: defaults, supportDirectory: support).shouldPresentOnLaunch,
                         "Empty directories and Finder metadata are not user setup")
        }
        print("PASS read-only history, installed/paused model detection, empty-directory handling")
        print("All setup guide persistence tests passed using isolated preferences and temporary files.")
    }

    @MainActor private static func withStore(_ body: (UserDefaults, URL) throws -> Void) throws {
        let suite = "Talkless.SetupGuideTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        try body(defaults, root.appendingPathComponent("Talkless", isDirectory: true))
    }
}
