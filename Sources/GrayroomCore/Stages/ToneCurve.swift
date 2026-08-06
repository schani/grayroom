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

    // MARK: - Components
    //
    // The curve is a sum of independent additive offsets in EV space. They are
    // factored out here because M3's *local* (per-mask) tone deltas cannot go
    // through a LUT — the mask stage produces a different (contrast, highlights,
    // shadows) triple per pixel — so the shader has to evaluate the same
    // components analytically. `Shaders/Tone.metal:grToneDeltaEV` is the direct
    // translation of `toneDeltaEV` below, and `ToneDeltaTests` compares them.

    /// Contrast: an odd bump `x·exp(-x²/2σ²)` adds slope at the pivot and decays
    /// to zero far away, so it steepens midtones without moving the extremes.
    /// Positive contrast = steeper.
    @inline(__always)
    public static func contrastDeltaEV(_ x: Double, _ contrast: Double) -> Double {
        let c = min(max(contrast, -100), 100) / 100
        guard c != 0 else { return 0 }
        let u = x / contrastSigma
        return c * contrastGain * x * exp(-0.5 * u * u)
    }

    /// Highlights: a one-sided smootherstep ramp saturating to a constant EV
    /// offset in the highlight zone. Positive brightens.
    @inline(__always)
    public static func highlightsDeltaEV(_ x: Double, _ highlights: Double) -> Double {
        let h = min(max(highlights, -100), 100) / 100
        guard h != 0 else { return 0 }
        return h * highlightRange * smootherstep(highlightRamp.0, highlightRamp.1, x)
    }

    /// Shadows: the mirror of the highlight ramp about `x = 0`. Positive lifts.
    @inline(__always)
    public static func shadowsDeltaEV(_ x: Double, _ shadows: Double) -> Double {
        let s = min(max(shadows, -100), 100) / 100
        guard s != 0 else { return 0 }
        return s * shadowRange * smootherstep(-shadowRamp.0, -shadowRamp.1, -x)
    }

    /// Whites: an endpoint control with a soft shoulder, reaching further out
    /// than highlights so it acts on the extremes.
    @inline(__always)
    public static func whitesDeltaEV(_ x: Double, _ whites: Double) -> Double {
        let w = min(max(whites, -100), 100) / 100
        guard w != 0 else { return 0 }
        return w * whitesRange * smootherstep(whitesRamp.0, whitesRamp.1, x)
    }

    /// Blacks: the mirror of whites.
    @inline(__always)
    public static func blacksDeltaEV(_ x: Double, _ blacks: Double) -> Double {
        let b = min(max(blacks, -100), 100) / 100
        guard b != 0 else { return 0 }
        return b * blacksRange * smootherstep(-blacksRamp.0, -blacksRamp.1, -x)
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
        return x
            + contrastDeltaEV(x, t.contrast)
            + highlightsDeltaEV(x, t.highlights)
            + shadowsDeltaEV(x, t.shadows)
            + whitesDeltaEV(x, t.whites)
            + blacksDeltaEV(x, t.blacks)
    }

    // MARK: - Local (per-pixel) tone delta

    /// The three curve components a **mask** can drive, summed. The CPU
    /// reference for `grToneDeltaEV` in `Tone.metal`.
    ///
    /// Whites and blacks are deliberately not maskable in v1 (PLAN.md lists
    /// exposure/contrast/highlights/shadows/clarity as the per-mask set).
    public static func toneDeltaEV(_ x: Double,
                                   contrast: Double,
                                   highlights: Double,
                                   shadows: Double) -> Double {
        contrastDeltaEV(x, contrast)
            + highlightsDeltaEV(x, highlights)
            + shadowsDeltaEV(x, shadows)
    }

    /// Applies a **local** tone delta to an already globally-toned luminance.
    ///
    /// Composition order (also documented in README.md): the global LUT runs
    /// first, and the local delta is applied to its result. Within the delta the
    /// ordering mirrors the global curve — Δexposure is a pure shift in EV space
    /// and the zone controls are evaluated on the shifted value:
    ///
    /// ```
    /// x  = log2(Y/0.18) + Δev
    /// Y' = 0.18 · 2^(x + Δ_c(x) + Δ_h(x) + Δ_s(x))
    /// ```
    ///
    /// All-zero deltas return `y` unchanged **bit-for-bit** (not merely to
    /// within rounding) — that early-out is what keeps unmasked pixels identical
    /// to a pre-M3 render, and the shader has the same guard.
    public static func applyToneDelta(_ y: Double,
                                      exposure: Double,
                                      contrast: Double,
                                      highlights: Double,
                                      shadows: Double) -> Double {
        if exposure == 0 && contrast == 0 && highlights == 0 && shadows == 0 { return y }
        guard y > 0 else { return 0 }
        let ev = min(max(exposure, -MaskAdjustments.exposureLimit), MaskAdjustments.exposureLimit)
        let x = log2(y / pivot) + ev
        return pivot * exp2(x + toneDeltaEV(x, contrast: contrast,
                                            highlights: highlights, shadows: shadows))
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
