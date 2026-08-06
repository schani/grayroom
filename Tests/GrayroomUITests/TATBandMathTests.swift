import Foundation
import GrayroomCore
import XCTest
@testable import GrayroomUI

final class TATBandMathTests: XCTestCase {
    func testAHueOnABandCentreGoesEntirelyToThatBand() {
        for (i, c) in BWMixBands.centers.enumerated() {
            let s = TATBandMath.split(hueDegrees: c)
            XCTAssertEqual(s.lowerIndex, i, "hue \(c)")
            XCTAssertEqual(s.upperWeight, 0, accuracy: 1e-12, "hue \(c)")
        }
    }

    func testWeightsArePartitionOfUnityAndBoundedEverywhere() {
        for h in stride(from: 0.0, to: 360.0, by: 0.25) {
            let s = TATBandMath.split(hueDegrees: h)
            XCTAssertEqual(s.lowerWeight + s.upperWeight, 1, accuracy: 1e-12)
            XCTAssertGreaterThanOrEqual(s.upperWeight, 0)
            XCTAssertLessThanOrEqual(s.upperWeight, 1)
            XCTAssertTrue((0..<8).contains(s.lowerIndex))
            XCTAssertTrue((0..<8).contains(s.upperIndex))
        }
    }

    func testTheWrapFrom320To0GoesToMagentaAndRed() {
        let s = TATBandMath.split(hueDegrees: 340)
        XCTAssertEqual(s.lowerIndex, 7)      // magenta
        XCTAssertEqual(s.upperIndex, 0)      // red
        XCTAssertEqual(s.upperWeight, 0.5, accuracy: 1e-12)   // smoothstep(0.5) = 0.5
    }

    func testHueNormalisation() {
        XCTAssertEqual(TATBandMath.split(hueDegrees: -20), TATBandMath.split(hueDegrees: 340))
        XCTAssertEqual(TATBandMath.split(hueDegrees: 400), TATBandMath.split(hueDegrees: 40))
    }

    func testDeltaIsSplitInProportionToTheBandWeights() {
        let sliders = [Double](repeating: 0, count: 8)
        let hue = 45.0                       // between orange (30) and yellow (60)
        let out = TATBandMath.applying(delta: 20, hueDegrees: hue, to: sliders)
        let s = TATBandMath.split(hueDegrees: hue)
        // Proportional to the weights...
        XCTAssertEqual(out[s.upperIndex] * s.lowerWeight, out[s.lowerIndex] * s.upperWeight,
                       accuracy: 1e-12)
        // ...and normalised so the sampled pixel moves by exactly `delta`.
        XCTAssertEqual(out[s.lowerIndex], 20 * s.lowerWeight / s.weightNormSquared,
                       accuracy: 1e-12)
        // Every other band untouched.
        for i in 0..<8 where i != s.lowerIndex && i != s.upperIndex {
            XCTAssertEqual(out[i], 0)
        }
    }

    func testOnABandCentreOnlyThatBandMoves() {
        for (i, c) in BWMixBands.centers.enumerated() {
            let out = TATBandMath.applying(delta: 30, hueDegrees: c,
                                           to: [Double](repeating: 0, count: 8))
            XCTAssertEqual(out[i], 30, accuracy: 1e-12, "band \(i)")
            XCTAssertEqual(out.reduce(0, +), 30, accuracy: 1e-12, "band \(i)")
        }
    }

    func testTheAppliedDeltaIsWhatTheShaderWouldSee() {
        // The shader's mix() of the two bracketing sliders must move by exactly
        // `delta` — that is the contract that makes the drag feel 1:1.
        func shaderMix(_ sliders: [Double], hue: Double) -> Double {
            let s = TATBandMath.split(hueDegrees: hue)
            return sliders[s.lowerIndex] * s.lowerWeight + sliders[s.upperIndex] * s.upperWeight
        }
        for hue in stride(from: 0.0, to: 360.0, by: 7.0) {
            let start = [Double](repeating: 0, count: 8)
            let moved = TATBandMath.applying(delta: 12, hueDegrees: hue, to: start)
            XCTAssertEqual(shaderMix(moved, hue: hue) - shaderMix(start, hue: hue), 12,
                           accuracy: 1e-9, "hue \(hue)")
        }
    }

    func testSlidersClampAtPlusMinus100() {
        let sliders = [Double](repeating: 95, count: 8)
        let out = TATBandMath.applying(delta: 50, hueDegrees: 210, to: sliders)
        XCTAssertTrue(out.allSatisfy { $0 <= 100 })
        let down = TATBandMath.applying(delta: -500, hueDegrees: 210, to: sliders)
        XCTAssertTrue(down.allSatisfy { $0 >= -100 })
    }

    func testHueSaturationOfPrimaries() {
        let (rh, rs) = TATBandMath.hueSaturation(linearRGB: (0.5, 0, 0))
        XCTAssertEqual(rh, 0, accuracy: 1e-9)
        XCTAssertEqual(rs, 1, accuracy: 1e-9)
        let (gh, _) = TATBandMath.hueSaturation(linearRGB: (0, 0.5, 0))
        XCTAssertEqual(gh, 120, accuracy: 1e-6)
        let (bh, _) = TATBandMath.hueSaturation(linearRGB: (0, 0, 0.5))
        XCTAssertEqual(bh, 240, accuracy: 1e-6)
        // A neutral has no hue and no saturation, so the tool cannot move it.
        let (_, ns) = TATBandMath.hueSaturation(linearRGB: (0.4, 0.4, 0.4))
        XCTAssertEqual(ns, 0, accuracy: 1e-9)
    }

    func testHueAndSaturationAreExposureInvariant() {
        // The gamma encode is a power function, so a uniform scale factors out:
        // the same subject sampled a stop darker must land on the same bands.
        let base = (0.31, 0.12, 0.04)
        let (h0, s0) = TATBandMath.hueSaturation(linearRGB: base)
        for k in [0.25, 0.5, 2.0, 8.0] {
            let (h, s) = TATBandMath.hueSaturation(linearRGB: (base.0 * k, base.1 * k, base.2 * k))
            XCTAssertEqual(h, h0, accuracy: 1e-6, "scale \(k)")
            XCTAssertEqual(s, s0, accuracy: 1e-6, "scale \(k)")
        }
    }

    func testGammaEncodingIsAppliedBeforeTheHSVDecomposition() {
        // Same construction as `bwMixKernel`: encode with 1/2.2, then HSV. The
        // encoded saturation is lower than the linear one for a dark pixel,
        // which is the observable signature that the encode really happens.
        let linearSat = (0.01 - 0.002) / 0.01
        let (_, encodedSat) = TATBandMath.hueSaturation(linearRGB: (0.01, 0.002, 0.002))
        let expected = (pow(0.01, 1 / 2.2) - pow(0.002, 1 / 2.2)) / pow(0.01, 1 / 2.2)
        XCTAssertEqual(encodedSat, expected, accuracy: 1e-9)
        XCTAssertNotEqual(encodedSat, linearSat, accuracy: 0.05)
    }

    func testDragConversion() {
        XCTAssertEqual(TATBandMath.delta(forDragPixels: 100), 50, accuracy: 1e-12)
        XCTAssertEqual(TATBandMath.delta(forDragPixels: -100), -50, accuracy: 1e-12)
    }

    func testBWMixSubscriptRoundTrip() {
        var mix = EditState.BWMix()
        for i in 0..<8 { mix[band: i] = Double(i) * 10 - 30 }
        XCTAssertEqual(mix.sliderValues, (0..<8).map { Double($0) * 10 - 30 })
        XCTAssertEqual(mix.red, -30)
        XCTAssertEqual(mix.magenta, 40)
        XCTAssertEqual(mix.sliderValues, mix.sliders)   // all within ±100
    }
}
