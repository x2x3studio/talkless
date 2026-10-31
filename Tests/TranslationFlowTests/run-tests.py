#!/usr/bin/env python3
"""Run production translation flow and SwiftUI callbacks with isolated, non-network fakes."""
from pathlib import Path
import argparse
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--snapshots", type=Path, help="Write synthetic native popup snapshots to this directory")
arguments = parser.parse_args()

ROOT = Path(__file__).resolve().parents[2]
controller = (ROOT / "Sources/Talkless/DictationController.swift").read_text()
flow = controller.split("    // MARK: - Selected-text translation\n", 1)[1]
flow = flow.replace("private ", "").replace("NSRunningApplication", "FakeApplication").replace("NSWorkspace", "FakeWorkspace")
overlay = (ROOT / "Sources/Talkless/Overlay.swift").read_text().split("// MARK: - Selected-text translation panel\n", 1)[1]
prompts = (ROOT / "Sources/Talkless/Prompts.swift").read_text().split("    static func translate(target:", 1)[1]
prompts = "enum Prompts {\n    static func translate(target:" + prompts

STUBS = r'''
import AppKit
import SwiftUI

struct FakeApplication: Equatable {
    let localizedName: String?
}
@MainActor final class FakeWorkspace {
    static let shared = FakeWorkspace()
    var frontmostApplication: FakeApplication? = .init(localizedName: "Original app")
}
@MainActor final class FakeSettings {
    var llmConfigured = true
    var llmConfig = "isolated fake config"
    var translationLanguages = TranslationLanguagePreferences(
        source: .languageID("en"), target: .languageID("fr")
    )
}
struct HistoryEntry {
    enum Kind { case translation }
    let kind: Kind
    let app: String
    let raw: String
    let output: String
    let duration: Double
}
@MainActor final class FakeHistory {
    var entries: [HistoryEntry] = []
    func add(_ entry: HistoryEntry) { entries.append(entry) }
}
@MainActor final class FakeHUD {
    enum Phase { case error(String) }
    var errors: [String] = []
    func show(_ phase: Phase) { if case .error(let error) = phase { errors.append(error) } }
}
@MainActor enum TextIO {
    static var selection: String? = "The original selected sentence."
    static var suspendSelection = false
    static var selections: [CheckedContinuation<String?, Never>] = []
    static var copies: [String] = []
    static func selectedText() async -> String? {
        if suspendSelection { return await withCheckedContinuation { selections.append($0) } }
        return selection
    }
    static func copyToClipboard(_ text: String) { copies.append(text) }
}
@MainActor enum LLMClient {
    struct Request {
        let system: String
        let user: String
        let config: String
        let continuation: CheckedContinuation<String, Error>
    }
    static var requests: [Request] = []
    static var cancellationSeen: [Bool] = []
    static func complete(system: String, user: String, config: String) async throws -> String {
        defer { cancellationSeen.append(Task.isCancelled) }
        // Deliberately ignore cancellation until manually completed: generation guards must still work.
        return try await withCheckedThrowingContinuation {
            requests.append(Request(system: system, user: user, config: config, continuation: $0))
        }
    }
}
@MainActor final class FakePanel {
    var view: TranslationView?
    var onClose: (() -> Void)?
    var isVisible: Bool { view != nil }
    var updates = 0
    func show(source: String, result: String?, error: String?,
              preferences: TranslationLanguagePreferences, resolution: TranslationLanguageResolution,
              allowsReplacement: Bool,
              onLanguagesChanged: @escaping (TranslationLanguageSelection, TranslationLanguageSelection) -> Void,
              onReplace: @escaping (String) -> Void, onClose: @escaping () -> Void) {
        updates += 1
        self.onClose = onClose
        view = TranslationView(source: source, result: result, error: error,
                               preferences: preferences, resolution: resolution, allowsReplacement: allowsReplacement,
                               onLanguagesChanged: onLanguagesChanged,
                               onCopy: { _ in }, onReplace: { [weak self] value in self?.close(); onReplace(value) },
                               onClose: { [weak self] in self?.close() })
    }
    func close() {
        view = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}
@MainActor final class FlowHarness {
    static var accessibilityGranted = true
    enum PermissionPane { case accessibility, microphone }
    var openedPanes: [PermissionPane] = []
    func openPermissionSettings(_ pane: PermissionPane) { openedPanes.append(pane) }
    enum State { case idle, recording, processing }
    var state: State = .idle
    let settings = FakeSettings()
    let hud = FakeHUD()
    let history = FakeHistory()
    let translationPanel = FakePanel()
    var shortcutCaptureActive = false
    var pasted: [(String, FakeApplication?)] = []
    func paste(_ text: String, into app: FakeApplication?) async { pasted.append((text, app)) }
'''

TESTS = r'''
@main struct Tests {
    @MainActor static func wait(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        preconditionFailure("Timed out waiting for isolated task")
    }
    @MainActor static func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(5))
    }
    @MainActor static func main() async {
        // No real settings, clipboard, application activation, provider, or network is touched.
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        localization.interfaceLanguage = .english
        for activeState in [FlowHarness.State.recording, .processing] {
            let active = FlowHarness()
            active.state = activeState
            active.settings.llmConfigured = false
            await active.translateSelection()
            precondition(active.hud.errors.isEmpty, "Translation setup errors must not replace an active dictation HUD")
            active.settings.llmConfigured = true
            TextIO.selection = ""
            await active.translateSelection()
            precondition(active.hud.errors.isEmpty, "Missing selection must not dismiss the active transcript")
        }
        TextIO.selection = "The original selected sentence."
        let flow = FlowHarness()
        precondition(LLMClient.requests.isEmpty, "Constructing UI/settings never translates")
        flow.settings.llmConfigured = false
        await flow.translateSelection()
        precondition(LLMClient.requests.isEmpty && flow.hud.errors.count == 1)
        flow.settings.llmConfigured = true
        TextIO.selection = " \n "
        await flow.translateSelection()
        precondition(LLMClient.requests.isEmpty && !flow.translationPanel.isVisible)
        precondition(flow.hud.errors.last == "Could not read any selected text")
        FlowHarness.accessibilityGranted = false
        await flow.translateSelection()
        precondition(flow.hud.errors.last?.contains("Accessibility permission") == true,
                     "Without Accessibility, a missing selection names the permission")
        precondition(flow.openedPanes == [.accessibility], "and opens the Accessibility pane")
        FlowHarness.accessibilityGranted = true
        TextIO.selection = "The original selected sentence."
        await flow.translateSelection()
        flow.translationPanel.close()
        await settle()
        precondition(LLMClient.requests.isEmpty, "Closing before the task starts must not call the service")
        await flow.translateSelection()
        await wait { LLMClient.requests.count == 1 }
        let first = LLMClient.requests[0]
        precondition(first.user == "<text>\nThe original selected sentence.\n</text>")
        precondition(first.system.contains("French") && first.system.contains("source language is English"))
        precondition(!first.system.contains("translate it into English instead"))
        precondition(flow.translationPanel.view?.result == nil)

        // Source callback is the actual SwiftUI binding, not an imitation of the handler.
        flow.translationPanel.view!.sourceSelection.wrappedValue = .languageID("de")
        await wait { LLMClient.requests.count == 2 }
        precondition(flow.settings.translationLanguages.source == .languageID("de"))
        precondition(LLMClient.requests[1].system.contains("source language is German"))
        flow.translationPanel.view!.targetSelection.wrappedValue = .languageID("ja")
        await wait { LLMClient.requests.count == 3 }
        precondition(flow.settings.translationLanguages.target == .languageID("ja"))
        precondition(LLMClient.requests.allSatisfy { $0.user == first.user })
        LLMClient.requests[2].continuation.resume(returning: "Newest translation")
        await wait { flow.translationPanel.view?.result == "Newest translation" }
        first.continuation.resume(returning: "Stale translation")
        LLMClient.requests[1].continuation.resume(throwing: NSError(domain: "Fake", code: 1))
        await settle()
        precondition(flow.translationPanel.view?.result == "Newest translation")
        precondition(flow.history.entries.map(\.output) == ["Newest translation"])
        precondition(LLMClient.cancellationSeen.filter { $0 }.count == 2)

        // A repeated selection does not bill twice; swap changes stable choices once.
        let count = LLMClient.requests.count
        flow.translationPanel.view!.targetSelection.wrappedValue = .languageID("ja")
        await settle()
        precondition(LLMClient.requests.count == count)
        flow.translationPanel.view!.swapLanguages()
        await wait { LLMClient.requests.count == count + 1 }
        precondition(flow.settings.translationLanguages.source == .languageID("ja"))
        precondition(flow.settings.translationLanguages.target == .languageID("de"))
        precondition(LLMClient.requests.last!.user == first.user, "Never translate the previous result")
        flow.translationPanel.view!.onClose()
        LLMClient.requests.last!.continuation.resume(returning: "After close")
        await settle()
        precondition(!flow.translationPanel.isVisible && flow.history.entries.count == 1)
        precondition(LLMClient.cancellationSeen.last == true)

        // Explicit same normalized language is free; Chinese scripts remain distinct.
        flow.settings.translationLanguages.source = .languageID("en-US")
        flow.settings.translationLanguages.target = .languageID("en-GB")
        await flow.translateSelection()
        await settle()
        precondition(LLMClient.requests.count == count + 1)
        precondition(flow.translationPanel.view?.result == TextIO.selection)
        flow.settings.translationLanguages.source = .languageID("zh-Hans")
        flow.settings.translationLanguages.target = .languageID("zh-Hant")
        TextIO.selection = "\u{8BF7}\u{8F6C}\u{6362}\u{4E3A}\u{7E41}\u{4F53}\u{4E2D}\u{6587}。"
        await flow.translateSelection()
        await wait { LLMClient.requests.count == count + 2 }
        precondition(LLMClient.requests.last!.system.contains("Traditional Chinese"))

        // A new invocation invalidates prior requests and keeps its original destination.
        TextIO.selection = "A new original selection."
        FakeWorkspace.shared.frontmostApplication = .init(localizedName: "Captured app")
        flow.settings.translationLanguages.source = .languageID("en")
        flow.settings.translationLanguages.target = .languageID("fr")
        await flow.translateSelection()
        await wait { LLMClient.requests.count == count + 3 }
        LLMClient.requests[count + 1].continuation.resume(returning: "Old invocation")
        LLMClient.requests[count + 2].continuation.resume(returning: "New invocation")
        await wait { flow.translationPanel.view?.result == "New invocation" }
        FakeWorkspace.shared.frontmostApplication = .init(localizedName: "Different app")
        flow.translationPanel.view!.onReplace("New invocation")
        await wait { flow.pasted.count == 1 }
        precondition(flow.pasted[0].1?.localizedName == "Captured app")
        precondition(flow.history.entries.last?.raw == "A new original selection.")

        // A pending clipboard acquisition owns the pasteboard; retriggers cannot race it.
        TextIO.suspendSelection = true
        let older = Task { await flow.translateSelection() }
        await wait { TextIO.selections.count == 1 }
        let newer = Task { await flow.translateSelection() }
        await newer.value
        precondition(TextIO.selections.count == 1, "Never overlap clipboard acquisitions")
        TextIO.selections[0].resume(returning: "First captured source")
        await older.value
        await wait { LLMClient.requests.count == count + 4 }
        precondition(flow.translationPanel.view?.source == "First captured source")
        precondition(LLMClient.requests.count == count + 4)
        flow.translationPanel.close()
        LLMClient.requests.last!.continuation.resume(returning: "No resurrection")
        await settle()
        precondition(!flow.translationPanel.isVisible)
        TextIO.suspendSelection = false

        // Custom targets keep their remembered value after switching away and translate only on selection.
        let customStart = LLMClient.requests.count
        flow.settings.translationLanguages.target = .custom("Cantonese (Hong Kong)")
        await flow.translateSelection()
        await wait { LLMClient.requests.count == customStart + 1 }
        precondition(LLMClient.requests.last!.system.contains("Cantonese (Hong Kong)"))
        precondition(flow.translationPanel.view?.canSwap == false)
        flow.translationPanel.view!.targetSelection.wrappedValue = .languageID("fr")
        await wait { LLMClient.requests.count == customStart + 2 }
        precondition(flow.settings.translationLanguages.customTargetName == "Cantonese (Hong Kong)")
        flow.translationPanel.view!.targetSelection.wrappedValue = .custom(flow.settings.translationLanguages.customTargetName!)
        await wait { LLMClient.requests.count == customStart + 3 }
        precondition(LLMClient.requests.last!.system.contains("Cantonese (Hong Kong)"))
        precondition(LLMClient.requests.suffix(3).allSatisfy { $0.user == Prompts.translateInput(TextIO.selection!) })
        flow.translationPanel.close()
        for request in LLMClient.requests.suffix(3) { request.continuation.resume(returning: "Cancelled custom translation") }
        await settle()
        precondition(!flow.translationPanel.isVisible)

        // An automatic source estimate never skips translation merely because its dominant
        // language matches the target: mixed text and long selections still need translation.
        let autoSourceStart = LLMClient.requests.count
        flow.settings.translationLanguages.source = .auto
        flow.settings.translationLanguages.target = .languageID("en")
        TextIO.selection = "This is a clearly written English sentence."
        await flow.translateSelection()
        await wait { LLMClient.requests.count == autoSourceStart + 1 }
        precondition(flow.translationPanel.view?.resolution.sourceLanguageID == "en")
        // A stale popup target edit must preserve the newer source from Settings.
        flow.settings.translationLanguages.source = .languageID("de")
        flow.translationPanel.view!.targetSelection.wrappedValue = .languageID("fr")
        await wait { LLMClient.requests.count == autoSourceStart + 2 }
        precondition(flow.settings.translationLanguages.source == .languageID("de"))
        precondition(LLMClient.requests.last!.system.contains("source language is German"))
        // And a source edit must preserve a newer target chosen in Settings.
        flow.settings.translationLanguages.target = .languageID("ja")
        flow.translationPanel.view!.sourceSelection.wrappedValue = .languageID("ko")
        await wait { LLMClient.requests.count == autoSourceStart + 3 }
        precondition(flow.settings.translationLanguages.target == .languageID("ja"))
        flow.translationPanel.close()
        for request in LLMClient.requests.suffix(3) { request.continuation.resume(returning: "Cancelled preference translation") }
        await settle()

        // Auto labels remain neutral across translation directions and interface changes.
        var preferences = TranslationLanguagePreferences()
        preferences.primary = .languageID("zh-Hans")
        preferences.secondary = .languageID("en")
        let resolution = TranslationLanguages.resolve(text: "This is a clearly written English sentence.", preferences: preferences)
        let view = TranslationView(source: "source", result: nil, error: nil,
                                   preferences: preferences, resolution: resolution,
                                   onLanguagesChanged: { _, _ in }, onCopy: { _ in }, onReplace: { _ in }, onClose: {})
        precondition(view.automaticSourceLabel == "Auto")
        precondition(view.automaticTargetLabel == "Auto")
        var explicitPreferences = preferences
        explicitPreferences.target = .languageID("fr")
        let explicitView = TranslationView(source: "source", result: nil, error: nil,
                                           preferences: explicitPreferences,
                                           resolution: TranslationLanguages.resolve(text: "This is a clearly written English sentence.", preferences: explicitPreferences),
                                           onLanguagesChanged: { _, _ in }, onCopy: { _ in }, onReplace: { _ in }, onClose: {})
        precondition(explicitView.automaticTargetLabel == "Auto",
                     "Auto menu option must not look like a fixed translation direction")
        let autoCount = LLMClient.requests.count
        localization.interfaceLanguage = .simplifiedChinese
        precondition(view.automaticSourceLabel == L10n.tr("Auto"))
        precondition(view.automaticTargetLabel == L10n.tr("Auto"))
        precondition(LLMClient.requests.count == autoCount)
        let unknown = TranslationLanguages.resolve(text: "12345", preferences: preferences)
        let unknownView = TranslationView(source: "12345", result: nil, error: nil,
                                          preferences: preferences, resolution: unknown,
                                          onLanguagesChanged: { _, _ in }, onCopy: { _ in }, onReplace: { _ in }, onClose: {})
        precondition(unknownView.automaticSourceLabel == L10n.tr("Auto") && !unknownView.canSwap)
        if CommandLine.arguments.count > 1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let panel = TranslationPanelController()
            var closeCount = 0
            let source = "Please send the updated meeting notes before Friday."
            let translated = "\u{8BF7}\u{5728}\u{5468}\u{4E94}\u{4E4B}\u{524D}\u{53D1}\u{9001}\u{66F4}\u{65B0}\u{540E}\u{7684}\u{4F1A}\u{8BAE}\u{8BB0}\u{5F55}。"
            for language in [InterfaceLanguage.english, .simplifiedChinese] {
                LocalizationSettings.shared.interfaceLanguage = language
                panel.show(source: source, result: translated, error: nil,
                           preferences: preferences,
                           resolution: TranslationLanguages.resolve(text: source, preferences: preferences),
                           onLanguagesChanged: { _, _ in }, onReplace: { _ in }, onClose: { closeCount += 1 })
                precondition(panel.isVisible && panel.isNonactivating && !panel.isClickThrough)
                precondition(closeCount == 0, "Updating a panel must not cancel its request")
                let window = app.windows.first { $0.isVisible && $0 is NSPanel }!
                window.appearance = NSAppearance(named: .aqua)
                let content = window.contentView!
                content.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                await settle()
                let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
                content.cacheDisplay(in: content.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(
                    to: directory.appendingPathComponent("translation-popup-synthetic-\(language.rawValue).png"))
            }
            let popupWindow = app.windows.first { $0.isVisible && $0 is NSPanel }!
            panel.handleLocalClick(in: popupWindow)
            precondition(panel.isVisible, "Clicks in the panel must stay open")
            let settingsWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
            let menuWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
            menuWindow.level = .popUpMenu
            panel.handleLocalClick(in: menuWindow)
            precondition(panel.isVisible, "Popup menu windows are not outside clicks")
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
            panel.handleLocalClick(in: settingsWindow)
            precondition(panel.isVisible, "A tracking menu must consume its own dismissal click")
            NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
            panel.handleLocalClick(in: settingsWindow)
            precondition(!panel.isVisible && closeCount == 1, "Local Settings clicks dismiss the popup")
            panel.close()
            precondition(closeCount == 1, "Closing is idempotent and invalidates exactly once")
            print("PASS: native clickable nonactivating popup, in-place update and idempotent close; synthetic en/zh screenshots saved")
        }
        print("PASS: translation lifecycle, cancellation/races, source/target/swap bindings, original source/app, zero-call guards, scripts, Auto labels and localization")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="talkless-translation-flow-") as temporary:
    directory = Path(temporary)
    source = directory / "TranslationFlowTests.swift"
    source.write_text(STUBS + flow + "\n" + prompts + "\n" + overlay + "\n" + TESTS)
    binary = directory / "translation-flow-tests"
    # Use source resources but never initialize the real user's persisted interface preference.
    localization_source = (ROOT / "Sources/Talkless/L10n.swift").read_text()
    localization_source = localization_source.replace("static let shared = LocalizationSettings()", "static let shared = LocalizationSettings(defaults: nil)")
    localization_source = localization_source.replace(
        'URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources")',
        'URL(fileURLWithPath: "' + str(ROOT / "Sources/Talkless/Resources") + '")',
    )
    localization_file = directory / "L10n.swift"
    localization_file.write_text(localization_source)
    # System Python can inject a Command Line Tools SDKROOT; select Xcode's SDK
    # explicitly so the SwiftUI macro plugins are available in CI too.
    subprocess.run([
        "/usr/bin/xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library", "-swift-version", "6",
        str(localization_file),
        str(ROOT / "Sources/Talkless/TranslationLanguages.swift"),
        str(ROOT / "Sources/Talkless/LanguagePickerView.swift"),
        str(source), "-o", str(binary),
    ], check=True)
    subprocess.run([str(binary)] + ([str(arguments.snapshots.resolve())] if arguments.snapshots else []), check=True)
