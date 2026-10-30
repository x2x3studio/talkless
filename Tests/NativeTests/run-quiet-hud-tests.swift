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
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let hud = HUDController()
        hud.model.preview = "Recognized words"
        hud.show(.listening(handsFree: true))
        precondition(hud.model.displayText == "Recognized words")
        precondition(hud.model.phase.statusText == nil)
        for (phase, label) in [
            (HUDModel.Phase.working, "Preparing recognition…"),
            (.recognizing, "Recognizing…"),
            (.polishing, "Polishing…"),
            (.editing, "Editing…")
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
            if CommandLine.arguments.count == 2 {
                let hosting = NSHostingView(rootView: HUDView(model: hud.model))
                hosting.setFrameSize(NSSize(width: HUDModel.maximumWidth, height: HUDModel.maximumHeight))
                hosting.layoutSubtreeIfNeeded()
                guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
                    preconditionFailure("Could not render the HUD")
                }
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]) else {
                    preconditionFailure("Could not encode the HUD snapshot")
                }
                let name = String(label.prefix(while: { $0 != " " && $0 != "…" })).lowercased()
                let output = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("\(name).png")
                try png.write(to: output)
            }
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
