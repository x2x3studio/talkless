import AppKit
import AVFoundation
import Foundation
import SwiftUI

// Both views compile against synthetic services: no real preferences, credentials,
// model assets, audio device, network or system permission request is exercised.
enum SettingsAppearance {
    static let accent = Color(red: 86 / 255, green: 103 / 255, blue: 219 / 255)
}

@MainActor final class AppSettings: ObservableObject {
    enum Engine { case qwen, apple, openAICompatible }
    struct Key { var title = "Right ⌘"; var keyCode: Int? = 1 }
    enum Gesture { case hold, toggle }
    static let shared = AppSettings()
    var asrEngine = Engine.qwen
    var useCustomQwenDirectory = false
    var llmConfigured = false
    var polishEnabled = false
    var triggerKey = Key()
    var recordingGestureMode = Gesture.hold
    var effectiveAlternateFinishKey: Key?
    var translationShortcut = Key()
}

@MainActor final class ModelManager: ObservableObject {
    enum Phase { case checking, notInstalled, downloading, verifying, paused, installed, failed, deleting }
    struct Entry {
        struct Model { let name = "Synthetic local model" }
        var model = Model()
        let id = "test-model"
        var phase = Phase.notInstalled
    }
    static let shared = ModelManager()
    var activeModelID = "test-model"
    var isChecking = false
    var isBusy = false
    var entryValue: Entry? = Entry()
    var directory: URL?
    func entry(modelID: String) -> Entry? { entryValue }
    func installedDirectory(_ id: String) -> URL? { directory }
}

@MainActor final class DictationController: ObservableObject {
    enum ModelPreparationState { case unprepared, preparing, ready, failed }
    static var microphoneStatus = AVAuthorizationStatus.notDetermined
    static var accessibilityGranted = false
    static func requestAccessibility() { preconditionFailure("No permission requests in synthetic tests") }
    var hotkeyActive = false
    var preparation = ModelPreparationState.unprepared
    var preparationDirectory: URL?
    func modelPreparationState(for directory: URL) -> ModelPreparationState {
        preparationDirectory == directory ? preparation : .unprepared
    }
}

@main
struct SetupGuideViewTests {
    @MainActor static func main() throws {
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        localization.interfaceLanguage = .english
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var assertions = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            precondition(condition(), message)
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.10)) }
        var calls: [String] = []
        let state = SetupGuideState()
        let actions = SetupGuideActions(
            refresh: { calls.append("refresh") },
            requestMicrophone: { calls.append("microphone") },
            openMicrophoneSettings: { calls.append("microphoneSettings") },
            requestAccessibility: { calls.append("accessibility") },
            openAccessibilitySettings: { calls.append("accessibilitySettings") },
            openSpeechSettings: { calls.append("speech") },
            openAISettings: { calls.append("ai") },
            enablePolish: { calls.append("polish"); state.snapshot.polishEnabled = true },
            finish: { calls.append("finish") },
            skipSetup: { calls.append("skip") }
        )
        check(SetupGuideStep.allCases.count == 7, "Seven steps including current controls")
        let controls = SetupGuideControls(dictationKeyTitle: "Right ⌘", holdToTalk: false)
        check(controls.dictationInstruction == "Tap Right ⌘ to start; tap again to finish.", "Controls respect customized key and toggle gesture")
        check(SetupGuideControls(dictationKeyTitle: "Fn").dictationInstruction == "Hold Fn to talk; release to finish.", "Hold controls describe release-to-finish")
        for enabled in [false, true] {
            let controls = SetupGuideControls(alternateFinishKeyTitle: "Right ⌘", polishEnabled: enabled)
            check(controls.polishingAction == (enabled ? "Skip AI polishing" : "Use AI polishing"),
                  "Guide names the action for the current default")
            check(controls.polishingInstruction == (enabled
                ? "While recording, press this key to finish and skip AI polishing for this input only. Your default stays unchanged."
                : "While recording, press this key to finish and use AI polishing for this input only. Your default stays unchanged."),
                  "Guide explains recording end, current-input scope, and unchanged default")
            localization.interfaceLanguage = .simplifiedChinese
            check(controls.polishingAction == (enabled ? "\u{8DF3}\u{8FC7} AI \u{6DA6}\u{8272}" : "\u{4F7F}\u{7528} AI \u{6DA6}\u{8272}"),
                  "Guide uses plain Chinese action labels")
            check(controls.polishingInstruction == (enabled
                ? "\u{5F55}\u{97F3}\u{65F6}\u{6309}\u{6B64}\u{952E}\u{7ED3}\u{675F}\u{5F55}\u{97F3}，\u{5E76}\u{4EC5}\u{4E3A}\u{672C}\u{6B21}\u{8F93}\u{5165}\u{8DF3}\u{8FC7} AI \u{6DA6}\u{8272}，\u{4E0D}\u{66F4}\u{6539}\u{9ED8}\u{8BA4}\u{8BBE}\u{7F6E}。"
                : "\u{5F55}\u{97F3}\u{65F6}\u{6309}\u{6B64}\u{952E}\u{7ED3}\u{675F}\u{5F55}\u{97F3}，\u{5E76}\u{4EC5}\u{4E3A}\u{672C}\u{6B21}\u{8F93}\u{5165}\u{4F7F}\u{7528} AI \u{6DA6}\u{8272}，\u{4E0D}\u{66F4}\u{6539}\u{9ED8}\u{8BA4}\u{8BBE}\u{7F6E}。"),
                  "Chinese guide preserves end-recording and one-input scope")
            localization.interfaceLanguage = .english
        }
        check(SetupGuideStep.welcome.previous == .welcome && SetupGuideStep.done.next == .done, "Navigation clamps to guide boundaries")
        check(!state.snapshot.dictationReady, "Skipped requirements never claim ready")
        state.snapshot = .init(microphone: .granted, accessibility: .granted, speechReady: true)
        check(!state.snapshot.dictationReady, "AX permission alone cannot claim ready when the event tap failed")
        check(state.snapshot.accessibility == .granted, "Shortcut failure does not revoke the actual permission")
        state.snapshot.shortcutsReady = true
        check(state.snapshot.dictationReady, "Optional AI does not block basic readiness")
        state.snapshot.accessibility = .denied
        check(!state.snapshot.dictationReady, "Stale active hotkey cannot override revoked Accessibility permission")
        state.snapshot = .init()

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 540),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Talkless Setup — Synthetic preview"
        window.appearance = NSAppearance(named: .aqua)
        func mount(_ step: SetupGuideStep) -> NSHostingView<SetupGuideView> {
            let hosting = NSHostingView(rootView: SetupGuideView(state: state, actions: actions, localization: localization, initialStep: step))
            window.contentView = hosting
            window.setContentSize(NSSize(width: 600, height: 540))
            window.orderFrontRegardless()
            window.layoutIfNeeded()
            settle()
            hosting.layoutSubtreeIfNeeded()
            return hosting
        }
        // Exercise the same dispatch methods used by the buttons, with fake callbacks only.
        _ = mount(.welcome)
        check(calls.isEmpty, "Mount never asks for permission, refreshes, writes preferences or invokes providers")
        for step in SetupGuideStep.allCases { _ = mount(step) }
        check(calls.isEmpty, "Every step renders without service side effects")
        for permission in [SetupGuidePermission.notDetermined, .requesting, .granted, .denied, .restricted] {
            state.snapshot.microphone = permission
            _ = mount(.microphone)
        }
        check(calls.isEmpty, "Every permission state renders without requesting access")
        state.snapshot = .init()
        actions.allow(.requesting, microphone: true)
        check(calls.isEmpty, "Pending microphone dialog cannot launch another request")
        actions.allow(.notDetermined, microphone: true)
        check(calls == ["microphone"], "Undecided microphone request dispatches explicitly")
        actions.allow(.denied, microphone: true)
        check(calls.last == "microphoneSettings", "Denied permission opens settings instead of requesting again")
        actions.allow(.restricted, microphone: true)
        check(calls.last == "microphoneSettings", "Restricted permission opens settings")
        let grantedCount = calls.count
        actions.allow(.granted, microphone: true)
        actions.allow(.granted, microphone: false)
        check(calls.count == grantedCount, "Already-granted permissions do nothing")
        actions.allow(.notDetermined, microphone: false)
        check(calls.last == "accessibility", "Accessibility dispatches only through explicit action")
        actions.allow(.denied, microphone: false)
        check(calls.last == "accessibilitySettings", "Accessibility denial routes to settings")
        actions.openSpeechSettings()
        check(calls.last == "speech", "Model setup delegates to existing settings")
        let unconfiguredCount = calls.count
        actions.enablePolishIfConfigured(state.snapshot)
        check(calls.count == unconfiguredCount, "Unconfigured AI cannot enable polishing")
        state.snapshot.aiConfigured = true
        actions.enablePolishIfConfigured(state.snapshot)
        check(state.snapshot.polishEnabled && calls.last == "polish", "Polishing enables only on an explicit configured action")
        let enabledCount = calls.count
        actions.enablePolishIfConfigured(state.snapshot)
        check(calls.count == enabledCount, "Already-enabled polishing does not write again")
        actions.finish()
        check(calls.last == "finish", "Completion delegates to coordinator")
        state.snapshot = .init()
        let beforeSkip = state.snapshot
        actions.skipSetup()
        check(calls.last == "skip" && state.snapshot == beforeSkip, "Skip invokes only the callback, leaving settings unchanged")

        // Exercise the production readiness adapter through async lifecycle snapshots.
        let controller = DictationController()
        let live = SetupGuideLiveView(controller: controller, onComplete: {}, onSkip: {}, openSettings: { _ in })
        let manager = ModelManager.shared
        let settings = AppSettings.shared
        for phase in [ModelManager.Phase.checking, .notInstalled, .downloading, .verifying, .paused, .failed, .deleting] {
            manager.entryValue?.phase = phase
            check(!live.speechStatus.ready, "Incomplete model phase cannot be ready: \(phase)")
        }
        manager.entryValue?.phase = .installed
        manager.directory = URL(fileURLWithPath: "/synthetic/models/selected")
        controller.preparationDirectory = manager.directory
        check(!live.speechStatus.ready, "Installed alone is not loaded/ready")
        controller.preparation = .preparing
        check(!live.speechStatus.ready, "Async preparation remains unavailable")
        controller.preparation = .failed
        check(!live.speechStatus.ready, "Preparation failure stays actionable")
        controller.preparation = .ready
        check(live.speechStatus.ready, "Verified selected model becomes ready after preparation completes")
        controller.preparationDirectory = URL(fileURLWithPath: "/synthetic/models/old")
        check(!live.speechStatus.ready, "Stale readiness for a different model cannot leak")
        controller.preparationDirectory = manager.directory
        manager.isChecking = true
        check(!live.speechStatus.ready, "Startup integrity checks gate readiness")
        manager.isChecking = false
        manager.isBusy = true
        check(!live.speechStatus.ready, "Switch/delete/install operations gate readiness")
        manager.isBusy = false
        manager.directory = nil
        check(!live.speechStatus.ready, "Deleted or damaged files invalidate installed status")
        settings.useCustomQwenDirectory = true
        check(!live.speechStatus.ready, "Custom folders are not falsely validated")
        settings.useCustomQwenDirectory = false
        settings.asrEngine = .apple
        check(!live.speechStatus.ready, "Apple assets are not silently probed")
        settings.asrEngine = .openAICompatible
        check(!live.speechStatus.ready, "Cloud configuration is not silently tested")
        settings.asrEngine = .qwen
        manager.directory = controller.preparationDirectory
        localization.interfaceLanguage = .simplifiedChinese
        check(live.speechStatus.ready, "Readiness is typed, independent of display language")
        localization.interfaceLanguage = .english

        if let argument = CommandLine.arguments.dropFirst().first {
            let output = URL(fileURLWithPath: argument, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            for language in [InterfaceLanguage.english, .simplifiedChinese] {
                localization.interfaceLanguage = language
                for step in SetupGuideStep.allCases {
                    state.snapshot = .init(microphone: .denied, accessibility: .granted,
                                           speechStatus: L10n.tr("Not downloaded"),
                                           controls: SetupGuideControls(dictationKeyTitle: L10n.tr("Fn / Globe"),
                                                                        alternateFinishKeyTitle: "Right ⌘",
                                                                        translationShortcutTitle: "⌃⌥T"))
                    let hosting = mount(step)
                    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 540,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    bitmap.size = NSSize(width: 600, height: 540)
                    hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                    let png = bitmap.representation(using: .png, properties: [:])!
                    check(png.count > 8_000, "Snapshot contains rendered UI")
                    let code = language == .english ? "en" : "zh"
                    try png.write(to: output.appendingPathComponent("setup-\(code)-\(step.rawValue + 1).png"))
                }
            }
            print("Rendered 14 synthetic 600×540 setup screenshots at \(output.path)")
        }
        window.orderOut(nil)
        print("PASS \(assertions) setup view, fake action, skip and readiness assertions")
    }
}
