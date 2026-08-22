import Metal
import XCTest
@testable import GrayroomCore

/// The GPU pieces the interactive preview adds on top of the export pipeline:
/// the draft downsample, the display mip pyramid and the two-slot mask cache
/// that keeps draft/refine alternation from re-rasterising every stamp.
final class PreviewPathTests: XCTestCase {

    // MARK: - Draft downsample

    /// A separable linear ramp survives a box reduction exactly: the mean of a
    /// box over a linear function is the function at the box's centre. So the
    /// reduced image must still be the same ramp, resampled — which is a much
    /// tighter statement than "roughly similar".
    func testDownsamplePreservesALinearGradient() throws {
        let (ctx, _) = try TestGPU.require()
        let d = try Downsampler(context: ctx)
        let w = 512, h = 256
        let source = try ctx.makeTexture(width: w, height: h) { x, y in
            (Float(x) / Float(w - 1), Float(y) / Float(h - 1), 0.25)
        }
        let reduced = try XCTUnwrap(try d.downsampled(source, longEdge: 128))
        XCTAssertEqual(reduced.width, 128)
        XCTAssertEqual(reduced.height, 64)

        let image = try TextureReadback.read(reduced)
        var worst = 0.0
        // Skip the outermost texel: clamp_to_edge truncates the box there, so
        // the edge sample is legitimately biased inward.
        for y in 1..<(image.height - 1) {
            for x in 1..<(image.width - 1) {
                let (r, g, b) = image.rgb(x: x, y: y)
                // Centre of destination texel x, in source pixel coordinates.
                let sx = (Double(x) + 0.5) * Double(w) / Double(image.width) - 0.5
                let sy = (Double(y) + 0.5) * Double(h) / Double(image.height) - 0.5
                worst = max(worst, abs(Double(r) - sx / Double(w - 1)))
                worst = max(worst, abs(Double(g) - sy / Double(h - 1)))
                worst = max(worst, abs(Double(b) - 0.25))
            }
        }
        XCTAssertLessThan(worst, 2e-3, "the reduced ramp drifted from the source ramp")
    }

    /// Rounding keeps the aspect ratio and never produces a zero edge.
    func testDownsampleTargetSize() {
        XCTAssertEqual(Downsampler.targetSize(width: 6000, height: 4000, longEdge: 2560)?.width,
                       2560)
        XCTAssertEqual(Downsampler.targetSize(width: 6000, height: 4000, longEdge: 2560)?.height,
                       1707)
        XCTAssertEqual(Downsampler.targetSize(width: 4000, height: 6000, longEdge: 2560)?.height,
                       2560)
        // A very wide panorama still keeps at least one row.
        XCTAssertEqual(Downsampler.targetSize(width: 40000, height: 5, longEdge: 2560)?.height, 1)
        // Already small enough: nothing to do.
        XCTAssertNil(Downsampler.targetSize(width: 2560, height: 1707, longEdge: 2560))
        XCTAssertNil(Downsampler.targetSize(width: 800, height: 600, longEdge: 2560))
    }

    func testDownsampleDeclinesWhenTheSourceAlreadyFits() throws {
        let (ctx, _) = try TestGPU.require()
        let d = try Downsampler(context: ctx)
        let source = try ctx.makeTexture(width: 100, height: 80) { _, _ in (0.5, 0.5, 0.5) }
        XCTAssertNil(try d.downsampled(source, longEdge: 2560))
    }

    /// A flat field must come out flat: any tap weighting mistake shows up here
    /// as a value that is not the constant.
    func testDownsampleOfAFlatFieldIsTheSameFlatField() throws {
        let (ctx, _) = try TestGPU.require()
        let d = try Downsampler(context: ctx)
        let source = try ctx.makeTexture(width: 600, height: 400) { _, _ in (0.2, 0.6, 0.9) }
        let reduced = try XCTUnwrap(try d.downsampled(source, longEdge: 150))
        let image = try TextureReadback.read(reduced)
        for y in stride(from: 0, to: image.height, by: 7) {
            for x in stride(from: 0, to: image.width, by: 7) {
                let (r, g, b) = image.rgb(x: x, y: y)
                XCTAssertEqual(Double(r), 0.2, accuracy: 1e-3)
                XCTAssertEqual(Double(g), 0.6, accuracy: 1e-3)
                XCTAssertEqual(Double(b), 0.9, accuracy: 1e-3)
            }
        }
    }

    // MARK: - Display mip pyramid

    /// `generateDisplayMipmaps` may change only the *availability* of the mip
    /// levels, never level 0 — the canvas and the exporter have to be looking at
    /// the same picture.
    func testDisplayMipmapsLeaveLevelZeroUntouched() throws {
        let (ctx, pipeline) = try TestGPU.require()
        let input = try ctx.makeTexture(width: 96, height: 64) { x, y in
            (Float(x) / 95, Float(y) / 63, 0.4)
        }
        var edit = EditState()
        edit.tone.exposure = 0.8
        edit.tone.contrast = 30
        edit.clarity = 40

        let flat = try pipeline.render(input: input, edit: edit)
        let mipped = try pipeline.render(input: input, edit: edit, generateDisplayMipmaps: true)

        XCTAssertEqual(flat.texture.mipmapLevelCount, 1)
        XCTAssertGreaterThan(mipped.texture.mipmapLevelCount, 1)

        let a = try TextureReadback.read(flat.texture).pixels
        let b = try TextureReadback.read(mipped.texture).pixels
        XCTAssertEqual(a, b, "the display pyramid changed the rendered image")
    }

    /// The pyramid must actually be filled, not merely allocated: an unfilled
    /// level reads back as zeroes and would show the canvas a black frame at
    /// fit zoom.
    func testDisplayMipmapsAreGenerated() throws {
        let (ctx, pipeline) = try TestGPU.require()
        // A constant linear input through a default edit is a constant output,
        // so every level must hold that same value.
        let input = try ctx.makeTexture(width: 128, height: 128) { _, _ in (0.25, 0.25, 0.25) }
        let result = try pipeline.render(input: input, edit: EditState(),
                                         generateDisplayMipmaps: true)
        let texture = result.texture
        XCTAssertEqual(texture.mipmapLevelCount, 8)   // 128 -> 1

        let expected = Double(try TextureReadback.read(texture).rgb(x: 0, y: 0).0)
        XCTAssertGreaterThan(expected, 0.4)           // sRGB-encoded 0.25

        for level in 1..<texture.mipmapLevelCount {
            let side = max(1, 128 >> level)
            var pixels = [Float16](repeating: 0, count: side * side * 4)
            pixels.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!,
                                 bytesPerRow: side * 4 * MemoryLayout<Float16>.size,
                                 from: MTLRegionMake2D(0, 0, side, side),
                                 mipmapLevel: level)
            }
            XCTAssertEqual(Double(pixels[0]), expected, accuracy: 2e-3,
                           "mip level \(level) is not the image")
        }
    }

    /// The export path is the default, and stays flat.
    func testFileRendersHaveNoPyramid() throws {
        let (ctx, pipeline) = try TestGPU.require()
        let input = try ctx.makeTexture(width: 64, height: 64) { _, _ in (0.5, 0.5, 0.5) }
        XCTAssertEqual(try pipeline.render(input: input, edit: EditState())
                        .texture.mipmapLevelCount, 1)
    }

    // MARK: - Mask cache

    /// Draft and refine alternate between two resolutions with the *same*
    /// strokes. Both must stay cached, or every frame of a brush drag would
    /// re-rasterise every stamp at both sizes.
    func testTheMaskCacheHoldsBothPreviewResolutions() throws {
        let (ctx, _) = try TestGPU.require()
        // A private pipeline: the shared one carries whatever earlier tests left.
        let pipeline = try Pipeline(context: ctx)
        var mask = Mask(name: "m")
        mask.adjustments.exposure = 0.5
        mask.strokes = [Stroke(brush: BrushParams(size: 0.2),
                               polyline: [(0.3, 0.3), (0.7, 0.7)])]
        var edit = EditState()
        edit.masks = [mask]

        let draft = try ctx.makeTexture(width: 64, height: 48) { _, _ in (0.4, 0.4, 0.4) }
        let full = try ctx.makeTexture(width: 256, height: 192) { _, _ in (0.4, 0.4, 0.4) }

        _ = try pipeline.render(input: draft, edit: edit)
        _ = try pipeline.render(input: full, edit: edit)
        XCTAssertEqual(pipeline.maskCacheResolutions.count, 2)

        // Alternate a few times; both entries must survive every round.
        for _ in 0..<3 {
            _ = try pipeline.render(input: draft, edit: edit)
            _ = try pipeline.render(input: full, edit: edit)
            let sizes = Set(pipeline.maskCacheResolutions.map { "\($0.width)x\($0.height)" })
            XCTAssertEqual(sizes, ["64x48", "256x192"])
        }
    }

    /// At full resolution an entry is ~240 MB, so opening a different image has
    /// to be able to drop them.
    func testTheMaskCacheCanBeCleared() throws {
        let (ctx, _) = try TestGPU.require()
        let pipeline = try Pipeline(context: ctx)
        var mask = Mask(name: "m")
        mask.adjustments.exposure = 0.5
        mask.strokes = [Stroke(brush: BrushParams(size: 0.3), polyline: [(0.5, 0.5)])]
        var edit = EditState()
        edit.masks = [mask]

        let input = try ctx.makeTexture(width: 48, height: 32) { _, _ in (0.4, 0.4, 0.4) }
        _ = try pipeline.render(input: input, edit: edit)
        XCTAssertFalse(pipeline.maskCacheResolutions.isEmpty)

        pipeline.clearMaskCache()
        XCTAssertTrue(pipeline.maskCacheResolutions.isEmpty)

        // And the next render still comes out right, from a cold cache.
        _ = try pipeline.render(input: input, edit: edit)
        XCTAssertEqual(pipeline.maskCacheResolutions.count, 1)
    }

    /// Two is the capacity: a third resolution evicts the least recently used
    /// one, not an arbitrary one.
    func testTheMaskCacheEvictsTheLeastRecentlyUsedResolution() throws {
        let (ctx, _) = try TestGPU.require()
        let pipeline = try Pipeline(context: ctx)
        var mask = Mask(name: "m")
        mask.adjustments.exposure = 0.5
        mask.strokes = [Stroke(brush: BrushParams(size: 0.3), polyline: [(0.5, 0.5)])]
        var edit = EditState()
        edit.masks = [mask]

        let a = try ctx.makeTexture(width: 32, height: 32) { _, _ in (0.4, 0.4, 0.4) }
        let b = try ctx.makeTexture(width: 64, height: 64) { _, _ in (0.4, 0.4, 0.4) }
        let c = try ctx.makeTexture(width: 96, height: 96) { _, _ in (0.4, 0.4, 0.4) }

        _ = try pipeline.render(input: a, edit: edit)
        _ = try pipeline.render(input: b, edit: edit)
        _ = try pipeline.render(input: a, edit: edit)     // a is now the newest
        _ = try pipeline.render(input: c, edit: edit)     // evicts b

        let sizes = Set(pipeline.maskCacheResolutions.map { $0.width })
        XCTAssertEqual(sizes, [32, 96])
    }
}
