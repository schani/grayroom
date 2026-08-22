import Foundation

/// The tone curve, evaluated on the CPU and baked into a 1-D LUT that the
/// `tone` compute kernel samples.
///
/// The curve lives in **EV space around middle gray**: for a linear luminance
/// `Y`, `x = log2(Y / 0.18)`. It maps `x -> y` and the kernel converts back with
/// `Y' = 0.18 * 2^y`. Working in EV space makes every control a smooth additive
/// offset and makes monotonicity a statement about `dy/dx > 0` that is easy to
/// bound analytically (see README.md).
///
/// Structure (Lightroom-parity wave 1 — see `research/audit/tone.json` and
/// `research/audit/decode-output.json`):
///
/// ```
/// x_r = baseline(x0)                       fixed rendition curve ("the profile")
/// x   = x_r + exposure                     exposure is a pure EV shift
/// y   = x + Δc + Δh + Δs + Δw              zone controls, evaluated on x
/// y   = shoulder(y)                        always-on soft highlight rolloff
/// Y'  = blackPedestal(0.18 · 2^y)          Blacks: a linear-domain pedestal
/// ```
///
/// The **all-zero curve is no longer the identity**: it is `shoulder(baseline(x))`,
/// the documented default rendition. That retires the old
/// "all sliders zero == exact identity" invariant on purpose — Lightroom's zero
/// is not linear either (a camera profile's baseline tone curve is always on).
public enum ToneCurve {
    /// Middle gray in linear scene-referred units.
    public static let pivot: Double = 0.18
    /// LUT domain, in EV relative to `pivot`.
    public static let domainMinEV: Double = -14
    public static let domainMaxEV: Double = 8
    public static let lutSize = 4096

    /// Rec.709 luminance weights (the decoded image has sRGB/Rec.709 primaries).
    public static let luma = (r: 0.2126, g: 0.7152, b: 0.0722)

    /// Display white, in EV above the pivot: `log2(1 / 0.18) = 2.4739`.
    public static let displayWhiteEV: Double = log2(1.0 / 0.18)

    /// The display ceiling `W` an HDR (EDR) render aims at, in linear units
    /// relative to SDR white 1.0. +2 EV of headroom above SDR — comfortably
    /// inside what an XDR panel sustains, and about the range a print-like
    /// rendition can use before speculars stop reading as speculars.
    ///
    /// Mirrored into the shaders as `StageConstants.hdrDisplayWhite`.
    public static let hdrDisplayWhite: Double = 4.0

    /// The ceiling for an edit: SDR white, or the HDR one when `hdr` is set.
    @inline(__always)
    public static func displayWhite(hdr: Bool) -> Double {
        hdr ? hdrDisplayWhite : 1.0
    }

    /// Where a display ceiling `W` sits in EV above the pivot. `W = 1` gives
    /// `displayWhiteEV` exactly.
    @inline(__always)
    public static func displayWhiteEV(displayWhite w: Double) -> Double {
        log2(w / pivot)
    }

    // MARK: - Tuning constants
    //
    // The zone controls (contrast / highlights / shadows / whites) are additive
    // bumps in EV space, so `Σ |dΔ_i/dx| < 1` guarantees a strictly increasing
    // sum. Baseline and shoulder cannot break that: the baseline's derivative is
    // ≥ 0 everywhere and the shoulder's is in (0, 1]. See
    // `ToneCurveTests.testZoneSumSlopeStaysPositive`.

    /// Baseline rendition ("the camera profile"), a fixed S-curve in EV space.
    /// Offsets `baselineLowEV` far below the ramp and `baselineHighEV` far above,
    /// blended with a quintic smootherstep. Fitted to the measured
    /// neutralized-decode -> Apple-default transfer on the repo's Leica DNGs
    /// (research/audit/decode-output.json, deviation #0).
    static let baselineLowEV: Double = -1.0
    static let baselineHighEV: Double = 1.0
    static let baselineRamp: (Double, Double) = (-6.0, 0.8)

    /// Knee of the always-on display shoulder, in EV. Above it the curve
    /// approaches `displayWhiteEV` exponentially, so tone alone never clips.
    static let shoulderKneeEV: Double = 1.4

    /// Peak extra slope contributed by contrast at the pivot.
    static let contrastGain: Double = 0.40
    /// Width (EV) of the contrast bump — peak displacement sits at ±σ, i.e. in
    /// the midtones, not above display white.
    static let contrastSigma: Double = 1.2

    /// Maximum EV shift of the highlight / shadow controls.
    static let highlightRange: Double = 1.3
    static let shadowRange: Double = 1.3
    /// Ramp limits (EV) for the highlight / shadow weights. The 50% point sits
    /// at +1.3 EV (highlights) / −1.3 EV (shadows), matching Lightroom's
    /// histogram zone centres, and the ramp is wide enough that both weights are
    /// still ~22% at middle gray — the LR taper, not a dead band.
    static let zoneRamp: (Double, Double) = (-2.7, 5.3)

    /// Whites: still an additive ramp, but placed inside the displayable range
    /// (50% weight at +2.1 EV = Lightroom's Whites zone centre).
    static let whitesRange: Double = 0.6
    static let whitesRamp: (Double, Double) = (0.8, 3.4)

    /// Blacks: a pedestal in the *output* linear domain. At Blacks −100
    /// everything at or below this luminance is crushed to 0 (2% of white,
    /// −3.17 EV, inside Lightroom's Blacks zone); at Blacks +100 the same amount
    /// is added back as a lift.
    static let blacksPedestal: Double = 0.02

    // MARK: - Curve helpers

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

    // MARK: - Baseline rendition

    /// The fixed baseline tone curve: what the pipeline renders with every
    /// slider at zero. Monotone (its derivative is `1 + something ≥ 0`), so it
    /// can never threaten the curve's monotonicity.
    @inline(__always)
    public static func baselineEV(_ x: Double) -> Double {
        x + baselineLowEV
            + (baselineHighEV - baselineLowEV) * smootherstep(baselineRamp.0, baselineRamp.1, x)
    }

    // MARK: - Display shoulder

    /// Soft highlight shoulder: identity up to the knee, then an exponential
    /// approach to the display ceiling. C¹ at the knee (slope 1 on both sides),
    /// strictly increasing, and asymptotic to linear `W` — so a tone-driven
    /// value never reaches, let alone exceeds, display white.
    ///
    /// The knee is a property of the *curve*, not of the display, so it stays at
    /// 1.4 EV in both modes: an HDR render is the same picture below the knee and
    /// rolls off into more headroom above it.
    @inline(__always)
    public static func shoulderEV(_ y: Double, displayWhite: Double = 1.0) -> Double {
        guard y > shoulderKneeEV else { return y }
        let span = displayWhiteEV(displayWhite: displayWhite) - shoulderKneeEV
        return shoulderKneeEV + span * (1 - exp(-(y - shoulderKneeEV) / span))
    }

    // MARK: - Components
    //
    // The zone controls are independent additive offsets in EV space. They are
    // factored out here because M3's *local* (per-mask) tone deltas cannot go
    // through a LUT — the mask stage produces a different (contrast, highlights,
    // shadows) triple per pixel — so the shader has to evaluate the same
    // components analytically. `Shaders/Tone.metal:grToneDeltaEV` is the direct
    // translation of `toneDeltaEV` below, and `MaskTests` compares them.

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
        return h * highlightRange * smootherstep(zoneRamp.0, zoneRamp.1, x)
    }

    /// Shadows: the mirror of the highlight ramp about `x = 0`. Positive lifts.
    @inline(__always)
    public static func shadowsDeltaEV(_ x: Double, _ shadows: Double) -> Double {
        let s = min(max(shadows, -100), 100) / 100
        guard s != 0 else { return 0 }
        return s * shadowRange * smootherstep(zoneRamp.0, zoneRamp.1, -x)
    }

    /// Whites: an endpoint control reaching further out than highlights, but
    /// still inside what the output transform can display.
    @inline(__always)
    public static func whitesDeltaEV(_ x: Double, _ whites: Double) -> Double {
        let w = min(max(whites, -100), 100) / 100
        guard w != 0 else { return 0 }
        return w * whitesRange * smootherstep(whitesRamp.0, whitesRamp.1, x)
    }

    /// Blacks: a pedestal in the output linear domain, applied *after* the EV
    /// curve because "map to pure black" is not expressible as a bounded EV
    /// offset. Negative crushes (and genuinely reaches 0), positive lifts.
    ///
    /// Monotone non-decreasing, with a saturated toe at negative settings — that
    /// flat run at zero is the deliberate carve-out in the monotonicity tests.
    @inline(__always)
    public static func blackPedestal(_ y: Double, _ blacks: Double) -> Double {
        let b = min(max(blacks, -100), 100) / 100
        guard b != 0 else { return y }
        if b < 0 {
            let p = blacksPedestal * (-b)
            return max(0, y - p) / (1 - p)
        }
        let p = blacksPedestal * b
        return y * (1 - p) + p
    }

    /// The sum of the four additive zone controls, evaluated on an
    /// already-exposed EV value. Kept separate from `evaluateEV` because the
    /// monotonicity budget is a statement about *this* function's slope: the
    /// baseline only ever adds slope and the shoulder only ever scales it by a
    /// positive factor ≤ 1.
    @inline(__always)
    public static func zoneSumEV(_ x: Double, _ tone: EditState.Tone) -> Double {
        x
            + contrastDeltaEV(x, tone.contrast)
            + highlightsDeltaEV(x, tone.highlights)
            + shadowsDeltaEV(x, tone.shadows)
            + whitesDeltaEV(x, tone.whites)
    }

    /// Evaluates the curve in EV space. `x0` is `log2(Y/0.18)` of the *scene*
    /// luminance; the baseline rendition, exposure and the shoulder are all
    /// folded in here so a single LUT covers everything.
    ///
    /// Blacks is **not** part of this function — it is a linear-domain pedestal,
    /// see `blackPedestal` / `evaluateLinear`.
    ///
    /// Returns `log2(Y'/0.18)`.
    public static func evaluateEV(_ x0: Double, _ tone: EditState.Tone,
                                  displayWhite: Double = 1.0) -> Double {
        let t = tone.clamped
        // The baseline is the rendition the image starts from; exposure is a
        // pure EV shift on top of it, so "+1 EV doubles linear luminance" stays
        // exactly true below the shoulder knee. The zone controls are then
        // evaluated on the *exposed, rendered* value, which is also the space
        // Lightroom's histogram zones are defined in.
        let x = baselineEV(x0) + t.exposure
        return shoulderEV(zoneSumEV(x, t), displayWhite: displayWhite)
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
    /// first — baseline, exposure, zones, shoulder and the black pedestal — and
    /// the local delta is applied to its result. Within the delta the ordering
    /// mirrors the global curve — Δexposure is a pure shift in EV space and the
    /// zone controls are evaluated on the shifted value:
    ///
    /// ```
    /// x  = log2(Y/0.18) + Δev
    /// Y' = 0.18 · 2^(x + Δ_c(x) + Δ_h(x) + Δ_s(x))
    /// ```
    ///
    /// The local path does **not** re-apply the shoulder (that would compress
    /// twice), so a large local Δexposure can push a masked highlight past
    /// display white and into the output clamp.
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

    /// Convenience: maps a linear luminance through the whole curve, blacks
    /// included.
    ///
    /// The black pedestal is **absolute**: 0.02 of SDR white in both modes, so
    /// raising the ceiling does not also move the black point.
    public static func evaluateLinear(_ y: Double, _ tone: EditState.Tone,
                                      displayWhite: Double = 1.0) -> Double {
        guard y > 0 else { return 0 }
        let x = log2(y / pivot)
        return blackPedestal(pivot * exp2(evaluateEV(x, tone, displayWhite: displayWhite)),
                             tone.clamped.blacks)
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
    /// monotone, so this pass only ever matters for the flat toe the black
    /// pedestal produces (which it passes through unchanged).
    public static func makeLUT(for tone: EditState.Tone,
                               size: Int = ToneCurve.lutSize,
                               displayWhite: Double = 1.0) -> LUT {
        precondition(size >= 2)
        let blacks = tone.clamped.blacks
        var values = [Float](repeating: 0, count: size)
        var prev = -Double.infinity
        for i in 0..<size {
            let x = domainMinEV + (domainMaxEV - domainMinEV) * Double(i) / Double(size - 1)
            var y = evaluateEV(x, tone, displayWhite: displayWhite)
            if y < prev { y = prev }
            prev = y
            values[i] = Float(blackPedestal(pivot * exp2(y), blacks))
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
