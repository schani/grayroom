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
        static let pureRed = 5
        static let pureMagenta = 6
    }

    private let patches: [(Float, Float, Float)] = [
        (0.18, 0.18, 0.18),   // mid gray
        (0.40, 0.02, 0.02),   // saturated red
        (0.02, 0.02, 0.40),   // saturated blue
        (0.02, 0.02, 0.02),   // dark gray
        (0.90, 0.90, 0.90),   // near white
        (0.40, 0.00, 0.00),   // fully saturated red (HSV sat = 1, hue 0)
        (0.40, 0.00, 0.40),   // fully saturated magenta (hue 300)
    ]

    private func run(_ edit: EditState, upTo: Pipeline.Stage) throws -> FloatImage {
        let (ctx, pipe) = try TestGPU.require()
        let input = try ctx.makePatchTexture(patches)
        let result = try pipe.render(input: input, edit: edit, upTo: upTo)
        return try TextureReadback.read(result.texture)
    }

    // MARK: - Tone

    /// Exposure is still a pure EV shift, but it now sits on top of the baseline
    /// rendition and below the always-on shoulder — so "+1 EV doubles" is a
    /// statement about the *rendered* value, and only below the shoulder knee.
    /// The red / blue / dark patches render below the knee; mid gray and near
    /// white do not (they are covered by `testToneGPUMatchesCPUCurve`).
    func testExposurePlusOneEVDoublesLinearValues() throws {
        let base = try run(EditState(), upTo: .tone)
        var edit = EditState()
        edit.tone.exposure = 1
        let out = try run(edit, upTo: .tone)
        for idx in [P.red, P.blue, P.darkGray] {
            let (r, g, b) = out.rgb(x: idx, y: 0)
            let (br, bg, bb) = base.rgb(x: idx, y: 0)
            XCTAssertEqual(Double(r), Double(br) * 2, accuracy: Double(br) * 0.02 + 1e-4)
            XCTAssertEqual(Double(g), Double(bg) * 2, accuracy: Double(bg) * 0.02 + 1e-4)
            XCTAssertEqual(Double(b), Double(bb) * 2, accuracy: Double(bb) * 0.02 + 1e-4)
        }
    }

    /// All sliders at zero is the **baseline rendition**, not the identity: the
    /// pipeline now starts from a Lightroom-like default instead of scene-linear
    /// (research/audit/decode-output.json deviation #0).
    func testToneAtDefaultsIsTheBaselineRendition() throws {
        let out = try run(EditState(), upTo: .tone)
        let zero = EditState.Tone()
        for idx in 0..<patches.count {
            let src = patches[idx]
            let y = 0.2126 * Double(src.0) + 0.7152 * Double(src.1) + 0.0722 * Double(src.2)
            let gain = ToneCurve.evaluateLinear(y, zero) / y
            let (r, g, b) = out.rgb(x: idx, y: 0)
            XCTAssertEqual(Double(r), Double(src.0) * gain, accuracy: 0.004, "patch \(idx)")
            XCTAssertEqual(Double(g), Double(src.1) * gain, accuracy: 0.004, "patch \(idx)")
            XCTAssertEqual(Double(b), Double(src.2) * gain, accuracy: 0.004, "patch \(idx)")
            // ... and it really is a rendition: mid gray comes out much brighter.
            if idx == P.midGray { XCTAssertGreaterThan(gain, 1.5) }
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

    /// Wave 2 authority (audit `bwmix-toning.json` #0): a *fully* saturated
    /// colour at −100 on its own band goes to 1/8 of its untouched luminance —
    /// three stops, symmetric with ×8 at +100. That is the "red filter" reach
    /// Lightroom's mixer has and the old linear law (×0.2 … ×1.8) did not.
    func testFullySaturatedColourAtMinus100ReachesNearBlack() throws {
        let neutral = try run(EditState(), upTo: .bwMix)
        var edit = EditState()
        edit.bwMix.red = -100
        let dark = try run(edit, upTo: .bwMix)

        let base = Double(neutral.rgb(x: P.pureRed, y: 0).0)
        XCTAssertGreaterThan(base, 0.05, "the reference patch must not already be black")
        let ratio = Double(dark.rgb(x: P.pureRed, y: 0).0) / base
        XCTAssertEqual(ratio, 1.0 / 8, accuracy: 0.002,
                       "sat = 1 at −100 must land on exactly 2^−maxEV")

        edit.bwMix.red = 100
        let bright = try run(edit, upTo: .bwMix)
        XCTAssertEqual(Double(bright.rgb(x: P.pureRed, y: 0).0) / base, 8, accuracy: 0.05,
                       "and be symmetric in stops in the other direction")
    }

    /// The GPU gain must equal the law `BWMixBands.gain` publishes, because the
    /// GUI reasons about the mixer through that mirror.
    func testMixerGainMatchesTheDocumentedLaw() throws {
        let neutral = try run(EditState(), upTo: .bwMix)
        // Encoded HSV saturation of each patch, computed the way the kernel does.
        func encodedSat(_ p: (Float, Float, Float)) -> Double {
            let e = [p.0, p.1, p.2].map { pow(Double(max($0, 0)), 1 / 2.2) }
            let mx = e.max()!, mn = e.min()!
            return mx > 1e-6 ? (mx - mn) / mx : 0
        }
        for slider in [-100.0, -55.0, 25.0, 100.0] {
            var edit = EditState()
            edit.bwMix.red = slider          // hue 0 -> the red band alone
            let out = try run(edit, upTo: .bwMix)
            for idx in [P.red, P.pureRed, P.midGray] {
                let expected = BWMixBands.gain(mixAmount: slider,
                                               saturation: encodedSat(patches[idx]))
                let got = Double(out.rgb(x: idx, y: 0).0) / Double(neutral.rgb(x: idx, y: 0).0)
                XCTAssertEqual(got, expected, accuracy: expected * 0.01,
                               "patch \(idx) at slider \(slider)")
            }
        }
    }

    /// The saturation weight is what keeps neutrals invariant and keeps the
    /// mixer from banding. Pure Swift; the GPU side is pinned above.
    func testSaturationWeightShape() {
        XCTAssertEqual(BWMixBands.saturationWeight(0), 0, accuracy: 1e-15)
        XCTAssertEqual(BWMixBands.saturationWeight(1), 1, accuracy: 1e-12)
        XCTAssertEqual(BWMixBands.gain(mixAmount: 0, saturation: 1), 1, accuracy: 1e-12)
        XCTAssertEqual(BWMixBands.gain(mixAmount: -100, saturation: 1), 0.125, accuracy: 1e-12)
        XCTAssertEqual(BWMixBands.gain(mixAmount: 100, saturation: 1), 8, accuracy: 1e-12)
        // Monotone, and always above the linear weight it replaced — that is the
        // whole point: a real subject at saturation 0.5 gets 0.66 of the
        // authority, not 0.5.
        XCTAssertEqual(BWMixBands.saturationWeight(0.5), 0.6598, accuracy: 1e-4)
        var previous = 0.0
        var maxSlope = 0.0
        for i in 1...10_000 {
            let s = Double(i) / 10_000
            let w = BWMixBands.saturationWeight(s)
            XCTAssertGreaterThan(w, previous, "not monotone at \(s)")
            maxSlope = max(maxSlope, (w - previous) * 10_000)
            previous = w
        }
        // Without the knee this would diverge as s -> 0.
        XCTAssertLessThan(maxSlope, 5, "saturation weight slope is unbounded")
    }

    func testBlueSliderTargetsBlueNotRed() throws {
        let neutral = try run(EditState(), upTo: .bwMix)
        var edit = EditState()
        edit.bwMix.blue = -100
        let out = try run(edit, upTo: .bwMix)

        // (0.02, 0.02, 0.40) has encoded saturation 0.744, so it lands at
        // 2^(−3·0.744^0.6) ≈ 0.175 — several stops, not the ~0.7 EV the linear
        // law managed on the same patch.
        XCTAssertLessThan(Double(out.rgb(x: P.blue, y: 0).0),
                          Double(neutral.rgb(x: P.blue, y: 0).0) * 0.2)
        // The red patch is on the far side of the hue circle and must not move.
        XCTAssertEqual(Double(out.rgb(x: P.red, y: 0).0),
                       Double(neutral.rgb(x: P.red, y: 0).0),
                       accuracy: Double(neutral.rgb(x: P.red, y: 0).0) * 0.02)
    }

    /// Band centres moved in wave 2 (audit #5): a pure magenta pixel (HSV 300°)
    /// now lands entirely on the Magenta slider instead of being split 50/50
    /// with Purple.
    func testPureMagentaLandsOnTheMagentaSlider() throws {
        let neutral = try run(EditState(), upTo: .bwMix)
        let base = Double(neutral.rgb(x: P.pureMagenta, y: 0).0)

        var onBand = EditState()
        onBand.bwMix.magenta = -100
        let magenta = try run(onBand, upTo: .bwMix)
        XCTAssertEqual(Double(magenta.rgb(x: P.pureMagenta, y: 0).0) / base,
                       1.0 / 8, accuracy: 0.002)

        var neighbour = EditState()
        neighbour.bwMix.purple = -100
        let purple = try run(neighbour, upTo: .bwMix)
        XCTAssertEqual(Double(purple.rgb(x: P.pureMagenta, y: 0).0), base,
                       accuracy: base * 0.01, "Purple must not touch a pure magenta")
    }

    /// PV6 exists because big mixer moves band. Ours must not: on a near-neutral
    /// gradient with a faint cast — the sky/skin case — a ±100 move has to leave
    /// a monotone, gap-free 8-bit ramp.
    func testMixerDoesNotBandANearNeutralGradient() throws {
        let (ctx, pipe) = try TestGPU.require()
        let w = 512
        for cast in [0.004, 0.01, 0.03] {
            let tex = try ctx.makeTexture(width: w, height: 2) { x, _ in
                let y = Float(0.01 + Double(x) * (0.5 - 0.01) / Double(w - 1))
                return (y * Float(1 + cast), y, y * Float(1 - cast))
            }
            for slider in [-100.0, 100.0] {
                var edit = EditState()
                edit.bwMix.red = slider
                edit.bwMix.orange = slider
                let out = try TextureReadback.read(
                    pipe.render(input: tex, edit: edit, upTo: .output).texture)
                let codes = (0..<w).map { Int((Double(out.rgb(x: $0, y: 0).0) * 255).rounded()) }
                let span = abs(codes.last! - codes.first!) + 1
                let jumps = (1..<w).map { abs(codes[$0] - codes[$0 - 1]) }
                let label = "cast \(cast) slider \(slider)"
                XCTAssertGreaterThan(span, 150, "\(label): the ramp must still span the range")
                // No skipped levels: a banded ramp shows plateaus and then jumps.
                XCTAssertLessThanOrEqual(jumps.max() ?? 0, 2, "\(label): step > 2 codes")
                XCTAssertGreaterThan(Double(Set(codes).count) / Double(span), 0.85,
                                     "\(label): output uses too few of its levels")
                // Half-float quantisation of a sub-1 % saturation leaves a little
                // jitter; the saturation knee keeps it to a handful of 1-code
                // reversals (21 -> 9 at cast 0.004, measured) rather than a
                // staircase. Nothing above 1 code ever reverses.
                let reversals = (1..<w).filter { codes[$0] < codes[$0 - 1] }
                XCTAssertLessThan(reversals.count, 20, "\(label): ramp is not smooth")
                for i in reversals {
                    XCTAssertEqual(codes[i - 1] - codes[i], 1, "\(label): reversal at \(i)")
                }
            }
        }
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

        // Wave 2 retired the exact luminance invariant on purpose (audit #2):
        // `lumaPreserve = 0.5` keeps half the tint's luminance excursion, so a
        // warm tint *lifts*. What is asserted now is the sign and the bound.
        for idx in 0..<patches.count {
            let (r0, g0, b0) = before.rgb(x: idx, y: 0)
            let (r1, g1, b1) = out.rgb(x: idx, y: 0)
            let y0 = 0.2126 * Double(r0) + 0.7152 * Double(g0) + 0.0722 * Double(b0)
            let y1 = 0.2126 * Double(r1) + 0.7152 * Double(g1) + 0.0722 * Double(b1)
            let dEV = log2(y1 / y0)
            XCTAssertGreaterThanOrEqual(dEV, 0, "a warm tint must not darken (patch \(idx))")
            XCTAssertLessThan(dEV, 0.1, "excursion too large on patch \(idx)")
        }
        // ... and it really does move: the deep shadow, which is fully tinted,
        // gains about 1/27 of a stop at hue 30 / saturation 50.
        let (r0, g0, b0) = before.rgb(x: P.darkGray, y: 0)
        let (r1, g1, b1) = out.rgb(x: P.darkGray, y: 0)
        let y0 = 0.2126 * Double(r0) + 0.7152 * Double(g0) + 0.0722 * Double(b0)
        let y1 = 0.2126 * Double(r1) + 0.7152 * Double(g1) + 0.0722 * Double(b1)
        XCTAssertEqual(log2(y1 / y0), 0.0366, accuracy: 0.004)
    }

    /// The other sign: a cool tint darkens. Together with the test above this is
    /// the whole of the new luminance contract — bidirectional, hue-dependent,
    /// bounded, and *not* zero.
    func testCoolToningDarkensAndTheExcursionIsBounded() throws {
        let before = try run(EditState(), upTo: .toning)
        func lumaShift(hue: Double, sat: Double, at idx: Int) throws -> Double {
            var edit = EditState()
            edit.toning = .init(shadowHue: hue, shadowSaturation: sat,
                                highlightHue: hue, highlightSaturation: sat)
            let out = try run(edit, upTo: .toning)
            let (r0, g0, b0) = before.rgb(x: idx, y: 0)
            let (r1, g1, b1) = out.rgb(x: idx, y: 0)
            let y0 = 0.2126 * Double(r0) + 0.7152 * Double(g0) + 0.0722 * Double(b0)
            let y1 = 0.2126 * Double(r1) + 0.7152 * Double(g1) + 0.0722 * Double(b1)
            return log2(y1 / y0)
        }
        XCTAssertLessThan(try lumaShift(hue: 240, sat: 100, at: P.midGray), -0.3)
        XCTAssertGreaterThan(try lumaShift(hue: 40, sat: 100, at: P.midGray), 0.05)
        // Worst case over the hue circle at full saturation is blue, −0.64 EV.
        for hue in stride(from: 0.0, to: 360.0, by: 15.0) {
            let d = try lumaShift(hue: hue, sat: 100, at: P.midGray)
            XCTAssertLessThan(abs(d), 0.7, "hue \(hue) moved luminance by \(d) EV")
        }
        // And it scales with saturation, so a mild tint is a mild shift.
        XCTAssertLessThan(abs(try lumaShift(hue: 240, sat: 20, at: P.midGray)), 0.1)
    }

    /// The Swift mirror the crossover is documented and unit-tested through has
    /// to be the curve the kernel actually evaluates.
    func testToningWeightsMatchTheShader() throws {
        let (ctx, pipe) = try TestGPU.require()
        // Neutral ramp wide enough that the tone stage delivers t across 0…1.
        let inputs: [Float] = [0.0002, 0.001, 0.003, 0.008, 0.02, 0.05, 0.12,
                               0.18, 0.3, 0.6, 1.2, 2.5, 5, 10]
        let tex = try ctx.makeTexture(width: inputs.count, height: 2) { x, _ in
            (inputs[x], inputs[x], inputs[x])
        }
        for balance in [-100.0, 0.0, 100.0] {
            let base = try TextureReadback.read(
                pipe.render(input: tex, edit: EditState(), upTo: .bwMix).texture)
            // Shadow wheel only, then highlight wheel only, same hue and
            // saturation: the tint each produces is linear in its weight, so the
            // ratio of the two chromas is the ratio of the two weights.
            func chroma(shadow: Bool) throws -> [Double] {
                var edit = EditState()
                edit.toning = shadow
                    ? .init(shadowHue: 0, shadowSaturation: 40, balance: balance)
                    : .init(highlightHue: 0, highlightSaturation: 40, balance: balance)
                let out = try TextureReadback.read(
                    pipe.render(input: tex, edit: edit, upTo: .toning).texture)
                return (0..<inputs.count).map {
                    let (r, _, b) = out.rgb(x: $0, y: 0)
                    let y = Double(base.rgb(x: $0, y: 0).0)
                    return (Double(r) - Double(b)) / max(y, 1e-9)
                }
            }
            let cs = try chroma(shadow: true)
            let ch = try chroma(shadow: false)
            for i in 0..<inputs.count {
                let t = Double(base.rgb(x: i, y: 0).0).squareRoot()
                let w = ToningWeights.weights(t: min(t, 1), balance: balance)
                // Full weight on either side produces the same chroma, so the
                // predicted split scales one measured total.
                let total = cs[i] + ch[i]
                guard total > 0.02 else { continue }
                XCTAssertEqual(cs[i] / total, w.shadow / (w.shadow + w.highlight),
                               accuracy: 0.03,
                               "balance \(balance), t \(t): shadow share")
            }
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
        // Sampled on the dark patch: with the baseline rendition in place the
        // mid-gray patch renders at ~0.35 linear, which is above the shadow
        // crossover at either balance, so it is no longer a probe of it.
        XCTAssertGreaterThan(warmth(mid, P.darkGray), 1.05)
        XCTAssertLessThan(warmth(shifted, P.darkGray), warmth(mid, P.darkGray))
    }

    /// Audit #1: the weights are complementary, so they sum to 1 everywhere the
    /// endpoint fade is inactive and there is no neutral band at the crossover.
    /// Pure Swift — this is the contract `testToningWeightsMatchTheShader` ties
    /// to the kernel.
    func testSplitToneWeightsSumToOneAndCrossoverFollowsBalance() throws {
        for balance in [-100.0, -50.0, 0.0, 50.0, 100.0] {
            var previousHighlight = -1.0
            for t in stride(from: 0.10, through: 0.90, by: 0.01) {
                let w = ToningWeights.weights(t: t, balance: balance)
                XCTAssertEqual(w.shadow + w.highlight, 1, accuracy: 1e-9,
                               "balance \(balance), t \(t)")
                XCTAssertGreaterThan(w.highlight, previousHighlight - 1e-12,
                                     "highlight weight must be monotone")
                previousHighlight = w.highlight
            }
            // Nothing in the midtones is left untinted — the old shape had both
            // weights at 0 exactly at the pivot.
            let p = ToningWeights.pivot(balance: balance)
            let atPivot = ToningWeights.weights(t: p, balance: balance)
            XCTAssertEqual(atPivot.shadow, 0.5, accuracy: 1e-9)
            XCTAssertEqual(atPivot.highlight, 0.5, accuracy: 1e-9)
        }
        // Balance moves the crossover, and only that.
        XCTAssertEqual(ToningWeights.pivot(balance: 0), 0.5, accuracy: 1e-12)
        XCTAssertEqual(ToningWeights.pivot(balance: 100), 0.15, accuracy: 1e-12)
        XCTAssertEqual(ToningWeights.pivot(balance: -100), 0.85, accuracy: 1e-12)
        // Positive balance favours highlights: at mid gray the shadow tint has
        // already handed over.
        XCTAssertLessThan(ToningWeights.weights(t: 0.5, balance: 100).shadow, 0.01)
        XCTAssertGreaterThan(ToningWeights.weights(t: 0.5, balance: -100).shadow, 0.99)
        // The extremes stay black and white.
        XCTAssertEqual(ToningWeights.weights(t: 0, balance: 0).shadow, 0, accuracy: 1e-12)
        XCTAssertEqual(ToningWeights.weights(t: 1, balance: 0).highlight, 0, accuracy: 1e-12)
    }

    /// The audit's own golden for the dead zone: both wheels on the same hue and
    /// saturation must give one *uniform* tint across the tonal range, not
    /// tinted ends around a grey middle.
    func testEqualWheelsGiveAUniformTintWithNoNeutralMidtones() throws {
        let (ctx, pipe) = try TestGPU.require()
        let inputs: [Float] = [0.008, 0.02, 0.05, 0.12, 0.18, 0.3, 0.6]
        let tex = try ctx.makeTexture(width: inputs.count, height: 2) { x, _ in
            (inputs[x], inputs[x], inputs[x])
        }
        let base = try TextureReadback.read(
            pipe.render(input: tex, edit: EditState(), upTo: .bwMix).texture)
        var edit = EditState()
        edit.toning = .init(shadowHue: 210, shadowSaturation: 60,
                            highlightHue: 210, highlightSaturation: 60)
        let out = try TextureReadback.read(
            pipe.render(input: tex, edit: edit, upTo: .toning).texture)

        let chroma = (0..<inputs.count).map { i -> Double in
            let (r, _, b) = out.rgb(x: i, y: 0)
            return (Double(b) - Double(r)) / max(Double(base.rgb(x: i, y: 0).0), 1e-9)
        }
        let lo = chroma.min()!, hi = chroma.max()!
        XCTAssertGreaterThan(lo, 0.3, "some tone was left untinted: \(chroma)")
        XCTAssertLessThan(hi / lo, 1.15, "the tint is not uniform: \(chroma)")
    }

    /// Sepia sanity: shadows warm, the tint weakens monotonically with
    /// luminance, and only genuinely near-white stays neutral.
    func testSepiaPresetIsWarmAndMonotone() throws {
        let (ctx, pipe) = try TestGPU.require()
        let inputs: [Float] = [0.0002, 0.001, 0.003, 0.008, 0.02, 0.05, 0.12,
                               0.18, 0.3, 0.6, 1.2, 2.5, 5, 10]
        let tex = try ctx.makeTexture(width: inputs.count, height: 2) { x, _ in
            (inputs[x], inputs[x], inputs[x])
        }
        let base = try TextureReadback.read(
            pipe.render(input: tex, edit: EditState(), upTo: .bwMix).texture)
        var edit = EditState()
        edit.toning = .init(shadowHue: 40, shadowSaturation: 30,
                            highlightHue: 45, highlightSaturation: 25)
        let out = try TextureReadback.read(
            pipe.render(input: tex, edit: edit, upTo: .toning).texture)

        var chroma: [Double] = []
        for i in 0..<inputs.count {
            let (r, g, b) = out.rgb(x: i, y: 0)
            let y0 = Double(base.rgb(x: i, y: 0).0)
            let y1 = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
            chroma.append((Double(r) - Double(b)) / max(y1, 1e-9))
            // Hue direction: warm means R > G > B, everywhere it is tinted.
            if chroma[i] > 0.01 {
                XCTAssertGreaterThan(Double(r), Double(g), "patch \(i) not warm")
                XCTAssertGreaterThan(Double(g), Double(b), "patch \(i) not warm")
                // ... and the warm tint lifts, it does not darken.
                XCTAssertGreaterThan(log2(y1 / y0), 0)
            }
            XCTAssertLessThan(log2(y1 / max(y0, 1e-12)), 0.06, "patch \(i) lifted too far")
        }
        // Peak strength is in the deep shadows and it falls monotonically with
        // luminance from there. (Below the peak the endpoint fade takes it to 0,
        // which is what keeps clipped black black.)
        let peak = chroma.firstIndex(of: chroma.max()!)!
        XCTAssertGreaterThan(chroma[peak], 0.35)
        for i in (peak + 1)..<inputs.count {
            XCTAssertLessThanOrEqual(chroma[i], chroma[i - 1] + 1e-6,
                                     "tint strength not monotone at \(i): \(chroma)")
        }
        XCTAssertLessThan(chroma[0], 0.05, "clipped black must stay neutral")
        XCTAssertLessThan(chroma[inputs.count - 1], 0.01, "clipped white must stay neutral")
        // Mid gray really does gain warmth — the old shape left it exactly grey.
        let mid = 7   // input 0.18
        XCTAssertGreaterThan(chroma[mid], 0.25)
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
        let zero = EditState.Tone()
        for idx in 0..<patches.count {
            let src = patches[idx]
            // The tone stage is no longer the identity at zero, so the reference
            // is "baseline rendition, then sRGB encode".
            let y = 0.2126 * Double(src.0) + 0.7152 * Double(src.1) + 0.0722 * Double(src.2)
            let gain = ToneCurve.evaluateLinear(y, zero) / y
            let (r, g, b) = out.rgb(x: idx, y: 0)
            XCTAssertEqual(Double(r), sRGBEncodeReference(Double(src.0) * gain), accuracy: 0.003)
            XCTAssertEqual(Double(g), sRGBEncodeReference(Double(src.1) * gain), accuracy: 0.003)
            XCTAssertEqual(Double(b), sRGBEncodeReference(Double(src.2) * gain), accuracy: 0.003)
        }
    }

    func testOutputClampsOutOfRangeValues() throws {
        let (ctx, pipe) = try TestGPU.require()
        // 64 is above the LUT domain (+8 EV), where the endpoint gain applies —
        // the only route to a genuine clip now that the tone curve carries a
        // shoulder that asymptotes at linear 1.0.
        let input = try ctx.makePatchTexture([(-0.5, -0.5, -0.5), (64, 64, 64)])
        var edit = EditState()
        edit.bwMix.enabled = false
        let result = try pipe.render(input: input, edit: edit, upTo: .output)
        let out = try TextureReadback.read(result.texture)
        XCTAssertEqual(Double(out.rgb(x: 0, y: 0).0), 0, accuracy: 1e-4)
        XCTAssertEqual(Double(out.rgb(x: 1, y: 0).0), 1, accuracy: 1e-3)
    }

    /// The shoulder means the tone stage rolls off toward display white instead
    /// of cutting off at it. Before wave 1, Exposure +2 mapped everything above
    /// linear 0.25 to pure white (audit tone.json deviation #0).
    func testToneRollsOffInsteadOfClipping() throws {
        let (ctx, pipe) = try TestGPU.require()
        let input = try ctx.makePatchTexture([(0.5, 0.5, 0.5), (2, 2, 2)])
        var edit = EditState()
        edit.bwMix.enabled = false
        edit.tone = .init(exposure: 2, contrast: 100, whites: 100)
        let out = try TextureReadback.read(
            pipe.render(input: input, edit: edit, upTo: .tone).texture)
        let a = Double(out.rgb(x: 0, y: 0).0)
        let b = Double(out.rgb(x: 1, y: 0).0)
        XCTAssertLessThan(a, 0.999, "0.5 clipped at exposure +2")
        XCTAssertLessThan(b, 0.999, "2.0 clipped at exposure +2")
        // Still ordered: the shoulder compresses, it does not flatten.
        XCTAssertGreaterThan(b, a)
    }

    // MARK: - Histogram

    func testHistogramCountsAndClipping() throws {
        let (ctx, pipe) = try TestGPU.require()
        // 4 columns x 4 rows: black, mid, white, white. The white patches are
        // above the LUT domain so they still clip now that the tone curve has a
        // shoulder (see testToneRollsOffInsteadOfClipping).
        let input = try ctx.makePatchTexture([(0, 0, 0), (0.18, 0.18, 0.18), (64, 64, 64), (64, 64, 64)],
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
        // Scene 0.18 renders through the baseline curve, not through identity.
        let midBin = Int((sRGBEncodeReference(
            ToneCurve.evaluateLinear(0.18, EditState.Tone())) * 255).rounded())
        XCTAssertEqual(h.bins[midBin - 1] + h.bins[midBin] + h.bins[midBin + 1], 4)

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
