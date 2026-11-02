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
        let history = HistoryStore(url: directory.appendingPathComponent("history.json"), activity: activity)
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
            let narrow = render(HistoryView(history: history, activity: activity), size: NSSize(width: 604, height: 900))
            #expect(sidebar.count > 2_000 && page.count > 2_000)
            if let output {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try sidebar.write(to: output.appendingPathComponent("sidebar-\(suffix).png"))
                try page.write(to: output.appendingPathComponent("history-\(suffix).png"))
                try narrow.write(to: output.appendingPathComponent("history-narrow-\(suffix).png"))
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

    @Test func guideEmbedsRecordingControls() throws {
        let actions = SetupGuideActions(refresh: {}, requestMicrophone: {}, openMicrophoneSettings: {},
            requestAccessibility: {}, openAccessibilitySettings: {}, openSpeechSettings: {}, openAISettings: {},
            enablePolish: {}, finish: {}, skipSetup: {}, setLaunchAtLogin: { _ in }, openLoginItems: {})
        let state = SetupGuideState()
        for mode in RecordingGestureMode.allCases {
            var key = TriggerKey.rightCommand
            var selectedMode = mode
            let controls = Form {
                RecordingSettingsSection(mode: Binding(get: { selectedMode }, set: { selectedMode = $0 }),
                    triggerKey: Binding(get: { key }, set: { key = $0 }),
                    setCaptureActive: { _ in true }, resetKey: { nil })
            }.formStyle(.grouped).scrollDisabled(true).frame(height: 280)
            let guide = SetupGuideView(state: state, actions: actions, controlsSetup: AnyView(controls), initialStep: .controls)
            #expect(guide.controlsSetup != nil)
            let image = render(guide, size: NSSize(width: 600, height: 640))
            #expect(image.count > 2_000)
            #expect(selectedMode == mode && key == .rightCommand, "Rendering never changes shortcut preferences")
        }
    }

    @Test func rendersSettingsPagesWithoutServices() throws {
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Sources/Talkless/Resources").standardizedFileURL
        L10n.useCatalog(LocalizationCatalog(bundle: Bundle(url: resources)))
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        defer { localization.interfaceLanguage = .english; withExtendedLifetime(localization) {} }
        let suite = "talkless-layout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, credentialStore: LayoutCredentials())
        settings.audioInputDeviceUID = "test-mic"
        settings.dictionary = "Talkless\nSwiftUI"
        settings.dictionaryReplacements = [DictionaryReplacement(heard: "talk less", term: "Talkless")]
        for second in 0..<2 {
            settings.learnFromDictation(raw: "Please open Notian before our meeting.", output: "Please open Notion before our meeting.",
                                        fired: [], at: Date() - Double(3_600 * 26 + second))
        }
        settings.learnFromDictation(raw: "Use Figmer here.", output: "Use Figma here.", fired: [], at: Date())
        let customSuite = "\(suite)-custom"
        let customDefaults = UserDefaults(suiteName: customSuite)!
        defer { customDefaults.removePersistentDomain(forName: customSuite) }
        let customSettings = AppSettings(defaults: customDefaults, credentialStore: LayoutCredentials())
        customSettings.selectPolishProvider(.custom)
        let output = ProcessInfo.processInfo.environment["TALKLESS_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        for language in [InterfaceLanguage.english, .simplifiedChinese] {
            localization.interfaceLanguage = language
            for dark in [false, true] {
                let views: [(String, AnyView)] = [
                    ("audio", AnyView(Form {
                        AudioInputSettingsView(settings: settings, loadDevices: {
                            [AudioInputDevice(id: 1, uid: "test-mic", name: "USB Microphone with a deliberately long device name")]
                        })
                        RecordingSettingsSection(mode: .constant(.toggle), triggerKey: .constant(.rightCommand),
                                                 setCaptureActive: { _ in true }, resetKey: { nil })
                        DictationProcessingSettingsView(settings: settings, onConfigureAI: {})
                    }.formStyle(.grouped))),
                    ("ai-service", AnyView(AIServiceSettingsView(settings: settings))),
                    ("ai-service-custom", AnyView(AIServiceSettingsView(settings: customSettings))),
                    ("doubao", AnyView(Form {
                        Section { RecognitionEngineChooser(engine: .constant(.doubao)) }
                        DoubaoSettingsSection(settings: settings)
                    }.formStyle(.grouped))),
                    ("model", AnyView(Form {
                        Section(L10n.tr("Speech models")) {
                            ModelDownloadCard(entry: ModelEntry(model: ModelCatalog.models[0], phase: .installed),
                                              isInUse: true, preparationStatus: L10n.tr("Ready · kept in memory")) {
                                Button(L10n.tr("Delete…"), role: .destructive) {}
                            }
                            ModelDownloadCard(entry: ModelEntry(model: ModelCatalog.models[0], phase: .failed,
                                                               error: "Synthetic download failure; retry or select another source."),
                                              isInUse: false) {
                                Button(L10n.tr("Delete…"), role: .destructive) {}
                                Button(L10n.tr("Retry")) {}.buttonStyle(.borderedProminent)
                            }
                        }
                    }.formStyle(.grouped))),
                    ("system-controls", AnyView(Form {
                        Section(L10n.tr("Permissions")) {
                            PermissionRow(title: L10n.tr("Accessibility"), detail: L10n.tr("Keyboard shortcuts and text insertion"),
                                          granted: false, action: {})
                            PermissionRow(title: L10n.tr("Microphone"), detail: L10n.tr("Record your voice"),
                                          granted: true, action: {})
                        }
                        Section(L10n.tr("Startup")) {
                            LaunchAtLoginControls(presentation: LaunchAtLoginPresentation(), setEnabled: { _ in }, openLoginItems: {})
                        }
                        DiagnosticsSection()
                    }.formStyle(.grouped))),
                    ("languages-sheet", AnyView(PreferredTranslationLanguagesView(preferredLanguageIDs: ["en", "zh-Hans"]) { _ in })),
                    ("translation", AnyView(TranslationSettingsView(settings: settings, isBusy: false,
                        shortcutError: nil, setCaptureActive: { _ in true }, onConfigureAI: {}))),
                    ("processing", AnyView(Form {
                        DictationProcessingSettingsView(settings: settings, onConfigureAI: {})
                    }.formStyle(.grouped))),
                    ("dictionary", AnyView(DictionaryView(settings: settings).padding(28))),
                    ("term-editor", AnyView(DictionaryTermEditor(original: "Talkless", settings: settings) { _ in })),
                    ("overlay", AnyView(OverlaySettingsView(appearance: .constant(HUDAppearance())))),
                ]
                for (name, view) in views {
                    let png = render(view, size: NSSize(width: 604, height: 850), dark: dark)
                    #expect(png.count > 2_000)
                    if let output {
                        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                        try png.write(to: output.appendingPathComponent("\(name)-\(language.rawValue)-\(dark ? "dark" : "light").png"))
                    }
                }
            }
        }
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

/// Never touches Keychain or production preferences during layout review.
@MainActor private struct LayoutCredentials: CredentialStoring {
    func credential(for provider: PolishProvider) throws -> String? { nil }
    func setCredential(_ value: String, for provider: PolishProvider) throws {}
    func doubaoCredential() throws -> String? { nil }
    func setDoubaoCredential(_ value: String) throws {}
}
