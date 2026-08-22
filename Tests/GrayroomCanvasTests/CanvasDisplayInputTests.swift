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
        /// r, g, b as unorm bytes in the marker texture.
        var rgb: (UInt8, UInt8, UInt8) {
            switch self {
            case .topLeft: return (255, 0, 0)        // red
            case .topRight: return (0, 255, 0)       // green
            case .bottomLeft: return (0, 0, 255)     // blue
            case .bottomRight: return (255, 255, 0)  // yellow
            }
        }

        /// What the drawable must hold for it. The canvas passes display-linear
        /// values through unencoded, and 0 and 1 are the same number in any
        /// transfer function, so the marker colours arrive unchanged.
        var linear: (Double, Double, Double) {
            let (r, g, b) = rgb
            return (Double(r) / 255, Double(g) / 255, Double(b) / 255)
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

    /// The drawable is `rgba16Float` holding **display-linear** values, so a
    /// frame is read back as half floats, not as unorm bytes.
    private struct Frame {
        var rgba: [Float16]
        var width: Int
        var height: Int
        func rgb(x: Int, y: Int) -> (Double, Double, Double) {
            let i = (y * width + x) * 4
            return (Double(rgba[i]), Double(rgba[i + 1]), Double(rgba[i + 2]))
        }
    }

    private func render() throws -> Frame {
        let size = h.canvas.transform.viewSize
        let w = Int(size.width.rounded()), hgt = Int(size.height.rounded())
        XCTAssertEqual(h.canvas.colorPixelFormat, .rgba16Float)
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

        var pixels = [Float16](repeating: 0, count: w * hgt * 4)
        pixels.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!,
                            bytesPerRow: w * 4 * MemoryLayout<Float16>.size,
                            from: MTLRegionMake2D(0, 0, w, hgt), mipmapLevel: 0)
        }
        return Frame(rgba: pixels, width: w, height: hgt)
    }

    private func classify(_ rgb: (Double, Double, Double)) -> Quadrant? {
        for q in Quadrant.allCases {
            let (r, g, b) = q.linear
            if abs(rgb.0 - r) < 0.16, abs(rgb.1 - g) < 0.16, abs(rgb.2 - b) < 0.16 {
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

    /// The EDR drawable: half-float, extended **linear** sRGB, extended-range
    /// content declared.
    ///
    /// All three have to hold together. Half-float carries linear values above
    /// 1.0 that an 8-bit unorm cannot; the extended-linear colourspace is what
    /// hands the transfer function to the window server, which is also what
    /// keeps the frame colour-matched to the display profile (wave 3, audit
    /// `decode-output` #9 — untagged, encoded values were interpreted in the
    /// display's own space and toned images came out more saturated than the
    /// exported file); and without the EDR opt-in the layer is an ordinary SDR
    /// surface that happens to be float, so the headroom is clamped away.
    func testDrawableIsEDRLinear() throws {
        let layer = try XCTUnwrap(h.canvas.layer as? CAMetalLayer)
        let space = try XCTUnwrap(layer.colorspace)
        XCTAssertEqual(space.name, CGColorSpace.extendedLinearSRGB)
        XCTAssertEqual(h.canvas.colorPixelFormat, .rgba16Float)
        XCTAssertTrue(layer.wantsExtendedDynamicRangeContent)
    }

    /// The canvas encodes nothing: whatever display-linear value the pipeline
    /// wrote is what reaches the drawable, bit for bit where the filter taps
    /// agree. That is the whole contract of the linear output mode — an sRGB
    /// encode left in the shader would show up here as 0 → 0 but 1 → 1 with
    /// everything in between lifted, and the backdrop off by a factor of three.
    func testTheCanvasPassesLinearValuesThroughUnchanged() throws {
        let frame = try render()
        let t = h.canvas.transform
        var checked = 0, wrong = 0
        for py in stride(from: 5, to: frame.height, by: 11) {
            for px in stride(from: 5, to: frame.width, by: 11) {
                let view = CGPoint(x: CGFloat(px) + 0.5, y: CGFloat(py) + 0.5)
                guard let q = quadrant(ofImagePoint: t.imagePoint(fromView: view)) else { continue }
                checked += 1
                let (r, g, b) = frame.rgb(x: px, y: py)
                let want = q.linear
                if abs(r - want.0) > 1e-3 || abs(g - want.1) > 1e-3 || abs(b - want.2) > 1e-3 {
                    wrong += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 100)
        XCTAssertEqual(wrong, 0, "\(wrong)/\(checked) image pixels were not passed through")
    }

    /// The letterbox is authored in sRGB and must be *decoded*, or it would be
    /// drawn about three times too bright on the linear drawable. The shader's
    /// constant and the clear colour both come from `CanvasColors`, so this pins
    /// the decode itself.
    func testTheLetterboxBackdropIsSRGBDecoded() throws {
        let expected = CanvasColors.backdropLinear
        XCTAssertEqual(expected.0, 0.00845, accuracy: 1e-4)    // sRGB 0.09
        XCTAssertEqual(expected.2, 0.01002, accuracy: 1e-4)    // sRGB 0.10
        XCTAssertEqual(CanvasColors.srgbToLinear(0), 0, accuracy: 1e-12)
        XCTAssertEqual(CanvasColors.srgbToLinear(1), 1, accuracy: 1e-12)

        // The portrait image is letterboxed left and right at fit zoom, so the
        // far-left column of the canvas is pure backdrop.
        let frame = try render()
        let t = h.canvas.transform
        let view = CGPoint(x: 2.5, y: CGFloat(frame.height / 2) + 0.5)
        XCTAssertNil(quadrant(ofImagePoint: t.imagePoint(fromView: view)),
                     "precondition: that column must be outside the image")
        let (r, g, b) = frame.rgb(x: 2, y: frame.height / 2)
        XCTAssertEqual(r, expected.0, accuracy: 2e-4)
        XCTAssertEqual(g, expected.1, accuracy: 2e-4)
        XCTAssertEqual(b, expected.2, accuracy: 2e-4)
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
