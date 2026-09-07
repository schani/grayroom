import Metal
import XCTest
@testable import GrayroomCore

/// The colour style stage: the CPU curve, the OKLab chroma block, the band
/// table and the ten presets.
final class ColorStyleTests: XCTestCase {

    // Patch indices.
    private enum P {
        static let midGray = 0
        static let red = 1
        static let blue = 2
        static let darkGray = 3
        static let nearWhite = 4
        static let pureRed = 5
        static let lowSat = 6
        static let green = 7
    }

    private let patches: [(Float, Float, Float)] = [
        (0.18, 0.18, 0.18),   // mid gray
        (0.40, 0.02, 0.02),   // saturated red
        (0.02, 0.02, 0.40),   // saturated blue
        (0.02, 0.02, 0.02),   // dark gray
        (0.90, 0.90, 0.90),   // near white
        (0.40, 0.00, 0.00),   // fully saturated red (HSV sat = 1, hue 0)
        (0.30, 0.25, 0.25),   // barely tinted
        (0.02, 0.40, 0.02),   // saturated green
    ]

    private let grays = [P.midGray, P.darkGray, P.nearWhite]

    private func style(_ mutate: (inout ColorStyleParameters) -> Void) throws -> FloatImage {
        let (ctx, pipe) = try TestGPU.require()
        var p = ColorStyleParameters.identity
        mutate(&p)
        let input = try ctx.makePatchTexture(patches)
        return try TextureReadback.read(pipe.renderStyleOnly(input: input, parameters: p))
    }

    private func luminance(_ c: (Float, Float, Float)) -> Double {
        0.2126 * Double(c.0) + 0.7152 * Double(c.1) + 0.0722 * Double(c.2)
    }

    private func chroma(_ c: (Float, Float, Float)) -> Double {
        Double(max(c.0, max(c.1, c.2)) - min(c.0, min(c.1, c.2)))
    }

    /// OKLab lightness, which is what the chroma block's L is.
    private func lightness(_ c: (Float, Float, Float)) -> Double {
        ColorStyleChroma.linearToOKLab(SIMD3(Double(c.0), Double(c.1), Double(c.2))).x
    }

    // MARK: - The CPU curve

    private func curve(_ e: Double, _ contrast: Double, _ blacks: Double,
                       _ shoulder: Double) -> Double {
        ColorStyleCurve.apply(encoded: e, contrast: contrast, blacks: blacks, shoulder: shoulder)
    }

    func testZeroParametersAreTheIdentity() {
        for i in 0...64 {
            let e = Double(i) / 64
            XCTAssertEqual(curve(e, 0, 0, 0), e, accuracy: 1e-12, "at \(e)")
        }
    }

    /// Contrast is a slope, not a shape: it fixes black and mid grey and puts
    /// exactly `contrastReach^(contrast/100)` through the pivot.
    func testContrastSetsTheSlopeAtMidGrey() {
        let p = ColorStyleCurve.pivot
        let h = 1e-4
        for (c, slope) in [(100.0, ColorStyleCurve.contrastReach),
                           (-100.0, 1 / ColorStyleCurve.contrastReach)] {
            XCTAssertEqual(curve(0, c, 0, 0), 0, accuracy: 1e-12, "black moved at \(c)")
            XCTAssertEqual(curve(p, c, 0, 0), p, accuracy: 1e-12, "pivot moved at \(c)")
            let d = (curve(p + h, c, 0, 0) - curve(p - h, c, 0, 0)) / (2 * h)
            XCTAssertEqual(d, slope, accuracy: 1e-3, "slope at \(c)")
        }
    }

    /// Contrast pushes white past 1. Without a shoulder that is a hard clamp;
    /// with one it rolls off just under white.
    func testTheShoulderCatchesWhatContrastPushesPastWhite() {
        XCTAssertGreaterThan(ColorStyleCurve.pivot
            * pow(1 / ColorStyleCurve.pivot, ColorStyleCurve.contrastReach), 1)
        XCTAssertEqual(curve(1, 100, 0, 0), 1)
        let rolled = curve(1, 100, 0, 50)
        XCTAssertLessThan(rolled, 1)
        XCTAssertGreaterThan(rolled, 0.9)
    }

    func testBlacksLiftAndCrushTheToe() {
        XCTAssertEqual(curve(0, 100, 100, 0), ColorStyleCurve.blackLift, accuracy: 1e-9)
        XCTAssertEqual(curve(ColorStyleCurve.blackCrush, 0, -100, 0), 0, accuracy: 1e-9)
        XCTAssertEqual(curve(1, 0, -100, 0), 1, accuracy: 1e-9)
    }

    func testShoulderIsMonotoneContinuousAndCapsWhite() {
        var previous = -1.0
        for i in 0...256 {
            let v = curve(Double(i) / 256, 0, 0, 100)
            XCTAssertGreaterThan(v, previous, "not monotone at \(i)")
            previous = v
        }
        let k = 1 - ColorStyleCurve.shoulderReach
        XCTAssertEqual(curve(k - 1e-6, 0, 0, 100), curve(k + 1e-6, 0, 0, 100), accuracy: 1e-5)
        XCTAssertLessThan(curve(1, 0, 0, 100), 1)
    }

    /// Everything above SDR white is headroom and rides through additively.
    func testHeadroomPassesThroughAdditively() {
        let a = ColorStyleCurve.applyLinear(2.0, contrast: 60, blacks: 30, shoulder: 50)
        let b = ColorStyleCurve.applyLinear(1.0, contrast: 60, blacks: 30, shoulder: 50)
        XCTAssertEqual(a, b + 1, accuracy: 1e-12)
    }

    // MARK: - The kernel against the CPU mirrors

    func testGPUCurveMatchesTheCPUMirror() throws {
        let (ctx, pipe) = try TestGPU.require()
        let steps = 64
        let ramp = (0..<steps).map { Float(Double($0) / Double(steps - 1)) }
        let input = try ctx.makeTexture(width: steps, height: 2) { x, _ in
            (ramp[x], ramp[x], ramp[x])
        }
        var p = ColorStyleParameters.identity
        (p.contrast, p.blacks, p.shoulder) = (60, 30, 50)
        let out = try TextureReadback.read(pipe.renderStyleOnly(input: input, parameters: p))
        for x in 0..<steps {
            let expected = ColorStyleCurve.applyLinear(Double(ramp[x]), contrast: 60,
                                                       blacks: 30, shoulder: 50)
            let (r, g, b) = out.rgb(x: x, y: 0)
            XCTAssertEqual(Double(r), expected, accuracy: 2e-3, "step \(x)")
            XCTAssertEqual(Double(g), expected, accuracy: 2e-3, "step \(x)")
            XCTAssertEqual(Double(b), expected, accuracy: 2e-3, "step \(x)")
        }
    }

    func testGPUChromaMatchesTheCPUMirror() throws {
        let out = try style {
            $0.bandHue = Array(repeating: 20, count: 8)
            $0.bandSaturation = Array(repeating: 50, count: 8)
            $0.saturation = 30
            $0.vibrance = 40
            $0.density = 60
        }
        for idx in 0..<patches.count {
            let p = patches[idx]
            let source = SIMD3(Double(Float16(p.0)), Double(Float16(p.1)), Double(Float16(p.2)))
            let expected = ColorStyleChroma.apply(rgb: source, hueDegrees: 20, chromaScale: 1.5,
                                                  vibrance: 40, saturation: 30, density: 60)
            let (r, g, b) = out.rgb(x: idx, y: 0)
            XCTAssertEqual(Double(r), expected.x, accuracy: 3e-3, "patch \(idx) red")
            XCTAssertEqual(Double(g), expected.y, accuracy: 3e-3, "patch \(idx) green")
            XCTAssertEqual(Double(b), expected.z, accuracy: 3e-3, "patch \(idx) blue")
        }
    }

    // MARK: - The band table

    /// The hue rotation happens on OKLab's `ab`, so it turns the colour without
    /// touching its lightness.
    func testBandHueRotatesAtConstantLightness() throws {
        let base = try style { _ in }
        for (angle, warmer) in [(30.0, true), (-30.0, false)] {
            let out = try style { $0.bandHue[0] = angle }
            let c = out.rgb(x: P.pureRed, y: 0)
            if warmer {
                XCTAssertGreaterThan(c.1, c.2, "+30 should move red toward yellow")
            } else {
                XCTAssertGreaterThan(c.2, c.1, "−30 should move red toward magenta")
            }
            XCTAssertEqual(lightness(c), lightness(base.rgb(x: P.pureRed, y: 0)), accuracy: 2e-3)
            for idx in grays {
                XCTAssertEqual(lightness(out.rgb(x: idx, y: 0)),
                               lightness(base.rgb(x: idx, y: 0)), accuracy: 1e-3)
                XCTAssertLessThan(chroma(out.rgb(x: idx, y: 0)), 1e-3, "gray \(idx) took a tint")
            }
        }
    }

    func testBandSaturationActsOnItsBandOnly() throws {
        let base = try style { _ in }
        let out = try style { $0.bandSaturation[0] = -100 }
        XCTAssertLessThan(chroma(out.rgb(x: P.red, y: 0)), 1e-3, "the red band should be achromatic")
        for idx in grays + [P.blue] {
            let (r, g, b) = out.rgb(x: idx, y: 0)
            let (br, bg, bb) = base.rgb(x: idx, y: 0)
            XCTAssertEqual(Double(r), Double(br), accuracy: 1e-3, "patch \(idx)")
            XCTAssertEqual(Double(g), Double(bg), accuracy: 1e-3, "patch \(idx)")
            XCTAssertEqual(Double(b), Double(bb), accuracy: 1e-3, "patch \(idx)")
        }
    }

    func testBandLuminanceFollowsTheDocumentedGain() throws {
        let base = try style { _ in }
        let out = try style { $0.bandLuminance[0] = 100 }
        let expected = luminance(base.rgb(x: P.pureRed, y: 0))
            * ColorStyleCurve.bandLuminanceGain(amount: 100, saturation: 1)
        XCTAssertEqual(luminance(out.rgb(x: P.pureRed, y: 0)), expected,
                       accuracy: expected * 0.02)
        for idx in grays {
            XCTAssertEqual(luminance(out.rgb(x: idx, y: 0)),
                           luminance(base.rgb(x: idx, y: 0)), accuracy: 1e-3)
        }
    }

    // MARK: - Chroma

    func testGlobalSaturationAtMinusOneHundredIsAchromatic() throws {
        let out = try style { $0.saturation = -100 }
        for idx in 0..<patches.count {
            XCTAssertLessThan(chroma(out.rgb(x: idx, y: 0)), 1e-3, "patch \(idx)")
        }
    }

    /// Vibrance is weighted toward low chroma, so it grows a faint tint by more
    /// than it grows an already saturated colour.
    func testVibrancePullsTheUnsaturatedHarder() throws {
        let base = try style { _ in }
        let out = try style { $0.vibrance = 100 }
        func ratio(_ idx: Int) -> Double {
            chroma(out.rgb(x: idx, y: 0)) / max(chroma(base.rgb(x: idx, y: 0)), 1e-9)
        }
        XCTAssertGreaterThan(ratio(P.lowSat), ratio(P.red))
    }

    /// Density is what reads as "rich": it darkens saturated colour in
    /// proportion to its chroma and leaves neutrals exactly alone.
    func testDensityDarkensSaturatedColourOnly() throws {
        let base = try style { _ in }
        let full = try style { $0.density = 100 }
        XCTAssertLessThan(lightness(full.rgb(x: P.red, y: 0)),
                          lightness(base.rgb(x: P.red, y: 0)) * 0.9)
        for idx in grays {
            XCTAssertEqual(lightness(full.rgb(x: idx, y: 0)),
                           lightness(base.rgb(x: idx, y: 0)), accuracy: 1e-3, "gray \(idx)")
        }
        let none = try style { $0.density = 0 }
        XCTAssertEqual(lightness(none.rgb(x: P.red, y: 0)),
                       lightness(base.rgb(x: P.red, y: 0)), accuracy: 1e-6)
    }

    /// Out of gamut, chroma shrinks at fixed hue and lightness rather than one
    /// channel clipping — which would twist both.
    func testChromaShrinksIntoGamutInsteadOfClipping() throws {
        let out = try style { $0.saturation = 100 }
        let (r, g, b) = out.rgb(x: P.green, y: 0)
        XCTAssertGreaterThanOrEqual(r, 0)
        XCTAssertGreaterThanOrEqual(b, 0)
        XCTAssertGreaterThan(g, r)
        XCTAssertGreaterThan(g, b)
        for idx in 0..<patches.count {
            for v in [out.rgb(x: idx, y: 0).0, out.rgb(x: idx, y: 0).1, out.rgb(x: idx, y: 0).2] {
                XCTAssertGreaterThanOrEqual(v, 0, "patch \(idx) went negative")
            }
        }
    }

    // MARK: - The per-channel curve

    /// The shoulder is applied per channel, so a bright saturated colour walks
    /// toward white as it rolls off — the filmic path to white the
    /// ratio-preserving tone stage cannot produce.
    func testThePerChannelShoulderDesaturatesHighlights() throws {
        let (ctx, pipe) = try TestGPU.require()
        let input = try ctx.makePatchTexture([(1.0, 0.6, 0.2)], height: 2)
        func relativeChroma(shoulder: Double) throws -> Double {
            var p = ColorStyleParameters.identity
            p.shoulder = shoulder
            let out = try TextureReadback.read(
                pipe.renderStyleOnly(input: input, parameters: p))
            let c = out.rgb(x: 0, y: 0)
            return chroma(c) / Double(max(c.0, max(c.1, c.2)))
        }
        XCTAssertLessThan(try relativeChroma(shoulder: 100), try relativeChroma(shoulder: 0))
    }

    // MARK: - The presets

    func testEveryPresetIsInRangeAndNeutralIsTheIdentity() {
        XCTAssertEqual(ColorStyleParameters.identity,
                       ColorStyleParameters.parameters(for: .neutral))
        for style in EditState.ColorStyle.allCases {
            XCTAssertTrue(ColorStyleParameters.parameters(for: style).isWithinRanges,
                          "\(style.rawValue) is out of range")
            XCTAssertFalse(style.displayName.isEmpty)
        }
    }

    func testEveryPresetRendersFiniteNonNegativePixelsAndDiffersFromNeutral() throws {
        let (ctx, pipe) = try TestGPU.require()
        let input = try ctx.makePatchTexture(patches)
        func render(_ style: EditState.ColorStyle) throws -> FloatImage {
            var edit = EditState()
            edit.treatment = .color
            edit.style = style
            return try TextureReadback.read(
                pipe.render(input: input, edit: edit, upTo: .toning).texture)
        }
        let neutral = try render(.neutral)
        for style in EditState.ColorStyle.allCases where style != .neutral {
            let out = try render(style)
            for v in out.pixels {
                XCTAssertTrue(v.isFinite, "\(style.rawValue) produced \(v)")
                XCTAssertGreaterThanOrEqual(v, 0, "\(style.rawValue) produced \(v)")
            }
            XCTAssertNotEqual(out.pixels, neutral.pixels, "\(style.rawValue) rendered as neutral")
        }
        // The two presets with no split tone leave neutrals neutral.
        for style in [EditState.ColorStyle.chrome, .softCinema] {
            let out = try render(style)
            for idx in grays {
                XCTAssertLessThan(chroma(out.rgb(x: idx, y: 0)), 1e-3,
                                  "\(style.rawValue) tinted gray \(idx)")
            }
        }
    }
}
