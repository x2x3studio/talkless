import AppKit
import Combine
import SwiftUI

@main
enum TalklessMain {
    // NSApplication.delegate is weak; retain the delegate in optimized builds too.
    @MainActor private static var retainedDelegate: AppDelegate?

    @MainActor
    static func main() {
        // A hermetic packaging probe, not an application launch. Keep this before
        // NSApplication, diagnostics, settings, permissions, and model initialization.
        if CommandLine.arguments.contains("--verify-bundle") {
            Task {
                let status = await BundleValidation.run()
                exit(status)
            }
            dispatchMain()
        }
        Diagnostics.shared.startSession()
        if LocalizationCatalog.applicationBundle == nil {
            Diagnostics.shared.record(event: "startup_resource_error", metadata: [
                "stage": "startup", "reason": "localization_missing",
            ])
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let setupGuide: SetupGuideController
    private let controller: DictationController
    private let settings: AppSettings
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var setupWindow: NSWindow?
    private var testWindow: NSWindow?
    private var testTextView: NSTextView?
    private var permissionTimer: Timer?
    private var updateController: UpdateController?
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        // AppSettings writes migrated/default preferences during initialization, so
        // capture first-run evidence and enrollment before constructing the controller.
        let guide = SetupGuideController.shared
        if !CommandLine.arguments.contains("--test-audio"),
           !CommandLine.arguments.contains("--test-microphone") {
            guide.beginFirstLaunchIfNeeded()
        }
        setupGuide = guide
        controller = DictationController()
        settings = AppSettings.shared
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = LocalizationSettings.shared
        ApplicationEditMenu.install()
        if CommandLine.arguments.contains("--test-microphone") {
            Task {
                do {
                    let arguments = CommandLine.arguments
                    var repetitions = 1
                    if let index = arguments.firstIndex(of: "--test-repeat") {
                        guard arguments.indices.contains(index + 1), let value = Int(arguments[index + 1]),
                              (1...30).contains(value) else {
                            throw TalklessError.message("--test-repeat requires a value from 1 to 30")
                        }
                        repetitions = value
                    }
                    let deviceUID = arguments.contains("--test-selected-microphone") ? settings.audioInputDeviceUID : nil
                    let count = try await MicrophoneDiagnostic.run(repetitions: repetitions, deviceUID: deviceUID)
                    FileHandle.standardOutput.write(Data("Microphone test passed: \(count) background audio callbacks across \(repetitions) recording(s).\n".utf8))
                    NSApp.terminate(nil)
                } catch {
                    FileHandle.standardError.write(Data("Microphone test failed: \(error.localizedDescription)\n".utf8))
                    Diagnostics.shared.finishSession()
                    exit(1)
                }
            }
            return
        }
        ModelManager.shared.beforeModelChange = { [weak self] _ in
            guard let self else { return }
            try await self.controller.prepareForModelChange()
        }
        controller.onModelSetupRequested = { [weak self] in
            self?.openSettings(sectionNotification: "TalklessShowModels")
        }
        if CommandLine.arguments.contains("--test-audio") {
            launchAudioTest()
            return
        }
        ModelManager.shared.onModelOperationChange = { [weak self] in
            self?.controller.prepareSelectedModel()
        }
        settings.$asrEngine.combineLatest(settings.$qwenModelDirectory, settings.$useCustomQwenDirectory)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.controller.prepareSelectedModel() }
            .store(in: &cancellables)
        controller.prepareSelectedModel()
        updateController = UpdateController { [weak self] in
            self?.controller.state != .idle
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        NotificationCenter.default.publisher(for: .interfaceLanguageDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                ApplicationEditMenu.install()
                self?.updateIcon()
                self?.settingsWindow?.title = L10n.tr("Talkless Settings")
                self?.setupWindow?.title = L10n.tr("Talkless Setup")
                self?.testWindow?.title = L10n.tr("Talkless · Local Audio Test")
            }
            .store(in: &cancellables)

        controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        settings.$triggerKey
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.controller.updateTriggerKey() }
            .store(in: &cancellables)

        settings.$translationShortcut
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] shortcut in self?.controller.updateTranslationShortcut(shortcut) }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .showSetupGuide)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.openSetupGuide() }
            .store(in: &cancellables)

        // Startup only checks permission; prompts belong to explicit guide/settings actions.
        // Avoid even attempting to create an event tap before Accessibility is granted.
        if !DictationController.accessibilityGranted {
            Diagnostics.shared.record(event: "permission_blocked", metadata: [
                "permission": "accessibility", "reason": "denied", "stage": "startup",
            ])
        }
        if !DictationController.accessibilityGranted || !controller.activateHotkey() {
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if DictationController.accessibilityGranted, self.controller.activateHotkey() {
                        self.permissionTimer?.invalidate()
                        self.permissionTimer = nil
                    }
                }
            }
        }
        if setupGuide.shouldPresentOnLaunch { openSetupGuide() }
    }

    /// Exercise the product controller without microphone, accessibility, or external paste.
    /// Invoke the executable with --test-audio PATH [--test-output PATH] [--test-keep-open].
    private func launchAudioTest() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--test-audio"),
              arguments.indices.contains(index + 1), !arguments[index + 1].hasPrefix("--") else {
            FileHandle.standardError.write(Data("Usage: Talkless --test-audio PATH [--test-output PATH] [--test-keep-open]\n".utf8))
            exit(2)
        }
        let audio = URL(fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath)
        var outputURL: URL?
        if let outputIndex = arguments.firstIndex(of: "--test-output") {
            guard arguments.indices.contains(outputIndex + 1), !arguments[outputIndex + 1].hasPrefix("--") else {
                FileHandle.standardError.write(Data("--test-output requires a file path.\n".utf8))
                exit(2)
            }
            outputURL = URL(fileURLWithPath: NSString(string: arguments[outputIndex + 1]).expandingTildeInPath)
        }
        var repetitions = 1
        if let repeatIndex = arguments.firstIndex(of: "--test-repeat") {
            guard arguments.indices.contains(repeatIndex + 1),
                  let value = Int(arguments[repeatIndex + 1]), (1...5).contains(value) else {
                FileHandle.standardError.write(Data("--test-repeat requires a value from 1 to 5.\n".utf8))
                exit(2)
            }
            repetitions = value
        }
        let keepOpen = arguments.contains("--test-keep-open")
        showTestWindow(audio: audio)
        controller.$previewText
            .receive(on: RunLoop.main)
            .sink { [weak self] preview in
                guard !preview.isEmpty else { return }
                self?.testTextView?.string = preview
            }
            .store(in: &cancellables)
        Task {
            do {
                var result = ""
                for index in 1...repetitions {
                    result = try await controller.runAudioTest(url: audio)
                    FileHandle.standardOutput.write(Data("Session \(index): \(result)\n".utf8))
                }
                if let outputURL {
                    try result.write(to: outputURL, atomically: true, encoding: .utf8)
                }
                testTextView?.string = result
                if !keepOpen { NSApp.terminate(nil) }
            } catch {
                let message = L10n.format("Audio test failed: %@", error.localizedDescription)
                FileHandle.standardError.write(Data((message + "\n").utf8))
                testTextView?.string = message
                if !keepOpen { exit(1) }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        CommandLine.arguments.contains("--test-audio")
    }

    private func showTestWindow(audio: URL) {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 620, height: 340))
        scrollView.hasVerticalScroller = true
        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.font = .systemFont(ofSize: 20)
        textView.textContainerInset = NSSize(width: 24, height: 24)
        textView.string = L10n.format("Transcribing with Qwen: %@…\n\nThis test only displays the result; it does not paste into other apps.", audio.lastPathComponent)
        scrollView.documentView = textView
        testTextView = textView
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = L10n.tr("Talkless · Local Audio Test")
        window.contentView = scrollView
        window.isReleasedWhenClosed = false
        window.center()
        testWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.state == .idle else {
            // Also protects resumed updates and a new dictation started after Sparkle's check.
            UpdateController.showDictationBusyAlert()
            return .terminateCancel
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        Diagnostics.shared.finishSession()
        permissionTimer?.invalidate()
    }

    private func updateIcon() {
        let state: MenuBarIcon.State
        switch controller.state {
        case .idle: state = .idle
        case .recording: state = .recording
        case .processing: state = .processing
        }
        statusItem.button?.image = MenuBarIcon.image(for: state)
        statusItem.button?.toolTip = state.accessibilityDescription
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        MenuContent.populate(menu, state: .init(
            dictationKeyTitle: settings.triggerKey.title,
            holdToTalk: settings.recordingGestureMode == .hold,
            alternateFinishKeyTitle: settings.effectiveAlternateFinishKey?.title,
            polishEnabled: settings.polishEnabled,
            translationShortcutTitle: settings.translationShortcut.keyCode == nil ? nil : settings.translationShortcut.title
        ), target: self, actions: .init(
            openSettings: #selector(openSettingsAction),
            quit: #selector(quit)
        ), updateItem: updateController?.makeMenuItem())
    }

    @objc private func openSettingsAction() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func openSetupGuide() {
        if setupWindow == nil {
            let hosting = NSHostingController(rootView: SetupGuideLiveView(
                controller: controller,
                onComplete: { [weak self] in
                    self?.setupGuide.complete()
                    self?.setupWindow?.close()
                },
                onSkip: { [weak self] in
                    self?.setupGuide.skip()
                    self?.setupWindow?.close()
                },
                openSettings: { [weak self] section in self?.openSettings(sectionNotification: section) }
            ))
            let window = NSWindow(contentViewController: hosting)
            window.title = L10n.tr("Talkless Setup")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 600, height: 540))
            window.minSize = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 600, height: 540)).size
            window.delegate = self
            window.center()
            setupWindow = window
        }
        setupGuide.present()
        NSApp.activate()
        setupWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === setupWindow else { return }
        if setupGuide.isPresented { setupGuide.skip() }
        // A manual reopen starts at the welcome page with fresh live status, not stale UI.
        setupWindow = nil
    }

    private func openSettings(sectionNotification: String) {
        openSettings()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Notification.Name(sectionNotification), object: nil)
        }
    }

    func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(controller: controller, updateController: updateController))
            let window = NSWindow(contentViewController: hosting)
            window.title = L10n.tr("Talkless Settings")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 900, height: 660))
            window.minSize = NSSize(width: 820, height: 600)
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
