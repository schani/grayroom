import Foundation

/// The pure (CPU, testable) half of the clarity stage: the slider mapping, the
/// point-wise remap function it produces, the gamma-level discretisation and the
/// pyramid geometry. `ClarityStage` is the GPU orchestration that uses these.
///
/// Everything here lives in **log2 luminance**: `L = log2(max(Y, eps))`, so a
/// "detail" magnitude is measured in photographic stops and the remap window
/// `sigmaR` is a number of stops. See `README.md` for the full write-up.
public enum ClarityMapping {

    // MARK: - Tuning constants

    /// K: number of discrete gamma levels of the fast local Laplacian
    /// approximation (Aubry et al. 2014). Cost is linear in K.
    ///
    /// 16, not the 8 one might expect, because of how the discretisation
    /// interacts with the remap. Linearising the filter around a local mean
    /// shows that the *effective* fine-detail gain at a pixel whose Gaussian
    /// value sits a fraction `t` of the way between two gamma levels is
    ///
    /// ```
    /// gain(t) = (1−t)·r'(t·step) + t·r'((1−t)·step)
    /// ```
    ///
    /// — the remap's slope is only ever sampled *within one gamma step* of the
    /// grid. So `step / sigmaR` has to be small enough that `r'` is roughly
    /// constant over a step, otherwise clarity strength swings with tone. With
    /// `step = 11/15 = 0.733` stops and `sigmaR = 1.0`, `gain(t)` never drops
    /// below 0.81 of its ideal value; K = 8 would take that to 0.59, and the
    /// classic `x^alpha` remap at K = 8 swings from 2.2x down to 0.91x — i.e.
    /// it would *attenuate* texture over half the tonal range.
    public static let gammaLevelCount = 16

    /// Width of the detail-lift window, in log2 stops. Detail much larger than
    /// this is left alone, which is what keeps strong edges — and the low
    /// frequencies around them — from haloing. The lift is negligible beyond
    /// ~3·sigmaR, so the effective window is ~3 stops — the "sigma_r ≈ 2.5
    /// stops" the milestone asked for, expressed for a soft window instead of a
    /// hard one.
    public static let sigmaR: Double = 1.0

    /// Working log range, in EV relative to middle gray (0.18). The stage runs
    /// after the tone stage, so this brackets the tone-mapped image: −8 EV is
    /// black (sRGB 2/255), +3 EV is past diffuse white even after an exposure
    /// push. Outside it clarity fades out rather than misbehaving — see
    /// `gammaWeight`.
    public static let workingMinEV: Double = -8
    public static let workingMaxEV: Double = 3

    /// alpha at clarity = +100 is `1 − alphaBoostRange`. The remap's fine-detail
    /// slope is `1/alpha`, so +100 means "fine detail ×2.5".
    ///
    /// This is an **endpoint** definition: alpha does not slide with the slider
    /// (see `parameters(for:)`), it is pinned here and `gain` does the
    /// interpolating, which is what makes the response linear.
    public static let alphaBoostRange: Double = 0.6

    /// Midtone weighting of the applied lift (wave 3, audit `clarity-local` #1).
    ///
    /// Lightroom's Clarity is a *midtone* local-contrast control: highlights and
    /// deep shadows are protected, which is why a heavy clarity push does not
    /// blow specular highlights or crush blacks. Ours used to apply the same
    /// lift at every level of the gamma grid.
    ///
    /// The weight is a Gaussian in stops around middle gray with a floor, so
    /// extremes are *attenuated* rather than switched off (a hard zero would put
    /// a visible strength edge across a smooth gradient):
    ///
    /// ```
    /// w(L) = max(toneWeightFloor, exp(−½·((L − log2 0.18) / toneWeightSigmaEV)²))
    /// ```
    ///
    /// σ = 3 EV keeps the whole diffuse range (−2…+2 EV, w ≥ 0.80) near full
    /// strength and only rolls off into the deep shadows and the highlight
    /// shoulder; the floor is reached at ±5.4 EV.
    public static let toneWeightSigmaEV: Double = 3.0
    public static let toneWeightFloor: Double = 0.2

    /// `lift` must stay below this or the remap stops being monotone: the
    /// minimum of `(1−y²)·exp(−y²/2)` is −0.4463 at y = √3.
    public static let maxLift: Double = 1 / 0.4463

    /// Luminance floor before the log. 2^-14 is ~14 stops below 1.0, below the
    /// noise floor of any real capture.
    public static let epsLuminance: Double = 0x1p-14

    /// Safety clamp on the log2 ratio the stage may apply to a pixel.
    public static let maxAppliedStops: Double = 6

    /// Pyramid geometry: halve until the short side would drop below
    /// `minPyramidDimension`, or until `maxPyramidLevels` levels exist.
    public static let minPyramidDimension = 32
    public static let maxPyramidLevels = 8

    /// Per-pyramid-level scale on the lift (wave 3, audit `clarity-local` #2).
    ///
    /// Clarity in Lightroom is the *mid/large-radius* local-contrast control —
    /// Texture is the mid-frequency one and was explicitly engineered to spare
    /// the finest high-frequency content so it does not amplify noise, and
    /// Clarity sits coarser still. Ours lifted every Laplacian level with the
    /// same slope, level 0 included, so at +100 sensor grain was multiplied by
    /// 2.5× exactly like real texture.
    ///
    /// Level 0 is pixel scale (period ≲ 4 px) — that band is now passed through
    /// untouched, level 1 gets 40 %, and everything coarser gets the full lift.
    /// The complementary weights are what a future Texture slider would use.
    public static let levelGains: [Double] = [0.0, 0.4]

    /// The lift scale for pyramid level `l` (1.0 past the end of `levelGains`).
    public static func levelGain(_ l: Int) -> Double {
        l < levelGains.count ? levelGains[l] : 1.0
    }

    // MARK: - Slider mapping

    /// What the clarity slider means to the remap function.
    ///
    /// * `alpha < 1` boosts detail: the remap's slope on fine detail is
    ///   `1 + gain·(1/alpha − 1)`, so `alpha` keeps its usual "detail exponent"
    ///   reading (`1/alpha` is the fine-detail gain).
    /// * `gain` blends the remap with the identity, so `clarity = 0` is
    ///   *exactly* the identity for any alpha.
    /// * The magnitude drives `gain`, so strength is monotone in `clarity`.
    /// * `amount` is the final `mix(L, L_llf, amount)` weight. Since wave 3 the
    ///   pyramid is *always* built at the full-scale lift (see `referenceLift`),
    ///   so the global amount is `clarity/100`; M3 masks replace it with a
    ///   per-pixel texture carrying the same quantity.
    ///
    /// Clarity is **positive only** (0…100). There is no smoothing operator: a
    /// per-mask delta that pushes the effective value below zero simply lands at
    /// amount 0, i.e. the identity.
    public struct Parameters: Equatable, Sendable {
        public var alpha: Double
        public var gain: Double
        public var amount: Double

        /// Coefficient of the detail lift: `r(v) = v + lift·d·exp(−d²/2sigmaR²)`.
        /// Positive boosts, 0 is the identity.
        public var lift: Double { gain * (1 / alpha - 1) }

        /// The remap's slope on infinitesimal detail, `r'(g)`.
        public var detailSlope: Double { 1 + lift }

        /// No pixel moves.
        public var isIdentity: Bool { gain == 0 || amount == 0 }
    }

    /// Maps the 0…100 slider onto the remap parameters. Out-of-range values
    /// clamp, so a negative clarity from an older stored edit is the identity.
    ///
    /// `a = clarity / 100`:
    ///
    /// ```
    /// gain  = a                                   (0 at 0, 1 at 100)
    /// alpha = 1 − alphaBoostRange                 = 0.4, fixed
    /// lift  = gain · (1/alpha − 1)                = 1.5 · a
    /// ```
    ///
    /// **Wave 3 (audit `clarity-local` #0).** `alpha` used to slide with the
    /// slider as well, which made `lift = a·(1/(1 − 0.6a) − 1)` strongly convex:
    /// the detail slope was 1.006 at +10, 1.044 at +25 and 1.214 at +50, i.e.
    /// the first half of the slider did nothing and the whole perceptual range
    /// lived in +60…+100. Lightroom's working range is +10…+25 and Adobe's own
    /// instruction ("increase until you see halos, then back off") only makes
    /// sense if small values already do visible work. Pinning `alpha` at its
    /// endpoint value and letting `gain` interpolate makes `lift` **linear** in
    /// the slider while keeping the endpoint exactly where it was (detail ×2.5
    /// at +100). Slope table: 1.15 at +10, 1.375 at +25, 1.75 at +50, 2.5 at
    /// +100.
    ///
    /// Linearity is not just cosmetic: the whole filter is exactly affine in
    /// `lift` (the pyramid operators and the hat weights are linear and the
    /// weights use the *unremapped* Gaussian pyramid), so a linear slider
    /// response makes `amount = c/100` reproduce each pixel's own strength
    /// exactly — which is what fixes the mask-normalisation bug (audit #6).
    public static func parameters(for clarity: Double) -> Parameters {
        let a = min(max(clarity, 0), 100) / 100
        return Parameters(alpha: 1 - alphaBoostRange, gain: a, amount: a)
    }

    /// The lift the local-Laplacian pyramid is **always** built with;
    /// `parameters(for:).amount` then scales the result per pixel.
    ///
    /// Building at full scale and scaling down afterwards is exactly equivalent
    /// (the filter is affine in `lift`) and it makes the rendition independent
    /// of *which other* clarity values happen to be present in the frame — see
    /// `MaskStage.encodeClarityAmount`.
    public static var referenceLift: Double { parameters(for: 100).lift }

    /// Midtone weight of the applied lift at log2 luminance `l`. CPU reference
    /// for `grClarityToneWeight` in `Clarity.metal`.
    public static func toneWeight(logLuminance l: Double) -> Double {
        let y = (l - log2(0.18)) / toneWeightSigmaEV
        return max(toneWeightFloor, exp(-0.5 * y * y))
    }

    // MARK: - Remap

    /// CPU reference for `grClarityRemap` in `Clarity.metal`:
    ///
    /// ```
    /// r_g(v) = v + lift · d · exp(−d² / 2·sigmaR²),   d = v − g
    /// ```
    ///
    /// A Gaussian-windowed linear lift rather than the classic
    /// `g + sign(d)·sigmaR·(|d|/sigmaR)^alpha`, for two reasons (see README):
    ///
    /// * `alpha`'s derivative is singular at d = 0 and only bounded by an ad-hoc
    ///   clamp, which makes the effective gain swing wildly with tone at any
    ///   affordable K. This form's derivative is flat at d = 0 (quadratic
    ///   maximum), so a coarse gamma grid barely notices.
    /// * `r − v → 0` as |d| grows, and it is C^∞, so there is no slope break
    ///   where a hard `|d| < sigmaR` window would end. Large edges pass through
    ///   untouched, which is the halo-suppression property that matters.
    ///
    /// It is odd in `d` (detail is treated the same up and down), monotone while
    /// `|lift| < maxLift`, and leaves the local mean alone.
    public static func remap(_ v: Double, center g: Double, _ p: Parameters) -> Double {
        let d = v - g
        return v + p.lift * d * exp(-d * d / (2 * sigmaR * sigmaR))
    }

    /// `dr/dv` — the CPU reference used to reason about (and test) the
    /// effective gain of the discretised filter.
    public static func remapSlope(_ v: Double, center g: Double, _ p: Parameters) -> Double {
        let y = (v - g) / sigmaR
        return 1 + p.lift * (1 - y * y) * exp(-y * y / 2)
    }

    /// Effective fine-detail gain for a pixel whose Gaussian-pyramid value sits
    /// a fraction `t` of the way between two gamma levels. Linearising the
    /// filter gives `(1−t)·r'(t·step) + t·r'((1−t)·step)`: the remap's slope is
    /// only ever sampled within one gamma step, which is what fixes K.
    public static func effectiveDetailGain(at t: Double, _ p: Parameters) -> Double {
        let s = gammaStep
        return (1 - t) * remapSlope(t * s, center: 0, p) + t * remapSlope((1 - t) * s, center: 0, p)
    }

    // MARK: - Gamma levels

    /// `g_0 … g_{K−1}`, in log2(Y).
    public static var gammaLevels: [Double] {
        (0..<gammaLevelCount).map { gamma0 + gammaStep * Double($0) }
    }

    public static var gamma0: Double { log2(0.18) + workingMinEV }
    public static var gammaStep: Double {
        (workingMaxEV - workingMinEV) / Double(gammaLevelCount - 1)
    }

    /// Hat weight of level `k`, the CPU reference for `grClarityWeight`. The
    /// weights are a partition of unity over the clamped range, which is what
    /// makes an identity remap reproduce the input exactly.
    public static func gammaWeight(_ v: Double, level k: Int) -> Double {
        let t = min(max((v - gamma0) / gammaStep, 0), Double(gammaLevelCount - 1))
        return max(0, 1 - abs(t - Double(k)))
    }

    // MARK: - Pyramid geometry

    /// Number of pyramid levels (including level 0) for an image of this size.
    public static func pyramidLevelCount(width: Int, height: Int) -> Int {
        var n = 1
        var w = max(width, 1), h = max(height, 1)
        while n < maxPyramidLevels, min(w, h) >= 2 * minPyramidDimension {
            w = (w + 1) / 2
            h = (h + 1) / 2
            n += 1
        }
        return n
    }

    /// Size of pyramid level `level` for a level-0 size of `width x height`.
    public static func levelSize(width: Int, height: Int, level: Int) -> (width: Int, height: Int) {
        var w = max(width, 1), h = max(height, 1)
        for _ in 0..<max(level, 0) {
            w = (w + 1) / 2
            h = (h + 1) / 2
        }
        return (w, h)
    }
}
