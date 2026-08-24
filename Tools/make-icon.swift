#!/usr/bin/env swift
//
// make-icon.swift — draws the Grayroom app icon and packs it into an `.icns`.
//
//   swift Tools/make-icon.swift --concept 1 --size 256 --out /tmp/icon-1.png
//   swift Tools/make-icon.swift --concept 1 --icns Sources/GrayroomApp/Resources/AppIcon.icns
//
// The icon is drawn rather than pasted in so it can be regenerated at any size
// and so the geometry follows Apple's macOS grid exactly: a 1024 px canvas with
// the squircle occupying the centred 824 px area, continuous-curvature corners
// (approximated by a superellipse), a subtle top-to-bottom body gradient and a
// soft drop shadow.
//

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry

/// Apple's macOS icon grid, expressed as fractions of the canvas so every size
/// renders identically.
private enum Grid {
    static let canvas: CGFloat = 1024
    /// The squircle body: 824 of 1024.
    static let body: CGFloat = 824
    /// Superellipse exponent. n = 5 is the closest simple match to the
    /// continuous corner curvature of macOS Big Sur and later (whose corner
    /// radius is ≈ 0.2237 × 824 ≈ 184 px).
    static let squircleExponent: CGFloat = 5
}

/// A superellipse |x/a|^n + |y/b|^n = 1, sampled densely enough that the curve
/// is smooth at 1024 px.
private func squirclePath(in rect: CGRect, exponent n: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    let e = 2 / n
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * (c < 0 ? -1 : 1) * pow(abs(c), e)
        let y = cy + b * (s < 0 ? -1 : 1) * pow(abs(s), e)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

// MARK: - Colours

private func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

private enum Palette {
    /// Body gradient: mid-charcoal at the top falling to near-black.
    static let bodyTop = rgb(72, 77, 84)
    static let bodyBottom = rgb(17, 18, 21)
    /// The one accent: a darkroom safelight.
    static let safelight = rgb(226, 66, 45)
    static let safelightWarm = rgb(255, 138, 66)
}

private func linearGradient(
    _ ctx: CGContext, from: CGPoint, to: CGPoint, colors: [CGColor], locations: [CGFloat]
) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
    else { return }
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

private func radialGlow(
    _ ctx: CGContext, center: CGPoint, radius: CGFloat, colors: [CGColor], locations: [CGFloat]
) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
    else { return }
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

// MARK: - Shared pieces

/// The squircle body with its gradient and drop shadow. Returns the body path so
/// the caller can clip the artwork to it.
@discardableResult
private func drawBody(_ ctx: CGContext, s: CGFloat) -> CGPath {
    let side = Grid.body * s
    let rect = CGRect(
        x: (Grid.canvas * s - side) / 2, y: (Grid.canvas * s - side) / 2,
        width: side, height: side)
    let path = squirclePath(in: rect, exponent: Grid.squircleExponent)

    // Apple's template shadow: soft, straight down, and small.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 26 * s, color: rgb(0, 0, 0, 0.42))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0, 0, 0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    linearGradient(
        ctx, from: CGPoint(x: 0, y: rect.maxY), to: CGPoint(x: 0, y: rect.minY),
        colors: [Palette.bodyTop, Palette.bodyBottom], locations: [0, 1])
    ctx.restoreGState()

    return path
}

/// The safelight: a red-to-transparent radial wash in the top-right corner,
/// clipped to the body.
private func drawSafelight(_ ctx: CGContext, body: CGPath, s: CGFloat, strength: CGFloat = 1) {
    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    ctx.setBlendMode(.screen)
    // A lamp, not a wash: a small bright core with a fast falloff, so the red
    // stays an accent in one corner instead of tinting the whole body.
    radialGlow(
        ctx, center: CGPoint(x: 830 * s, y: 868 * s), radius: 340 * s,
        colors: [
            Palette.safelightWarm.copy(alpha: 0.95 * strength)!,
            Palette.safelight.copy(alpha: 0.80 * strength)!,
            Palette.safelight.copy(alpha: 0.16 * strength)!,
            Palette.safelight.copy(alpha: 0)!,
        ],
        locations: [0, 0.16, 0.45, 1])
    ctx.restoreGState()
}

/// A rounded rectangle with a hairline light edge — the "print" or film frame.
private func cardPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Concepts

/// 1 — the tonal ramp print: a landscape photo card carrying a black-to-white
/// step-free gray ramp, lit from the top right by the safelight.
private func drawConcept1(_ ctx: CGContext, s: CGFloat) {
    let body = drawBody(ctx, s: s)
    drawSafelight(ctx, body: body, s: s)

    let card = CGRect(x: 232 * s, y: 300 * s, width: 560 * s, height: 400 * s)
    let path = cardPath(card, radius: 26 * s)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 30 * s, color: rgb(0, 0, 0, 0.55))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0, 0, 0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    linearGradient(
        ctx, from: CGPoint(x: card.minX, y: 0), to: CGPoint(x: card.maxX, y: 0),
        colors: [rgb(14, 14, 16), rgb(120, 122, 126), rgb(238, 238, 240)],
        locations: [0, 0.5, 1])
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.22))
    ctx.setLineWidth(6 * s)
    ctx.strokePath()
    ctx.restoreGState()
}

/// 2 — the film frame: a single 35 mm frame with sprocket runs top and bottom,
/// the image area holding the gray ramp.
private func drawConcept2(_ ctx: CGContext, s: CGFloat) {
    let body = drawBody(ctx, s: s)
    drawSafelight(ctx, body: body, s: s, strength: 0.85)

    let strip = CGRect(x: 212 * s, y: 262 * s, width: 600 * s, height: 476 * s)
    let stripPath = cardPath(strip, radius: 22 * s)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 30 * s, color: rgb(0, 0, 0, 0.55))
    ctx.addPath(stripPath)
    ctx.setFillColor(rgb(24, 25, 28))
    ctx.fillPath()
    ctx.restoreGState()

    // Image area.
    let frame = strip.insetBy(dx: 34 * s, dy: 96 * s)
    ctx.saveGState()
    ctx.addPath(cardPath(frame, radius: 8 * s))
    ctx.clip()
    linearGradient(
        ctx, from: CGPoint(x: frame.minX, y: 0), to: CGPoint(x: frame.maxX, y: 0),
        colors: [rgb(16, 16, 18), rgb(126, 128, 132), rgb(240, 240, 242)],
        locations: [0, 0.5, 1])
    ctx.restoreGState()

    // Sprockets.
    ctx.setFillColor(rgb(96, 99, 105))
    let holeW = 52 * s, holeH = 38 * s, gap = 30 * s
    let count = 6
    let total = CGFloat(count) * holeW + CGFloat(count - 1) * gap
    var x = strip.midX - total / 2
    for _ in 0..<count {
        for y in [strip.minY + 29 * s, strip.maxY - 29 * s - holeH] {
            ctx.addPath(cardPath(CGRect(x: x, y: y, width: holeW, height: holeH), radius: 10 * s))
        }
        x += holeW + gap
    }
    ctx.fillPath()
}

/// 3 — the test strip: the same photo card, but carrying the stepped gray wedge
/// a darkroom printer exposes to find the time, instead of a smooth ramp.
private func drawConcept3(_ ctx: CGContext, s: CGFloat) {
    let body = drawBody(ctx, s: s)
    drawSafelight(ctx, body: body, s: s)

    let card = CGRect(x: 232 * s, y: 300 * s, width: 560 * s, height: 400 * s)
    let path = cardPath(card, radius: 26 * s)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 30 * s, color: rgb(0, 0, 0, 0.55))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0, 0, 0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let steps: [CGColor] = [
        rgb(14, 14, 16), rgb(58, 59, 63), rgb(112, 114, 118), rgb(174, 176, 180), rgb(240, 240, 242),
    ]
    let w = card.width / CGFloat(steps.count)
    for (i, color) in steps.enumerated() {
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: card.minX + CGFloat(i) * w, y: card.minY, width: w + 1, height: card.height))
    }
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.22))
    ctx.setLineWidth(6 * s)
    ctx.strokePath()
    ctx.restoreGState()
}

/// 4 — the print with a scene: the same photo card carrying a minimal B&W
/// landscape (graded sky, sun, ridge silhouette).
private func drawConcept4(_ ctx: CGContext, s: CGFloat) {
    let body = drawBody(ctx, s: s)
    drawSafelight(ctx, body: body, s: s)

    let card = CGRect(x: 232 * s, y: 300 * s, width: 560 * s, height: 400 * s)
    let path = cardPath(card, radius: 26 * s)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12 * s), blur: 30 * s, color: rgb(0, 0, 0, 0.55))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0, 0, 0))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    // Sky: bright at the horizon, dark at the top — a printed-down sky.
    linearGradient(
        ctx, from: CGPoint(x: 0, y: card.maxY), to: CGPoint(x: 0, y: card.minY),
        colors: [rgb(38, 39, 43), rgb(150, 152, 157), rgb(244, 244, 246)],
        locations: [0, 0.55, 1])
    // Sun.
    ctx.setFillColor(rgb(255, 255, 255, 0.9))
    ctx.fillEllipse(in: CGRect(x: card.midX + 92 * s, y: card.midY + 40 * s, width: 84 * s, height: 84 * s))
    // Ridge.
    let ridge = CGMutablePath()
    ridge.move(to: CGPoint(x: card.minX, y: card.minY))
    ridge.addLine(to: CGPoint(x: card.minX, y: card.minY + 92 * s))
    ridge.addLine(to: CGPoint(x: card.minX + 150 * s, y: card.minY + 196 * s))
    ridge.addLine(to: CGPoint(x: card.minX + 262 * s, y: card.minY + 108 * s))
    ridge.addLine(to: CGPoint(x: card.minX + 400 * s, y: card.minY + 236 * s))
    ridge.addLine(to: CGPoint(x: card.maxX, y: card.minY + 96 * s))
    ridge.addLine(to: CGPoint(x: card.maxX, y: card.minY))
    ridge.closeSubpath()
    ctx.addPath(ridge)
    ctx.setFillColor(rgb(12, 12, 14))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.setStrokeColor(rgb(255, 255, 255, 0.22))
    ctx.setLineWidth(6 * s)
    ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Rendering

/// Concept 0: an externally supplied square artwork, scaled onto the standard
/// 824/1024 body rect, clipped to the squircle, over the template shadow.
private var sourceImage: CGImage?

private func drawFromSource(_ ctx: CGContext, s: CGFloat) {
    guard let src = sourceImage else { fatalError("--from image not loaded") }
    let side = Grid.body * s
    let rect = CGRect(
        x: (Grid.canvas * s - side) / 2, y: (Grid.canvas * s - side) / 2,
        width: side, height: side)
    let path = squirclePath(in: rect, exponent: Grid.squircleExponent)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14 * s), blur: 26 * s, color: rgb(0, 0, 0, 0.42))
    ctx.addPath(path)
    ctx.setFillColor(rgb(0, 0, 0))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(src, in: rect)
    ctx.restoreGState()
}

private func render(concept: Int, size: Int) -> CGImage {
    let px = size
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("could not create a \(px)×\(px) bitmap context") }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    let s = CGFloat(px) / Grid.canvas
    switch concept {
    case 0: drawFromSource(ctx, s: s)
    case 1: drawConcept1(ctx, s: s)
    case 2: drawConcept2(ctx, s: s)
    case 3: drawConcept3(ctx, s: s)
    case 4: drawConcept4(ctx, s: s)
    default: fatalError("unknown concept \(concept)")
    }
    guard let image = ctx.makeImage() else { fatalError("could not snapshot the context") }
    return image
}

private func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed")
    }
    try! FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! data.write(to: url)
}

/// Builds the `.iconset` macOS expects and runs `iconutil` over it.
private func writeICNS(concept: Int, to url: URL) {
    let fm = FileManager.default
    let work = fm.temporaryDirectory.appendingPathComponent("Grayroom-\(UUID().uuidString)")
    let iconset = work.appendingPathComponent("AppIcon.iconset")
    try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    // 16/32/128/256/512 at @1x and @2x — the full set `iconutil` wants.
    for base in [16, 32, 128, 256, 512] {
        writePNG(render(concept: concept, size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
        writePNG(render(concept: concept, size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", iconset.path, "-o", url.path]
    try! p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { fatalError("iconutil failed with \(p.terminationStatus)") }
    try? fm.removeItem(at: work)
    print("wrote \(url.path)")
}

// MARK: - Command line

var concept = 1
var size = 1024
var out: String?
var icns: String?
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--concept": concept = Int(args.removeFirst())!
    case "--from":
        let path = args.removeFirst()
        guard let provider = CGDataProvider(url: URL(fileURLWithPath: path) as CFURL),
              let img = CGImage(pngDataProviderSource: provider, decode: nil,
                                shouldInterpolate: true, intent: .defaultIntent)
        else { fatalError("could not read \(path) as PNG") }
        sourceImage = img
        concept = 0
    case "--size": size = Int(args.removeFirst())!
    case "--out": out = args.removeFirst()
    case "--icns": icns = args.removeFirst()
    default: fatalError("unknown argument \(arg)")
    }
}

if let out {
    writePNG(render(concept: concept, size: size), to: URL(fileURLWithPath: out))
    print("wrote \(out) (\(size) px, concept \(concept))")
}
if let icns {
    writeICNS(concept: concept, to: URL(fileURLWithPath: icns))
}
if out == nil && icns == nil {
    print("nothing to do: pass --out <png> and/or --icns <file>")
}
