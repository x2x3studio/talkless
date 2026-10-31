import AppKit
import SwiftUI

// No real updater, app settings, permissions, login items, audio or network.
@MainActor final class DictationController: ObservableObject {
    enum State { case idle, recording, processing }
    @Published var state = State.idle
}

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable, beta
    var id: Self { self }
    var title: String { L10n.tr(self == .stable ? "Stable" : "Beta") }
}

@MainActor final class UpdateController: ObservableObject {
    @Published var channel = UpdateChannel.beta
    @Published var automaticallyChecksForUpdates = true
    @Published var canChangeChannel = true
    @Published var canChangeAutomaticChecks = true
    @Published var canCheckForUpdates = true
    @Published var lastUpdateCheckDate: Date?
    @Published var status: String?
    @Published var checkForUpdatesTitle = L10n.tr("Check for updates…")
    var installedVersion: String { L10n.format("%@ (build %@)", "0.0.0-test", "42") }
    var calls: [String] = []
    func selectChannel(_ channel: UpdateChannel) { calls.append("channel"); self.channel = channel }
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) { calls.append("automatic"); automaticallyChecksForUpdates = enabled }
    func checkForUpdates(_ sender: Any?) { calls.append("check") }
}

@main struct AboutSettingsTests {
    @MainActor static func main() throws {
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        defer { withExtendedLifetime(localization) {} }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller = DictationController()
        let updater = UpdateController()
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            precondition(condition(), message)
        }
        check(SettingsSection.allCases.map(\.rawValue) == ["dictation", "models", "dictionary", "aiService", "overlay", "history", "translation", "system", "about"],
              "About appends without changing existing section raw values/order")
        check(SettingsSection.about.symbol == "info.circle", "About uses a native information symbol")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 604, height: 570),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Talkless About — Synthetic preview"
        func render(_ injectedUpdater: UpdateController?, dark: Bool = false) -> Data {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let root = AnyView(AboutSettingsTab(controller: controller, updateController: injectedUpdater)
                .environment(\.locale, localization.locale))
            let hosting = NSHostingView(rootView: root)
            window.contentView = hosting
            window.setContentSize(NSSize(width: 604, height: 570))
            window.orderFrontRegardless()
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let image = bitmap.representation(using: .png, properties: [:])!
            check(image.count > 5_000, "Native grouped form renders substantive content")
            check(updater.calls.isEmpty, "Rendering About never invokes updater actions or writes preferences")
            return image
        }
        var localizedImages: [Data] = []
        for language in [InterfaceLanguage.english, .simplifiedChinese] {
            localization.interfaceLanguage = language
            check(SettingsSection.about.title == (language == .english ? "About" : "\u{5173}\u{4E8E}"), "About title localizes")
            check(SettingsSection.about.subtitle == L10n.tr("Version, updates, and project information."), "About explains its contents")
            check(SettingsSection.system.subtitle == L10n.tr("Permissions, language, startup, and troubleshooting."), "System no longer advertises updates")
            check(L10n.tr("Voice input for macOS.") == (language == .english ? "Voice input for macOS." : "macOS \u{8BED}\u{97F3}\u{8F93}\u{5165}。"), "Product description localizes")
            for dark in [false, true] {
                updater.checkForUpdatesTitle = L10n.tr("Check for updates…")
                let image = render(updater, dark: dark)
                if !dark { localizedImages.append(image) }
                if let index = CommandLine.arguments.firstIndex(of: "--snapshots"), CommandLine.arguments.indices.contains(index + 1) {
                    let directory = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try image.write(to: directory.appendingPathComponent("about-\(language.rawValue)-\(dark ? "dark" : "light").png"))
                }
            }
            let fallback = render(nil)
            check(fallback != localizedImages.last!, "Missing updater renders the unavailable metadata-only fallback")
        }
        check(localizedImages[0] != localizedImages[1], "English and Chinese produce distinct localized renders")
        localization.interfaceLanguage = .english
        updater.status = "Synthetic update status"
        updater.lastUpdateCheckDate = Date(timeIntervalSince1970: 1_700_000_000)
        updater.canChangeChannel = false
        updater.canChangeAutomaticChecks = false
        updater.canCheckForUpdates = false
        updater.checkForUpdatesTitle = "Update in progress…"
        _ = render(updater)
        updater.canChangeAutomaticChecks = true
        _ = render(updater)
        updater.canCheckForUpdates = true
        for state in [DictationController.State.recording, .processing] {
            controller.state = state
            _ = render(updater)
        }
        check(updater.calls.isEmpty, "Every state renders without an update check or preference changes")
        window.orderOut(nil)
        print("PASS \(assertions) About localization, native light/dark rendering, unavailable fallback, and side-effect-free updater state assertions")
    }
}
