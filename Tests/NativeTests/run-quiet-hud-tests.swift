import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("talkless-quiet-hud-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let source = directory.appendingPathComponent("HUDTests.swift")
try #"""
import AppKit
import Combine
import SwiftUI

@main
struct HUDTests {
    @MainActor @discardableResult
    static func snapshot(_ model: HUDModel, name: String,
                         reduceTransparency: Bool = false, reduceMotion: Bool = true) throws -> NSBitmapImageRep {
        // Accessibility environment values are read-only. Render their resolved appearance
        // without changing macOS preferences; the pure policy is tested separately.
        let rendered = HUDModel(appearance: model.appearance)
        rendered.phase = model.phase
        rendered.preview = model.preview
        rendered.isEditMode = model.isEditMode
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
        if CommandLine.arguments.count == 2 {
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                preconditionFailure("Could not encode the HUD snapshot")
            }
            let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("\(name).png")
            try png.write(to: output)
        }
        return bitmap
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
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
        precondition(caretReads == readsBeforeAppearanceChange, "Adaptive layout uses the cached caret")
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
        for (phase, label) in [
            (HUDModel.Phase.working, "Preparing recognition"),
            (.recognizing, "Recognizing"),
            (.polishing, "Polishing"),
            (.editing, "Editing")
        ] {
            hud.show(phase)
            precondition(hud.model.phase == phase)
            precondition(hud.model.preview == "Recognized words")
            precondition(hud.model.displayText == label)
            hud.model.preview = "Late recognition preview"
            precondition(hud.model.displayText == label)
            hud.model.preview = ""
            precondition(hud.model.displayText == label)
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

        let preview = HUDModel(appearance: HUDAppearance(animationsEnabled: false))
        for stage in HUDPreviewStage.allCases {
            preview.phase = stage.phase
            preview.preview = HUDPreviewSample.short.text
            precondition(preview.displayText == (stage == .recording ? HUDPreviewSample.short.text : stage.title))
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
                stage: .recording, sample: .short).environment(\.colorScheme, scheme),
                size: CGSize(width: 550, height: 214), name: "preview-\(name)")
        }
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
        print("PASS HUD appearance updates, native preview snapshots, cached caret, click-through, adaptive wrapping, processing stages, and hide lifecycle")
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
try run("/usr/bin/xcrun", ["swiftc", "-swift-version", "6", "-parse-as-library", source.path,
    root.appendingPathComponent("Sources/Talkless/HUDAppearance.swift").path,
    root.appendingPathComponent("Sources/Talkless/Overlay.swift").path,
    root.appendingPathComponent("Sources/Talkless/OverlaySettingsView.swift").path,
    root.appendingPathComponent("Sources/Talkless/CaretPosition.swift").path,
    root.appendingPathComponent("Sources/Talkless/TextIO.swift").path, "-o", binary.path])
try run(binary.path, Array(CommandLine.arguments.dropFirst()))
