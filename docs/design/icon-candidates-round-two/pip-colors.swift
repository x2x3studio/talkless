#!/usr/bin/env swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct Palette {
    let label: String
    let name: String
    let background: UInt32
    let body: [UInt32]
    let face: UInt32
}

let palettes = [
    Palette(label: "1", name: "Porcelain / Cobalt", background: 0xF5F3ED,
            body: [0x5A9BFF, 0x3167E5, 0x2549B8], face: 0x172D64),
    Palette(label: "2", name: "Lilac / Butter", background: 0xDCD3F0,
            body: [0xFFF0AD, 0xF5D975, 0xE9BC56], face: 0x534132),
    Palette(label: "3", name: "Midnight / Coral", background: 0x182848,
            body: [0xFFAFB9, 0xF27D91, 0xDA597B], face: 0x673145),
    Palette(label: "4", name: "Ice / Tangerine", background: 0xD7EDF6,
            body: [0xFFB075, 0xFA784D, 0xE64B3D], face: 0x6D2B29),
]
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255) / 255,
        CGFloat((hex >> 8) & 255) / 255, CGFloat(hex & 255) / 255, alpha])!
}
func context(_ size: Int, height: Int? = nil) -> CGContext {
    CGContext(data: nil, width: size, height: height ?? size, bitsPerComponent: 8,
              bytesPerRow: size * 4, space: space,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func path(_ data: String) -> CGPath {
    let tokens = data.split(separator: " ").map(String.init)
    let result = CGMutablePath()
    var index = 0
    func point() -> CGPoint {
        let x = Double(tokens[index])!, y = Double(tokens[index + 1])!
        index += 2
        return CGPoint(x: x, y: y)
    }
    while index < tokens.count {
        let command = tokens[index]; index += 1
        switch command {
        case "M": result.move(to: point())
        case "L": result.addLine(to: point())
        case "C":
            let a = point(), b = point(), end = point()
            result.addCurve(to: end, control1: a, control2: b)
        case "Z": result.closeSubpath()
        default: fatalError("Unsupported path command")
        }
    }
    return result
}
let tile = path("M 332 92 L 692 92 C 786 92 837 97 882 142 C 927 187 932 238 932 332 L 932 692 C 932 786 927 837 882 882 C 837 927 786 932 692 932 L 332 932 C 238 932 187 927 142 882 C 97 837 92 786 92 692 L 92 332 C 92 238 97 187 142 142 C 187 97 238 92 332 92 Z")
// Geometry is identical to Pip in generate.swift; these studies change color only.
let body = path("M 292 715 C 218 645 214 503 260 410 L 292 271 C 299 239 323 237 345 267 L 405 348 C 463 327 521 326 583 344 L 679 260 C 705 237 729 250 730 282 L 730 430 C 789 497 800 616 754 690 C 716 752 648 778 580 771 C 533 766 485 790 438 782 C 397 775 368 744 339 740 C 322 738 305 728 292 715 Z")
let smile = path("M 471 633 C 489 657 517 655 539 631")
func fill(_ c: CGContext, _ p: CGPath, _ value: UInt32) {
    c.addPath(p); c.setFillColor(color(value)); c.fillPath()
}
func gradient(_ c: CGContext, _ p: CGPath, _ colors: [UInt32]) {
    c.saveGState(); c.addPath(p); c.clip()
    let g = CGGradient(colorsSpace: space, colors: colors.map { color($0) } as CFArray, locations: nil)!
    c.drawLinearGradient(g, start: CGPoint(x: 250, y: 240), end: CGPoint(x: 760, y: 780),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
}
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}
func render(_ palette: Palette, size: Int) -> CGImage {
    let c = context(size * 4), scale = CGFloat(size * 4) / 1024
    c.translateBy(x: 0, y: CGFloat(size * 4)); c.scaleBy(x: scale, y: -scale)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 20, color: color(0x182338, alpha: 0.16))
    fill(c, tile, palette.background); c.restoreGState()
    c.saveGState(); c.addPath(tile); c.clip()
    let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, alpha: 0.13), color(0xFFFFFF, alpha: 0), color(0x182338, alpha: 0.08)] as CFArray, locations: nil)!
    c.drawLinearGradient(sheen, start: CGPoint(x: 330, y: 92), end: CGPoint(x: 700, y: 932),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.restoreGState()
    gradient(c, body, palette.body)
    fill(c, rounded(357, 449, 122, 166, 61), 0xFFFDFC)
    fill(c, rounded(528, 433, 122, 166, 61), 0xFFFDFC)
    fill(c, rounded(408, 488, 49, 74, 24.5), palette.face)
    fill(c, rounded(574, 470, 49, 74, 24.5), palette.face)
    c.addPath(smile); c.setStrokeColor(color(palette.face)); c.setLineWidth(size <= 32 ? 28 : 20)
    c.setLineCap(.round); c.strokePath()
    let final = context(size); final.interpolationQuality = .high
    final.draw(c.makeImage()!, in: CGRect(x: 0, y: 0, width: size, height: size))
    return final.makeImage()!
}
func image(_ c: CGContext, _ image: CGImage, x: CGFloat, y: CGFloat, size: CGFloat) {
    c.saveGState(); c.translateBy(x: x, y: y + size); c.scaleBy(x: 1, y: -1)
    c.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size)); c.restoreGState()
}
func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, bold: Bool = false) {
    (value as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [
        .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
        .foregroundColor: NSColor(cgColor: color(0x303544))!,
    ])
}
func sheet() -> CGImage {
    let c = context(1000, height: 1120)
    c.translateBy(x: 0, y: 1120); c.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }
    c.setFillColor(color(0xECEEF2)); c.fill(CGRect(x: 0, y: 0, width: 1000, height: 1120))
    text("Pip / Color studies", x: 32, y: 24, size: 30, bold: true)
    text("Same character. Four palettes.", x: 32, y: 64, size: 14)
    for (i, palette) in palettes.enumerated() {
        let x = CGFloat(24 + (i % 2) * 488), y = CGFloat(106 + (i / 2) * 490)
        fill(c, rounded(x, y, 464, 472, 22), 0xFAFBFD)
        text("\(palette.label)   \(palette.name)", x: x + 25, y: y + 18, size: 20, bold: true)
        image(c, render(palette, size: 360), x: x + 52, y: y + 49, size: 360)
        for (dark, offset) in [(false, CGFloat(20)), (true, CGFloat(237))] {
            fill(c, rounded(x + offset, y + 407, 207, 46, 10), dark ? 0x242934 : 0xECEEF2)
            image(c, render(palette, size: 32), x: x + offset + 27, y: y + 414, size: 32)
            image(c, render(palette, size: 16), x: x + offset + 89, y: y + 422, size: 16)
            for (j, swatch) in [palette.background, palette.body[1]].enumerated() {
                fill(c, rounded(x + offset + 140 + CGFloat(j * 25), y + 421, 18, 18, 9), swatch)
            }
        }
    }
    text("Color studies only — shipped icon unchanged.", x: 32, y: 1092, size: 12)
    return c.makeImage()!
}
func write(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
}
precondition(CommandLine.arguments.count == 2, "Provide a new output directory")
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
for palette in palettes {
    for size in [16, 32, 360, 1024] {
        write(render(palette, size: size), to: output.appendingPathComponent("pip-\(palette.label)-\(size).png"))
    }
}
write(sheet(), to: output.appendingPathComponent("pip-color-studies.png"))
print(output.path)
