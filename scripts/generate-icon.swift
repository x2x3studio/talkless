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

// A spoken contour relaxes into a written baseline. The taller second oscillation
// and long, quiet exit distinguish it from a stock waveform or heartbeat symbol.
private func voicePath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 232, y: 518))
    p.addLine(to: CGPoint(x: 251, y: 518))
    p.addCurve(to: CGPoint(x: 286, y: 456), control1: CGPoint(x: 272, y: 518), control2: CGPoint(x: 268, y: 456))
    p.addCurve(to: CGPoint(x: 332, y: 589), control1: CGPoint(x: 313, y: 456), control2: CGPoint(x: 303, y: 589))
    p.addCurve(to: CGPoint(x: 397, y: 345), control1: CGPoint(x: 371, y: 589), control2: CGPoint(x: 359, y: 345))
    p.addCurve(to: CGPoint(x: 463, y: 665), control1: CGPoint(x: 442, y: 345), control2: CGPoint(x: 423, y: 665))
    p.addCurve(to: CGPoint(x: 526, y: 478), control1: CGPoint(x: 501, y: 665), control2: CGPoint(x: 491, y: 478))
    p.addCurve(to: CGPoint(x: 576, y: 518), control1: CGPoint(x: 552, y: 478), control2: CGPoint(x: 548, y: 518))
    p.addLine(to: CGPoint(x: 657, y: 518))
    return p
}

private func caretPath() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 754, y: 391))
    p.addLine(to: CGPoint(x: 754, y: 635))
    p.move(to: CGPoint(x: 727, y: 391))
    p.addLine(to: CGPoint(x: 781, y: 391))
    p.move(to: CGPoint(x: 727, y: 635))
    p.addLine(to: CGPoint(x: 781, y: 635))
    return p
}

private func drawArtwork(in c: CGContext, opticalSize: Int) {
    let tile = tilePath()

    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -13), blur: 25, color: color(0x26316C, alpha: 0.23))
    c.setFillColor(color(0x5667DB))
    c.addPath(tile)
    c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(tile)
    c.clip()
    let base = CGGradient(colorsSpace: colorSpace, colors: [
        color(0x6676E2), color(0x5667DB), color(0x4554C3)
    ] as CFArray, locations: [0, 0.46, 1])!
    c.drawLinearGradient(base, start: CGPoint(x: 330, y: 92), end: CGPoint(x: 677, y: 958), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

    let light = CGGradient(colorsSpace: colorSpace, colors: [
        color(0xDFE8FF, alpha: 0.12), color(0xDFE8FF, alpha: 0)
    ] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(light, startCenter: CGPoint(x: 275, y: 144), startRadius: 0,
                         endCenter: CGPoint(x: 275, y: 144), endRadius: 695, options: [])

    // A narrow illuminated lip gives the tile a material edge, not a heavy frame.
    c.addPath(tile)
    c.setLineWidth(3)
    c.replacePathWithStrokedPath()
    c.clip()
    let lip = CGGradient(colorsSpace: colorSpace, colors: [
        color(0xF4F2FF, alpha: 0.42), color(0xF4F2FF, alpha: 0.04)
    ] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(lip, start: CGPoint(x: 512, y: 92), end: CGPoint(x: 512, y: 932), options: [])
    c.restoreGState()

    c.saveGState()
    c.setLineCap(.round)
    c.setLineJoin(.round)
    c.setStrokeColor(color(0xFFF8EA))
    // Optical correction preserves the single-stroke silhouette at 16 and 32 px.
    c.setLineWidth(opticalSize <= 32 ? 56 : 48)
    c.setShadow(offset: CGSize(width: 0, height: -4), blur: 6, color: color(0x25317D, alpha: 0.24))
    c.addPath(voicePath())
    c.strokePath()
    c.setLineWidth(opticalSize <= 32 ? 43 : 36)
    c.addPath(caretPath())
    c.strokePath()
    c.restoreGState()
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
