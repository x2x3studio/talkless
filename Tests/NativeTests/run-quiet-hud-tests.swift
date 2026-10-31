import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("talkless-quiet-hud-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let source = directory.appendingPathComponent("HUDTests.swift")
// Verify configured durations exactly; runtime lifecycle tests allow scheduler slack.
let overlaySource = try String(contentsOf: root.appendingPathComponent("Sources/Talkless/Overlay.swift"), encoding: .utf8)
let showStart = overlaySource.range(of: "    func show(_ phase: HUDModel.Phase)")!.lowerBound
let showEnd = overlaySource.range(of: "    func hide(after", range: showStart..<overlaySource.endIndex)!.lowerBound
let showSource = String(overlaySource[showStart..<showEnd])
let completedStart = showSource.range(of: "        case .completed:")!.lowerBound
let completedEnd = showSource.range(of: "        default:", range: completedStart..<showSource.endIndex)!.lowerBound
precondition(showSource[completedStart..<completedEnd].contains("hide(after: .milliseconds(50))"),
             "Completed confirmation schedules dismissal after 50 ms, not the insertion/clipboard delay")
let errorStart = showSource.range(of: "        case .error:")!.lowerBound
precondition(showSource[errorStart..<completedStart].contains("hide(after: .seconds(3))"),
             "Errors keep their existing three-second timeout")
// Compile the production display enums, but none of the controller's services.
let settingsSource = try String(contentsOf: root.appendingPathComponent("Sources/Talkless/Settings.swift"), encoding: .utf8)
let displayStart = settingsSource.range(of: "enum TriggerKey:")!.lowerBound
let displayEnd = settingsSource.range(of: "enum ASREngine:")!.lowerBound
let displaySource = directory.appendingPathComponent("RecordingDisplay.swift")
try ("import Foundation\n" + settingsSource[displayStart..<displayEnd]).write(to: displaySource, atomically: true, encoding: .utf8)
try #"""
import AppKit
import Combine
import SwiftUI

@main
struct HUDTests {
    // The launcher appends a process-only preference override after optional snapshot arguments.
    static var testArguments: [String] { Array(CommandLine.arguments.dropLast(2)) }
    @MainActor @discardableResult
    static func snapshot(_ model: HUDModel, name: String,
                         reduceTransparency: Bool = false, reduceMotion: Bool = true) throws -> NSBitmapImageRep {
        // Accessibility environment values are read-only. Render their resolved appearance
        // without changing macOS preferences; the pure policy is tested separately.
        let rendered = HUDModel(appearance: model.appearance)
        rendered.phase = model.phase
        rendered.preview = model.preview
        rendered.revisionOriginal = model.revisionOriginal
        rendered.isEditMode = model.isEditMode
        rendered.setDictionaryTerms(model.dictionaryTerms)
        if reduceTransparency { rendered.appearance.backdrop = .solid }
        if reduceMotion { rendered.appearance.animationsEnabled = false }
        return try snapshotView(HUDView(model: rendered), size: rendered.contentSize, name: name)
    }

    @MainActor @discardableResult
    static func snapshotView<V: View>(_ view: V, size: CGSize, name: String,
                                     scrollToBottom: Bool = false) throws -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.setFrameSize(size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        if name.contains("settings") {
            func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
                (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap { segmentedControls(in: $0) }
            }
            let stages = segmentedControls(in: hosting).filter { control in
                control.segmentCount == HUDPreviewStage.allCases.count
                    && (0..<control.segmentCount).map { control.label(forSegment: $0) ?? "" }
                        == HUDPreviewStage.allCases.map(\.title)
            }
            precondition(stages.count == 1,
                         "Settings must render one Stage control, not alias it to the Sample picker through duplicate IDs")
        }
        if scrollToBottom {
            func scrollView(in view: NSView) -> NSScrollView? {
                if let scroll = view as? NSScrollView { return scroll }
                return view.subviews.compactMap { scrollView(in: $0) }.first
            }
            guard let scroll = scrollView(in: hosting), let document = scroll.documentView else {
                preconditionFailure("Settings must contain a native scroll view")
            }
            precondition(document.frame.height > scroll.contentView.bounds.height,
                         "The small settings pane must scroll to all controls: document \(document.frame), clip \(scroll.contentView.bounds)")
            let y = document.isFlipped ? document.frame.height - scroll.contentView.bounds.height : 0
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            hosting.layoutSubtreeIfNeeded()
        }
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            preconditionFailure("Could not render the HUD")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        if testArguments.count == 2 {
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                preconditionFailure("Could not encode the HUD snapshot")
            }
            let output = URL(fileURLWithPath: testArguments[1]).appendingPathComponent("\(name).png")
            try png.write(to: output)
        }
        return bitmap
    }

    @MainActor static func testPlacementPreferences() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900),
                       CGRect(x: 1440, y: 0, width: 1440, height: 900)]
        var pointer = CGPoint(x: 100, y: 100)
        var caret: CGRect? = CGRect(x: 200, y: 400, width: 1, height: 18)
        var caretReads = 0
        var pointerReads = 0
        let updates = CurrentValueSubject<HUDAppearance, Never>(HUDAppearance())
        let hud = HUDController(appearanceUpdates: updates.eraseToAnyPublisher(), caretProvider: {
            caretReads += 1
            return caret
        }, screenFramesProvider: { screens }, pointerProvider: {
            pointerReads += 1
            return pointer
        })
        func wait(_ seconds: TimeInterval = 0.02) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        func expected(caret: CGRect? = nil, pointer: CGPoint) -> CGRect {
            CaretPlacement.frame(size: hud.model.contentSize, caret: caret, screens: screens, fallbackPoint: pointer)
        }
        func matches(_ actual: CGRect, _ expected: CGRect) -> Bool {
            // AppKit aligns panel origins to display pixels.
            actual.size == expected.size && abs(actual.minX - expected.minX) <= 1
                && abs(actual.minY - expected.minY) <= 1
        }
        hud.show(.listening(handsFree: true))
        wait(0.26)
        precondition(caretReads == 0, "Default placement never reads Accessibility caret geometry")
        precondition(pointerReads == 1, "Fixed mode has no placement polling timer")
        precondition(matches(hud.frame, expected(pointer: pointer)), "Default HUD is bottom center on the pointer's display")
        let firstPointer = pointer
        pointer = CGPoint(x: 1800, y: 500)
        hud.model.preview = String(repeating: "Words that resize the panel. ", count: 15)
        wait(0.26)
        precondition(matches(hud.frame, expected(pointer: firstPointer)), "Resizing remains anchored to the original display")
        precondition(caretReads == 0 && pointerReads == 1, "Fixed resizing never samples the caret or pointer")
        hud.show(.recognizing)
        wait()
        precondition(matches(hud.frame, expected(pointer: firstPointer)),
                     "Changing stages keeps the fixed display: actual \(hud.frame), expected \(expected(pointer: firstPointer))")
        hud.show(.completed)
        let readsBeforeNewRecording = pointerReads
        hud.model.preview = "New recording on the other display"
        hud.show(.listening(handsFree: true))
        precondition(matches(hud.frame, expected(pointer: pointer)),
                     "A new recording during completion review chooses its own active display")
        precondition(pointerReads == readsBeforeNewRecording + 1)
        hud.model.preview = "Another partial on the same display"
        hud.show(.listening(handsFree: true))
        precondition(pointerReads == readsBeforeNewRecording + 1,
                     "Repeated partials in the new session do not resample the display")
        hud.show(.error("Synthetic previous-session error"))
        pointer = firstPointer
        let readsBeforeErrorRecovery = pointerReads
        hud.model.preview = "New recording after an error"
        hud.show(.listening(handsFree: false))
        precondition(matches(hud.frame, expected(pointer: pointer)),
                     "A new recording during error review chooses its own active display")
        precondition(pointerReads == readsBeforeErrorRecovery + 1)
        let errorRecoveryPointer = pointer
        pointer = CGPoint(x: 1800, y: 500)
        hud.model.preview = "Another partial after error recovery"
        hud.show(.listening(handsFree: false))
        precondition(pointerReads == readsBeforeErrorRecovery + 1
                     && matches(hud.frame, expected(pointer: errorRecoveryPointer)),
                     "Partials after error recovery retain the new session's fixed display")
        hud.hide()
        hud.show(.recognizing)
        precondition(matches(hud.frame, expected(pointer: pointer)), "A new session chooses the active display again")
        precondition(caretReads == 0, "Repeated fixed sessions never query the caret")

        updates.send(HUDAppearance(followsCaret: true))
        wait()
        precondition(caretReads == 1, "Enabling follow live immediately queries the caret")
        precondition(matches(hud.frame, expected(caret: caret, pointer: pointer)), "Enabled follow uses caret placement")
        let readsBeforeLayout = caretReads
        hud.model.preview = "A wider recording preview"
        hud.show(.listening(handsFree: true))
        wait()
        precondition(caretReads == readsBeforeLayout, "Follow mode also resizes using the cached caret")
        precondition(matches(hud.frame, expected(caret: caret, pointer: pointer)))
        caret = CGRect(x: 600, y: 600, width: 1, height: 18)
        wait(0.26)
        precondition(caretReads > readsBeforeLayout, "Opt-in follow polls for caret movement")
        precondition(matches(hud.frame, expected(caret: caret, pointer: pointer)), "Polling follows the moved caret")
        caret = nil
        wait(0.26)
        precondition(matches(hud.frame, expected(pointer: pointer)), "Unavailable caret safely falls back to screen bottom")
        caret = CGRect(x: 500, y: 500, width: 1, height: 18)
        wait(0.26)
        precondition(matches(hud.frame, expected(caret: caret, pointer: pointer)),
                     "Following recovers when caret geometry becomes available")

        let readsBeforeDisable = caretReads
        updates.send(HUDAppearance())
        wait()
        precondition(matches(hud.frame, expected(pointer: pointer)), "Disabling follow live moves to fixed bottom center")
        let pointerReadsAfterDisable = pointerReads
        let fixedFrame = hud.frame
        pointer = firstPointer
        caret = CGRect(x: 300, y: 650, width: 1, height: 18)
        wait(0.26)
        precondition(caretReads == readsBeforeDisable, "Disabling follow cancels all caret queries")
        precondition(pointerReads == pointerReadsAfterDisable && hud.frame == fixedFrame,
                     "Fixed placement does not follow the mouse between displays")
        hud.hide()
        updates.send(HUDAppearance(followsCaret: true))
        wait(0.26)
        precondition(caretReads == readsBeforeDisable && hud.model.phase == .hidden,
                     "Enabling follow while hidden neither queries nor reveals the HUD")
        hud.show(.recognizing)
        precondition(caretReads == readsBeforeDisable + 1, "Hidden follow preference takes effect on next show")
        hud.hide()
        let readsAfterHide = caretReads
        wait(0.26)
        precondition(caretReads == readsAfterHide, "Hiding an opted-in HUD cancels tracking")

        var initialFollowReads = 0
        let followingHUD = HUDController(appearance: HUDAppearance(followsCaret: true), caretProvider: {
            initialFollowReads += 1
            return nil
        }, screenFramesProvider: { screens }, pointerProvider: { pointer })
        followingHUD.show(.recognizing)
        wait(0.26)
        precondition(initialFollowReads >= 2, "Persisted opt-in starts tracking without an update publisher")
        precondition(matches(followingHUD.frame, CaretPlacement.frame(size: followingHUD.model.contentSize, caret: nil,
                     screens: screens, fallbackPoint: pointer)), "Persisted opt-in also handles unavailable caret geometry")
        followingHUD.hide()
    }

    @MainActor static func testDictionaryHighlights() throws {
        let model = HUDModel(appearance: HUDAppearance(backdrop: .solid, animationsEnabled: false))
        model.phase = .listening(handsFree: true)
        model.preview = "Review Talkless and \u{5317}\u{4EAC} with \u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}, then Talkless again."
        let plainSize = model.contentSize
        let plainTextSize = model.textSize
        let plain = try snapshot(model, name: "dictionary-unmarked")
        model.setDictionaryTerms(["Talkless", "\u{5317}\u{4EAC}", "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}"])
        func highlights(_ attributed: AttributedString) -> [String] {
            attributed.runs.compactMap { run in
                guard run.underlineStyle != nil else {
                    precondition(run.backgroundColor == nil)
                    return nil
                }
                precondition(run.backgroundColor != nil)
                precondition(run.font == nil && run.foregroundColor == nil,
                             "Decoration cannot change font metrics or transcript text color")
                return String(attributed.characters[run.range])
            }
        }
        precondition(highlights(model.attributedDisplayText()) == ["Talkless", "\u{5317}\u{4EAC}", "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}", "Talkless"])
        precondition(String(model.attributedDisplayText().characters) == model.preview)
        precondition(model.contentSize == plainSize && model.textSize == plainTextSize,
                     "Matching cannot resize or rewrap the HUD")
        let marked = try snapshot(model, name: "dictionary-marked")
        precondition(marked.pixelsWide == plain.pixelsWide && marked.pixelsHigh == plain.pixelsHigh)
        // Check actual rendered ink, not just attributed-string metadata.
        var bluePixels = 0
        var unchangedGlyphs = 0
        for y in 0..<marked.pixelsHigh {
            for x in 0..<marked.pixelsWide {
                let color = marked.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                let prior = plain.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if color.blueComponent - color.redComponent > 0.08,
                   color.blueComponent > prior.blueComponent + 0.05 { bluePixels += 1 }
                if prior.redComponent > 0.9 && prior.greenComponent > 0.9 && prior.blueComponent > 0.9 {
                    precondition(color.redComponent > 0.87 && color.greenComponent > 0.87 && color.blueComponent > 0.87,
                                 "Decoration must preserve bright glyph positions and wrapping")
                    unchangedGlyphs += 1
                }
            }
        }
        precondition(bluePixels > 20 && unchangedGlyphs > 20, "Native renderer must draw the highlight and original glyphs")
        let standard = model.attributedDisplayText()
        let increased = model.attributedDisplayText(increasedContrast: true)
        precondition(highlights(increased) == highlights(standard) && increased != standard)
        model.preview = "Review Talkles"
        precondition(highlights(model.attributedDisplayText()).isEmpty, "Revised partial removes prior match")
        model.preview = "Talkless Talkless"
        precondition(highlights(model.attributedDisplayText()) == ["Talkless", "Talkless"])
        let limit = HUDModel.maximumDictionaryHighlightCharacters
        func paddedTail(_ prefix: String) -> String {
            prefix + String(repeating: " ", count: limit - prefix.count)
        }
        model.setDictionaryTerms(["OpenAI", "\u{5317}\u{4EAC}"])
        for prefix in ["prefix", "pre-", "user_"] {
            model.preview = prefix + paddedTail("OpenAI")
            precondition(highlights(model.attributedDisplayText()).isEmpty,
                         "Cropped suffix cannot create a false lexical boundary")
        }
        model.preview = "Earlier. " + paddedTail("OpenAI")
        precondition(highlights(model.attributedDisplayText()) == ["OpenAI"])
        model.preview = "Earlier \u{5317}" + paddedTail("\u{4EAC}")
        precondition(highlights(model.attributedDisplayText()).isEmpty,
                     "A Chinese phrase beginning outside the highlight tail is omitted, not partially highlighted")
        model.preview = "Earlier \u{5728}" + paddedTail("\u{5317}\u{4EAC}")
        precondition(highlights(model.attributedDisplayText()) == ["\u{5317}\u{4EAC}"],
                     "Han adjacency remains valid at the bounded edge")
        let emoji = "\u{1F469}\u{1F3FD}\u{200D}\u{1F4BB}"
        let decomposed = "Cafe\u{301}"
        model.setDictionaryTerms(["Caf\u{E9}", emoji, "\u{5317}\u{4EAC}"])
        model.preview = String(repeating: emoji, count: 2_000) + " " + paddedTail(decomposed + " " + emoji + " \u{5317}\u{4EAC}")
        precondition(highlights(model.attributedDisplayText()) == [decomposed, emoji, "\u{5317}\u{4EAC}"],
                     "Tail UTF-16 offsets preserve original combining and emoji grapheme indices")
        let legacy = String(repeating: "\u{5317}", count: 4_000) + "\u{4EAC}"
        model.setDictionaryTerms([legacy, "Talkless"])
        model.preview = String(repeating: "\u{5317}", count: 10_000) + " Talkless"
        let input = HUDModel.dictionaryHighlightInput(in: model.preview)
        precondition(input.text.count == limit + 2 && input.contextLength == 2,
                     "Very long transcripts/legacy terms cannot increase matching input beyond the tail bound")
        precondition(input.utf16Offset == (model.preview as NSString).length - (input.text as NSString).length)
        precondition(highlights(model.attributedDisplayText()) == ["Talkless"])
        precondition(String(model.attributedDisplayText().characters) == model.preview,
                     "Only matching is bounded; transcript content is never truncated")
        model.preview = "Talkless Talkless"
        model.isEditMode = true
        precondition(highlights(model.attributedDisplayText()).isEmpty, "Voice edit instructions never imply dictionary use")
        model.isEditMode = false
        for phase in [HUDModel.Phase.working, .recognizing, .polishing, .inserting, .completed] {
            model.phase = phase
            precondition(highlights(model.attributedDisplayText()) == ["Talkless", "Talkless"],
                         "Exact dictionary matches persist across transcript processing and completion")
        }
        model.preview = ""
        model.setDictionaryTerms(["Preparing recognition", "Dictating", "Polishing", "Inserting", "Completed"])
        for phase in [HUDModel.Phase.working, .recognizing, .polishing, .inserting, .completed] {
            model.phase = phase
            precondition(highlights(model.attributedDisplayText()).isEmpty,
                         "Status fallback is never mistaken for recognized dictionary text")
        }
        model.phase = .editing
        precondition(highlights(model.attributedDisplayText()).isEmpty, "Voice edit has no dictation dictionary attribution")
        for phase in [HUDModel.Phase.hidden, .error("Talkless")] {
            model.setDictionaryTerms(["Talkless"])
            model.phase = phase
            precondition(highlights(model.attributedDisplayText()).isEmpty && model.dictionaryTerms.isEmpty)
            model.phase = .listening(handsFree: false)
            precondition(highlights(model.attributedDisplayText()).isEmpty, "Hidden/error matcher cannot leak into a new session")
        }
        let hud = HUDController(caretProvider: { nil }, screenFramesProvider: { [] }, pointerProvider: { .zero })
        hud.model.setDictionaryTerms(["Talkless"])
        hud.model.preview = "Talkless"
        hud.show(.listening(handsFree: true))
        hud.hide()
        precondition(hud.model.dictionaryTerms.isEmpty)
        hud.model.preview = "Talkless"
        precondition(highlights(hud.model.attributedDisplayText()).isEmpty)
        hud.show(.listening(handsFree: false))
        precondition(highlights(hud.model.attributedDisplayText()).isEmpty)
        hud.hide()
        print("PASS exact native dictionary attribution, glyph/layout preservation, partial revisions, edit/status exclusion, contrast, and lifecycle resets")
    }

    @MainActor static func testDictatingPresentation(_ localization: LocalizationSettings) throws {
        precondition(HUDPreviewStage.allCases == [.dictating, .polishing, .editing, .completed],
                     "Settings exposes one continuous dictating stage, not technical capture/recognition phases")
        precondition(HUDPreviewStage.dictating.phase == .listening(handsFree: true))
        for (languageName, language) in [("en", InterfaceLanguage.english), ("zh", .simplifiedChinese)] {
            localization.interfaceLanguage = language
            let label = language == .english ? "Dictating" : "\u{542C}\u{5199}\u{4E2D}"
            precondition(HUDPreviewStage.dictating.title == label)
            for handsFree in [false, true] {
                for editing in [false, true] {
                    let model = HUDModel(appearance: HUDAppearance(backdrop: .solid, animationsEnabled: false))
                    model.isEditMode = editing
                    model.setDictionaryTerms(["Talkless"])
                    for (sampleName, text) in [("empty", ""), ("short", "Review Talkless tomorrow."),
                                              ("long", String(repeating: "Earlier words. ", count: 90) + "Review Talkless tomorrow.")] {
                        let name = "dictating-\(languageName)-\(handsFree ? "toggle" : "hold")-\(editing ? "edit" : "input")-\(sampleName)"
                        model.preview = text
                        model.phase = .listening(handsFree: handsFree)
                        let size = model.contentSize
                        let attributed = model.attributedDisplayText()
                        let captured = try snapshot(model, name: "\(name)-capture")
                        precondition(model.phase.accessibilityLabel == label && model.phase.statusText == nil)
                        model.phase = .recognizing
                        precondition(model.phase == .recognizing, "Engine phase remains distinct after release")
                        precondition(model.phase.accessibilityLabel == label && model.phase.statusText == nil)
                        precondition(model.displayText == text && model.contentSize == size
                                     && model.attributedDisplayText() == attributed,
                                     "Release cannot replace text, rewrap it, or remove dictionary attribution")
                        let recognized = try snapshot(model, name: "\(name)-release")
                        precondition(captured.representation(using: .png, properties: [:]) ==
                                     recognized.representation(using: .png, properties: [:]),
                                     "Capture and final recognition must render the same waveform, text, and empty pill")
                        if text.isEmpty {
                            precondition(size == CGSize(width: 44, height: 40), "No placeholder or reserved footer for empty dictation")
                        }
                    }
                }
            }
        }
        localization.interfaceLanguage = .english
        print("PASS unified dictating label/preview, identical native pixels across release, both locales/gestures, edit mode, empty and overflowing text")
    }

    @MainActor static func testRevisionDecoration() throws {
        let model = HUDModel(appearance: HUDAppearance(backdrop: .solid, animationsEnabled: false))
        model.phase = .completed
        model.preview = "\u{660E}\u{5929}\u{8BA8}\u{8BBA} Talkless。\u{8BF7}\u{53D1}\u{7ED9}\u{6211}。"
        model.setDictionaryTerms(["Talkless"])
        let plainSize = model.contentSize
        let dictionaryOnly = try snapshot(model, name: "revision-dictionary-only")
        model.revisionOriginal = "\u{660E}\u{5929}\u{8BA8}\u{8BBA} Talkles，\u{53D1}\u{7ED9}\u{6211}。"
        let decorated = model.attributedDisplayText()
        precondition(String(decorated.characters) == model.preview && model.contentSize == plainSize)
        let dictionary = decorated.runs.filter { $0.underlineStyle != nil }.map { String(decorated.characters[$0.range]) }.joined()
        precondition(dictionary == "Talkless", "Blue dictionary underline survives overlapping revision fill")
        let changed = decorated.runs.filter { $0.backgroundColor != nil && $0.underlineStyle == nil }
            .map { String(decorated.characters[$0.range]) }.joined()
        precondition(changed.contains("\u{8BF7}") && changed.contains("。"), "Actual additions and punctuation replacements get fill")
        precondition(decorated.runs.allSatisfy { $0.font == nil && $0.foregroundColor == nil })
        let revised = try snapshot(model, name: "revision-marked")
        precondition(revised.pixelsWide == dictionaryOnly.pixelsWide && revised.pixelsHigh == dictionaryOnly.pixelsHigh)
        var amberPixels = 0
        for y in 0..<revised.pixelsHigh {
            for x in 0..<revised.pixelsWide {
                let color = revised.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if color.redComponent - color.blueComponent > 0.06,
                   color.greenComponent - color.blueComponent > 0.03 { amberPixels += 1 }
            }
        }
        precondition(amberPixels > 20, "Native renderer must draw factual change fill")
        model.isEditMode = true
        precondition(model.attributedDisplayText().runs.allSatisfy { $0.backgroundColor == nil && $0.underlineStyle == nil },
                     "Voice-edit output is not compared with the spoken instruction")
        model.isEditMode = false
        model.phase = .polishing
        precondition(model.attributedDisplayText().runs.filter { $0.underlineStyle == nil }.allSatisfy { $0.backgroundColor == nil },
                     "No claimed changes before final AI output exists")
        model.phase = .hidden
        precondition(model.revisionOriginal == nil)
        print("PASS native factual revision fill, overlap with exact dictionary underline, unchanged glyph metrics, and edit/processing/lifecycle exclusions")
    }

    @MainActor static func transcriptReview(_ localization: LocalizationSettings) throws {
        for (languageName, language) in [("zh", InterfaceLanguage.simplifiedChinese), ("en", .english)] {
            localization.interfaceLanguage = language
            let chinese = language == .simplifiedChinese
            let raw = chinese ? "\u{660E}\u{5929}\u{4E0A}\u{5348}\u{8BA8}\u{8BBA} Talkless，\u{628A}\u{4F1A}\u{540E}\u{7684}\u{7B14}\u{8BB0}\u{53D1}\u{7ED9}\u{6211}。" : "Let's discuss Talkless tomorrow morning, send me the notes after the meeting."
            let final = chinese ? "\u{660E}\u{5929}\u{4E0A}\u{5348}\u{8BA8}\u{8BBA} Talkless。\u{4F1A}\u{540E}\u{8BF7}\u{628A}\u{7B14}\u{8BB0}\u{53D1}\u{7ED9}\u{6211}。" : "Let's discuss Talkless tomorrow morning. Please send me the notes after the meeting."
            var models: [HUDModel] = []
            var labels: [String] = []
            for stage in HUDPreviewStage.allCases {
                let model = HUDModel(appearance: HUDAppearance(animationsEnabled: false))
                model.phase = stage.phase
                model.preview = stage == .completed ? final : raw
                model.isEditMode = stage == .editing
                model.revisionOriginal = stage == .completed ? raw : nil
                model.setDictionaryTerms(["Talkless"])
                models.append(model)
                labels.append(stage == .dictating ? (chinese ? "\u{542C}\u{5199}\u{4E2D} · \u{6B63}\u{5728}\u{8BF4}\u{8BDD}" : "Dictating · speaking") : stage.title)
                try snapshot(model, name: "transcript-\(languageName)-\(stage.rawValue)")
                if stage == .dictating {
                    let released = HUDModel(appearance: model.appearance)
                    released.phase = .recognizing
                    released.preview = raw
                    released.setDictionaryTerms(["Talkless"])
                    models.append(released)
                    labels.append(chinese ? "\u{542C}\u{5199}\u{4E2D} · \u{677E}\u{952E}\u{540E}\u{4ECD}\u{4FDD}\u{6301}\u{6CE2}\u{5F62}" : "Dictating · same waveform after release")
                    try snapshot(released, name: "transcript-\(languageName)-released")
                }
                if stage == .completed {
                    model.phase = .inserting
                    try snapshot(model, name: "transcript-\(languageName)-inserting")
                    model.phase = .completed
                }
            }
            let empty = HUDModel(appearance: HUDAppearance(animationsEnabled: false))
            empty.phase = .listening(handsFree: true)
            precondition(empty.displayText.isEmpty && empty.contentSize == CGSize(width: 44, height: 40))
            models.append(empty)
            try snapshot(empty, name: "transcript-\(languageName)-empty")
            labels.append(chinese ? "\u{542C}\u{5199}\u{4E2D} · \u{5C1A}\u{65E0}\u{6587}\u{5B57}" : "Dictating · no words yet")
            let sheet = VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(chinese ? "\u{6587}\u{5B57}\u{7559}\u{5728}\u{539F}\u{5904}，\u{56FE}\u{6807}\u{8BF4}\u{660E}\u{8FDB}\u{5EA6}" : "The words stay. The icon shows progress.")
                        .font(.system(size: 23, weight: .semibold))
                    Text(chinese ? "\u{8FB9}\u{8BF4}\u{8FB9}\u{542C}\u{5199}，\u{677E}\u{952E}\u{540E}\u{4E0D}\u{5207}\u{6362}\u{56FE}\u{6807}；\u{6DA6}\u{8272}\u{65F6}\u{624D}\u{53D8}\u{4E3A}\u{661F}\u{5149}，\u{5B8C}\u{6210}\u{540E}\u{770B}\u{6E05}\u{5B9E}\u{9645}\u{4FEE}\u{6539}。" : "One waveform while speaking and after release; sparkles for polishing, actual changes on completion.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.fixed(408)), GridItem(.fixed(408))], alignment: .leading, spacing: 22) {
                    ForEach(models.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(labels[index]).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                            ZStack(alignment: .leading) {
                                Color.clear
                                HUDView(model: models[index], materialBlending: .withinWindow)
                            }
                            .frame(width: 408, height: 90)
                        }
                    }
                }
                Text(chinese ? "\u{84DD}\u{8272}\u{4E0B}\u{5212}\u{7EBF}：\u{8BCD}\u{5178}\u{5339}\u{914D} · \u{6696}\u{8272}\u{9AD8}\u{4EAE}：AI \u{5B9E}\u{9645}\u{4FEE}\u{6539} · \u{5B8C}\u{6210}\u{540E}\u{8BA1}\u{5212} 50 ms \u{540E}\u{5173}\u{95ED}（\u{5C3D}\u{529B}\u{8C03}\u{5EA6}） · \u{9759}\u{6001}\u{9884}\u{89C8}" : "Blue: dictionary match · Amber: actual AI change · Hide scheduled after 50 ms (best effort) · Static preview")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding(30)
            .frame(width: 898, height: 592, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            try snapshotView(sheet, size: CGSize(width: 898, height: 592), name: "transcript-contact-\(languageName)")
        }
        localization.interfaceLanguage = .english
    }

    @MainActor static func main() throws {
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        localization.interfaceLanguage = .english
        defer { withExtendedLifetime(localization) {} }
        _ = NSApplication.shared
        testPlacementPreferences()
        try testDictionaryHighlights()
        try testDictatingPresentation(localization)
        try testRevisionDecoration()
        try transcriptReview(localization)
        var caretReads = 0
        let updates = CurrentValueSubject<HUDAppearance, Never>(HUDAppearance())
        let hud = HUDController(appearanceUpdates: updates.eraseToAnyPublisher(), caretProvider: {
            caretReads += 1
            return CGRect(x: 200, y: 400, width: 1, height: 18)
        })
        precondition(hud.isClickThrough && hud.isNonactivating)
        hud.model.preview = "Recognized words"
        hud.show(.listening(handsFree: true))
        precondition(hud.model.displayText == "Recognized words")
        precondition(hud.model.phase.statusText == nil)
        let shortSize = hud.model.contentSize
        let shortFrame = hud.frame
        let readsBeforeAppearanceChange = caretReads
        let updatedAppearance = HUDAppearance(backdrop: .solid, backgroundOpacity: 0.25, animationsEnabled: false)
        updates.send(updatedAppearance)
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        precondition(hud.model.appearance == updatedAppearance, "Published settings apply to a visible HUD")
        precondition(hud.frame == shortFrame, "Appearance does not move or resize the HUD")
        precondition(caretReads == readsBeforeAppearanceChange, "Appearance does not poll the caret")
        precondition(hud.isClickThrough && hud.isNonactivating, "Appearance never changes panel interaction")
        hud.model.preview = String(repeating: "A longer sentence with natural word wrapping. ", count: 6)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let longSize = hud.model.contentSize
        precondition(longSize.width > shortSize.width && longSize.height > shortSize.height)
        precondition(longSize.width <= HUDModel.maximumWidth && longSize.height <= HUDModel.maximumHeight)
        precondition(hud.frame.size == longSize)
        precondition(caretReads == 0, "Default adaptive layout never queries the caret")
        try snapshot(hud.model, name: "long-recording")
        hud.model.preview = String(repeating: "\u{957F}\u{53E5}\u{6362}\u{884C}\u{6D4B}\u{8BD5}", count: 100)
        hud.show(.listening(handsFree: false))
        precondition(hud.model.contentSize.height == HUDModel.maximumHeight)
        precondition(hud.model.textSize.height > HUDModel.maximumHeight)
        hud.model.preview = String(repeating: "Earlier words that should scroll out of view. ", count: 40) + "LATEST WORDS"
        hud.show(.listening(handsFree: true))
        try snapshot(hud.model, name: "overflow-recording")
        hud.model.preview = "First line\nSecond line\nThird line"
        hud.show(.listening(handsFree: true))
        precondition(hud.model.contentSize.height > shortSize.height)
        try snapshot(hud.model, name: "explicit-newlines")
        hud.model.preview = "Recognized words"
        hud.show(.listening(handsFree: true))
        precondition(hud.model.contentSize == shortSize, "No visible recording footer or reserved footer space")
        precondition(hud.frame.size == hud.model.contentSize)
        try snapshot(hud.model, name: "alternate-finish")
        hud.model.preview = String(repeating: "Earlier words fill the preview. ", count: 40) + "LATEST WORDS"
        hud.show(.listening(handsFree: true))
        precondition(hud.model.contentSize.height == HUDModel.maximumHeight)
        try snapshot(hud.model, name: "alternate-finish-long")
        hud.model.isEditMode = true
        precondition(hud.model.contentSize.height == HUDModel.maximumHeight)
        hud.model.isEditMode = false
        hud.model.preview = "Recognized words"
        for (phase, label) in [
            (HUDModel.Phase.working, "Preparing recognition"),
            (.recognizing, "Dictating"),
            (.polishing, "Polishing"),
            (.editing, "Editing"),
            (.inserting, "Inserting"),
            (.completed, "Completed")
        ] {
            hud.show(phase)
            precondition(hud.model.phase == phase)
            precondition(hud.model.phase.accessibilityLabel == label, "Icon phase remains verbal for accessibility")
            precondition(hud.model.preview == "Recognized words")
            precondition(hud.model.displayText == "Recognized words" && hud.model.contentSize == shortSize)
            precondition(hud.model.textAlignment == .bottomLeading)
            hud.model.preview = "Late recognition preview"
            precondition(hud.model.displayText == "Late recognition preview")
            hud.model.preview = ""
            precondition(hud.model.displayText == (phase == .recognizing ? "" : label))
            hud.model.preview = "Recognized words"
            try snapshot(hud.model, name: String(label.prefix(while: { $0 != " " })).lowercased())
        }
        hud.show(.hidden)
        precondition(hud.model.phase == .hidden)
        precondition(hud.model.preview.isEmpty)
        precondition(hud.model.displayText.isEmpty)
        hud.show(.error("Microphone unavailable"))
        precondition(hud.model.phase == .error("Microphone unavailable"))
        precondition(hud.model.displayText == "Microphone unavailable")
        hud.hide()
        precondition(hud.model.phase == .hidden)
        let readsAfterHide = caretReads
        updates.send(HUDAppearance(backgroundOpacity: 0.6, animationsEnabled: false))
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        precondition(caretReads == readsAfterHide, "Hidden HUD stops caret tracking")
        precondition(hud.model.appearance.backgroundOpacity == 0.6, "Hidden HUD receives settings for next use")
        precondition(hud.model.phase == .hidden, "Settings never reveal a hidden HUD")
        hud.show(.recognizing)
        hud.hide(after: .milliseconds(40))
        hud.show(.polishing)
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        precondition(hud.model.phase == .polishing, "New stage cancels a stale hide task")
        hud.hide()
        var completionLifecycleFinished = false
        Task { @MainActor in
            hud.model.preview = "Final result"
            hud.model.revisionOriginal = "Raw result"
            hud.show(.completed)
            precondition(hud.model.phase == .completed && hud.model.preview == "Final result",
                         "Completion is set immediately without a blocking dwell")
            // Let the dismissal task start, then replace the result without assuming
            // humans can inspect a 50 ms confirmation or requiring a 100 ms dwell.
            await Task.yield()
            hud.model.preview = "New recording"
            hud.model.revisionOriginal = nil
            hud.show(.listening(handsFree: true))
            try! await Task.sleep(for: .milliseconds(150))
            precondition(hud.model.phase == .listening(handsFree: true) && hud.model.preview == "New recording",
                         "Old completion dismissal cannot hide a new session")
            hud.model.preview = "Final result"
            hud.model.revisionOriginal = "Raw result"
            hud.show(.completed)
            // The source assertion pins 50 ms. Exercise the actual asynchronous hide
            // with bounded scheduler slack, not a race against an exact wall-clock instant.
            let clock = ContinuousClock()
            let dismissalDeadline = clock.now.advanced(by: .seconds(1))
            while hud.model.phase != .hidden && clock.now < dismissalDeadline {
                try! await Task.sleep(for: .milliseconds(10))
            }
            precondition(hud.model.phase == .hidden && hud.model.preview.isEmpty && hud.model.revisionOriginal == nil,
                         "Completion automatically clears well before the old two-second dwell")
            hud.show(.error("Synthetic error"))
            try! await Task.sleep(for: .milliseconds(150))
            precondition(hud.model.phase == .error("Synthetic error"),
                         "Short completion timeout does not shorten the error display")
            hud.hide()
            completionLifecycleFinished = true
        }
        let lifecycleDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !completionLifecycleFinished && ContinuousClock.now < lifecycleDeadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(completionLifecycleFinished, "Asynchronous completion lifecycle must finish within its time cap")

        let preview = HUDModel(appearance: HUDAppearance(animationsEnabled: false))
        for stage in HUDPreviewStage.allCases {
            preview.phase = stage.phase
            preview.preview = HUDPreviewSample.short.text
            precondition(preview.displayText == HUDPreviewSample.short.text)
            let stageSize = preview.contentSize
            for opacity in [0.2, 0.9, 1.0] {
                preview.appearance.backgroundOpacity = opacity
                precondition(preview.contentSize == stageSize, "Opacity never changes text geometry")
                try snapshot(preview, name: "\(stage.rawValue)-opacity-\(Int(opacity * 100))")
            }
            preview.appearance.backdrop = .solid
            try snapshot(preview, name: "\(stage.rawValue)-solid")
            preview.appearance.backdrop = .translucent
            try snapshot(preview, name: "\(stage.rawValue)-reduced-transparency", reduceTransparency: true)
            try snapshot(preview, name: "\(stage.rawValue)-embedded", reduceMotion: true)
            try snapshotView(OverlayPreview(appearance: preview.appearance, stage: stage, sample: .long),
                size: CGSize(width: 550, height: 214), name: "preview-\(stage.rawValue)")
        }
        preview.phase = .listening(handsFree: true)
        preview.preview = HUDPreviewSample.long.text
        precondition(preview.textSize.height > HUDModel.maximumHeight, "Long sample exercises latest-line clipping")
        try snapshot(preview, name: "sample-long")
        try snapshotView(OverlaySettingsView(appearance: .constant(HUDAppearance(animationsEnabled: false))),
            size: CGSize(width: 603, height: 478), name: "overlay-settings-small")
        try snapshotView(OverlaySettingsView(appearance: .constant(HUDAppearance(animationsEnabled: false))),
            size: CGSize(width: 703, height: 558), name: "overlay-settings")
        try snapshotView(OverlaySettingsView(appearance: .constant(HUDAppearance(animationsEnabled: false))),
            size: CGSize(width: 603, height: 478), name: "overlay-settings-small-bottom", scrollToBottom: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
            try snapshotView(OverlayPreview(appearance: HUDAppearance(animationsEnabled: false),
                stage: .dictating, sample: .short).environment(\.colorScheme, scheme),
                size: CGSize(width: 550, height: 214), name: "preview-\(name)")
        }
        // Render the real production settings/HUD in both languages and appearances.
        // This local localization object has nil defaults: language changes never persist.
        for (languageName, language) in [("en", InterfaceLanguage.english), ("zh-Hans", .simplifiedChinese)] {
            localization.interfaceLanguage = language
            localization.refreshLocale()
            for (schemeName, scheme) in [("light", ColorScheme.light), ("dark", .dark)] {
                try snapshotView(OverlayPreview(appearance: HUDAppearance(animationsEnabled: false),
                    stage: .dictating, sample: .dictionary).environment(\.colorScheme, scheme),
                    size: CGSize(width: 550, height: 214), name: "dictionary-preview-\(languageName)-\(schemeName)")
                try snapshotView(OverlaySettingsView(appearance: .constant(HUDAppearance(animationsEnabled: false)))
                    .environment(\.colorScheme, scheme),
                    size: CGSize(width: 703, height: 640), name: "dictionary-settings-\(languageName)-\(schemeName)")
                let terms = ["Talkless", "\u{5317}\u{4EAC}", "\u{7528}\u{6237}\u{8BCD}\u{5178}"]
                preview.setDictionaryTerms(terms)
                preview.preview = language == .english
                    ? "Let's review Talkless tomorrow."
                    : "\u{660E}\u{5929}\u{5728}\u{5317}\u{4EAC}\u{8BA8}\u{8BBA} Talkless \u{548C}\u{7528}\u{6237}\u{8BCD}\u{5178}\u{3002}"
                try snapshotView(HUDView(model: preview).environment(\.colorScheme, scheme), size: preview.contentSize,
                    name: "dictionary-hud-\(languageName)-\(schemeName)")
            }
        }
        localization.interfaceLanguage = .english
        preview.setDictionaryTerms([])
        preview.preview = HUDPreviewSample.short.text
        preview.appearance.backgroundOpacity = 0.2
        let faint = try snapshot(preview, name: "alpha-faint")
        preview.appearance.backgroundOpacity = 1
        let opaque = try snapshot(preview, name: "alpha-opaque")
        // Rendered text must remain opaque even when the surrounding backdrop fades.
        // Reduce Transparency can force both backgrounds opaque on an accessible host.
        let backgroundX = faint.pixelsWide / 2
        let backgroundY = faint.pixelsHigh - 8
        let faintAlpha = faint.colorAt(x: backgroundX, y: backgroundY)!.alphaComponent
        let opaqueAlpha = opaque.colorAt(x: backgroundX, y: backgroundY)!.alphaComponent
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            precondition(opaqueAlpha - faintAlpha > 0.5, "Slider changes rendered backdrop alpha")
        }
        var textPixels = 0
        for y in 10..<(opaque.pixelsHigh - 10) {
            for x in 40..<(opaque.pixelsWide - 15) {
                let color = opaque.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                if color.redComponent > 0.8 && color.greenComponent > 0.8 && color.blueComponent > 0.8 {
                    let other = faint.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    if color.alphaComponent > 0.98 {
                        precondition(other.alphaComponent > 0.75, "Backdrop opacity must not fade text")
                        textPixels += 1
                    }
                }
            }
        }
        precondition(textPixels > 10, "Text opacity assertion samples real glyphs")
        print("PASS HUD default fixed placement, opt-in caret tracking, live toggling, fallback, appearance updates, native preview snapshots, click-through, adaptive wrapping, processing stages, and hide lifecycle")
    }
}
"""#.write(to: source, atomically: true, encoding: .utf8)
func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
}
let binary = directory.appendingPathComponent("hud-tests")
try run("/usr/bin/xcrun", ["swiftc", "-swift-version", "6", "-parse-as-library", source.path, displaySource.path,
    root.appendingPathComponent("Sources/Talkless/L10n.swift").path,
    root.appendingPathComponent("Sources/Talkless/TranslationLanguages.swift").path,
    root.appendingPathComponent("Sources/Talkless/LanguagePickerView.swift").path,
    root.appendingPathComponent("Sources/Talkless/HUDAppearance.swift").path,
    root.appendingPathComponent("Sources/Talkless/Overlay.swift").path,
    root.appendingPathComponent("Sources/Talkless/DictionaryHighlight.swift").path,
    root.appendingPathComponent("Sources/Talkless/TextRevisionHighlight.swift").path,
    root.appendingPathComponent("Sources/Talkless/OverlaySettingsView.swift").path,
    root.appendingPathComponent("Sources/Talkless/CaretPosition.swift").path,
    root.appendingPathComponent("Sources/Talkless/TextIO.swift").path, "-o", binary.path])
// Overlay settings observe the production shared localization object. Override its read
// through NSArgumentDomain only; never write the user's persisted language preference.
try run(binary.path, Array(CommandLine.arguments.dropFirst()) + ["-interfaceLanguage", "english"])
