import Foundation

/// The tone curve, evaluated on the CPU and baked into a 1-D LUT that the
/// `tone` compute kernel samples.
///
/// The curve lives in **EV space around middle gray**: for a linear luminance
/// `Y`, `x = log2(Y / 0.18)`. It maps `x -> y` and the kernel converts back with
/// `Y' = 0.18 * 2^y`. Working in EV space makes every control a smooth additive
/// offset, makes identity trivially `y = x`, and makes monotonicity a statement
/// about `dy/dx > 0` that is easy to bound analytically (see README.md).
public enum ToneCurve {
    /// Middle gray in linear scene-referred units.
    public static let pivot: Double = 0.18
    /// LUT domain, in EV relative to `pivot`.
    public static let domainMinEV: Double = -14
    public static let domainMaxEV: Double = 8
    public static let lutSize = 4096

    /// Rec.709 luminance weights (the decoded image has sRGB/Rec.709 primaries).
    public static let luma = (r: 0.2126, g: 0.7152, b: 0.0722)

    // MARK: - Tuning constants
    //
    // Chosen so that |d(delta)/dx| summed over all five controls stays below 1
    // for every slider combination, which guarantees dy/dx > 0. See
    // `ToneCurveTests.testMonotonicUnderRandomCombos`.

    /// Peak extra slope contributed by contrast at the pivot.
    static let contrastGain: Double = 0.55
    /// Width (EV) of the contrast bump.
    static let contrastSigma: Double = 2.5

    /// Maximum EV shift of the highlight / shadow controls.
    static let highlightRange: Double = 1.2
    static let shadowRange: Double = 1.2
    /// Ramp limits (EV) for the highlight / shadow weights.
    static let highlightRamp: (Double, Double) = (0.25, 4.0)
    static let shadowRamp: (Double, Double) = (-0.25, -4.0)

    /// Maximum EV shift of the whites / blacks controls.
    static let whitesRange: Double = 1.5
    static let blacksRange: Double = 1.5
    static let whitesRamp: (Double, Double) = (1.0, 7.5)
    static let blacksRamp: (Double, Double) = (-1.0, -7.5)

    // MARK: - Curve

    /// Cubic smoothstep, clamped.
    @inline(__always)
    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        guard e1 != e0 else { return x < e0 ? 0 : 1 }
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Quintic smootherstep, clamped. Zero first *and* second derivative at the
    /// endpoints, so the controls blend in without a visible slope break.
    @inline(__always)
    static func smootherstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        guard e1 != e0 else { return x < e0 ? 0 : 1 }
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// Evaluates the curve in EV space. `x` is `log2(Y/0.18)` of the *scene*
    /// luminance; exposure is folded in here so a single LUT covers everything.
    ///
    /// Returns `log2(Y'/0.18)`.
    public static func evaluateEV(_ x0: Double, _ tone: EditState.Tone) -> Double {
        let t = tone.clamped
        // Exposure is a pure shift in EV space; all zone weights are evaluated on
        // the *exposed* image, matching Lightroom's ordering.
        let x = x0 + t.exposure

        let c = t.contrast / 100
        let h = t.highlights / 100
        let s = t.shadows / 100
        let w = t.whites / 100
        let b = t.blacks / 100

        var y = x

        // Contrast: an odd bump x*exp(-x^2/2s^2) adds slope at the pivot and
        // decays to zero far away, so it steepens midtones without moving the
        // extremes. Positive contrast = steeper.
        if c != 0 {
            let u = x / contrastSigma
            y += c * contrastGain * x * exp(-0.5 * u * u)
        }

        // Highlights / shadows: one-sided smootherstep ramps that saturate to a
        // constant EV offset in their zone. +highlights brightens highlights,
        // +shadows lifts shadows (Lightroom sign convention).
        if h != 0 {
            y += h * highlightRange * smootherstep(highlightRamp.0, highlightRamp.1, x)
        }
        if s != 0 {
            // mirror of the highlight ramp about x = 0
            y += s * shadowRange * smootherstep(-shadowRamp.0, -shadowRamp.1, -x)
        }

        // Whites / blacks: endpoint controls with a soft shoulder/toe, reaching
        // further out than highlights/shadows so they act on the extremes.
        if w != 0 {
            y += w * whitesRange * smootherstep(whitesRamp.0, whitesRamp.1, x)
        }
        if b != 0 {
            y += b * blacksRange * smootherstep(-blacksRamp.0, -blacksRamp.1, -x)
        }

        return y
    }

    /// Convenience: maps a linear luminance through the curve.
    public static func evaluateLinear(_ y: Double, _ tone: EditState.Tone) -> Double {
        guard y > 0 else { return 0 }
        let x = log2(y / pivot)
        return pivot * exp2(evaluateEV(x, tone))
    }

    // MARK: - LUT

    public struct LUT {
        /// `size` linear output luminances over `[domainMinEV, domainMaxEV]`.
        public var values: [Float]
        /// Multiplicative gain to apply below the LUT domain.
        public var gainBelow: Float
        /// Multiplicative gain to apply above the LUT domain.
        public var gainAbove: Float
        public var minEV: Float
        public var maxEV: Float

        public var size: Int { values.count }
    }

    /// Builds the LUT. The sampled curve is forced non-decreasing as a final
    /// safety net; with the tuning constants above the analytic curve is already
    /// monotonic, so this pass is a no-op in practice.
    public static func makeLUT(for tone: EditState.Tone, size: Int = ToneCurve.lutSize) -> LUT {
        precondition(size >= 2)
        var values = [Float](repeating: 0, count: size)
        var prev = -Double.infinity
        for i in 0..<size {
            let x = domainMinEV + (domainMaxEV - domainMinEV) * Double(i) / Double(size - 1)
            var y = evaluateEV(x, tone)
            if y < prev { y = prev }
            prev = y
            values[i] = Float(pivot * exp2(y))
        }
        let yMinIn = Float(pivot * exp2(domainMinEV))
        let yMaxIn = Float(pivot * exp2(domainMaxEV))
        return LUT(
            values: values,
            gainBelow: values[0] / yMinIn,
            gainAbove: values[size - 1] / yMaxIn,
            minEV: Float(domainMinEV),
            maxEV: Float(domainMaxEV)
        )
    }

    /// CPU reference for what the kernel does: LUT lookup with linear
    /// interpolation plus the out-of-domain gains.
    public static func applyLUT(_ lut: LUT, toLuminance y: Double) -> Double {
        guard y > 0 else { return 0 }
        let x = log2(y / pivot)
        if x <= Double(lut.minEV) { return y * Double(lut.gainBelow) }
        if x >= Double(lut.maxEV) { return y * Double(lut.gainAbove) }
        let t = (x - Double(lut.minEV)) / (Double(lut.maxEV) - Double(lut.minEV)) * Double(lut.size - 1)
        let i0 = Int(t)
        let i1 = min(i0 + 1, lut.size - 1)
        let f = t - Double(i0)
        return Double(lut.values[i0]) * (1 - f) + Double(lut.values[i1]) * f
    }
}
