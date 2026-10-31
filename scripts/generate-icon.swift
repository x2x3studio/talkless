#!/usr/bin/env swift
// Original Talkless artwork. No fonts, external images, or third-party icon assets.
// Run from any directory: swift /path/to/talkless/scripts/generate-icon.swift
// The artwork is drawn at 4x resolution, then reduced for each native icon size.

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private let canvas: CGFloat = 1024
private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
private let resources = root.appendingPathComponent("Resources", isDirectory: true)

private func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [
        CGFloat((hex >> 16) & 255) / 255,
        CGFloat((hex >> 8) & 255) / 255,
        CGFloat(hex & 255) / 255,
        alpha
    ])!
}

// Continuous corners, with straight shoulders rather than a circular rounded rect.
private func tilePath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 332, y: 92))
    p.addLine(to: CGPoint(x: 692, y: 92))
    p.addCurve(to: CGPoint(x: 882, y: 142), control1: CGPoint(x: 786, y: 92), control2: CGPoint(x: 837, y: 97))
    p.addCurve(to: CGPoint(x: 932, y: 332), control1: CGPoint(x: 927, y: 187), control2: CGPoint(x: 932, y: 238))
    p.addLine(to: CGPoint(x: 932, y: 692))
    p.addCurve(to: CGPoint(x: 882, y: 882), control1: CGPoint(x: 932, y: 786), control2: CGPoint(x: 927, y: 837))
    p.addCurve(to: CGPoint(x: 692, y: 932), control1: CGPoint(x: 837, y: 927), control2: CGPoint(x: 786, y: 932))
    p.addLine(to: CGPoint(x: 332, y: 932))
    p.addCurve(to: CGPoint(x: 142, y: 882), control1: CGPoint(x: 238, y: 932), control2: CGPoint(x: 187, y: 927))
    p.addCurve(to: CGPoint(x: 92, y: 692), control1: CGPoint(x: 97, y: 837), control2: CGPoint(x: 92, y: 786))
    p.addLine(to: CGPoint(x: 92, y: 332))
    p.addCurve(to: CGPoint(x: 142, y: 142), control1: CGPoint(x: 92, y: 238), control2: CGPoint(x: 97, y: 187))
    p.addCurve(to: CGPoint(x: 332, y: 92), control1: CGPoint(x: 187, y: 97), control2: CGPoint(x: 238, y: 92))
    p.closeSubpath()
    return p
}

// BEGIN PIP ARTWORK — generator/menu parity is enforced by native tests.
// Pip silhouette in 1024-unit coordinates.
// Eyes and smile are negative space, never white paint or pupils.
enum PipArtwork {
    static func bodyPath() -> CGPath {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 292, y: 715))
        p.addCurve(to: CGPoint(x: 260, y: 410), control1: CGPoint(x: 218, y: 645), control2: CGPoint(x: 214, y: 503))
        p.addLine(to: CGPoint(x: 292, y: 271))
        p.addCurve(to: CGPoint(x: 345, y: 267), control1: CGPoint(x: 299, y: 239), control2: CGPoint(x: 323, y: 237))
        p.addLine(to: CGPoint(x: 405, y: 348))
        p.addCurve(to: CGPoint(x: 583, y: 344), control1: CGPoint(x: 463, y: 327), control2: CGPoint(x: 521, y: 326))
        p.addLine(to: CGPoint(x: 679, y: 260))
        p.addCurve(to: CGPoint(x: 730, y: 282), control1: CGPoint(x: 705, y: 237), control2: CGPoint(x: 729, y: 250))
        p.addLine(to: CGPoint(x: 730, y: 430))
        p.addCurve(to: CGPoint(x: 754, y: 690), control1: CGPoint(x: 789, y: 497), control2: CGPoint(x: 800, y: 616))
        p.addCurve(to: CGPoint(x: 580, y: 771), control1: CGPoint(x: 716, y: 752), control2: CGPoint(x: 648, y: 778))
        p.addCurve(to: CGPoint(x: 438, y: 782), control1: CGPoint(x: 533, y: 766), control2: CGPoint(x: 485, y: 790))
        p.addCurve(to: CGPoint(x: 339, y: 740), control1: CGPoint(x: 397, y: 775), control2: CGPoint(x: 368, y: 744))
        p.addCurve(to: CGPoint(x: 292, y: 715), control1: CGPoint(x: 322, y: 738), control2: CGPoint(x: 305, y: 728))
        p.closeSubpath()
        return p
    }

    private static func eyePath(x: CGFloat, y: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let w: CGFloat = 122, h: CGFloat = 166, r: CGFloat = 61, k: CGFloat = 0.55228475
        p.move(to: CGPoint(x: x + r, y: y))
        p.addLine(to: CGPoint(x: x + w - r, y: y))
        p.addCurve(to: CGPoint(x: x + w, y: y + r), control1: CGPoint(x: x + w - r + r * k, y: y), control2: CGPoint(x: x + w, y: y + r - r * k))
        p.addLine(to: CGPoint(x: x + w, y: y + h - r))
        p.addCurve(to: CGPoint(x: x + w - r, y: y + h), control1: CGPoint(x: x + w, y: y + h - r + r * k), control2: CGPoint(x: x + w - r + r * k, y: y + h))
        p.addLine(to: CGPoint(x: x + r, y: y + h))
        p.addCurve(to: CGPoint(x: x, y: y + h - r), control1: CGPoint(x: x + r - r * k, y: y + h), control2: CGPoint(x: x, y: y + h - r + r * k))
        p.addLine(to: CGPoint(x: x, y: y + r))
        p.addCurve(to: CGPoint(x: x + r, y: y), control1: CGPoint(x: x, y: y + r - r * k), control2: CGPoint(x: x + r - r * k, y: y))
        p.closeSubpath()
        return p
    }

    static func path(small: Bool) -> CGPath {
        let p = CGMutablePath()
        p.addPath(bodyPath())
        p.addPath(eyePath(x: 357, y: 449))
        p.addPath(eyePath(x: 528, y: 433))
        let smile = CGMutablePath()
        smile.move(to: CGPoint(x: 471, y: 633))
        smile.addCurve(to: CGPoint(x: 539, y: 631), control1: CGPoint(x: 489, y: 657), control2: CGPoint(x: 517, y: 655))
        // A slightly wider smile keeps its negative space legible at small sizes.
        p.addPath(smile.copy(strokingWithWidth: small ? 28 : 20, lineCap: .round, lineJoin: .round, miterLimit: 10))
        return p
    }
}
// END PIP ARTWORK

private func drawArtwork(in c: CGContext, opticalSize: Int) {
    let tile = tilePath()

    // A quiet native tile. Only its exterior casts a shadow; Pip stays flat and mono.
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 22, color: color(0x232833, alpha: 0.16))
    c.setFillColor(color(0xF5F6F8))
    c.addPath(tile)
    c.fillPath()
    c.restoreGState()

    c.setFillColor(color(0x232833))
    c.addPath(PipArtwork.path(small: opticalSize <= 32))
    c.fillPath(using: .evenOdd)
}

private func render(size: Int) -> CGImage {
    let pixels = size * 4
    let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                      bytesPerRow: pixels * 4, space: colorSpace,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x: 0, y: CGFloat(pixels))
    c.scaleBy(x: CGFloat(pixels) / canvas, y: -CGFloat(pixels) / canvas)
    drawArtwork(in: c, opticalSize: size)
    let highResolution = c.makeImage()!
    let reduced = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    reduced.interpolationQuality = .high
    reduced.draw(highResolution, in: CGRect(x: 0, y: 0, width: size, height: size))
    return reduced.makeImage()!
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "TalklessIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot create PNG at \(url.path)"])
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "TalklessIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot write PNG at \(url.path)"])
    }
}

try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("TalklessIcon-\(UUID().uuidString)", isDirectory: true)
let iconset = scratch.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: scratch) }

var images: [Int: CGImage] = [:]
for size in [16, 32, 64, 128, 256, 512, 1024] {
    images[size] = render(size: size)
}
try writePNG(images[1024]!, to: resources.appendingPathComponent("AppIcon.png"))
for size in [16, 32, 128, 256, 512] {
    try writePNG(images[size]!, to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try writePNG(images[size * 2]!, to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["--convert", "icns", "--output", resources.appendingPathComponent("AppIcon.icns").path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    throw NSError(domain: "TalklessIcon", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil could not package the icon."])
}
print("Generated Resources/AppIcon.png (1024 px) and Resources/AppIcon.icns (16-1024 px).")
