import XCTest
@testable import GrayroomCore

final class ToneCurveTests: XCTestCase {

    private let samples: [Double] = stride(from: ToneCurve.domainMinEV,
                                           through: ToneCurve.domainMaxEV,
                                           by: 0.02).map { $0 }

    /// The scene luminance that the **all-zero** curve renders to `target`.
    /// Every behavioural assertion below is phrased in rendered (display)
    /// luminance, because that is the space Lightroom's zones are defined in.
    private func sceneLuminance(renderingTo target: Double) -> Double {
        var lo = 1e-9, hi = 1e6
        let zero = EditState.Tone()
        for _ in 0..<200 {
            let mid = (lo + hi) / 2
            if ToneCurve.evaluateLinear(mid, zero) < target { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    private func sRGBToLinear(_ v: Double) -> Double {
        v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    // MARK: - Baseline rendition (replaces the retired identity invariant)

    /// All sliders at zero is no longer the identity: it is the documented
    /// baseline rendition, `shoulder(baseline(x))`. Assert against the baseline
    /// functions themselves, so the two can never drift apart.
    func testAllZeroCurveIsTheBaselineRendition() {
        let t = EditState.Tone()
        for x in samples {
            XCTAssertEqual(ToneCurve.evaluateEV(x, t),
                           ToneCurve.shoulderEV(ToneCurve.baselineEV(x)),
                           accuracy: 1e-12)
        }
        // ... and through the LUT.
        let lut = ToneCurve.makeLUT(for: t)
        for y in [1e-4, 0.005, 0.05, 0.18, 0.5, 1.0, 4.0, 20.0] {
            let expected = ToneCurve.evaluateLinear(y, t)
            XCTAssertEqual(ToneCurve.applyLUT(lut, toLuminance: y), expected,
                           accuracy: expected * 1e-3)
        }
    }

    /// The baseline is a *rendition*, not a no-op: it lifts the midtones by
    /// ~0.75 EV and steepens the shadows, which is what closes the measured gap
    /// to Lightroom's camera-profile default (decode-output.json deviation #0).
    func testBaselineLiftsMidtonesAndDeepensShadows() {
        let t = EditState.Tone()
        // Scene middle gray comes out well above 0.18 (a real rendition).
        XCTAssertEqual(ToneCurve.evaluateLinear(0.18, t), 0.3533, accuracy: 0.002)
        // The measured median of testdata/L1000003.DNG: 0.0848 -> 0.1423.
        XCTAssertEqual(ToneCurve.evaluateLinear(0.0848, t), 0.1423, accuracy: 0.004)
        // ... its p95: 0.264 -> 0.524 ...
        XCTAssertEqual(ToneCurve.evaluateLinear(0.264, t), 0.524, accuracy: 0.015)
        // ... and its p05, which gets *darker* (increased shadow contrast).
        XCTAssertEqual(ToneCurve.evaluateLinear(0.0108, t), 0.0065, accuracy: 0.0005)
        // Baseline offsets saturate at ±1 EV.
        XCTAssertEqual(ToneCurve.baselineEV(-13) + 13, ToneCurve.baselineLowEV, accuracy: 1e-9)
        XCTAssertEqual(ToneCurve.baselineEV(6) - 6, ToneCurve.baselineHighEV, accuracy: 1e-9)
    }

    // MARK: - Display shoulder

    /// Nothing tone-driven ever hard-clips: the shoulder is C¹ at the knee and
    /// asymptotic to linear 1.0.
    func testShoulderIsSmoothAndNeverReachesWhite() {
        let k = ToneCurve.shoulderKneeEV
        XCTAssertEqual(ToneCurve.shoulderEV(k), k, accuracy: 1e-12)
        // Continuity of value and slope across the knee.
        let h = 1e-6
        let slopeBelow = (ToneCurve.shoulderEV(k - h) - ToneCurve.shoulderEV(k - 2 * h)) / h
        let slopeAbove = (ToneCurve.shoulderEV(k + 2 * h) - ToneCurve.shoulderEV(k + h)) / h
        XCTAssertEqual(slopeBelow, 1, accuracy: 1e-4)
        XCTAssertEqual(slopeAbove, 1, accuracy: 1e-4)
        // Strictly increasing, always below display white.
        var prev = -Double.infinity
        for i in 0...2000 {
            let y = Double(i) * 0.01
            let s = ToneCurve.shoulderEV(y)
            XCTAssertGreaterThan(s, prev)
            XCTAssertLessThan(s, ToneCurve.displayWhiteEV)
            prev = s
        }
        // ... which means the curve itself never produces linear 1.0.
        var hot = EditState.Tone()
        hot.exposure = 5
        hot.whites = 100
        hot.contrast = 100
        for y in [1.0, 10.0, 100.0] {
            XCTAssertLessThan(ToneCurve.evaluateLinear(y, hot), 1.0)
        }
    }

    // MARK: - Exposure

    /// Exposure is still a pure EV shift *after* the baseline, so +1 EV doubles
    /// linear luminance exactly — in the midrange that stays below the shoulder
    /// knee. Above the knee the shoulder compresses, by design.
    func testExposureDoublesLinearValuesBelowTheShoulderKnee() {
        var t = EditState.Tone()
        t.exposure = 1
        // The upper edge of the exact-doubling band: rendered y + 1 EV = knee.
        for y in [0.001, 0.005, 0.02, 0.05, 0.09, 0.12] {
            let base = ToneCurve.evaluateLinear(y, EditState.Tone())
            XCTAssertEqual(ToneCurve.evaluateLinear(y, t), base * 2, accuracy: base * 1e-9,
                           "exposure +1 must double at Y=\(y)")
        }
        let lut = ToneCurve.makeLUT(for: t)
        for y in [0.005, 0.02, 0.05, 0.09] {
            let base = ToneCurve.evaluateLinear(y, EditState.Tone())
            XCTAssertEqual(ToneCurve.applyLUT(lut, toLuminance: y), base * 2, accuracy: base * 2e-3)
        }
        t.exposure = -2
        for y in [0.01, 0.05, 0.18] {
            let base = ToneCurve.evaluateLinear(y, EditState.Tone())
            XCTAssertEqual(ToneCurve.evaluateLinear(y, t), base * 0.25, accuracy: base * 1e-9)
        }
        // Above the knee the shoulder takes over: still brighter, but not 2x.
        let hi = ToneCurve.evaluateLinear(0.5, EditState.Tone())
        var up = EditState.Tone(); up.exposure = 1
        let hiUp = ToneCurve.evaluateLinear(0.5, up)
        XCTAssertGreaterThan(hiUp, hi)
        XCTAssertLessThan(hiUp, hi * 2)
    }

    // MARK: - Monotonicity
    //
    // Carve-out (documented in README.md): the curve is monotone
    // *non-decreasing*, not strictly increasing everywhere. Blacks < 0 crushes a
    // toe of the domain to exactly 0, which is the whole point of the control
    // (Lightroom's "map more shadows to pure black"). Above that toe the curve
    // is strictly increasing. The strict slope budget is asserted separately on
    // the additive zone sum, where it is actually a design constraint.

    func testMonotonicUnderRandomCombos() {
        var rng = SeededRandom(seed: 0xF00D_BEEF)
        for _ in 0..<400 {
            let t = EditState.Tone(
                exposure: rng.double(in: -5...5),
                contrast: rng.double(in: -100...100),
                highlights: rng.double(in: -100...100),
                shadows: rng.double(in: -100...100),
                whites: rng.double(in: -100...100),
                blacks: rng.double(in: -100...100))
            assertMonotone(t)
        }
    }

    /// The extreme slider corners are the worst case for monotonicity.
    func testMonotonicAtAllSliderCorners() {
        let ends: [Double] = [-100, 0, 100]
        for e in [-5.0, 0, 5] {
            for c in ends {
                for h in ends {
                    for s in ends {
                        for w in ends {
                            for b in ends {
                                assertMonotone(EditState.Tone(exposure: e, contrast: c,
                                                              highlights: h, shadows: s,
                                                              whites: w, blacks: b))
                            }
                        }
                    }
                }
            }
        }
    }

    private func assertMonotone(_ t: EditState.Tone, file: StaticString = #filePath, line: UInt = #line) {
        var prev = -Double.infinity
        for x in samples {
            let y = ToneCurve.evaluateLinear(ToneCurve.pivot * exp2(x), t)
            XCTAssertGreaterThanOrEqual(y, prev, "non-monotone at x=\(x) for \(t)",
                                        file: file, line: line)
            // Strictly increasing everywhere above the black toe.
            if prev > 0 {
                XCTAssertGreaterThan(y, prev, "flat run above the black point at x=\(x) for \(t)",
                                     file: file, line: line)
            }
            prev = y
        }
        XCTAssertGreaterThan(prev, 0, "curve collapsed for \(t)")
    }

    /// The tuning constants are chosen so the *additive* part of the curve keeps
    /// a healthy positive slope for every slider combination. The baseline can
    /// only add slope (its derivative is ≥ 0) and the shoulder can only scale it
    /// by a factor in (0, 1], so this bound is what makes the whole curve
    /// monotone.
    func testZoneSumSlopeStaysPositive() {
        let ends: [Double] = [-100, 0, 100]
        var worst = Double.infinity
        for c in ends {
            for h in ends {
                for s in ends {
                    for w in ends {
                        let t = EditState.Tone(contrast: c, highlights: h, shadows: s, whites: w)
                        var prev = ToneCurve.zoneSumEV(-16, t)
                        var x = -16.0
                        while x < 12 {
                            x += 0.01
                            let y = ToneCurve.zoneSumEV(x, t)
                            worst = min(worst, (y - prev) / 0.01)
                            prev = y
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(worst, 0.05, "zone-sum slope budget is exhausted")
    }

    func testLUTIsNonDecreasing() {
        var rng = SeededRandom(seed: 12345)
        for _ in 0..<50 {
            let t = EditState.Tone(
                exposure: rng.double(in: -5...5),
                contrast: rng.double(in: -100...100),
                highlights: rng.double(in: -100...100),
                shadows: rng.double(in: -100...100),
                whites: rng.double(in: -100...100),
                blacks: rng.double(in: -100...100))
            let lut = ToneCurve.makeLUT(for: t)
            for i in 1..<lut.size {
                XCTAssertGreaterThanOrEqual(lut.values[i], lut.values[i - 1])
            }
            // gainBelow is 0 exactly when Blacks has crushed the bottom away.
            XCTAssertGreaterThanOrEqual(lut.gainBelow, 0)
            XCTAssertGreaterThan(lut.gainAbove, 0)
        }
    }

    // MARK: - Lightroom-parity behaviour

    /// Highlights and Shadows must have real authority at middle gray — the old
    /// ramps were exactly zero there (audit tone.json deviation #2).
    func testMiddleGrayRespondsToHighlightsAndShadows() {
        let scene = sceneLuminance(renderingTo: ToneCurve.pivot)
        for (name, t) in [("highlights", EditState.Tone(highlights: 100)),
                          ("shadows", EditState.Tone(shadows: 100))] {
            let up = log2(ToneCurve.evaluateLinear(scene, t) / ToneCurve.pivot)
            XCTAssertGreaterThan(up, 0.25, "\(name) +100 barely moves middle gray")
        }
        for (name, t) in [("highlights", EditState.Tone(highlights: -100)),
                          ("shadows", EditState.Tone(shadows: -100))] {
            let down = log2(ToneCurve.evaluateLinear(scene, t) / ToneCurve.pivot)
            XCTAssertLessThan(down, -0.25, "\(name) −100 barely moves middle gray")
        }
    }

    /// At Lightroom's measured zone centres (±1.3 EV from middle gray in the
    /// rendered image) the sliders must have most of their authority.
    func testZoneCentresMoveByMoreThanHalfAStop() {
        for centre in [1.3, 1.4] {
            let target = ToneCurve.pivot * exp2(centre)
            let scene = sceneLuminance(renderingTo: target)
            let moved = ToneCurve.evaluateLinear(scene, EditState.Tone(highlights: -100))
            XCTAssertLessThan(log2(moved / target), -0.6,
                              "highlights −100 at +\(centre) EV")
        }
        for centre in [-1.3, -1.4] {
            let target = ToneCurve.pivot * exp2(centre)
            let scene = sceneLuminance(renderingTo: target)
            let moved = ToneCurve.evaluateLinear(scene, EditState.Tone(shadows: 100))
            XCTAssertGreaterThan(log2(moved / target), 0.6, "shadows +100 at \(centre) EV")
        }
    }

    /// The classic dynamic-range-compression move must actually flatten the
    /// picture through the core of the tonal range, not just at the extremes.
    func testHighlightsDownShadowsUpFlattensTheMidtones() {
        let t = EditState.Tone(highlights: -100, shadows: 100)
        var previousSpan = Double.infinity
        for (lo, hi) in [(-2.0, 2.0), (-1.0, 1.0)] {
            let a = sceneLuminance(renderingTo: ToneCurve.pivot * exp2(lo))
            let b = sceneLuminance(renderingTo: ToneCurve.pivot * exp2(hi))
            let span = log2(ToneCurve.evaluateLinear(b, t) / ToneCurve.evaluateLinear(a, t))
            XCTAssertLessThan(span, (hi - lo) * 0.7,
                              "\(lo)…\(hi) EV wedge was not flattened (span \(span))")
            previousSpan = min(previousSpan, span)
        }
        XCTAssertGreaterThan(previousSpan, 0)
    }

    /// Contrast +100 must not promote a light gray to paper white (the old
    /// σ = 2.5 EV bump clipped everything above sRGB 79.5%).
    func testContrastDoesNotClipLightGray() {
        let target = sRGBToLinear(0.80)
        let scene = sceneLuminance(renderingTo: target)
        let out = ToneCurve.evaluateLinear(scene, EditState.Tone(contrast: 100))
        XCTAssertGreaterThan(out, target, "contrast +100 should still brighten a light gray")
        XCTAssertLessThan(out, sRGBToLinear(0.92), "contrast +100 blew out sRGB 80% gray")
        // ... and −100 flattens it toward the midtones without dropping the
        // white point by a whole stop.
        let down = ToneCurve.evaluateLinear(scene, EditState.Tone(contrast: -100))
        XCTAssertLessThan(down, target)
        XCTAssertGreaterThan(log2(down / target), -0.5)
        // Peak displacement is in the midtones: |Δ| is largest at ±σ.
        let peak = abs(ToneCurve.contrastDeltaEV(ToneCurve.contrastSigma, 100))
        for x in stride(from: 2.0, through: 6.0, by: 0.25) {
            XCTAssertLessThan(abs(ToneCurve.contrastDeltaEV(x, 100)), peak)
        }
    }

    /// Whites must act inside the displayable range (the old ramp had its 50%
    /// point at +4.25 EV, 1.8 stops above display white).
    func testWhitesActWithinDisplayableRange() {
        let target = sRGBToLinear(0.85)
        let scene = sceneLuminance(renderingTo: target)
        let up = ToneCurve.evaluateLinear(scene, EditState.Tone(whites: 100))
        let down = ToneCurve.evaluateLinear(scene, EditState.Tone(whites: -100))
        XCTAssertGreaterThan(log2(up / target), 0.10, "whites +100 barely moved sRGB 85%")
        XCTAssertLessThan(log2(down / target), -0.10, "whites −100 barely moved sRGB 85%")
        // 50% of the ramp lands on Lightroom's Whites zone centre, +2.1 EV.
        XCTAssertEqual(ToneCurve.whitesDeltaEV(2.1, 100), ToneCurve.whitesRange * 0.5,
                       accuracy: 1e-9)
        // ... and it leaves the midtones alone.
        XCTAssertEqual(ToneCurve.whitesDeltaEV(0, 100), 0, accuracy: 1e-12)
    }

    /// Blacks −100 must genuinely reach zero: Lightroom crushes.
    func testBlacksReachTrueBlack() {
        let t = EditState.Tone(blacks: -100)
        for v in [0.02, 0.05, 0.10, 0.15] {
            let scene = sceneLuminance(renderingTo: sRGBToLinear(v))
            XCTAssertEqual(ToneCurve.evaluateLinear(scene, t), 0, accuracy: 1e-12,
                           "blacks −100 left sRGB \(v) above zero")
        }
        // ... but does not eat the midtones.
        let mid = sceneLuminance(renderingTo: ToneCurve.pivot)
        XCTAssertGreaterThan(ToneCurve.evaluateLinear(mid, t), ToneCurve.pivot * 0.8)
        // The LUT sees the same crush.
        let lut = ToneCurve.makeLUT(for: t)
        XCTAssertEqual(Double(lut.values[0]), 0, accuracy: 1e-12)
        XCTAssertEqual(lut.gainBelow, 0)
        // Positive blacks lifts instead.
        let lifted = EditState.Tone(blacks: 100)
        let deep = sceneLuminance(renderingTo: sRGBToLinear(0.05))
        XCTAssertGreaterThan(ToneCurve.evaluateLinear(deep, lifted), sRGBToLinear(0.05) + 0.015)
    }

    func testSliderDirections() {
        // Everything below is phrased on the *rendered* image.
        func rendered(_ ev: Double, _ t: EditState.Tone) -> Double {
            let target = ToneCurve.pivot * exp2(ev)
            return log2(ToneCurve.evaluateLinear(sceneLuminance(renderingTo: target), t) / target)
        }
        // +contrast steepens: darks darker, brights brighter.
        XCTAssertLessThan(rendered(-1.5, EditState.Tone(contrast: 100)), -0.1)
        XCTAssertGreaterThan(rendered(1.5, EditState.Tone(contrast: 100)), 0.1)
        // -contrast flattens.
        XCTAssertGreaterThan(rendered(-1.5, EditState.Tone(contrast: -100)), 0.1)
        XCTAssertLessThan(rendered(1.5, EditState.Tone(contrast: -100)), -0.1)

        // Highlight recovery pulls highlights down hard and the shadows barely.
        let hlDown = EditState.Tone(highlights: -100)
        XCTAssertLessThan(rendered(2.0, hlDown), -0.6)
        XCTAssertGreaterThan(rendered(-3.0, hlDown), -0.05)

        // Shadow lift raises shadows and barely touches the highlights.
        let shUp = EditState.Tone(shadows: 100)
        XCTAssertGreaterThan(rendered(-2.0, shUp), 0.6)
        XCTAssertLessThan(rendered(2.0, shUp), 0.05)

        // Whites/blacks act further out than highlights/shadows.
        XCTAssertEqual(ToneCurve.whitesDeltaEV(0.5, 100), 0, accuracy: 1e-12)
        XCTAssertGreaterThan(ToneCurve.whitesDeltaEV(2.474, 100), ToneCurve.whitesRange * 0.7)
        XCTAssertGreaterThan(ToneCurve.blackPedestal(0.5, -100), 0.47)
    }

    func testLUTMatchesAnalyticCurve() {
        let t = EditState.Tone(exposure: 0.4, contrast: 35, highlights: -50,
                               shadows: 25, whites: 15, blacks: -20)
        let lut = ToneCurve.makeLUT(for: t)
        for y in [0.002, 0.02, 0.1, 0.18, 0.4, 0.9, 2.0, 8.0] {
            let expected = ToneCurve.evaluateLinear(y, t)
            let got = ToneCurve.applyLUT(lut, toLuminance: y)
            XCTAssertEqual(got, expected, accuracy: max(expected * 2e-3, 1e-9),
                           "LUT mismatch at Y=\(y)")
        }
    }

    func testOutOfDomainGainsAreContinuous() {
        let t = EditState.Tone(exposure: 0.5, contrast: 40, whites: 40, blacks: -60)
        let lut = ToneCurve.makeLUT(for: t)
        let yLow = ToneCurve.pivot * exp2(ToneCurve.domainMinEV)
        let yHigh = ToneCurve.pivot * exp2(ToneCurve.domainMaxEV)
        XCTAssertEqual(ToneCurve.applyLUT(lut, toLuminance: yLow * 0.999),
                       ToneCurve.applyLUT(lut, toLuminance: yLow * 1.001),
                       accuracy: max(Double(lut.values[0]) * 0.01, 1e-9))
        XCTAssertEqual(ToneCurve.applyLUT(lut, toLuminance: yHigh * 0.999),
                       ToneCurve.applyLUT(lut, toLuminance: yHigh * 1.001),
                       accuracy: Double(lut.values[lut.size - 1]) * 0.01)
        XCTAssertEqual(ToneCurve.applyLUT(lut, toLuminance: 0), 0)
    }
}
