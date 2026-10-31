import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let artwork = try String(contentsOf: root.appendingPathComponent("scripts/generate-icon.swift"), encoding: .utf8)
let menuArtwork = try String(contentsOf: root.appendingPathComponent("Sources/Talkless/MenuBarIcon.swift"), encoding: .utf8)
func pipSource(_ source: String) -> String {
    guard let start = source.range(of: "// BEGIN PIP ARTWORK"),
          let end = source.range(of: "// END PIP ARTWORK") else {
        preconditionFailure("Missing canonical Pip artwork block")
    }
    return String(source[start.lowerBound..<end.upperBound])
}
// Include composition, eyes, and optical correction, not just the outer path.
precondition(pipSource(artwork) == pipSource(menuArtwork), "Generator and menu must use identical Pip geometry")
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("talkless-menu-icon-\(UUID())")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let source = directory.appendingPathComponent("MenuIconTests.swift")
try #"""
import AppKit

@main struct MenuIconTests {
    @MainActor static func raster(_ image: NSImage, scale: Int) -> NSBitmapImageRep {
        let bitmap = bitmap(width: 28 * scale, height: 18 * scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: CGRect(x: 0, y: 0, width: 28 * scale, height: 18 * scale))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    static func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    }

    static func alpha(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> CGFloat {
        bitmap.colorAt(x: x, y: y)!.alphaComponent
    }

    static func write(_ bitmap: NSBitmapImageRep, to url: URL) throws {
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    static func checkApprovedOutline() {
        // Original case-I coordinates, independent of either production copy.
        let expected: [[CGFloat]] = [
            [292,715], [218,645,214,503,260,410], [292,271],
            [299,239,323,237,345,267], [405,348], [463,327,521,326,583,344],
            [679,260], [705,237,729,250,730,282], [730,430],
            [789,497,800,616,754,690], [716,752,648,778,580,771],
            [533,766,485,790,438,782], [397,775,368,744,339,740],
            [322,738,305,728,292,715], []
        ]
        var actual: [[CGFloat]] = []
        PipArtwork.bodyPath().applyWithBlock { element in
            let element = element.pointee
            let count: Int
            switch element.type {
            case .moveToPoint, .addLineToPoint: count = 1
            case .addQuadCurveToPoint: count = 2
            case .addCurveToPoint: count = 3
            case .closeSubpath: count = 0
            @unknown default: preconditionFailure("Unexpected path element")
            }
            actual.append((0..<count).flatMap { [element.points[$0].x, element.points[$0].y] })
        }
        precondition(actual == expected, "Preserve the approved Pip outline without redesign")
        for small in [false, true] {
            let path = PipArtwork.path(small: small)
            for point in [CGPoint(x: 418, y: 532), CGPoint(x: 589, y: 516),
                          CGPoint(x: 432, y: 525), CGPoint(x: 598, y: 507), CGPoint(x: 505, y: 649)] {
                precondition(!path.contains(point, using: .evenOdd), "Eyes, former pupil positions, and smile must be holes")
            }
            for point in [CGPoint(x: 320, y: 300), CGPoint(x: 700, y: 300),
                          CGPoint(x: 503, y: 520), CGPoint(x: 510, y: 725)] {
                precondition(path.contains(point, using: .evenOdd), "Ears, eye bridge, and chin must retain the solid silhouette")
            }
        }
    }

    @MainActor static func checkRaster(_ bitmap: NSBitmapImageRep, state: MenuBarIcon.State, scale: Int) {
        var bodyPixels = 0
        for y in 0..<18 * scale {
            for x in 0..<28 * scale {
                let a = alpha(bitmap, x, y)
                if x < 18 * scale && a > 0.5 { bodyPixels += 1 }
                if x >= 18 * scale && x < 21 * scale {
                    precondition(a == 0, "State badge needs an uninterrupted transparent gutter")
                }
                if x < scale || x >= 27 * scale || y < scale || y >= 17 * scale {
                    precondition(a < 0.05, "Artwork must not clip or introduce a background tile")
                }
            }
        }
        precondition(bodyPixels > 90 * scale * scale && bodyPixels < 180 * scale * scale,
                     "Pip must remain a substantial readable silhouette at 1x and 2x")
        func minAlpha(around point: CGPoint, radius: CGFloat) -> CGFloat {
            let px = (9.5 + (point.x - 512) * 0.027) * CGFloat(scale)
            let py = (9 + (point.y - 512) * 0.027) * CGFloat(scale)
            let r = radius * CGFloat(scale)
            return (Int(floor(py-r))...Int(floor(py+r))).flatMap { y in
                (Int(floor(px-r))...Int(floor(px+r))).map { x in alpha(bitmap, x, y) }
            }.min()!
        }
        for eye in [CGPoint(x: 418, y: 532), CGPoint(x: 589, y: 516)] {
            precondition(minAlpha(around: eye, radius: 0.45) < 0.05, "Both eye holes must survive native-size rasterization")
        }
        precondition(minAlpha(around: CGPoint(x: 505, y: 649), radius: 0.5) < 0.6,
                     "Optical smile must remain open at native size")
        // Badge column x 21..<27 pt: a solid dot near the top while recording, a taller
        // question mark while processing, nothing while idle.
        func ink(rows: Range<Int>) -> Int {
            rows.flatMap { y in (21 * scale..<27 * scale).map { x in alpha(bitmap, x, y) } }.filter { $0 > 0.5 }.count
        }
        let upper = ink(rows: 0..<7 * scale), lower = ink(rows: 8 * scale..<17 * scale)
        switch state {
        case .idle: precondition(upper == 0 && lower == 0, "Idle has no badge")
        case .recording:
            precondition(alpha(bitmap, 24 * scale, 4 * scale) > 0.9 && upper > 12 * scale * scale && lower == 0,
                         "Recording uses a solid, enlarged dot at the top")
        case .processing:
            precondition(upper > 4 * scale * scale && lower > 2 * scale * scale,
                         "Processing uses a question mark that reaches below the dot's rows")
        }
    }

    // Native AppKit template rendering (not manually recolored mask art).
    @MainActor static func nativePreview(state: MenuBarIcon.State, scale: Int, dark: Bool, selected: Bool) -> NSBitmapImageRep {
        let bitmap = bitmap(width: 28 * scale, height: 18 * scale)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let button = NSButton(frame: CGRect(x: 0, y: 0, width: 28, height: 18))
        button.image = MenuBarIcon.image(for: state)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleNone
        button.isBordered = false
        button.appearance = appearance
        button.cell?.backgroundStyle = selected ? .emphasized : .normal
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
            graphics.cgContext.translateBy(x: 0, y: CGFloat(18 * scale))
            graphics.cgContext.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
            NSGraphicsContext.current = NSGraphicsContext(cgContext: graphics.cgContext, flipped: true)
            button.contentTintColor = selected ? .selectedMenuItemTextColor : .labelColor
            (selected ? NSColor.selectedContentBackgroundColor : (dark ? NSColor(calibratedWhite: 0.15, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1))).setFill()
            CGRect(x: 0, y: 0, width: 28, height: 18).fill()
            button.cell!.draw(withFrame: button.bounds, in: button)
            NSGraphicsContext.restoreGraphicsState()
        }
        return bitmap
    }

    @MainActor static func contactSheet(app: NSImage, output: URL) throws {
        let width = 1000, height = 740
        let sheet = bitmap(width: width, height: height)
        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(bitmapImageRep: sheet)!
        NSGraphicsContext.current = graphics
        let c = graphics.cgContext
        c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
        NSColor(calibratedWhite: 0.92, alpha: 1).setFill()
        CGRect(x: 0, y: 0, width: width, height: height).fill()
        func text(_ value: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, dark: Bool = false, bold: Bool = false) {
            (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                .foregroundColor: dark ? NSColor.white : NSColor(calibratedWhite: 0.15, alpha: 1)
            ])
        }
        func draw(_ image: NSImage, _ rect: CGRect) {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.none.rawValue])
        }
        func drawBitmap(_ bitmap: NSBitmapImageRep, _ rect: CGRect) {
            let image = NSImage(size: NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
            image.addRepresentation(bitmap); draw(image, rect)
        }
        text("Talkless / Pip", 28, 22, 28, bold: true)
        text("Approved silhouette. Charcoal on off-white. Native template menu states.", 29, 61, 14)
        for dark in [false, true] {
            let x: CGFloat = dark ? 512 : 24
            (dark ? NSColor(calibratedWhite: 0.15, alpha: 1) : NSColor(calibratedWhite: 0.96, alpha: 1)).setFill()
            NSBezierPath(roundedRect: CGRect(x: x, y: 100, width: 464, height: 606), xRadius: 20, yRadius: 20).fill()
            text(dark ? "Dark" : "Light", x + 22, 119, 21, dark: dark, bold: true)
            draw(app, CGRect(x: x + 104, y: 149, width: 256, height: 256))
            for (index, size) in [16, 32, 64].enumerated() {
                let px = x + 90 + CGFloat(index * 123)
                draw(app, CGRect(x: px, y: 414 + CGFloat(64 - size) / 2, width: CGFloat(size), height: CGFloat(size)))
                text("\(size) px", px, 486, 11, dark: dark)
            }
            text("Menu bar · actual 28 × 18 pt", x + 22, 523, 13, dark: dark, bold: true)
            for (index, state) in MenuBarIcon.State.allCases.enumerated() {
                let px = x + 26 + CGFloat(index * 146)
                text("\(state)", px, 552, 12, dark: dark)
                for scale in [1, 2] {
                    let preview = nativePreview(state: state, scale: scale, dark: dark, selected: false)
                    drawBitmap(preview, CGRect(x: px + CGFloat((scale-1) * 46), y: 579, width: 28, height: 18))
                }
                let selected = nativePreview(state: state, scale: 2, dark: dark, selected: true)
                drawBitmap(selected, CGRect(x: px + 92, y: 579, width: 28, height: 18))
                text("1x     2x     selected", px, 607, 10, dark: dark)
                let enlarged = nativePreview(state: state, scale: 2, dark: dark, selected: false)
                drawBitmap(enlarged, CGRect(x: px, y: 640, width: 75, height: 54))
            }
        }
        text("Bottom row: 3× pixel inspection. Eyes and smile are transparent; badges stay separate.", 28, 719, 11)
        NSGraphicsContext.restoreGraphicsState()
        try write(sheet, to: output.appendingPathComponent("pip-production-contact-sheet.png"))
    }

    @MainActor static func main() throws {
        let localization = LocalizationSettings(defaults: nil, preferredLanguages: { ["en"] })
        localization.interfaceLanguage = .english
        defer { withExtendedLifetime(localization) {} }
        _ = NSApplication.shared
        checkApprovedOutline()
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let appURL = root.appendingPathComponent("Resources/AppIcon.png")
        let appBitmap = NSBitmapImageRep(data: try Data(contentsOf: appURL))!
        precondition(appBitmap.pixelsWide == 1024 && appBitmap.pixelsHigh == 1024)
        precondition(alpha(appBitmap, 0, 0) == 0, "App icon needs a transparent exterior")
        let ink = appBitmap.colorAt(x: 503, y: 520)!
        let tile = appBitmap.colorAt(x: 512, y: 150)!
        precondition(ink.redComponent < 0.2 && ink.blueComponent < 0.25, "Pip must be charcoal, not colored")
        precondition(tile.redComponent > 0.94 && tile.blueComponent > 0.94, "App tile must stay clean off-white")
        for (x,y) in [(418,532), (589,516), (505,649)] {
            let hole = appBitmap.colorAt(x: x, y: y)!
            precondition(abs(hole.redComponent-tile.redComponent) < 0.01, "App eyes/smile reveal the tile, with no pupils")
        }
        var output: URL?
        if CommandLine.arguments.count == 3 {
            output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            try FileManager.default.createDirectory(at: output!, withIntermediateDirectories: true)
        }
        for scale in [1, 2] {
            var rendered: [Data] = []
            let idleMask = raster(MenuBarIcon.image(for: .idle), scale: scale)
            for state in MenuBarIcon.State.allCases {
                let image = MenuBarIcon.image(for: state)
                precondition(image.isTemplate)
                precondition(image.size == NSSize(width: 28, height: 18))
                precondition(image.accessibilityDescription == state.accessibilityDescription)
                let bitmap = raster(image, scale: scale)
                checkRaster(bitmap, state: state, scale: scale)
                for y in 0..<18 * scale {
                    for x in 0..<21 * scale {
                        precondition(alpha(bitmap, x, y) == alpha(idleMask, x, y),
                                     "State changes must not move or alter Pip")
                    }
                }
                rendered.append(bitmap.representation(using: .png, properties: [:])!)
                if let output { try write(bitmap, to: output.appendingPathComponent("menu-\(state)-\(scale)x-template.png")) }
                var appearances: [Data] = []
                for dark in [false, true] {
                    for selected in [false, true] {
                        let preview = nativePreview(state: state, scale: scale, dark: dark, selected: selected)
                        appearances.append(preview.representation(using: .png, properties: [:])!)
                        func brightness(_ x: Int, _ y: Int) -> CGFloat {
                            let color = preview.colorAt(x: x, y: y)!
                            return (color.redComponent + color.greenComponent + color.blueComponent) / 3
                        }
                        let background = brightness(0, 0)
                        var foreground: [CGFloat] = []
                        for y in 0..<18 * scale {
                            for x in 0..<18 * scale {
                                if alpha(bitmap, x, y) > 0.99 { foreground.append(brightness(x, y)) }
                            }
                        }
                        let average = foreground.reduce(0, +) / CGFloat(foreground.count)
                        precondition(dark || selected ? average > background + 0.2 : average < background - 0.4,
                                     "Template foreground must adapt with readable contrast, not just change the background")
                        if let output {
                            try write(preview, to: output.appendingPathComponent("menu-\(state)-\(dark ? "dark" : "light")-\(selected ? "selected" : "normal")-\(scale)x.png"))
                        }
                    }
                }
                precondition(appearances[0] != appearances[2], "Native light and dark appearances must differ")
                precondition(appearances[0] != appearances[1], "Native selected appearance must differ")
            }
            precondition(Set(rendered).count == 3, "States need distinct badges at both native scales")
        }
        if let output {
            // ICNS supplies the actual optical-size variants in the review sheet.
            try contactSheet(app: NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.icns"))!, output: output)
            print("Preview: \(output.appendingPathComponent("pip-production-contact-sheet.png").path)")
        }
        print("PASS approved Pip outline, generator/menu parity, eye/smile holes, 1x/2x silhouette and badge separation, native appearances, app artwork, and accessible labels")
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
try run(binary.path, [root.path] + Array(CommandLine.arguments.dropFirst()))
