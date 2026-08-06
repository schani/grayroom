import Metal
import XCTest
@testable import GrayroomCore

final class GPUStageTests: XCTestCase {

    // Patch indices used by most tests.
    private enum P {
        static let midGray = 0
        static let red = 1
        static let blue = 2
        static let darkGray = 3
        static let nearWhite = 4
    }

    private let patches: [(Float, Float, Float)] = [
        (0.18, 0.18, 0.18),   // mid gray
        (0.40, 0.02, 0.02),   // saturated red
        (0.02, 0.02, 0.40),   // saturated blue
        (0.02, 0.02, 0.02),   // dark gray
        (0.90, 0.90, 0.90),   // near white
    ]

    private func run(_ edit: EditState, upTo: Pipeline.Stage) throws -> FloatImage {
        let (ctx, pipe) = try TestGPU.require()
        let input = try ctx.makePatchTexture(patches)
        let result = try pipe.render(input: input, edit: edit, upTo: upTo)
        return try TextureReadback.read(result.texture)
    }

    // MARK: - Tone

    func testExposurePlusOneEVDoublesLinearValues() throws {
        var edit = EditState()
        edit.tone.exposure = 1
        let out = try run(edit, upTo: .tone)
        for idx in [P.midGray, P.red, P.blue, P.darkGray] {
            let (r, g, b) = out.rgb(x: idx, y: 0)
            let src = patches[idx]
            XCTAssertEqual(Double(r), Double(src.0) * 2, accuracy: Double(src.0) * 0.02 + 1e-4)
            XCTAssertEqual(Double(g), Double(src.1) * 2, accuracy: Double(src.1) * 0.02 + 1e-4)
            XCTAssertEqual(Double(b), Double(src.2) * 2, accuracy: Double(src.2) * 0.02 + 1e-4)
        }
    }

    func testToneIdentityAtDefaults() throws {
        let out = try run(EditState(), upTo: .tone)
        for idx in 0..<patches.count {
            let (r, g, b) = out.rgb(x: idx, y: 0)
            XCTAssertEqual(Double(r), Double(patches[idx].0), accuracy: 0.003)
            XCTAssertEqual(Double(g), Double(patches[idx].1), accuracy: 0.003)
            XCTAssertEqual(Double(b), Double(patches[idx].2), accuracy: 0.003)
        }
    }

    func testTonePreservesRatiosNoHueShift() throws {
        var edit = EditState()
        edit.tone = .init(exposure: 0.5, contrast: 60, highlights: -40, shadows: 40,
                          whites: 20, blacks: -20)
        let out = try run(edit, upTo: .tone)
        for idx in [P.red, P.blue] {
            let (r, g, b) = out.rgb(x: idx, y: 0)
            let src = patches[idx]
            let srcMax = max(src.0, max(src.1, src.2))
            let outMax = max(r, max(g, b))
            XCTAssertGreaterThan(outMax, 0)
            // Channel ratios must be preserved by a ratio-preserving remap.
            XCTAssertEqual(Double(r / outMax), Double(src.0 / srcMax), accuracy: 0.02)
            XCTAssertEqual(Double(g / outMax), Double(src.1 / srcMax), accuracy: 0.02)
            XCTAssertEqual(Double(b / outMax), Double(src.2 / srcMax), accuracy: 0.02)
        }
    }

    func testToneGPUMatchesCPUCurve() throws {
        var edit = EditState()
        edit.tone = .init(exposure: 0.3, contrast: 25, highlights: -40, shadows: 20,
                          whites: 10, blacks: -15)
        let out = try run(edit, upTo: .tone)
        for idx in 0..<patches.count {
            let src = patches[idx]
            let y = 0.2126 * Double(src.0) + 0.7152 * Double(src.1) + 0.0722 * Double(src.2)
            let expected = ToneCurve.evaluateLinear(y, edit.tone)
            let (r, g, b) = out.rgb(x: idx, y: 0)
            let got = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
            XCTAssertEqual(got, expected, accuracy: max(expected * 0.02, 1e-4),
                           "patch \(idx)")
        }
    }

    // MARK: - B&W mix

    func testBWMixOutputIsAchromatic() throws {
        var edit = EditState()
        edit.bwMix = .init(red: 40, orange: -20, yellow: 60, green: -80,
                           aqua: 10, blue: -60, purple: 25, magenta: -5)
        let out = try run(edit, upTo: .bwMix)
        for idx in 0..<patches.count {
            let (r, g, b) = out.rgb(x: idx, y: 0)
            XCTAssertEqual(r, g, "patch \(idx) not achromatic")
            XCTAssertEqual(g, b, "patch \(idx) not achromatic")
        }
    }

    func testRedSliderDarkensRedPatch() throws {
        let neutral = try run(EditState(), upTo: .bwMix)
        var edit = EditState()
        edit.bwMix.red = -100
        let darkened = try run(edit, upTo: .bwMix)

        let base = Double(neutral.rgb(x: P.red, y: 0).0)
        let dark = Double(darkened.rgb(x: P.red, y: 0).0)
        XCTAssertGreaterThan(base, 0.05)
        XCTAssertLessThan(dark, base * 0.6, "red slider -100 should clearly darken a red patch")

        // ... and brightens it in the other direction.
        edit.bwMix.red = 100
        let brightened = try run(edit, upTo: .bwMix)
        XCTAssertGreaterThan(Double(brightened.rgb(x: P.red, y: 0).0), base * 1.4)
    }

    func testBlueSliderTargetsBlueNotRed() throws {
        let neutral = try run(EditState(), upTo: .bwMix)
        var edit = EditState()
        edit.bwMix.blue = -100
        let out = try run(edit, upTo: .bwMix)

        XCTAssertLessThan(Double(out.rgb(x: P.blue, y: 0).0),
                          Double(neutral.rgb(x: P.blue, y: 0).0) * 0.6)
        // The red patch is on the far side of the hue circle and must not move.
        XCTAssertEqual(Double(out.rgb(x: P.red, y: 0).0),
                       Double(neutral.rgb(x: P.red, y: 0).0),
                       accuracy: Double(neutral.rgb(x: P.red, y: 0).0) * 0.02)
    }

    func testNeutralPatchInvariantForAnySlider() throws {
        var rng = SeededRandom(seed: 0xBEEF)
        let reference = try run(EditState(), upTo: .bwMix)
        for _ in 0..<12 {
            var edit = EditState()
            edit.bwMix = .init(red: rng.double(in: -100...100),
                               orange: rng.double(in: -100...100),
                               yellow: rng.double(in: -100...100),
                               green: rng.double(in: -100...100),
                               aqua: rng.double(in: -100...100),
                               blue: rng.double(in: -100...100),
                               purple: rng.double(in: -100...100),
                               magenta: rng.double(in: -100...100))
            let out = try run(edit, upTo: .bwMix)
            for idx in [P.midGray, P.darkGray, P.nearWhite] {
                XCTAssertEqual(Double(out.rgb(x: idx, y: 0).0),
                               Double(reference.rgb(x: idx, y: 0).0),
                               accuracy: 1e-3,
                               "neutral patch \(idx) moved with mix \(edit.bwMix)")
            }
        }
    }

    func testBWMixDisabledPassesColourThrough() throws {
        var edit = EditState()
        edit.bwMix.enabled = false
        let out = try run(edit, upTo: .toning)
        let (r, _, b) = out.rgb(x: P.red, y: 0)
        XCTAssertGreaterThan(r, b * 4, "colour should survive when the mix is disabled")
    }

    // MARK: - Toning

    func testShadowToningWarmsShadowsAndLeavesHighlightsNeutral() throws {
        var edit = EditState()
        edit.toning = .init(shadowHue: 30, shadowSaturation: 50)
        let out = try run(edit, upTo: .toning)
        let before = try run(EditState(), upTo: .toning)

        let (dr, _, db) = out.rgb(x: P.darkGray, y: 0)
        XCTAssertGreaterThan(Double(dr), Double(db) * 1.2, "shadows should warm toward hue 30")

        let (wr, wg, wb) = out.rgb(x: P.nearWhite, y: 0)
        XCTAssertEqual(Double(wr), Double(wb), accuracy: 0.01, "near-white must stay neutral")
        XCTAssertEqual(Double(wg), Double(wb), accuracy: 0.01)

        // Luminance is (approximately) invariant: the tint is chroma only.
        for idx in 0..<patches.count {
            let (r0, g0, b0) = before.rgb(x: idx, y: 0)
            let (r1, g1, b1) = out.rgb(x: idx, y: 0)
            let y0 = 0.2126 * Double(r0) + 0.7152 * Double(g0) + 0.0722 * Double(b0)
            let y1 = 0.2126 * Double(r1) + 0.7152 * Double(g1) + 0.0722 * Double(b1)
            XCTAssertEqual(y1, y0, accuracy: max(y0 * 0.03, 1e-3), "luminance moved on patch \(idx)")
        }
    }

    func testHighlightToningCoolsHighlightsAndLeavesShadowsNeutral() throws {
        var edit = EditState()
        edit.toning = .init(highlightHue: 220, highlightSaturation: 60)
        let out = try run(edit, upTo: .toning)

        let (hr, _, hb) = out.rgb(x: P.nearWhite, y: 0)
        XCTAssertGreaterThan(Double(hb), Double(hr) * 1.1, "highlights should cool toward hue 220")

        let (dr, dg, db) = out.rgb(x: P.darkGray, y: 0)
        XCTAssertEqual(Double(dr), Double(db), accuracy: 1e-3)
        XCTAssertEqual(Double(dg), Double(db), accuracy: 1e-3)
    }

    func testToningBalanceShiftsCrossover() throws {
        var warmShadows = EditState()
        warmShadows.toning = .init(shadowHue: 30, shadowSaturation: 80, balance: 0)
        let mid = try run(warmShadows, upTo: .toning)

        warmShadows.toning.balance = 100   // favour highlights -> shadows zone shrinks
        let shifted = try run(warmShadows, upTo: .toning)

        func warmth(_ img: FloatImage, _ idx: Int) -> Double {
            let (r, _, b) = img.rgb(x: idx, y: 0)
            return Double(r) / max(Double(b), 1e-6)
        }
        XCTAssertLessThan(warmth(shifted, P.midGray), warmth(mid, P.midGray))
    }

    func testToningIdentityWhenSaturationsAreZero() throws {
        var edit = EditState()
        edit.toning = .init(shadowHue: 30, shadowSaturation: 0,
                            highlightHue: 200, highlightSaturation: 0, balance: 50)
        let out = try run(edit, upTo: .toning)
        let ref = try run(EditState(), upTo: .toning)
        for idx in 0..<patches.count {
            XCTAssertEqual(Double(out.rgb(x: idx, y: 0).0),
                           Double(ref.rgb(x: idx, y: 0).0), accuracy: 1e-4)
        }
    }

    // MARK: - Output transform

    func testOutputTransformMatchesCPUReference() throws {
        var edit = EditState()
        edit.bwMix.enabled = false          // keep colour so all channels are exercised
        let out = try run(edit, upTo: .output)
        for idx in 0..<patches.count {
            let (r, g, b) = out.rgb(x: idx, y: 0)
            XCTAssertEqual(Double(r), sRGBEncodeReference(Double(patches[idx].0)), accuracy: 0.002)
            XCTAssertEqual(Double(g), sRGBEncodeReference(Double(patches[idx].1)), accuracy: 0.002)
            XCTAssertEqual(Double(b), sRGBEncodeReference(Double(patches[idx].2)), accuracy: 0.002)
        }
    }

    func testOutputClampsOutOfRangeValues() throws {
        let (ctx, pipe) = try TestGPU.require()
        let input = try ctx.makePatchTexture([(-0.5, -0.5, -0.5), (8, 8, 8)])
        var edit = EditState()
        edit.bwMix.enabled = false
        let result = try pipe.render(input: input, edit: edit, upTo: .output)
        let out = try TextureReadback.read(result.texture)
        XCTAssertEqual(Double(out.rgb(x: 0, y: 0).0), 0, accuracy: 1e-4)
        XCTAssertEqual(Double(out.rgb(x: 1, y: 0).0), 1, accuracy: 1e-3)
    }

    // MARK: - Histogram

    func testHistogramCountsAndClipping() throws {
        let (ctx, pipe) = try TestGPU.require()
        // 4 columns x 4 rows: black, mid, white, white
        let input = try ctx.makePatchTexture([(0, 0, 0), (0.18, 0.18, 0.18), (2, 2, 2), (2, 2, 2)],
                                             height: 4)
        var edit = EditState()
        edit.bwMix.enabled = false
        let result = try pipe.render(input: input, edit: edit, upTo: .output, computeHistogram: true)
        let h = try XCTUnwrap(result.histogram)

        XCTAssertEqual(h.pixelCount, 16)
        XCTAssertEqual(h.bins.reduce(0, +), 16)
        XCTAssertEqual(h.shadowClippedPixels, 4)
        XCTAssertEqual(h.highlightClippedPixels, 8)
        XCTAssertEqual(h.bins[0], 4)
        XCTAssertEqual(h.bins[255], 8)
        // 0.18 linear -> ~0.4626 sRGB -> bin 118
        XCTAssertEqual(h.bins[118] + h.bins[117] + h.bins[119], 4)

        XCTAssertFalse(h.asciiPlot(rows: 8).isEmpty)
        XCTAssertTrue(h.summary.contains("pixels=16"))
    }

    // MARK: - Constants shared with the GUI

    /// `BWMixBands.centers` is what the GUI's targeted-adjustment tool does its
    /// band arithmetic with; if it ever drifts from `kBandCenters` in the shader
    /// the tool would move the wrong slider. Compare against the shader text
    /// itself rather than a second hand-written copy.
    func testBandCentresMatchTheShader() throws {
        let source = try MetalContext.combinedShaderSource()
        let line = try XCTUnwrap(source
            .split(separator: "\n")
            .first { $0.contains("kBandCenters") && $0.contains("{") })
        let numbers = line
            .replacingOccurrences(of: "f", with: "")
            .split(whereSeparator: { !"0123456789.".contains($0) })
            .compactMap { Double($0) }
        // The declaration also carries the array length (8).
        XCTAssertEqual(numbers, [8] + BWMixBands.centers, "shader line: \(line)")
    }

    /// The GUI reads back a neighbourhood of a linear intermediate to find the
    /// hue under the cursor; the region must line up with the full readback.
    func testReadRegionMatchesTheFullReadback() throws {
        let (ctx, _) = try TestGPU.require()
        let texture = try ctx.makeTexture(width: 8, height: 6) { x, y in
            (Float(x) / 8, Float(y) / 6, 0.25)
        }
        let full = try TextureReadback.read(texture)
        let region = try TextureReadback.readRegion(texture, x: 3, y: 2, width: 3, height: 3)
        XCTAssertEqual(region.width, 3)
        XCTAssertEqual(region.height, 3)
        for j in 0..<3 {
            for i in 0..<3 {
                let a = region.rgb(x: i, y: j)
                let b = full.rgb(x: 3 + i, y: 2 + j)
                XCTAssertEqual(a.0, b.0, accuracy: 1e-6)
                XCTAssertEqual(a.1, b.1, accuracy: 1e-6)
            }
        }
        // Clipped at the edges rather than trapping.
        let clipped = try TextureReadback.readRegion(texture, x: 7, y: 5, width: 4, height: 4)
        XCTAssertEqual(clipped.width, 1)
        XCTAssertEqual(clipped.height, 1)
        let negative = try TextureReadback.readRegion(texture, x: -5, y: -5, width: 2, height: 2)
        XCTAssertEqual(negative.width, 2)
    }

    /// The mask overlay on the canvas draws this texture directly.
    func testMaskCoverageTextureMatchesTheCPUReadbackPath() throws {
        let (_, pipe) = try TestGPU.require()
        let mask = Mask(name: "m",
                        adjustments: MaskAdjustments(exposure: 1),
                        strokes: [Stroke(brush: BrushParams(size: 0.4, feather: 50),
                                         polyline: [(0.2, 0.5), (0.8, 0.5)])])
        let w = 64, h = 48
        let texture = try pipe.maskCoverageTexture(masks: [mask], width: w, height: h, maskIndex: 0)
        XCTAssertEqual(texture.width, w)
        XCTAssertEqual(texture.height, h)
        let fromTexture = try TextureReadback.readScalar(texture)
        let fromCPU = try pipe.maskCoverage(masks: [mask], width: w, height: h, maskIndex: 0)
        XCTAssertEqual(fromTexture, fromCPU)
        XCTAssertGreaterThan(fromTexture.max() ?? 0, 0.9)

        // A disabled mask still shows its coverage when selected explicitly:
        // the overlay must show what you are painting.
        var disabled = mask
        disabled.enabled = false
        let selected = try pipe.maskCoverage(masks: [disabled], width: w, height: h, maskIndex: 0)
        XCTAssertGreaterThan(selected.max() ?? 0, 0.9)
        // ... but the "all enabled masks" union skips it.
        let union = try pipe.maskCoverage(masks: [disabled], width: w, height: h, maskIndex: nil)
        XCTAssertEqual(union.max() ?? 0, 0, accuracy: 1e-6)
    }
}
