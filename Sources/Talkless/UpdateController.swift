import AppKit
import Combine
import Sparkle

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case beta

    var id: String { rawValue }
    var title: String { self == .stable ? L10n.tr("Stable") : L10n.tr("Beta") }
}

/// Owns Sparkle's standard UI without starting an updater in unconfigured development builds.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, NSMenuItemValidation {
    private var standardController: SPUStandardUpdaterController?
    private let windowPlacement = UpdateWindowPlacement { window in
        guard let controller = window.windowController else { return false }
        return Bundle(for: type(of: controller)) == Bundle(for: SPUStandardUpdaterController.self)
    }
    private let isDictationActive: () -> Bool
    private let configuredFeeds: [UpdateChannel: String]?
    private let defaults: UserDefaults
    private var startupError: Error?
    private let version: String?
    private let build: String?
    @Published private(set) var lastUpdateError: Error?
    /// Latest version found by a silent check. Installing always starts a fresh check, so a
    /// prompt found hours earlier can never install an intermediate release.
    @Published private(set) var availableUpdateVersion: String?
    private var cancellables: Set<AnyCancellable> = []
    private var automaticCheckTimer: AnyCancellable?
    typealias AutomaticCheckScheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> AnyCancellable
    private let scheduleAutomaticCheck: AutomaticCheckScheduler
    private static let channelPreferenceKey = "TalklessUpdateChannel"
    private static let automaticChecksPreferenceKey = "TalklessAutomaticallyChecksForUpdates"
    /// How often the timer wakes to see whether a check is due; cheap, makes no request.
    static let automaticCheckTick: TimeInterval = 30 * 60
    /// Beta ships often, so it is checked every 6 hours; Stable every 48 hours.
    static func automaticCheckInterval(for channel: UpdateChannel) -> TimeInterval {
        channel == .beta ? 6 * 60 * 60 : 48 * 60 * 60
    }
    private let now: () -> Date
    @Published private(set) var channel: UpdateChannel
    @Published private(set) var automaticallyChecksForUpdates: Bool

    init(
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard,
        scheduleAutomaticCheck: @escaping AutomaticCheckScheduler = UpdateController.makeAutomaticCheckTimer,
        now: @escaping () -> Date = Date.init,
        isDictationActive: @escaping () -> Bool
    ) {
        self.now = now
        self.isDictationActive = isDictationActive
        self.defaults = defaults
        self.scheduleAutomaticCheck = scheduleAutomaticCheck
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let bundleDefault = UpdateChannel(rawValue: bundle.object(forInfoDictionaryKey: "TalklessDefaultUpdateChannel") as? String ?? "") ?? .stable
        channel = defaults.string(forKey: Self.channelPreferenceKey).flatMap(UpdateChannel.init(rawValue:)) ?? bundleDefault
        // Preserve the old Sparkle preference once, before disabling its scheduler.
        // Sparkle clamps its own cadence to one hour, so Talkless owns the half-hour timer.
        automaticallyChecksForUpdates = defaults.object(forKey: Self.automaticChecksPreferenceKey) as? Bool
            ?? defaults.object(forKey: "SUEnableAutomaticChecks") as? Bool
            ?? bundle.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool
            ?? true
        configuredFeeds = Self.validatedFeeds(in: bundle)
        super.init()

        guard configuredFeeds != nil else { return }
        // The initial channel belongs to this installation, not the next downloaded bundle.
        defaults.set(channel.rawValue, forKey: Self.channelPreferenceKey)
        defaults.set(automaticallyChecksForUpdates, forKey: Self.automaticChecksPreferenceKey)

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        // Keep Sparkle's standard notice/download/install UI and signature verification,
        // but never run a second scheduler or silently download/install an update.
        controller.updater.automaticallyChecksForUpdates = false
        controller.updater.automaticallyDownloadsUpdates = false
        do {
            // Start the underlying updater directly so packaging errors become menu status,
            // not Sparkle's delayed startup error dialog.
            try controller.updater.start()
            standardController = controller
            controller.updater.publisher(for: \.canCheckForUpdates).map { _ in () }
                .merge(with: controller.updater.publisher(for: \.sessionInProgress).map { _ in () })
                .merge(with: controller.updater.publisher(for: \.lastUpdateCheckDate).map { _ in () })
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
            restartAutomaticCheckTimer()
        } catch {
            startupError = error
        }
    }

    func makeMenuItem() -> NSMenuItem {
        let title = availableUpdateVersion.map { L10n.format("Update to %@…", $0) } ?? L10n.tr("Check for Updates…")
        let item = NSMenuItem(title: title, action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = canCheckForUpdates
        item.toolTip = status
        return item
    }

    var installedVersion: String {
        guard let version, !version.isEmpty else { return L10n.tr("Development build") }
        guard let build, !build.isEmpty else { return version }
        return L10n.format("%@ (build %@)", version, build)
    }

    var isUpdateSessionInProgress: Bool { standardController?.updater.sessionInProgress ?? false }

    /// Sparkle records attempted checks, not a guarantee that the installed version is current.
    var lastUpdateCheckDate: Date? { standardController?.updater.lastUpdateCheckDate }

    var checkForUpdatesTitle: String {
        guard isUpdateSessionInProgress else {
            return availableUpdateVersion.map { L10n.format("Update to %@…", $0) } ?? L10n.tr("Check for updates…")
        }
        // Sparkle permits a manual check to bring its existing update window back into focus.
        return canCheckForUpdates ? L10n.tr("Show update…") : L10n.tr("Update in progress…")
    }

    var status: String? {
        if configuredFeeds == nil { return L10n.tr("Updates are not configured for this build.") }
        if let startupError { return L10n.format("Updates are unavailable: %@", startupError.localizedDescription) }
        if isDictationActive() { return L10n.tr("Updates are paused during dictation.") }
        if isUpdateSessionInProgress { return L10n.tr("An update is in progress. Continue in the update window.") }
        if lastUpdateError != nil { return L10n.tr("The last update attempt failed. Check again to retry.") }
        return nil
    }

    var canCheckForUpdates: Bool {
        !isDictationActive() && (standardController?.updater.canCheckForUpdates ?? false)
    }

    var canChangeChannel: Bool {
        guard let updater = standardController?.updater else { return false }
        return !updater.sessionInProgress
    }

    func selectChannel(_ newChannel: UpdateChannel) {
        guard channel != newChannel, canChangeChannel else { return }
        channel = newChannel
        lastUpdateError = nil
        availableUpdateVersion = nil
        defaults.set(newChannel.rawValue, forKey: Self.channelPreferenceKey)
        // The next check uses the new feed. Do not reset Sparkle's cycle here:
        // a changed feed can force a background check even with automatic checks off.
        restartAutomaticCheckTimer()
    }

    var canChangeAutomaticChecks: Bool { standardController != nil }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard canChangeAutomaticChecks, automaticallyChecksForUpdates != enabled else { return }
        automaticallyChecksForUpdates = enabled
        defaults.set(enabled, forKey: Self.automaticChecksPreferenceKey)
        restartAutomaticCheckTimer()
    }

    private func restartAutomaticCheckTimer() {
        automaticCheckTimer = nil
        guard automaticallyChecksForUpdates, standardController != nil else { return }
        automaticCheckTimer = scheduleAutomaticCheck(Self.automaticCheckTick) { [weak self] in
            self?.checkForUpdatesAutomatically()
        }
    }

    private static func makeAutomaticCheckTimer(
        interval: TimeInterval, action: @escaping @MainActor () -> Void
    ) -> AnyCancellable {
        Timer.publish(every: interval, on: .main, in: .common)
            .autoconnect()
            .sink { _ in action() }
    }

    private func checkForUpdatesAutomatically() {
        guard automaticallyChecksForUpdates, canCheckForUpdates,
              let updater = standardController?.updater, !updater.sessionInProgress else { return }
        // Sparkle records every attempt; wait for the channel's interval since the last one.
        if let last = updater.lastUpdateCheckDate,
           now().timeIntervalSince(last) < Self.automaticCheckInterval(for: channel) { return }
        // Probe only: Sparkle's background prompt keeps the item it found, so a window left
        // open while newer Betas ship would install a stale version. Clicking update re-fetches.
        updater.checkForUpdateInformation()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        canCheckForUpdates
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard canCheckForUpdates else { return }
        windowPlacement.begin(sourceWindow: sender as? NSWindow)
        standardController?.checkForUpdates(sender)
        // Bringing an already-key update forward does not send didBecomeKey again.
        if let window = NSApp.keyWindow { windowPlacement.position(window) }
    }

    func standardUserDriverWillShowModalAlert() { windowPlacement.willShowModalAlert() }
    func standardUserDriverDidShowModalAlert() { windowPlacement.didShowModalAlert() }
    func standardUserDriverWillFinishUpdateSession() { windowPlacement.finish() }

    // Always use the selected, validated bundle URL, not an old user-default feed override.
    func feedURLString(for updater: SPUUpdater) -> String? {
        configuredFeeds?[channel]
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel == .beta ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error = error as NSError?,
           !(error.domain == SUSparkleErrorDomain && [SUError.noUpdateError, .installationCanceledError, .installationAuthorizeLaterError].contains(where: { Int($0.rawValue) == error.code })) {
            lastUpdateError = error
        } else {
            // No update, skipping, and cancelling installation are not failed checks.
            lastUpdateError = nil
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableUpdateVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableUpdateVersion = nil
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        lastUpdateError = nil
        try requireIdleDictation()
        if updateCheck != .updates, !automaticallyChecksForUpdates {
            throw NSError(
                domain: "Talkless.Update",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: L10n.tr("Automatic update checks are turned off. Use Check for Updates to check manually.")]
            )
        }
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        try requireIdleDictation()
        if let itemChannel = updateItem.channel, !allowedChannels(for: updater).contains(itemChannel) {
            throw NSError(
                domain: "Talkless.Update",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: L10n.tr("This update is not available on the selected update channel. Please check for updates again.")]
            )
        }
    }

    func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
        guard !isDictationActive() else {
            // Sparkle checks this immediately before installation, including resumed installs.
            // Returning false aborts the install attempt; it does not queue a silent relaunch.
            Self.showDictationBusyAlert()
            return false
        }
        return true
    }

    static func showDictationBusyAlert() {
        let alert = NSAlert()
        alert.messageText = L10n.tr("Finish Dictation First")
        alert.informativeText = L10n.tr("Talkless will not quit or install an update while recording or processing speech. Finish dictation, then try again.")
        alert.addButton(withTitle: L10n.tr("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func requireIdleDictation() throws {
        if isDictationActive() {
            throw NSError(
                domain: "Talkless.Update",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: L10n.tr("Updates are paused while Talkless records or processes speech. Please try again after dictation finishes.")]
            )
        }
    }

    private static func validatedFeeds(in bundle: Bundle) -> [UpdateChannel: String]? {
        guard bundle.bundleURL.pathExtension == "app",
              let stable = validatedFeedURL(bundle.object(forInfoDictionaryKey: "SUFeedURL")),
              let beta = validatedFeedURL(bundle.object(forInfoDictionaryKey: "SUBetaFeedURL")),
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let keyData = Data(base64Encoded: key.trimmingCharacters(in: .whitespacesAndNewlines)),
              keyData.count == 32 else {
            return nil
        }
        return [.stable: stable, .beta: beta]
    }

    private static func validatedFeedURL(_ value: Any?) -> String? {
        guard let feed = value as? String,
              !feed.contains("$("), !feed.contains("${"),
              let components = URLComponents(string: feed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil,
              let url = components.url else {
            return nil
        }
        return url.absoluteString
    }
}
