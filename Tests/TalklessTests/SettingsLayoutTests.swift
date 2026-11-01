import AppKit
import SwiftUI
import Testing
@testable import Talkless

@MainActor
@Suite struct SettingsLayoutTests {
    @Test func everyPageAppearsInExactlyOneSidebarGroup() {
        let grouped = SettingsSection.groups.flatMap(\.sections)
        #expect(grouped == SettingsSection.allCases, "Groups follow page order and include every page once")
        #expect(SettingsSection.groups.first?.sections.first == .dictation, "Dictation is the first page")
        #expect(grouped.firstIndex(of: .translation)! > grouped.firstIndex(of: .aiService)!,
                "Translation follows the voice-input pages")
    }

    /// Renders with synthetic data. Set TALKLESS_SNAPSHOT_DIR to save PNGs for review.
    @Test func rendersSidebarAndHistory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("talkless-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let activity = DictationActivityStore(url: directory.appendingPathComponent("activity.json"))
        let history = HistoryStore(url: directory.appendingPathComponent("history.json"), activity: activity,
                                   observeDictionaryReview: false)
        let now = Date()
        let calendar = Calendar.current
        func entry(_ kind: HistoryEntry.Kind, _ app: String, _ raw: String, _ output: String, daysAgo: Int, minutes: Int) -> HistoryEntry {
            let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
            var entry = HistoryEntry(kind: kind, app: app, raw: raw, output: output, duration: 4)
            entry.date = calendar.date(byAdding: .minute, value: -minutes, to: day)!
            return entry
        }
        for item in [
            entry(.translation, "Safari", "Let's ship the beta tonight.", "\u{4ECA}\u{665A}\u{53D1}\u{5E03} Beta \u{7248}\u{3002}", daysAgo: 2, minutes: 30),
            entry(.dictation, "Notes", "um so the meeting is moved to friday", "The meeting is moved to Friday.", daysAgo: 1, minutes: 50),
            entry(.edit, "Mail", "make it shorter", "Thanks, see you Friday.", daysAgo: 0, minutes: 90),
            entry(.dictation, "Slack", "open talk less and start dictating", "Open Talkless and start dictating.", daysAgo: 0, minutes: 5),
        ] { history.add(item) }
        history.flush()

        let output = ProcessInfo.processInfo.environment["TALKLESS_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Talkless/Resources").standardizedFileURL
        L10n.useCatalog(LocalizationCatalog(bundle: Bundle(url: resources)))
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        defer { localization.interfaceLanguage = .english; withExtendedLifetime(localization) {} }
        for language in [InterfaceLanguage.english, .simplifiedChinese] {
            localization.interfaceLanguage = language
            let suffix = language == .english ? "en" : "zh"
            let sidebar = render(SettingsSidebar(selection: .constant(.dictation)), size: NSSize(width: 196, height: 470))
            let page = render(HistoryView(history: history, activity: activity), size: NSSize(width: 704, height: 900))
            #expect(sidebar.count > 2_000 && page.count > 2_000)
            if let output {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try sidebar.write(to: output.appendingPathComponent("sidebar-\(suffix).png"))
                try page.write(to: output.appendingPathComponent("history-\(suffix).png"))
            }
        }
    }

    @Test func rendersRecordingControls() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Talkless/Resources").standardizedFileURL
        L10n.useCatalog(LocalizationCatalog(bundle: Bundle(url: resources)))
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        defer { localization.interfaceLanguage = .english; withExtendedLifetime(localization) {} }
        let output = ProcessInfo.processInfo.environment["TALKLESS_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        for language in [InterfaceLanguage.english, .simplifiedChinese] {
            localization.interfaceLanguage = language
            for width in [604, 704] {
                for dark in [false, true] {
                    let view = Form {
                        RecordingSettingsSection(mode: .constant(.toggle), triggerKey: .constant(.rightCommand),
                                                 setCaptureActive: { _ in true }, resetKey: { nil })
                    }.formStyle(.grouped)
                    let png = render(view, size: NSSize(width: width, height: 300), dark: dark)
                    #expect(png.count > 2_000)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        let name = "recording-\(language.rawValue)-\(width)-\(dark ? "dark" : "light").png"
                        try png.write(to: output.appendingPathComponent(name))
                    }
                }
            }
        }
        #expect(SettingsControlLayout.valueWidth + SettingsControlLayout.resetWidth < 300)
    }

    private func render(_ view: some View, size: NSSize, dark: Bool = false) -> Data {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
        host.frame = NSRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        // Native lists draw rows only inside a window; keep it far off screen.
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        host.displayIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])!
    }
}
