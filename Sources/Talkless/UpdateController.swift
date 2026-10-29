import AppKit
import Combine
import Sparkle

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case beta

    var id: String { rawValue }
    var title: String { self == .stable ? "Stable" : "Beta" }
}

/// Owns Sparkle's standard UI without starting an updater in unconfigured development builds.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, NSMenuItemValidation {
    private var standardController: SPUStandardUpdaterController?
    private let isDictationActive: () -> Bool
    private let configuredFeeds: [UpdateChannel: String]?
    private let defaults: UserDefaults
    private var unavailableReason: String?
    private var cancellables: Set<AnyCancellable> = []
    private static let channelPreferenceKey = "TalklessUpdateChannel"
    @Published private(set) var channel: UpdateChannel

    init(bundle: Bundle = .main, defaults: UserDefaults = .standard, isDictationActive: @escaping () -> Bool) {
        self.isDictationActive = isDictationActive
        self.defaults = defaults
        let bundleDefault = UpdateChannel(rawValue: bundle.object(forInfoDictionaryKey: "TalklessDefaultUpdateChannel") as? String ?? "") ?? .stable
        channel = defaults.string(forKey: Self.channelPreferenceKey).flatMap(UpdateChannel.init(rawValue:)) ?? bundleDefault
        configuredFeeds = Self.validatedFeeds(in: bundle)
        super.init()

        guard configuredFeeds != nil else {
            unavailableReason = "Updates are not configured for this build."
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        do {
            // Start the underlying updater directly so packaging errors become menu status,
            // not Sparkle's delayed startup error dialog.
            try controller.updater.start()
            standardController = controller
            controller.updater.publisher(for: \.canCheckForUpdates)
                .merge(with: controller.updater.publisher(for: \.sessionInProgress))
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        } catch {
            unavailableReason = "Updates are unavailable: \(error.localizedDescription)"
        }
    }

    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.target = self
        item.isEnabled = canCheckForUpdates
        item.toolTip = status
        return item
    }

    var status: String? {
        if let unavailableReason { return unavailableReason }
        if isDictationActive() { return "Updates are paused during dictation." }
        return nil
    }

    var canCheckForUpdates: Bool {
        !isDictationActive() && (standardController?.updater.canCheckForUpdates ?? false)
    }

    var canChangeChannel: Bool {
        !(standardController?.updater.sessionInProgress ?? false)
    }

    func selectChannel(_ newChannel: UpdateChannel) {
        guard channel != newChannel, canChangeChannel else { return }
        channel = newChannel
        defaults.set(newChannel.rawValue, forKey: Self.channelPreferenceKey)
        // Sparkle may schedule a check for the new feed; switching never requests installation.
        standardController?.updater.resetUpdateCycle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        canCheckForUpdates
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard canCheckForUpdates else { return }
        standardController?.checkForUpdates(sender)
    }

    // Always use the selected, validated bundle URL, not an old user-default feed override.
    func feedURLString(for updater: SPUUpdater) -> String? {
        configuredFeeds?[channel]
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channel == .beta ? ["beta"] : []
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try requireIdleDictation()
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        try requireIdleDictation()
        if let itemChannel = updateItem.channel, !allowedChannels(for: updater).contains(itemChannel) {
            throw NSError(
                domain: "Talkless.Update",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "This update is not available on the selected update channel. Please check for updates again."]
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
        alert.messageText = "Finish Dictation First"
        alert.informativeText = "Talkless will not quit or install an update while recording or processing speech. Finish dictation, then try again."
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }

    private func requireIdleDictation() throws {
        if isDictationActive() {
            throw NSError(
                domain: "Talkless.Update",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Updates are paused while Talkless records or processes speech. Please try again after dictation finishes."]
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
