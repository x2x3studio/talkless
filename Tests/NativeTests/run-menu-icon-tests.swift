import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let artwork = try String(contentsOf: root.appendingPathComponent("scripts/generate-icon.swift"), encoding: .utf8)
let menuArtwork = try String(contentsOf: root.appendingPathComponent("Sources/Talkless/MenuBarIcon.swift"), encoding: .utf8)
for name in ["voicePath", "caretPath"] {
    let pattern = "func " + name + #"\(\) -> CGPath \{([\s\S]*?)return p"#
    let regex = try NSRegularExpression(pattern: pattern)
    func pathBody(_ source: String) -> [String] {
        let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source))!
        return String(source[Range(match.range(at: 1), in: source)!]).split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
    precondition(pathBody(artwork) == pathBody(menuArtwork), "Menu mark must match application artwork")
}
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("talkless-menu-icon-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let source = directory.appendingPathComponent("MenuIconTests.swift")
try #"""
import AppKit

@main struct MenuIconTests {
    @MainActor static func main() throws {
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        localization.interfaceLanguage = .english
        defer { withExtendedLifetime(localization) {} }
        _ = NSApplication.shared
        var rendered: [Data] = []
        for state in MenuBarIcon.State.allCases {
            let image = MenuBarIcon.image(for: state)
            precondition(image.isTemplate)
            precondition(image.size == NSSize(width: 25, height: 18))
            precondition(image.accessibilityDescription == state.accessibilityDescription)
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 72,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: CGRect(x: 0, y: 0, width: 100, height: 72))
            NSGraphicsContext.restoreGraphicsState()
            let png = bitmap.representation(using: .png, properties: [:])!
            rendered.append(png)
            var opaquePixels = 0
            for y in 0..<72 {
                for x in 0..<100 {
                    if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 { opaquePixels += 1 }
                }
            }
            precondition(opaquePixels > 300 && opaquePixels < 3000, "Mark must be visible without a solid tile")
            if CommandLine.arguments.count == 2 {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSColor.white.setFill()
                CGRect(x: 0, y: 0, width: 100, height: 72).fill()
                image.draw(in: CGRect(x: 0, y: 0, width: 100, height: 72))
                NSGraphicsContext.restoreGraphicsState()
                let url = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("\(state).png")
                try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            }
        }
        precondition(Set(rendered).count == 3, "States need distinct badges")
        print("PASS custom template artwork, state badges, and accessible labels")
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
let binary = directory.appendingPathComponent("menu-icon-tests")
try run("/usr/bin/xcrun", ["swiftc", "-swift-version", "6", "-parse-as-library", source.path,
    root.appendingPathComponent("Sources/Talkless/L10n.swift").path,
    root.appendingPathComponent("Sources/Talkless/MenuBarIcon.swift").path, "-o", binary.path])
try run(binary.path, Array(CommandLine.arguments.dropFirst()))
