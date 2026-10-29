import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("talkless-quiet-hud-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let source = directory.appendingPathComponent("HUDTests.swift")
try #"""
import AppKit

@main
struct HUDTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        let hud = HUDController()
        hud.model.preview = "Recognized words"
        hud.show(.listening(handsFree: true))
        precondition(hud.model.preview == "Recognized words")
        hud.show(.working)
        precondition(hud.model.preview == "Recognized words")
        hud.show(.hidden)
        precondition(hud.model.phase == .hidden)
        precondition(hud.model.preview.isEmpty)
        hud.show(.error("Microphone unavailable"))
        precondition(hud.model.phase == .error("Microphone unavailable"))
        hud.hide()
        precondition(hud.model.phase == .hidden)
        print("PASS silent processing retains preview; completion hides immediately; errors remain visible")
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
    root.appendingPathComponent("Sources/Talkless/TextIO.swift").path, "-o", binary.path])
try run(binary.path, [])
