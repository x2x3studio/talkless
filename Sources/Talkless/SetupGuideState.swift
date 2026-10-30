import Combine
import Foundation

extension Notification.Name {
    static let showSetupGuide = Notification.Name("TalklessShowSetupGuide")
}

/// First-run enrollment is captured before AppSettings can persist its defaults.
/// This store never reads credentials, changes product settings, or requests permissions.
@MainActor
final class SetupGuideController: ObservableObject {
    enum Completion: String {
        case completed, dismissed
    }

    static let shared = SetupGuideController()
    static let completionKey = "setupGuide.completion.v1"
    static let enrollmentKey = "setupGuide.started.v1"

    @Published private(set) var completion: Completion?
    @Published private(set) var isPresented = false
    private let defaults: UserDefaults
    private let isEnrolled: Bool

    var shouldPresentOnLaunch: Bool { isEnrolled && completion == nil }

    static var defaultSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Talkless", isDirectory: true)
    }

    init(defaults: UserDefaults = .standard,
         supportDirectory: URL? = SetupGuideController.defaultSupportDirectory) {
        self.defaults = defaults
        completion = defaults.string(forKey: Self.completionKey).flatMap(Completion.init(rawValue:))
        isEnrolled = defaults.bool(forKey: Self.enrollmentKey)
            || !Self.hasExistingInstallation(defaults: defaults, supportDirectory: supportDirectory)
    }

    /// Separate from completion: a crash/quit during setup must not turn the defaults
    /// written by AppSettings into a false legacy-install signal on the next launch.
    /// Call before constructing AppSettings or DictationController, but not for CLI tests.
    func beginFirstLaunchIfNeeded() {
        guard shouldPresentOnLaunch else { return }
        defaults.set(true, forKey: Self.enrollmentKey)
    }

    /// Reopening only changes presentation; it never resets permissions or configuration.
    func present() { isPresented = true }

    func complete() {
        completion = .completed
        defaults.set(Completion.completed.rawValue, forKey: Self.completionKey)
        isPresented = false
    }

    /// The window close button is also an explicit dismissal. Reopening and closing an
    /// already-completed guide does not downgrade its completion marker.
    func skip() {
        if completion != .completed {
            completion = .dismissed
            defaults.set(Completion.dismissed.rawValue, forKey: Self.completionKey)
        }
        isPresented = false
    }

    private static func hasExistingInstallation(defaults: UserDefaults, supportDirectory: URL?) -> Bool {
        // Only app-owned, non-secret keys. Merely having a preference domain (Apple
        // language/window defaults, Sparkle, etc.) is not evidence of an earlier install.
        let preferenceKeys = [
            "polishProviderSettings.v1", "translationLanguages.v1", "translationShortcut.v1",
            "hudAppearance.v1", "recordingGestureMode", "triggerKey", "alternateFinishKey",
            "audioInputDeviceUID", "asrEngine", "qwenModelDirectory", "useCustomQwenDirectory",
            "managedModelID", "speechLocale", "asrBaseURL", "asrModel", "polishEnabled",
            "outputLanguage", "voiceEditEnabled", "appToneEnabled", "translateTarget",
            "dictionary", "dictionaryReviewEnabled", "customInstructions", "llmBaseURL", "llmModel",
            "interfaceLanguage",
        ]
        if preferenceKeys.contains(where: { defaults.object(forKey: $0) != nil }) { return true }
        guard let supportDirectory else { return false }
        let files = FileManager.default
        for name in ["history.json", "activity.json"] {
            if files.fileExists(atPath: supportDirectory.appendingPathComponent(name).path) { return true }
        }
        // Look only at names, including paused downloads. Never load history text or
        // model weights, and don't count an empty automatically-created folder.
        let models = supportDirectory.appendingPathComponent("Models", isDirectory: true)
        let names = (try? files.contentsOfDirectory(atPath: models.path)) ?? []
        return names.contains { $0 != ".DS_Store" }
    }
}
