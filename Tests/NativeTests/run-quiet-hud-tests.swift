import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("talkless-quiet-hud-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let source = directory.appendingPathComponent("HUDTests.swift")
try #"""
import AppKit
import SwiftUI

@main
struct HUDTests {
    @MainActor static func snapshot(_ model: HUDModel, name: String) throws {
        guard CommandLine.arguments.count == 2 else { return }
        let hosting = NSHostingView(rootView: HUDView(model: model))
        hosting.setFrameSize(model.contentSize)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            preconditionFailure("Could not render the HUD")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            preconditionFailure("Could not encode the HUD snapshot")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("\(name).png")
        try png.write(to: output)
    }

    @MainActor static func main() throws {
        _ = NSApplication.shared
        let hud = HUDController()
        hud.model.preview = "Recognized words"
        hud.show(.listening(handsFree: true))
        precondition(hud.model.displayText == "Recognized words")
        precondition(hud.model.phase.statusText == nil)
        let shortSize = hud.model.contentSize
        hud.model.preview = String(repeating: "A longer sentence with natural word wrapping. ", count: 6)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let longSize = hud.model.contentSize
        precondition(longSize.width > shortSize.width && longSize.height > shortSize.height)
        precondition(longSize.width <= HUDModel.maximumWidth && longSize.height <= HUDModel.maximumHeight)
        precondition(hud.frame.size == longSize)
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
        print("PASS processing stages override preview; completion hides immediately; errors remain visible")
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
    root.appendingPathComponent("Sources/Talkless/Overlay.swift").path,
    root.appendingPathComponent("Sources/Talkless/CaretPosition.swift").path,
    root.appendingPathComponent("Sources/Talkless/TextIO.swift").path, "-o", binary.path])
try run(binary.path, Array(CommandLine.arguments.dropFirst()))
