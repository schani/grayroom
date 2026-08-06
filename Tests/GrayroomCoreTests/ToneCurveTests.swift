import XCTest
@testable import GrayroomCore

final class ToneCurveTests: XCTestCase {

    private let samples: [Double] = stride(from: ToneCurve.domainMinEV,
                                           through: ToneCurve.domainMaxEV,
                                           by: 0.02).map { $0 }

    func testIdentityAtDefaults() {
        let t = EditState.Tone()
        for x in samples {
            XCTAssertEqual(ToneCurve.evaluateEV(x, t), x, accuracy: 1e-12)
        }
        // ... and through the LUT.
        let lut = ToneCurve.makeLUT(for: t)
        for y in [1e-4, 0.005, 0.05, 0.18, 0.5, 1.0, 4.0, 20.0] {
            XCTAssertEqual(ToneCurve.applyLUT(lut, toLuminance: y), y, accuracy: y * 1e-4)
        }
    }

    func testExposureDoublesLinearValues() {
        var t = EditState.Tone()
        t.exposure = 1
        for y in [0.001, 0.01, 0.18, 0.5, 1.0, 3.0] {
            XCTAssertEqual(ToneCurve.evaluateLinear(y, t), y * 2, accuracy: y * 1e-9)
        }
        let lut = ToneCurve.makeLUT(for: t)
        for y in [0.001, 0.01, 0.18, 0.5, 1.0, 3.0] {
            XCTAssertEqual(ToneCurve.applyLUT(lut, toLuminance: y), y * 2, accuracy: y * 1e-3)
        }
        t.exposure = -2
        for y in [0.01, 0.18, 1.0] {
            XCTAssertEqual(ToneCurve.evaluateLinear(y, t), y * 0.25, accuracy: y * 1e-9)
        }
    }

    /// The analytic curve must be strictly increasing for *any* slider
    /// combination — that is the property the tuning constants are chosen for.
    func testAnalyticCurveMonotonicUnderRandomCombos() {
        var rng = SeededRandom(seed: 0xF00D_BEEF)
        for _ in 0..<400 {
            let t = EditState.Tone(
                exposure: rng.double(in: -5...5),
                contrast: rng.double(in: -100...100),
                highlights: rng.double(in: -100...100),
                shadows: rng.double(in: -100...100),
                whites: rng.double(in: -100...100),
                blacks: rng.double(in: -100...100))
            var prev = -Double.infinity
            var minSlope = Double.infinity
            var prevX = 0.0
            var first = true
            for x in samples {
                let y = ToneCurve.evaluateEV(x, t)
                if !first {
                    minSlope = min(minSlope, (y - prev) / (x - prevX))
                }
                XCTAssertGreaterThan(y, prev, "non-monotonic at x=\(x) for \(t)")
                prev = y
                prevX = x
                first = false
            }
            // Also assert healthy margin, not just non-decreasing.
            XCTAssertGreaterThan(minSlope, 0.05, "slope too flat for \(t)")
        }
    }

    /// The extreme slider corners are the worst case for monotonicity.
    func testMonotonicAtAllSliderCorners() {
        let ends: [Double] = [-100, 0, 100]
        for c in ends {
            for h in ends {
                for s in ends {
                    for w in ends {
                        for b in ends {
                            let t = EditState.Tone(exposure: 0, contrast: c, highlights: h,
                                                   shadows: s, whites: w, blacks: b)
                            var prev = -Double.infinity
                            for x in samples {
                                let y = ToneCurve.evaluateEV(x, t)
                                XCTAssertGreaterThan(y, prev, "non-monotonic at x=\(x) for \(t)")
                                prev = y
                            }
                        }
                    }
                }
            }
        }
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
            XCTAssertGreaterThan(lut.gainBelow, 0)
            XCTAssertGreaterThan(lut.gainAbove, 0)
        }
    }

    func testSliderDirections() {
        // +contrast steepens: darks darker, brights brighter (relative to identity).
        let contrastUp = EditState.Tone(contrast: 100)
        XCTAssertLessThan(ToneCurve.evaluateEV(-2, contrastUp), -2)
        XCTAssertGreaterThan(ToneCurve.evaluateEV(2, contrastUp), 2)
        // -contrast flattens.
        let contrastDown = EditState.Tone(contrast: -100)
        XCTAssertGreaterThan(ToneCurve.evaluateEV(-2, contrastDown), -2)
        XCTAssertLessThan(ToneCurve.evaluateEV(2, contrastDown), 2)

        // Highlight recovery pulls highlights down, leaves the pivot alone.
        let hlDown = EditState.Tone(highlights: -100)
        XCTAssertLessThan(ToneCurve.evaluateEV(3, hlDown), 3 - 0.9)
        XCTAssertEqual(ToneCurve.evaluateEV(0, hlDown), 0, accuracy: 1e-9)

        // Shadow lift raises shadows, leaves the pivot alone.
        let shUp = EditState.Tone(shadows: 100)
        XCTAssertGreaterThan(ToneCurve.evaluateEV(-3, shUp), -3 + 0.9)
        XCTAssertEqual(ToneCurve.evaluateEV(0, shUp), 0, accuracy: 1e-9)

        // Whites/blacks act further out than highlights/shadows.
        let whitesUp = EditState.Tone(whites: 100)
        XCTAssertGreaterThan(ToneCurve.evaluateEV(6, whitesUp), 6 + 1.3)
        XCTAssertEqual(ToneCurve.evaluateEV(0.5, whitesUp), 0.5, accuracy: 1e-9)

        let blacksDown = EditState.Tone(blacks: -100)
        XCTAssertLessThan(ToneCurve.evaluateEV(-6, blacksDown), -6 - 1.3)
        XCTAssertEqual(ToneCurve.evaluateEV(-0.5, blacksDown), -0.5, accuracy: 1e-9)
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
                       accuracy: Double(lut.values[0]) * 0.01)
        XCTAssertEqual(ToneCurve.applyLUT(lut, toLuminance: yHigh * 0.999),
                       ToneCurve.applyLUT(lut, toLuminance: yHigh * 1.001),
                       accuracy: Double(lut.values[lut.size - 1]) * 0.01)
        XCTAssertEqual(ToneCurve.applyLUT(lut, toLuminance: 0), 0)
    }
}
