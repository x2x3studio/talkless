#!/usr/bin/env swift
// Original Talkless icon studies, round two. Native AppKit / CoreGraphics only.
// Only this study's SVGs and a temporary PNG directory are written.
// Usage: swift /absolute/path/to/generate.swift /tmp/talkless-icon-round-two-<unique-name>

import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

private let space = CGColorSpace(name: CGColorSpace.sRGB)!
private let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
private let sheet: UInt32 = 0xEFF1F5
private let ink: UInt32 = 0x232833
private let night: UInt32 = 0x242934
private let white: UInt32 = 0xF8F7F3

private func color(_ value: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat(value >> 16 & 255) / 255,
        CGFloat(value >> 8 & 255) / 255, CGFloat(value & 255) / 255, alpha])!
}
private func hex(_ value: UInt32) -> String { String(format: "#%06X", value) }
private func mix(_ a: UInt32, _ b: UInt32, _ amount: CGFloat) -> UInt32 {
    [16, 8, 0].map { shift -> UInt32 in
        let x = CGFloat(a >> shift & 255), y = CGFloat(b >> shift & 255)
        return UInt32((x + (y - x) * amount).rounded()) << shift
    }.reduce(0, |)
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
    p.move(x+r, y); p.line(x+w-r, y)
    p.curve(x+w-r+r*k, y, x+w, y+r-r*k, x+w, y+r); p.line(x+w, y+h-r)
    p.curve(x+w, y+h-r+r*k, x+w-r+r*k, y+h, x+w-r, y+h); p.line(x+r, y+h)
    p.curve(x+r-r*k, y+h, x, y+h-r+r*k, x, y+h-r); p.line(x, y+r)
    p.curve(x, y+r-r*k, x+r-r*k, y, x+r, y); p.close(); return p
}
private func tile() -> Path {
    var p = Path()
    p.move(332,92); p.line(692,92)
    p.curve(786,92,837,97,882,142); p.curve(927,187,932,238,932,332); p.line(932,692)
    p.curve(932,786,927,837,882,882); p.curve(837,927,786,932,692,932); p.line(332,932)
    p.curve(238,932,187,927,142,882); p.curve(97,837,92,786,92,692); p.line(92,332)
    p.curve(92,238,97,187,142,142); p.curve(187,97,238,92,332,92); p.close(); return p
}
private struct Shape {
    let path: Path
    var cutout = false
    var stroke: CGFloat = 0
    var paint: [UInt32] = []
    var start = CGPoint(x: 250, y: 240)
    var end = CGPoint(x: 760, y: 780)
    var radial = false
    var opacity: CGFloat = 1
    var geometry: CGPath {
        stroke == 0 ? path.cg : path.cg.copy(strokingWithWidth: stroke, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }
    func svgElement(fill: String) -> String {
        if stroke > 0 {
            return "<path d=\"\(path.svg)\" fill=\"none\" stroke=\"\(fill)\" stroke-width=\"\(stroke)\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/>"
        }
        return "<path d=\"\(path.svg)\" fill=\"\(fill)\"/>"
    }
}
private struct Candidate {
    let id: String
    let slug: String
    let name: String
    let subtitle: String
    let note: String
    let base: UInt32
    let foreground: UInt32

    func shapes(small: Bool) -> [Shape] {
        switch id {
        case "D":
            // A custom T/L ligature. One upright does the work of two letters.
            var p = Path()
            p.move(276,280); p.line(748,280)
            p.curve(766,280,776,290,776,308); p.line(776,378)
            p.curve(776,396,766,406,748,406); p.line(568,406); p.line(568,610)
            p.curve(568,628,578,638,596,638); p.line(720,638)
            p.curve(738,638,748,648,748,666); p.line(748,728)
            p.curve(748,746,738,756,720,756); p.line(460,756)
            p.curve(442,756,432,746,432,728); p.line(432,406); p.line(276,406)
            p.curve(258,406,248,396,248,378); p.line(248,308)
            p.curve(248,290,258,280,276,280); p.close()
            return [Shape(path: p)]
        case "E":
            // Opening quotation marks: the moment spoken words become written words.
            // Two broad commas read as one familiar punctuation sign, even without color.
            func quote(_ x: CGFloat) -> Path {
                var p = Path()
                p.move(x+206,286)
                p.curve(x+96,294,x+12,381,x+12,518); p.line(x+12,650)
                p.curve(x+12,682,x+34,704,x+66,704); p.line(x+188,704)
                p.curve(x+220,704,x+242,682,x+242,650); p.line(x+242,528)
                p.curve(x+242,496,x+220,474,x+188,474); p.line(x+116,474)
                p.curve(x+124,433,x+153,397,x+206,381)
                p.curve(x+222,376,x+230,368,x+230,352); p.line(x+230,308)
                p.curve(x+230,291,x+220,282,x+206,286); p.close(); return p
            }
            return [Shape(path: quote(230)), Shape(path: quote(536))]
        case "F":
            // A single cursive gesture: a breath-length loop settles into a written baseline.
            // Not a waveform, infinity symbol, or recording indicator.
            var p = Path()
            p.move(248,638)
            // Widen the counter optically at 16/32 px rather than simply adding weight.
            p.curve(405,548,small ? 654 : 636,340,552,272)
            p.curve(441,177,small ? 306 : 322,430,397,584)
            p.curve(429,671,478,694,574,694)
            p.line(756,694)
            return [Shape(path: p, stroke: small ? 100 : 96)]
        case "H":
            // Three overlapping folds form an off-axis, tangible loop. The palette changes
            // across faces, not across unrelated decorative objects.
            var left = Path()
            left.move(386,232); left.curve(418,206,454,216,471,246)
            left.line(561,400); left.line(402,704)
            left.curve(385,739,344,745,319,717); left.line(223,608)
            left.curve(203,583,204,552,220,522); left.line(348,270)
            left.curve(359,251,371,242,386,232); left.close()
            var bottom = Path()
            bottom.move(223,608); bottom.line(443,578); bottom.line(746,638)
            bottom.curve(785,646,799,684,776,715); bottom.line(691,815)
            bottom.curve(673,836,647,843,620,835); bottom.line(349,755)
            bottom.curve(302,741,270,703,251,666); bottom.close()
            var top = Path()
            top.move(386,232); top.curve(413,211,445,211,475,226)
            top.line(764,379); top.curve(790,393,803,416,800,447)
            top.line(784,664); top.curve(782,690,776,705,766,719)
            top.line(578,591); top.line(595,480); top.line(438,388)
            top.curve(412,373,398,350,395,322); top.close()
            return [Shape(path: left, paint: [0x143B9C,0x538FFF,0x234ACA]),
                    Shape(path: bottom, paint: [0x2728A8,0x7B63EF,0xC0B1FA],start: CGPoint(x: 330,y: 580),end: CGPoint(x: 760,y: 850)),
                    Shape(path: top, paint: [0xB4E4FF,0x51A9FE,0x4058DA],start: CGPoint(x: 490,y: 235),end: CGPoint(x: 770,y: 698))]
        case "I":
            // A little persimmon creature, all broad curves and a deliberately offbeat gaze.
            var body = Path()
            body.move(292,715)
            body.curve(218,645,214,503,260,410)
            body.line(292,271); body.curve(299,239,323,237,345,267)
            body.line(405,348); body.curve(463,327,521,326,583,344)
            body.line(679,260); body.curve(705,237,729,250,730,282)
            body.line(730,430); body.curve(789,497,800,616,754,690)
            body.curve(716,752,648,778,580,771)
            body.curve(533,766,485,790,438,782)
            body.curve(397,775,368,744,339,740)
            body.curve(322,738,305,728,292,715); body.close()
            var smile = Path(); smile.move(471,633); smile.curve(489,657,517,655,539,631)
            return [Shape(path: body,paint: [0xFFD875,0xFF9257,0xEF6045]),
                    Shape(path: rounded(357,449,122,166,61),paint: [0xFFFBE8]),
                    Shape(path: rounded(528,433,122,166,61),paint: [0xFFFBE8]),
                    Shape(path: rounded(408,488,49,74,24.5),paint: [0x37302D]),
                    Shape(path: rounded(574,470,49,74,24.5),paint: [0x37302D]),
                    Shape(path: smile,stroke: small ? 28 : 20,paint: [0x8B3831])]
        case "J":
            // An eccentric orbital body: an oversize off-center counter gives the heavy
            // black form its own momentum, without turning it into a literal letter.
            var orbit = Path()
            orbit.move(794,293)
            orbit.curve(680,153,466,239,326,398)
            orbit.curve(166,580,203,763,363,799)
            orbit.curve(530,837,739,667,801,489)
            orbit.curve(827,415,833,341,794,293); orbit.close()
            var counter = Path()
            counter.move(702,334)
            counter.curve(650,287,545,337,481,411)
            counter.curve(413,490,404,573,460,594)
            counter.curve(519,616,626,540,681,454)
            counter.curve(714,402,724,355,702,334); counter.close()
            return [Shape(path: orbit,paint: [0x191D24]),Shape(path: counter,cutout: true)]
        case "K":
            // A soft asymmetric liquid stone. Radial color pools provide material,
            // rather than an extra symbol or a decorative stripe on a flat blob.
            var blob = Path()
            blob.move(398,242)
            blob.curve(469,231,501,331,568,330)
            blob.curve(640,330,661,248,729,291)
            blob.curve(806,340,792,431,754,483)
            blob.curve(720,530,745,565,774,602)
            blob.curve(835,681,741,752,643,776)
            blob.curve(511,809,426,716,375,679)
            blob.curve(321,641,246,658,232,580)
            blob.curve(217,496,300,462,298,393)
            blob.curve(295,323,318,253,398,242); blob.close()
            return [Shape(path: blob,paint: [0xFED5FF,0xAF84ED,0x493BBA],start: CGPoint(x: 333,y: 260),end: CGPoint(x: 715,y: 766)),
                    Shape(path: blob,paint: [0xD4FFFF,0x70E2E1],start: CGPoint(x: 678,y: 372),end: CGPoint(x: 370,y: 780),radial: true,opacity: 0.95),
                    Shape(path: blob,paint: [0xFFEBC1,0xECAEEF],start: CGPoint(x: 351,y: 550),end: CGPoint(x: 624,y: 810),radial: true,opacity: 0.86),
                    Shape(path: blob,paint: [0xFFFFFF,0xF6DCFF],start: CGPoint(x: 377,y: 317),end: CGPoint(x: 534,y: 540),radial: true,opacity: 0.8)]
        default:
            // A writing nib, not a microphone: emphasize the text that voice leaves behind.
            // Its open slit and oversized counter remain legible as a single silhouette.
            var nib = Path()
            nib.move(262,762); nib.line(366,402)
            nib.curve(371,384,383,372,400,364); nib.line(643,252)
            nib.curve(659,245,671,248,683,260); nib.line(764,341)
            nib.curve(776,353,779,365,772,381); nib.line(660,624)
            nib.curve(652,641,640,653,622,658); nib.line(262,762); nib.close()
            var slit = Path(); slit.move(254,770); slit.line(510,514)
            let hole: CGFloat = small ? 130 : 122
            return [Shape(path: nib),
                    Shape(path: rounded(512-hole/2,512-hole/2,hole,hole,hole/2), cutout: true),
                    Shape(path: slit, cutout: true, stroke: small ? 52 : 44)]
        }
    }
}
private let groundedCandidates = [
    Candidate(id: "D", slug: "d-type-ligature", name: "Type Ligature", subtitle: "Two initials. One shared stroke.",
        note: "A compact T/L monogram, built for Talkless.", base: 0x354E86, foreground: white),
    Candidate(id: "E", slug: "e-first-word", name: "First Word", subtitle: "Spoken words, set in type.",
        note: "Opening quotes make speech a written object.", base: 0xDEA650, foreground: 0x3C2B1D),
    Candidate(id: "F", slug: "f-one-breath", name: "One Breath", subtitle: "One unbroken gesture, from thought to line.",
        note: "A cursive loop gives dictation a human rhythm.", base: 0x745880, foreground: white),
    Candidate(id: "G", slug: "g-air-nib", name: "Air Nib", subtitle: "Write without touching a key.",
        note: "A pared-back nib puts the written result first.", base: 0x373D47, foreground: 0xF0F1F3)
]
private let freeCandidates = [
    Candidate(id: "H",slug: "h-fold",name: "Fold",subtitle: "",note: "",base: 0xF1EFE9,foreground: 0x466CDE),
    Candidate(id: "I",slug: "i-pip",name: "Pip",subtitle: "",note: "",base: 0x184D43,foreground: 0xFFA566),
    Candidate(id: "J",slug: "j-offbeat",name: "Offbeat",subtitle: "",note: "",base: 0xDEF16C,foreground: 0x191D24),
    Candidate(id: "K",slug: "k-puddle",name: "Puddle",subtitle: "",note: "",base: 0x25203F,foreground: 0xC0B5FF)
]
private let candidates = groundedCandidates + freeCandidates
private func context(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
private func fill(_ c: CGContext, _ path: CGPath, _ value: CGColor) {
    c.setFillColor(value); c.addPath(path); c.fillPath()
}
private func mark(_ c: CGContext, _ candidate: Candidate, small: Bool, monochrome: UInt32? = nil) {
    c.saveGState(); c.beginTransparencyLayer(auxiliaryInfo: nil)
    for (index,shape) in candidate.shapes(small: small).enumerated() {
        // Character details become open counters in the one-color study.
        // The liquid highlight is material, so it disappears in monochrome.
        if monochrome != nil && candidate.id == "K" && index > 0 { continue }
        if monochrome != nil && candidate.id == "I" && (index == 3 || index == 4) { continue }
        c.setBlendMode(shape.cutout || (monochrome != nil && candidate.id == "I" && index > 0) ? .destinationOut : .normal)
        if monochrome == nil && shape.paint.count > 1 {
            c.saveGState(); c.addPath(shape.geometry); c.clip()
            let colors = shape.paint.enumerated().map { index,value in
                color(value,shape.radial ? (index == 0 ? shape.opacity : 0) : 1)
            } as CFArray
            let gradient = CGGradient(colorsSpace: space,colors: colors,locations: nil)!
            if shape.radial {
                let radius = hypot(shape.end.x-shape.start.x,shape.end.y-shape.start.y)
                c.drawRadialGradient(gradient,startCenter: shape.start,startRadius: 0,endCenter: shape.start,endRadius: radius,options: [])
            } else {
                c.drawLinearGradient(gradient,start: shape.start,end: shape.end,
                    options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
            }
            c.restoreGState()
        } else { fill(c,shape.geometry,color(monochrome ?? shape.paint.first ?? candidate.foreground)) }
    }
    c.endTransparencyLayer(); c.restoreGState()
}
private func artwork(_ c: CGContext, _ candidate: Candidate, size: Int) {
    let path = tile().cg
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -12), blur: 20, color: color(0x182338, 0.16))
    fill(c, path, color(candidate.base)); c.restoreGState()
    c.saveGState(); c.addPath(path); c.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        color(mix(candidate.base,0xFFFFFF,0.11)), color(candidate.base), color(mix(candidate.base,0x141C2C,0.16))
    ] as CFArray, locations: [0,0.48,1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 330,y: 92), end: CGPoint(x: 700,y: 932),
        options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
    c.addPath(path); c.setLineWidth(4); c.replacePathWithStrokedPath(); c.clip()
    let rim = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF,0.30),color(0xFFFFFF,0.02)] as CFArray, locations: [0,1])!
    c.drawLinearGradient(rim, start: CGPoint(x: 512,y: 92), end: CGPoint(x: 512,y: 932), options: [])
    c.restoreGState()
    c.saveGState()
    if size > 32 { c.setShadow(offset: CGSize(width: 0,height: -4), blur: 7, color: color(0x162030,0.12)) }
    mark(c,candidate,small: size <= 32); c.restoreGState()
}
private func render(_ candidate: Candidate, size: Int, monochrome: UInt32? = nil) -> CGImage {
    let pixels = size*4, c = context(size*4,size*4)
    c.translateBy(x: 0,y: CGFloat(pixels)); c.scaleBy(x: CGFloat(pixels)/1024,y: -CGFloat(pixels)/1024)
    if let monochrome {
        // Expand the mark for a menu-bar-sized study, with clear padding on every edge.
        c.translateBy(x: 512,y: 512); c.scaleBy(x: 1.48,y: 1.48); c.translateBy(x: -512,y: -512)
        mark(c,candidate,small: size <= 32,monochrome: monochrome)
    } else { artwork(c,candidate,size: size) }
    let result = context(size,size); result.interpolationQuality = .high
    result.draw(c.makeImage()!,in: CGRect(x: 0,y: 0,width: size,height: size))
    return result.makeImage()!
}
private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil) else {
        throw NSError(domain: "TalklessIconStudy",code: 1)
    }
    CGImageDestinationAddImage(destination,image,nil)
    guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "TalklessIconStudy",code: 2) }
}
private func svg(_ candidate: Candidate) -> String {
    let shapes = candidate.shapes(small: false)
    let mask = shapes.map { $0.svgElement(fill: $0.cutout ? "black" : "white") }.joined(separator: "\n      ")
    let gradients = shapes.enumerated().filter { $0.element.paint.count > 1 }.map { index,shape in
        let stops = shape.paint.enumerated().map { position,value in
            "<stop offset=\"\(Double(position)/Double(shape.paint.count-1))\" stop-color=\"\(hex(value))\" stop-opacity=\"\(shape.radial ? (position == 0 ? shape.opacity : 0) : 1)\"/>"
        }.joined()
        if shape.radial {
            let radius = hypot(shape.end.x-shape.start.x,shape.end.y-shape.start.y)
            return "<radialGradient id=\"face-\(index)\" gradientUnits=\"userSpaceOnUse\" cx=\"\(shape.start.x)\" cy=\"\(shape.start.y)\" r=\"\(radius)\">\(stops)</radialGradient>"
        }
        return "<linearGradient id=\"face-\(index)\" gradientUnits=\"userSpaceOnUse\" x1=\"\(shape.start.x)\" y1=\"\(shape.start.y)\" x2=\"\(shape.end.x)\" y2=\"\(shape.end.y)\">\(stops)</linearGradient>"
    }.joined(separator: "\n    ")
    let faces = shapes.enumerated().filter { !$0.element.cutout }.map { index,shape in
        shape.svgElement(fill: shape.paint.count > 1 ? "url(#face-\(index))" : hex(shape.paint.first ?? candidate.foreground))
    }.joined(separator: "\n    ")
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-labelledby="title desc">
      <title id="title">Talkless candidate \(candidate.id): \(candidate.name)</title>
      <desc id="desc">\(candidate.subtitle) Original icon study only, not a production replacement.</desc>
      <defs>
        \(gradients)
        <linearGradient id="tile" gradientUnits="userSpaceOnUse" x1="330" y1="92" x2="700" y2="932">
          <stop stop-color="\(hex(mix(candidate.base,0xFFFFFF,0.11)))"/>
          <stop offset=".48" stop-color="\(hex(candidate.base))"/>
          <stop offset="1" stop-color="\(hex(mix(candidate.base,0x141C2C,0.16)))"/>
        </linearGradient>
        <linearGradient id="rim" x2="0" y2="1"><stop stop-color="white" stop-opacity=".30"/><stop offset="1" stop-color="white" stop-opacity=".02"/></linearGradient>
        <filter id="shadow" x="-20%" y="-20%" width="140%" height="150%"><feDropShadow dx="0" dy="12" stdDeviation="10" flood-color="#182338" flood-opacity=".16"/></filter>
        <mask id="mark"><rect width="1024" height="1024" fill="black"/>
          \(mask)
        </mask>
      </defs>
      <path d="\(tile().svg)" fill="url(#tile)" filter="url(#shadow)"/>
      <path d="\(tile().svg)" fill="none" stroke="url(#rim)" stroke-width="3"/>
      <g mask="url(#mark)">
        \(faces)
      </g>
    </svg>
    """ + "\n"
}
private enum FontRole { case display, body, utility }
private func text(_ string: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular,
                  value: UInt32 = ink, width: CGFloat = 1000, role: FontRole = .body) {
    let font: NSFont
    switch role {
    case .display: font = NSFont(name: "AvenirNext-DemiBold",size: size) ?? NSFont.systemFont(ofSize: size,weight: .semibold)
    case .body: font = NSFont.systemFont(ofSize: size,weight: weight)
    case .utility: font = NSFont.monospacedSystemFont(ofSize: size,weight: weight)
    }
    (string as NSString).draw(in: CGRect(x: x,y: y,width: width,height: 64),withAttributes: [
        .font: font, .foregroundColor: NSColor(cgColor: color(value))!
    ])
}
private func image(_ c: CGContext, _ image: CGImage, x: CGFloat, y: CGFloat, size: CGFloat) {
    c.saveGState(); c.translateBy(x: x,y: y+size); c.scaleBy(x: 1,y: -1); c.interpolationQuality = .none
    c.draw(image,in: CGRect(x: 0,y: 0,width: size,height: size)); c.restoreGState()
}
private func preview(_ c: CGContext, _ candidate: Candidate, x: CGFloat, y: CGFloat, dark: Bool) {
    let foreground: UInt32 = dark ? 0xF3F5F8 : ink
    let secondary: UInt32 = dark ? 0xB6BECD : 0x626B7C
    fill(c,rounded(x,y,210,128,13).cg,color(dark ? night : sheet))
    text(dark ? "DARK" : "LIGHT",x: x+13,y: y+12,size: 10,weight: .semibold,value: secondary,role: .utility)
    text("32",x: x+103,y: y+12,size: 10,value: secondary,role: .utility)
    text("16",x: x+166,y: y+12,size: 10,value: secondary,role: .utility)
    text("APP",x: x+13,y: y+47,size: 10,value: secondary,role: .utility)
    text("MONO",x: x+13,y: y+94,size: 10,value: secondary,role: .utility)
    for (size,dx) in [(32,CGFloat(96)),(16,CGFloat(164))] {
        let offset = CGFloat(32-size)/2
        image(c,render(candidate,size: size),x: x+dx,y: y+36+offset,size: CGFloat(size))
        image(c,render(candidate,size: size,monochrome: foreground),x: x+dx,y: y+83+offset,size: CGFloat(size))
    }
}
private func contactSheet() -> CGImage {
    let width = 1144, height = 1040, c = context(1144,1040)
    c.translateBy(x: 0,y: CGFloat(height)); c.scaleBy(x: 1,y: -1)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c,flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }
    c.setFillColor(color(sheet)); c.fill(CGRect(x: 0,y: 0,width: width,height: height))
    text("Talkless / Further forms",x: 28,y: 22,size: 29,role: .display)
    text("Four new silhouettes for less typing. App icons at 256 px; small previews at actual 32 / 16 px.",
         x: 29,y: 67,size: 14,value: 0x626B7C)
    text("ROUND TWO  D–G",x: 981,y: 35,size: 11,weight: .medium,value: 0x626B7C,role: .utility)
    for (index,candidate) in groundedCandidates.enumerated() {
        let x = CGFloat(28+(index%2)*554), y = CGFloat(108+(index/2)*448)
        fill(c,rounded(x,y,534,424,21).cg,color(0xFFFFFF))
        text(candidate.id,x: x+22,y: y+22,size: 25,weight: .semibold,value: candidate.id == "E" ? 0x92611F : candidate.base,role: .utility)
        text(candidate.name,x: x+62,y: y+18,size: 25,role: .display)
        text(candidate.subtitle,x: x+22,y: y+61,size: 13,value: 0x626B7C,width: 490)
        image(c,render(candidate,size: 256),x: x+20,y: y+103,size: 256)
        preview(c,candidate,x: x+300,y: y+101,dark: false)
        preview(c,candidate,x: x+300,y: y+245,dark: true)
        text(candidate.note,x: x+22,y: y+391,size: 13,value: 0x626B7C,width: 490)
    }
    text("EXPLORATIONS ONLY — app and menu-bar icons are unchanged.",x: 28,y: 1007,size: 11,value: 0x626B7C)
    text("Original vectors · Native macOS render",x: 897,y: 1007,size: 11,value: 0x626B7C)
    return c.makeImage()!
}
private func freeContactSheet() -> CGImage {
    let width = 1000,height = 1110,c = context(1000,1110)
    c.translateBy(x: 0,y: CGFloat(height)); c.scaleBy(x: 1,y: -1)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: c,flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }
    c.setFillColor(color(0xECEEF2)); c.fill(CGRect(x: 0,y: 0,width: width,height: height))
    text("Talkless / Play",x: 36,y: 25,size: 30,role: .display)
    text("H — K",x: 878,y: 38,size: 12,weight: .medium,value: 0x626B7C,role: .utility)
    for (index,candidate) in freeCandidates.enumerated() {
        let x = CGFloat(24+(index%2)*488), y = CGFloat(88+(index/2)*498)
        fill(c,rounded(x,y,464,480,20).cg,color(0xFAFBFD))
        text(candidate.id,x: x+25,y: y+21,size: 17,weight: .semibold,value: 0x626B7C,role: .utility)
        text(candidate.name,x: x+60,y: y+16,size: 23,role: .display)
        image(c,render(candidate,size: 360),x: x+52,y: y+56,size: 360)
        fill(c,rounded(x+20,y+408,207,52,11).cg,color(0xECEEF2))
        fill(c,rounded(x+237,y+408,207,52,11).cg,color(night))
        for dark in [false,true] {
            let px = x+(dark ? 237 : 20), foreground: UInt32 = dark ? 0xF3F5F8 : ink
            image(c,render(candidate,size: 32),x: px+13,y: y+418,size: 32)
            image(c,render(candidate,size: 16),x: px+57,y: y+426,size: 16)
            fill(c,rounded(px+91,y+422,1,24,0.5).cg,color(dark ? 0x505766 : 0xC9CFD8))
            image(c,render(candidate,size: 32,monochrome: foreground),x: px+111,y: y+418,size: 32)
            image(c,render(candidate,size: 16,monochrome: foreground),x: px+160,y: y+426,size: 16)
        }
    }
    text("360 px  /  32 + 16 px in color and mono",x: 36,y: 1083,size: 11,value: 0x626B7C,role: .utility)
    text("Studies only",x: 880,y: 1083,size: 11,value: 0x626B7C,role: .utility)
    return c.makeImage()!
}
private func silhouettePanel(_ candidate: Candidate, dark: Bool, size: Int) -> CGImage {
    let c = context(size, size)
    c.setFillColor(color(dark ? night : 0xF5F6F8))
    c.fill(CGRect(x: 0, y: 0, width: size, height: size))
    c.draw(render(candidate, size: size * 3 / 4, monochrome: dark ? 0xF3F5F8 : ink),
           in: CGRect(x: size / 8, y: size / 8, width: size * 3 / 4, height: size * 3 / 4))
    return c.makeImage()!
}

private func silhouetteSheet() -> CGImage {
    let c = context(1000, 1100)
    c.translateBy(x: 0, y: 1100); c.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }
    c.setFillColor(color(0xECEEF2)); c.fill(CGRect(x: 0, y: 0, width: 1000, height: 1100))
    text("Talkless / Silhouettes", x: 32, y: 24, size: 30, role: .display)
    text("Original shapes, isolated. Light and dark are the same mark.", x: 32, y: 65, size: 14)
    for (index, candidate) in freeCandidates.enumerated() {
        let x = CGFloat(24 + (index % 2) * 488), y = CGFloat(104 + (index / 2) * 482)
        fill(c, rounded(x, y, 464, 458, 20).cg, color(0xFFFFFF))
        text("\(candidate.id)  \(candidate.name)", x: x + 24, y: y + 18, size: 24, role: .display)
        for dark in [false, true] {
            let px = x + (dark ? 242 : 16)
            image(c, silhouettePanel(candidate, dark: dark, size: 206), x: px, y: y + 76, size: 206)
            fill(c, rounded(px, y + 302, 206, 100, 12).cg, color(dark ? night : 0xF5F6F8))
            image(c, render(candidate, size: 32, monochrome: dark ? 0xF3F5F8 : ink),
                  x: px + 47, y: y + 322, size: 32)
            image(c, render(candidate, size: 16, monochrome: dark ? 0xF3F5F8 : ink),
                  x: px + 139, y: y + 330, size: 16)
            text("32 px     16 px", x: px + 44, y: y + 371, size: 11,
                 value: dark ? 0xBEC6D4 : 0x626B7C, role: .utility)
        }
    }
    text("Selection studies only — shipped icon unchanged.", x: 32, y: 1074, size: 12)
    return c.makeImage()!
}

private func run() throws {
    guard CommandLine.arguments.count == 2,CommandLine.arguments[1].hasPrefix("/") else {
        fputs("Usage: swift generate.swift /tmp/talkless-icon-round-two-<unique-name>\n",stderr); exit(64)
    }
    let output = URL(fileURLWithPath: CommandLine.arguments[1],isDirectory: true).standardizedFileURL
    let resolved = output.resolvingSymlinksInPath().path
    guard resolved.hasPrefix("/private/tmp/talkless-icon-round-two-") || resolved.hasPrefix("/tmp/talkless-icon-round-two-") else {
        fputs("PNG output must be a unique /tmp/talkless-icon-round-two-* directory.\n",stderr); exit(64)
    }
    try FileManager.default.createDirectory(at: output,withIntermediateDirectories: true)
    for candidate in candidates {
        let vector = svg(candidate).components(separatedBy: .newlines)
            .map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }
            .joined(separator: "\n")
        try vector.write(to: source.appendingPathComponent(candidate.slug+".svg"),atomically: true,encoding: .utf8)
        for size in [16,32,256,360,1024] {
            try writePNG(render(candidate,size: size),to: output.appendingPathComponent("\(candidate.slug)-\(size).png"))
        }
        for size in [16,32] {
            try writePNG(render(candidate,size: size,monochrome: ink),to: output.appendingPathComponent("\(candidate.slug)-mono-light-\(size).png"))
            try writePNG(render(candidate,size: size,monochrome: 0xF3F5F8),to: output.appendingPathComponent("\(candidate.slug)-mono-dark-\(size).png"))
        }
    }
    try writePNG(silhouetteSheet(), to: output.appendingPathComponent("silhouette-selection.png"))
    for candidate in freeCandidates {
        for dark in [false, true] {
            try writePNG(silhouettePanel(candidate, dark: dark, size: 512),
                         to: output.appendingPathComponent("\(candidate.slug)-\(dark ? "dark" : "light").png"))
        }
    }
    try writePNG(contactSheet(),to: output.appendingPathComponent("talkless-icon-round-two-contact-sheet.png"))
    try writePNG(freeContactSheet(),to: output.appendingPathComponent("talkless-icon-play-contact-sheet.png"))
    print("Rendered D–G and freer H–K, plus both contact sheets, to \(output.path)")
    print("Updated only SVGs in \(source.path). Production icons and previous studies are unchanged.")
}
try run()
