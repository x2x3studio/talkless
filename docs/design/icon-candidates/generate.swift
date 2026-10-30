#!/usr/bin/env swift
// Original Talkless candidate artwork. AppKit / CoreGraphics only; no external assets.
// This script never modifies the shipped icon or menu-bar implementation.
// Usage: swift /absolute/path/to/generate.swift /absolute/path/to/output-directory

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private let space = CGColorSpace(name: CGColorSpace.sRGB)!
private let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
private let paper: UInt32 = 0xFFF9ED
private let sheet: UInt32 = 0xF2F4F7
private let ink: UInt32 = 0x202736
private let night: UInt32 = 0x172029

private func cgColor(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat(value >> 16 & 255) / 255,
        CGFloat(value >> 8 & 255) / 255, CGFloat(value & 255) / 255, alpha])!
}
private func hex(_ value: UInt32) -> String { String(format: "#%06X", value) }
private func mix(_ a: UInt32, _ b: UInt32, _ amount: CGFloat) -> UInt32 {
    let channels = [16, 8, 0].map { shift -> UInt32 in
        let x = CGFloat(a >> shift & 255), y = CGFloat(b >> shift & 255)
        return UInt32((x + (y - x) * amount).rounded()) << shift
    }
    return channels.reduce(0, |)
}

private struct Path {
    let cg = CGMutablePath()
    var commands: [String] = []
    mutating func move(_ x: CGFloat, _ y: CGFloat) {
        cg.move(to: CGPoint(x: x, y: y)); commands.append("M \(x) \(y)")
    }
    mutating func line(_ x: CGFloat, _ y: CGFloat) {
        cg.addLine(to: CGPoint(x: x, y: y)); commands.append("L \(x) \(y)")
    }
    mutating func curve(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        cg.addCurve(to: CGPoint(x: x, y: y), control1: CGPoint(x: x1, y: y1), control2: CGPoint(x: x2, y: y2))
        commands.append("C \(x1) \(y1) \(x2) \(y2) \(x) \(y)")
    }
    mutating func close() { cg.closeSubpath(); commands.append("Z") }
    var svg: String { commands.joined(separator: " ") }
}
private func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> Path {
    var p = Path(); let k: CGFloat = 0.55228475
    p.move(x + r, y); p.line(x + w - r, y)
    p.curve(x + w - r + r*k, y, x + w, y + r - r*k, x + w, y + r)
    p.line(x + w, y + h - r)
    p.curve(x + w, y + h - r + r*k, x + w - r + r*k, y + h, x + w - r, y + h)
    p.line(x + r, y + h)
    p.curve(x + r - r*k, y + h, x, y + h - r + r*k, x, y + h - r)
    p.line(x, y + r)
    p.curve(x, y + r - r*k, x + r - r*k, y, x + r, y)
    p.close(); return p
}
private func tilePath() -> Path {
    var p = Path()
    p.move(332, 92); p.line(692, 92)
    p.curve(786, 92, 837, 97, 882, 142); p.curve(927, 187, 932, 238, 932, 332)
    p.line(932, 692)
    p.curve(932, 786, 927, 837, 882, 882); p.curve(837, 927, 786, 932, 692, 932)
    p.line(332, 932)
    p.curve(238, 932, 187, 927, 142, 882); p.curve(97, 837, 92, 786, 92, 692)
    p.line(92, 332)
    p.curve(92, 238, 97, 187, 142, 142); p.curve(187, 97, 238, 92, 332, 92)
    p.close(); return p
}

private enum Role { case foreground, cutout, keyEdge }
private struct Shape { let path: Path; let role: Role }
private struct Candidate {
    let id: String
    let slug: String
    let name: String
    let subtitle: String
    let note: String
    let base: UInt32

    func shapes(small: Bool) -> [Shape] {
        switch id {
        case "A":
            // A single, substantial key replaces the many keys of typing.
            // The waveform is knocked out of the key, not drawn as a tiny pictogram.
            return [
                Shape(path: rounded(222, 280, 580, 496, 100), role: .keyEdge),
                Shape(path: rounded(222, 250, 580, 496, 100), role: .foreground),
                Shape(path: rounded(348, 426, 64, 144, 32), role: .cutout),
                Shape(path: rounded(480, 370, 64, 256, 32), role: .cutout),
                Shape(path: rounded(612, 440, 64, 116, 32), role: .cutout)
            ]
        case "B":
            // A spoken bubble contains a written baseline and a live insertion point.
            var bubble = Path()
            bubble.move(376, 286); bubble.line(648, 286)
            bubble.curve(738, 286, 798, 346, 798, 436); bubble.line(798, 540)
            bubble.curve(798, 630, 738, 690, 648, 690); bubble.line(425, 690)
            bubble.curve(389, 730, 345, 758, 292, 778)
            bubble.curve(307, 737, 314, 702, 312, 671)
            bubble.curve(255, 646, 226, 600, 226, 540); bubble.line(226, 436)
            bubble.curve(226, 346, 286, 286, 376, 286); bubble.close()
            let thickness: CGFloat = small ? 58 : 48
            return [
                Shape(path: bubble, role: .foreground),
                Shape(path: rounded(334, 466, 224, 52, 26), role: .cutout),
                Shape(path: rounded(639, 396, thickness, 192, thickness/2), role: .cutout),
                Shape(path: rounded(612, 388, 108, 40, 20), role: .cutout),
                Shape(path: rounded(612, 564, 108, 40, 20), role: .cutout)
            ]
        default:
            // The waveform's last upright becomes the stem of an I-beam cursor.
            // Unequal bar heights make the voice-to-type direction unmistakable.
            let width: CGFloat = small ? 68 : 60
            return [
                Shape(path: rounded(242, 445, width, 134, width/2), role: .foreground),
                Shape(path: rounded(368, 354, width, 316, width/2), role: .foreground),
                Shape(path: rounded(494, 409, width, 206, width/2), role: .foreground),
                Shape(path: rounded(672, 314, width, 396, width/2), role: .foreground),
                Shape(path: rounded(604, 292, 204, 60, 30), role: .foreground),
                Shape(path: rounded(604, 672, 204, 60, 30), role: .foreground)
            ]
        }
    }
}
private let candidates = [
    Candidate(id: "A", slug: "a-one-key", name: "One Key", subtitle: "One voice key. A whole keyboard less.",
        note: "The most tactile direction. A familiar keycap\nturns the promise of less typing into an object.", base: 0x516781),
    Candidate(id: "B", slug: "b-spoken-line", name: "Spoken Line", subtitle: "A thought, already becoming text.",
        note: "The most conversational direction. Spoken\nwords become a line and an insertion point.", base: 0x326C68),
    Candidate(id: "C", slug: "c-voice-cursor", name: "Voice Cursor", subtitle: "Voice in. Text out. Nothing extra.",
        note: "The most direct direction. A voice rhythm\nresolves into the cursor where text appears.", base: 0xA8664D)
]

private func context(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
private func fill(_ c: CGContext, _ path: CGPath, _ color: CGColor) {
    c.setFillColor(color); c.addPath(path); c.fillPath()
}
private func drawMark(_ c: CGContext, candidate: Candidate, small: Bool, monochrome: UInt32? = nil) {
    c.saveGState()
    c.beginTransparencyLayer(auxiliaryInfo: nil)
    for shape in candidate.shapes(small: small) {
        if shape.role == .cutout {
            c.setBlendMode(.destinationOut)
            fill(c, shape.path.cg, cgColor(0x000000))
            c.setBlendMode(.normal)
        } else {
            let value = monochrome ?? (shape.role == .keyEdge ? mix(paper, candidate.base, 0.28) : paper)
            fill(c, shape.path.cg, cgColor(value))
        }
    }
    c.endTransparencyLayer()
    c.restoreGState()
}
private func drawArtwork(_ c: CGContext, candidate: Candidate, size: Int) {
    let tile = tilePath().cg
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 20, color: cgColor(0x111B2B, 0.18))
    fill(c, tile, cgColor(candidate.base))
    c.restoreGState()

    c.saveGState(); c.addPath(tile); c.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        cgColor(mix(candidate.base, 0xFFFFFF, 0.12)), cgColor(candidate.base),
        cgColor(mix(candidate.base, 0x102033, 0.20))
    ] as CFArray, locations: [0, 0.46, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 290, y: 92), end: CGPoint(x: 710, y: 932), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    c.addPath(tile); c.setLineWidth(4); c.replacePathWithStrokedPath(); c.clip()
    let rim = CGGradient(colorsSpace: space, colors: [cgColor(0xFFFFFF, 0.34), cgColor(0xFFFFFF, 0.02)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(rim, start: CGPoint(x: 512, y: 92), end: CGPoint(x: 512, y: 932), options: [])
    c.restoreGState()

    c.saveGState()
    if size > 32 { c.setShadow(offset: CGSize(width: 0, height: -5), blur: 8, color: cgColor(0x101C29, 0.18)) }
    drawMark(c, candidate: candidate, small: size <= 32)
    c.restoreGState()
}
private func render(_ candidate: Candidate, size: Int, monochrome: UInt32? = nil) -> CGImage {
    let scale = 4, pixels = size * scale
    let c = context(width: pixels, height: pixels)
    c.translateBy(x: 0, y: CGFloat(pixels)); c.scaleBy(x: CGFloat(pixels)/1024, y: -CGFloat(pixels)/1024)
    if let monochrome {
        // Menu-bar study: expand the mark to a 14 px live area inside a 16 px canvas.
        c.translateBy(x: 512, y: 512); c.scaleBy(x: 1.48, y: 1.48); c.translateBy(x: -512, y: -512)
        drawMark(c, candidate: candidate, small: size <= 32, monochrome: monochrome)
    } else { drawArtwork(c, candidate: candidate, size: size) }
    let result = context(width: size, height: size)
    result.interpolationQuality = .high
    result.draw(c.makeImage()!, in: CGRect(x: 0, y: 0, width: size, height: size))
    return result.makeImage()!
}
private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "IconCandidates", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "IconCandidates", code: 2) }
}
private func svg(_ candidate: Candidate) -> String {
    let shapes = candidate.shapes(small: false)
    let maskShapes = shapes.map { shape in
        "<path d=\"\(shape.path.svg)\" fill=\"\(shape.role == .cutout ? "black" : "white")\"/>"
    }.joined(separator: "\n      ")
    let keyEdge = shapes.filter { $0.role == .keyEdge }.map {
        "<path d=\"\($0.path.svg)\" fill=\"\(hex(mix(paper, candidate.base, 0.28)))\"/>"
    }.joined(separator: "\n    ")
    let foreground = shapes.filter { $0.role == .foreground }.map {
        "<path d=\"\($0.path.svg)\" fill=\"\(hex(paper))\"/>"
    }.joined(separator: "\n    ")
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title desc">
      <title id="title">Talkless candidate \(candidate.id): \(candidate.name)</title>
      <desc id="desc">\(candidate.subtitle) Candidate artwork only; not the shipped icon.</desc>
      <defs>
        <linearGradient id="tile" x1="0.24" y1="0" x2="0.74" y2="1">
          <stop stop-color="\(hex(mix(candidate.base, 0xFFFFFF, 0.12)))"/>
          <stop offset="0.46" stop-color="\(hex(candidate.base))"/>
          <stop offset="1" stop-color="\(hex(mix(candidate.base, 0x102033, 0.20)))"/>
        </linearGradient>
        <linearGradient id="rim" x2="0" y2="1"><stop stop-color="white" stop-opacity=".34"/><stop offset="1" stop-color="white" stop-opacity=".02"/></linearGradient>
        <filter id="shadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="12" stdDeviation="10" flood-color="#111B2B" flood-opacity=".18"/></filter>
        <mask id="mark"><rect width="1024" height="1024" fill="black"/>
          \(maskShapes)
        </mask>
      </defs>
      <path d="\(tilePath().svg)" fill="url(#tile)" filter="url(#shadow)"/>
      <path d="\(tilePath().svg)" fill="none" stroke="url(#rim)" stroke-width="3"/>
      <g mask="url(#mark)">
        \(keyEdge)
        \(foreground)
      </g>
    </svg>
    """.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.replacingOccurrences(of: "[ \\t]+$", with: "", options: .regularExpression) }
        .joined(separator: "\n") + "\n"
}

private func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
                  color: UInt32 = ink, width: CGFloat = 1000, monospaced: Bool = false) {
    let font = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
    let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 4
    (string as NSString).draw(in: CGRect(x: x, y: y, width: width, height: 100), withAttributes: [
        .font: font, .foregroundColor: NSColor(cgColor: cgColor(color))!, .paragraphStyle: paragraph
    ])
}
private func image(_ c: CGContext, _ image: CGImage, x: CGFloat, y: CGFloat, size: CGFloat) {
    c.saveGState(); c.translateBy(x: x, y: y + size); c.scaleBy(x: 1, y: -1)
    c.interpolationQuality = .none
    c.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size)); c.restoreGState()
}
private func previewPanel(_ c: CGContext, candidate: Candidate, x: CGFloat, y: CGFloat, dark: Bool, mono: Bool) {
    fill(c, rounded(x, y, 184, 128, 13).cg, cgColor(dark ? night : sheet))
    let foreground: UInt32 = dark ? 0xF1F4F8 : ink
    let secondary: UInt32 = dark ? 0xB6C0CA : 0x5E6979
    text(dark ? "DARK" : "LIGHT", x: x + 16, y: y + 13, size: 10, weight: .semibold, color: secondary, monospaced: true)
    image(c, render(candidate, size: 32, monochrome: mono ? foreground : nil), x: x + 30, y: y + 44, size: 32)
    image(c, render(candidate, size: 16, monochrome: mono ? foreground : nil), x: x + 122, y: y + 52, size: 16)
    text("32 px", x: x + 29, y: y + 92, size: 10, color: secondary, monospaced: true)
    text("16 px", x: x + 113, y: y + 92, size: 10, color: secondary, monospaced: true)
}
private func contactSheet() -> CGImage {
    let width = 1440, height = 1112
    let c = context(width: width, height: height)
    c.translateBy(x: 0, y: CGFloat(height)); c.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }
    c.setFillColor(cgColor(sheet)); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
    text("Talkless", x: 48, y: 32, size: 18, weight: .semibold)
    text("Less typing. More voice.", x: 48, y: 66, size: 36, weight: .semibold)
    text("APP ICON STUDIES  /  A–C", x: 1084, y: 42, size: 12, weight: .medium, color: 0x5E6979, monospaced: true)
    text("Three native macOS directions. Each shown at 256 px, with actual-size app and monochrome previews.",
         x: 48, y: 119, size: 15, color: 0x5E6979)

    for (index, candidate) in candidates.enumerated() {
        let x = CGFloat(48 + index * 456)
        fill(c, rounded(x, 170, 432, 878, 22).cg, cgColor(0xFFFFFF))
        text(candidate.id, x: x + 24, y: 195, size: 25, weight: .medium, color: candidate.base)
        text(candidate.name, x: x + 65, y: 195, size: 25, weight: .semibold)
        text(candidate.subtitle, x: x + 24, y: 237, size: 14, color: 0x5E6979, width: 384)
        image(c, render(candidate, size: 256), x: x + 88, y: 286, size: 256)
        text("APP ICON", x: x + 24, y: 577, size: 11, weight: .semibold, color: 0x5E6979, monospaced: true)
        previewPanel(c, candidate: candidate, x: x + 24, y: 604, dark: false, mono: false)
        previewPanel(c, candidate: candidate, x: x + 224, y: 604, dark: true, mono: false)
        text("MONOCHROME MARK", x: x + 24, y: 761, size: 11, weight: .semibold, color: 0x5E6979, monospaced: true)
        previewPanel(c, candidate: candidate, x: x + 24, y: 788, dark: false, mono: true)
        previewPanel(c, candidate: candidate, x: x + 224, y: 788, dark: true, mono: true)
        text(candidate.note, x: x + 24, y: 958, size: 14, color: 0x5E6979, width: 384)
    }
    text("CANDIDATES ONLY — shipped app and menu-bar icons are unchanged.", x: 48, y: 1072, size: 12, color: 0x5E6979)
    text("Original vector artwork · sRGB", x: 1160, y: 1072, size: 12, color: 0x5E6979)
    return c.makeImage()!
}

private func run() throws {
    guard CommandLine.arguments.count == 2, CommandLine.arguments[1].hasPrefix("/") else {
        fputs("Usage: swift generate.swift /absolute/path/to/output-directory\n", stderr)
        exit(64)
    }
    let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
    let repository = sourceDirectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dist = repository.appendingPathComponent("dist/icon-candidates", isDirectory: true).path
    guard !output.path.hasPrefix(repository.path + "/") || output.path == dist || output.path.hasPrefix(dist + "/") else {
        fputs("Keep PNGs outside the source tree, or in ignored dist/icon-candidates.\n", stderr)
        exit(64)
    }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for candidate in candidates {
        try svg(candidate).write(to: sourceDirectory.appendingPathComponent(candidate.slug + ".svg"), atomically: true, encoding: .utf8)
        for size in [16, 32, 256, 1024] {
            try writePNG(render(candidate, size: size), to: output.appendingPathComponent("\(candidate.slug)-\(size).png"))
        }
        for size in [16, 32] {
            try writePNG(render(candidate, size: size, monochrome: ink), to: output.appendingPathComponent("\(candidate.slug)-mono-light-\(size).png"))
            try writePNG(render(candidate, size: size, monochrome: 0xF1F4F8), to: output.appendingPathComponent("\(candidate.slug)-mono-dark-\(size).png"))
        }
    }
    try writePNG(contactSheet(), to: output.appendingPathComponent("talkless-icon-contact-sheet.png"))
    print("Rendered three candidate sets and contact sheet to \(output.path)")
    print("Updated editable SVGs in \(sourceDirectory.path)")
    print("No shipped resources were changed.")
}
try run()
