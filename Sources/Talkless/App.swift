import AppKit
import AVFoundation
import Combine
import SwiftUI

@main
enum TalklessMain {
    // NSApplication.delegate is weak; retain the delegate in optimized builds too.
    @MainActor private static var retainedDelegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        retainedDelegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = DictationController()
    private let settings = AppSettings.shared
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var testWindow: NSWindow?
    private var testTextView: NSTextView?
    private var permissionTimer: Timer?
    private var updateController: UpdateController?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Diagnostics.shared.startSession()
        if CommandLine.arguments.contains("--test-microphone") {
            Task {
                do {
                    let count = try await MicrophoneDiagnostic.run()
                    FileHandle.standardOutput.write(Data("Microphone test passed: \(count) background audio callbacks.\n".utf8))
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
            self?.openSettings()
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Notification.Name("TalklessShowModels"), object: nil)
            }
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

        controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        settings.$triggerKey
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.controller.updateTriggerKey() }
            .store(in: &cancellables)

        if !controller.activateHotkey() {
            // First launch: request permission and wait for the user to enable it in System Settings.
            DictationController.requestAccessibility()
            openSettings()
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
        if DictationController.microphoneStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
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
                let message = "Audio test failed: \(error.localizedDescription)"
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
        textView.string = "Transcribing with Qwen: \(audio.lastPathComponent)…\n\nThis test only displays the result; it does not paste into other apps."
        scrollView.documentView = textView
        testTextView = textView
        let window = NSWindow(contentRect: scrollView.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Talkless · Local Audio Test"
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
        let name: String
        switch controller.state {
        case .idle: name = "waveform"
        case .recording: name = "waveform.badge.mic"
        case .processing: name = "ellipsis.circle"
        }
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Talkless")
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hint = NSMenuItem(title: "Hold \(settings.triggerKey.title) to talk; tap for hands-free", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)

        if !controller.hotkeyActive {
            menu.addItem(item("Accessibility permission required…", #selector(openAccessibilitySettings)))
        }
        if DictationController.microphoneStatus == .denied {
            menu.addItem(item("Microphone permission required…", #selector(openMicrophoneSettings)))
        }
        menu.addItem(.separator())

        let dictateTitle = controller.state == .recording ? "Stop Dictation" : "Start Dictation (Hands-free)"
        menu.addItem(item(dictateTitle, #selector(toggleDictation)))
        menu.addItem(item("Translate Selected Text  ⌃⌥T", #selector(translate)))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettingsAction), key: ","))
        if let updateController {
            menu.addItem(updateController.makeMenuItem())
            if let status = updateController.status {
                let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
                statusItem.isEnabled = false
                menu.addItem(statusItem)
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Quit Talkless", #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func toggleDictation() { controller.toggleFromMenu() }
    @objc private func translate() { Task { await controller.translateSelection() } }
    @objc private func openSettingsAction() { openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func openAccessibilitySettings() {
        DictationController.requestAccessibility()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    func openSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(controller: controller, updateController: updateController))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Talkless Settings"
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
