import AppKit
import CoreGraphics
import GrayroomCanvas
import GrayroomUI
import Metal
import XCTest

/// Repro (b): the closed loop. Whatever the canvas *shows* at a view point must
/// be the image pixel that the *input* mapping claims is there.
///
/// The image is a four-quadrant marker texture, so "which image pixel" collapses
/// to "which colour", and the check needs no knowledge of either mapping's
/// internals: render through the real pipeline state and the real shader into an
/// offscreen texture, read it back, and for a grid of view points compare the
/// rendered colour against the quadrant that `CanvasTransform.imagePoint` names.
/// A flip, an offset or a scale mismatch anywhere between the shader and
/// `CanvasTransform` fails this.
final class CanvasDisplayInputTests: XCTestCase {
    private var h: CanvasHarness!
    private var queue: MTLCommandQueue!
    /// Portrait, like a preview decode of a 3:2 frame.
    private let imageSize = CGSize(width: 1707, height: 2560)

    private enum Quadrant: String, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        /// r, g, b as unorm bytes.
        var rgb: (UInt8, UInt8, UInt8) {
            switch self {
            case .topLeft: return (255, 0, 0)        // red
            case .topRight: return (0, 255, 0)       // green
            case .bottomLeft: return (0, 0, 255)     // blue
            case .bottomRight: return (255, 255, 0)  // yellow
            }
        }
    }

    override func setUpWithError() throws {
        h = try CanvasHarness()
        queue = h.device.makeCommandQueue()
        h.canvas.imageTexture = try makeQuadrantTexture()
        h.canvas.setImageSize(imageSize)
    }

    override func tearDown() {
        h = nil
        queue = nil
        super.tearDown()
    }

    // MARK: - Marker texture

    private func makeQuadrantTexture(scale: CGFloat = 1) throws -> MTLTexture {
        let w = Int(imageSize.width * scale), hgt = Int(imageSize.height * scale)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                         width: w, height: hgt,
                                                         mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let tex = h.device.makeTexture(descriptor: d) else {
            throw XCTSkip("could not allocate marker texture")
        }
        var bytes = [UInt8](repeating: 0, count: w * hgt * 4)
        for y in 0..<hgt {
            for x in 0..<w {
                let q: Quadrant = y < hgt / 2
                    ? (x < w / 2 ? .topLeft : .topRight)
                    : (x < w / 2 ? .bottomLeft : .bottomRight)
                let (r, g, b) = q.rgb
                let i = (y * w + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
            }
        }
        bytes.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, w, hgt), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: w * 4)
        }
        return tex
    }

    /// Which quadrant an image-space point falls in, or `nil` when it is outside
    /// the image or too close to a boundary for a linear-filtered sample to be
    /// unambiguous.
    private func quadrant(ofImagePoint p: CGPoint, margin: CGFloat = 12) -> Quadrant? {
        let w = imageSize.width, hgt = imageSize.height
        guard p.x > margin, p.y > margin, p.x < w - margin, p.y < hgt - margin else { return nil }
        guard abs(p.x - w / 2) > margin, abs(p.y - hgt / 2) > margin else { return nil }
        return p.y < hgt / 2 ? (p.x < w / 2 ? .topLeft : .topRight)
                             : (p.x < w / 2 ? .bottomLeft : .bottomRight)
    }

    // MARK: - Offscreen render of the real draw path

    private struct Frame {
        var bgra: [UInt8]
        var width: Int
        var height: Int
        func rgb(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * width + x) * 4
            return (bgra[i + 2], bgra[i + 1], bgra[i])
        }
    }

    private func render() throws -> Frame {
        let size = h.canvas.transform.viewSize
        let w = Int(size.width.rounded()), hgt = Int(size.height.rounded())
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: h.canvas.colorPixelFormat,
                                                         width: w, height: hgt, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        let target = try XCTUnwrap(h.device.makeTexture(descriptor: d))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = h.canvas.clearColor
        pass.colorAttachments[0].storeAction = .store

        let buffer = try XCTUnwrap(queue.makeCommandBuffer())
        h.canvas.encodeCanvas(into: pass, commandBuffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        XCTAssertNil(buffer.error)

        var bytes = [UInt8](repeating: 0, count: w * hgt * 4)
        bytes.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: w * 4,
                            from: MTLRegionMake2D(0, 0, w, hgt), mipmapLevel: 0)
        }
        return Frame(bgra: bytes, width: w, height: hgt)
    }

    private func classify(_ rgb: (UInt8, UInt8, UInt8)) -> Quadrant? {
        for q in Quadrant.allCases {
            let (r, g, b) = q.rgb
            if abs(Int(rgb.0) - Int(r)) < 40, abs(Int(rgb.1) - Int(g)) < 40,
               abs(Int(rgb.2) - Int(b)) < 40 {
                return q
            }
        }
        return nil
    }

    /// The whole point: for a grid of view points, what is drawn == what the
    /// input mapping says is there.
    private func assertDisplayAgreesWithInput(_ label: String,
                                              file: StaticString = #filePath,
                                              line: UInt = #line) throws {
        let frame = try render()
        let t = h.canvas.transform
        var checked = 0
        var mismatches: [String] = []
        let step = 37
        for py in stride(from: step / 2, to: frame.height, by: step) {
            for px in stride(from: step / 2, to: frame.width, by: step) {
                // Pixel centres: pixel (px, py) covers view device point px+0.5.
                let view = CGPoint(x: CGFloat(px) + 0.5, y: CGFloat(py) + 0.5)
                guard let want = quadrant(ofImagePoint: t.imagePoint(fromView: view)) else { continue }
                checked += 1
                let got = classify(frame.rgb(x: px, y: py))
                if got != want {
                    mismatches.append("view \(view) -> image \(t.imagePoint(fromView: view)): "
                                      + "input says \(want), display shows "
                                      + "\(got.map(\.rawValue) ?? "rgb\(frame.rgb(x: px, y: py))")")
                }
            }
        }
        XCTAssertGreaterThan(checked, 100, "\(label): not enough sample points", file: file, line: line)
        if !mismatches.isEmpty {
            XCTFail("\(label): \(mismatches.count)/\(checked) points disagree. "
                    + "First 5:\n" + mismatches.prefix(5).joined(separator: "\n"),
                    file: file, line: line)
        }
        print("[closed loop] \(label): \(checked) points agree "
              + "(zoom \(t.zoom), centre \(t.center), viewSize \(t.viewSize))")
    }

    func testDisplayAgreesWithInputAtFit() throws {
        try assertDisplayAgreesWithInput("fit")
    }

    /// The drawable is tagged sRGB so the window server colour-matches it to the
    /// display profile (wave 3, audit `decode-output` #9). Untagged, the
    /// pipeline's sRGB-encoded values were interpreted in the *display's* space,
    /// so on a P3 panel every toned image was drawn more saturated than the
    /// exported sRGB file — the split-toning sliders lied. Neutral B&W looks the
    /// same either way, which is exactly why this went unnoticed.
    func testDrawableIsTaggedSRGB() throws {
        let layer = try XCTUnwrap(h.canvas.layer as? CAMetalLayer)
        let space = try XCTUnwrap(layer.colorspace)
        XCTAssertEqual(space.name, CGColorSpace.sRGB)
        XCTAssertEqual(h.canvas.colorPixelFormat, .bgra8Unorm)
    }

    /// The canvas dithers to 8 bits with the exporter's rule, so a smooth
    /// gradient does not band on screen either. It must stay within one code of
    /// the undithered value — a dither that shifted the picture would break
    /// every "what you see is the PNG" claim in this suite.
    func testCanvasDitherLeavesExactCodesAlone() throws {
        // Inside a quadrant every filter tap is the same 0/255 marker colour, so
        // the fragment value is exactly on a code and the dither must be a
        // no-op. (The 0.09 backdrop is *not* on a code and is expected to
        // alternate between 22 and 23 — that is the dither working.)
        let frame = try render()
        let t = h.canvas.transform
        var checked = 0, offCode = 0
        for py in stride(from: 5, to: frame.height, by: 11) {
            for px in stride(from: 5, to: frame.width, by: 11) {
                let view = CGPoint(x: CGFloat(px) + 0.5, y: CGFloat(py) + 0.5)
                guard quadrant(ofImagePoint: t.imagePoint(fromView: view)) != nil else { continue }
                checked += 1
                let (r, g, b) = frame.rgb(x: px, y: py)
                if ![r, g, b].allSatisfy({ $0 == 0 || $0 == 255 }) { offCode += 1 }
            }
        }
        XCTAssertGreaterThan(checked, 100)
        XCTAssertEqual(offCode, 0, "\(offCode)/\(checked) image pixels moved off their exact code")
    }

    /// A draft render is a *smaller* texture standing in for the same image, and
    /// the canvas addresses it by the same normalised uv. Whatever the input
    /// mapping says is under a view point must therefore still be what is drawn
    /// — and the mask overlay, which is sampled by that same uv, keeps lining up
    /// for free.
    func testDisplayAgreesWithInputWhileADraftTextureIsUp() throws {
        h.canvas.imageTexture = try makeQuadrantTexture(scale: 0.4)
        XCTAssertLessThan(h.canvas.imageTexture!.width, Int(imageSize.width))
        XCTAssertEqual(h.canvas.transform.imageSize, imageSize,
                       "precondition: the transform still describes the full image")
        try assertDisplayAgreesWithInput("draft texture, fit")
        h.canvas.zoomToActualSize()
        try assertDisplayAgreesWithInput("draft texture, 1:1")
    }

    /// The mip level is a property of the texture being sampled, not of the
    /// transform: a draft at 40 % shown at 100 % is a 2.5x magnification of the
    /// texture and must stay on level 0, however far the image-pixel zoom is
    /// from it.
    func testTheLODFollowsTheTextureNotJustTheZoom() throws {
        h.canvas.zoomToActualSize()
        XCTAssertEqual(h.canvas.currentUniforms().lod, 0, accuracy: 1e-6)
        XCTAssertEqual(h.canvas.currentUniforms().nearest, 0)

        // Fit zoom on the full-resolution texture minifies, so the level rises.
        h.canvas.zoomToFit()
        let full = h.canvas.currentUniforms()
        XCTAssertGreaterThan(full.lod, 1)
        XCTAssertEqual(Double(full.lod),
                       CanvasTransform.displayLOD(zoom: h.canvas.transform.zoom),
                       accuracy: 1e-5)

        // The same view, showing a 40 % draft: minified 2.5x less.
        h.canvas.imageTexture = try makeQuadrantTexture(scale: 0.4)
        let draft = h.canvas.currentUniforms()
        let scale = Double(h.canvas.imageTexture!.width) / Double(imageSize.width)
        XCTAssertLessThan(draft.lod, full.lod)
        XCTAssertEqual(Double(draft.lod),
                       CanvasTransform.displayLOD(zoom: h.canvas.transform.zoom,
                                                  textureScale: scale),
                       accuracy: 1e-5)

        // Magnifying that draft to 100 % of the *image* is 2.5x of the texture:
        // level 0, and still interpolated — nearest is keyed on the image zoom,
        // so the transient draft is not blown up into hard blocks.
        h.canvas.zoomToActualSize()
        XCTAssertEqual(h.canvas.currentUniforms().lod, 0, accuracy: 1e-6)
        XCTAssertEqual(h.canvas.currentUniforms().nearest, 0)
    }

    func testDisplayAgreesWithInputAtActualSize() throws {
        h.canvas.zoomToActualSize()
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), 1, 1e-9)
        try assertDisplayAgreesWithInput("1:1")
    }

    func testDisplayAgreesWithInputAfterAPan() throws {
        h.canvas.zoomToActualSize()
        // Pan with real events, so the drag path is in the loop too.
        h.send(.leftMouseDown, at: h.windowPoint(rightOf: 400, below: 300))
        h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 430, below: 180))
        h.send(.leftMouseUp, at: h.windowPoint(rightOf: 430, below: 180))
        XCTAssertNotEqual(h.canvas.transform.center.y, imageSize.height / 2)
        try assertDisplayAgreesWithInput("panned")
    }

    /// The display must invert the *same* transform the input path inverts, even
    /// when the view's own bounds momentarily disagree with the drawable — which
    /// is what a live window resize does.
    func testDisplayFollowsTheTransformNotTheViewBounds() throws {
        h.canvas.zoomToActualSize()
        let expected = h.canvas.transform.viewSize
        // Decouple the drawable from the bounds, then move the bounds. Nothing
        // told the transform, so `bounds * scale != transform.viewSize` — the
        // exact skew a resize produces for a frame.
        h.canvas.autoResizeDrawable = false
        h.canvas.setFrameSize(NSSize(width: 500, height: 380))
        XCTAssertEqual(h.canvas.transform.viewSize, expected,
                       "precondition: the transform must not have followed the bounds")
        XCTAssertNotEqual(h.canvas.bounds.width * h.scale, expected.width)
        XCTAssertEqual(CGFloat(h.canvas.currentUniforms().viewSize.x), expected.width)
        XCTAssertEqual(CGFloat(h.canvas.currentUniforms().viewSize.y), expected.height)
        try assertDisplayAgreesWithInput("bounds skewed from drawable")
    }

    /// The top of the screen shows the top of the image — stated in raw colours,
    /// with no coordinate mapping involved on the expectation side at all.
    func testTopOfTheCanvasShowsTheTopOfTheImage() throws {
        let frame = try render()
        // The fitted portrait is letterboxed left/right, so sample on the
        // vertical centre line.
        let x = frame.width / 2 - frame.width / 8      // left of the image's centre
        let topRow = frame.height / 8
        let bottomRow = frame.height - frame.height / 8
        let top = classify(frame.rgb(x: x, y: topRow))
        let bottom = classify(frame.rgb(x: x, y: bottomRow))
        print("[orientation] top row \(topRow) = \(top?.rawValue ?? "?"), "
              + "bottom row \(bottomRow) = \(bottom?.rawValue ?? "?")")
        XCTAssertEqual(top, .topLeft, "the top of the render target must show the image's top-left")
        XCTAssertEqual(bottom, .bottomLeft, "…and the bottom its bottom-left")
    }
}
