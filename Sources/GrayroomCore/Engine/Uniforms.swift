import Foundation

// Swift mirrors of the shader uniform structs. Scalar-only layouts, so the
// default Swift struct layout matches Metal's.

struct ToneUniforms {
    var minEV: Float
    var maxEV: Float
    var gainBelow: Float
    var gainAbove: Float
    var lutSize: UInt32
    /// 1 when the `params` texture holds real per-pixel mask deltas. 0 takes the
    /// kernel down exactly the pre-M3 path.
    var hasLocal: UInt32
}

struct BWMixUniforms {
    /// Stops of gray gain at slider ±100 on a fully saturated pixel.
    var maxEV: Float
    /// Exponent on the HSV saturation before it weights the gain.
    var satExponent: Float
    /// Below this saturation the weight ramps linearly instead of following the
    /// exponent, which keeps `d(gain)/d(sat)` bounded near neutral.
    var satKnee: Float
}

struct ToningUniforms {
    var shadowHue: Float
    var shadowSat: Float
    var highlightHue: Float
    var highlightSat: Float
    var balance: Float
    var strength: Float
    /// Half-width, in `t = sqrt(Y)`, of the shadow/highlight crossover.
    var crossoverHalfWidth: Float
    /// 1 = luminance preserved exactly, 0 = raw tint. See `StageConstants`.
    var lumaPreserve: Float
}

/// Mirrors `ClarityUniforms` in `Clarity.metal`. Scalar-only, 4-byte aligned
/// throughout, so the Swift and MSL layouts agree.
struct ClarityUniforms {
    var sigmaR: Float
    var lift: Float
    var gamma0: Float
    var gammaStep: Float
    var center: Float
    var levelIndex: UInt32
    var levelCount: UInt32
    var remapFine: UInt32
}

struct ClarityApplyUniforms {
    var maxStops: Float
    /// Midtone weight: peak, width and floor. See `ClarityMapping.toneWeight`.
    var toneCenter: Float
    var toneSigma: Float
    var toneFloor: Float
}

struct ClarityLevelGainUniforms {
    var levelGain: Float
}

// MARK: - Masks (M3)

/// Mirrors `MaskStamp` in `Mask.metal`: five floats, stride 20.
struct MaskStampGPU {
    var cx: Float
    var cy: Float
    var radius: Float
    var innerRadius: Float
    var alpha: Float
}

struct MaskStrokeUniforms {
    var stampCount: UInt32
    var density: Float
    var erase: UInt32
}

struct MaskAccumulateUniforms {
    var dExposure: Float
    var dContrast: Float
    var dHighlights: Float
    var dShadows: Float
    var dClarity: Float
}

struct MaskClampUniforms {
    var exposureLimit: Float
    var otherLimit: Float
}

struct MaskClarityUniforms {
    var globalClarity: Float
    var dominantSign: Float
    /// 1 / 100 — the **fixed** full-scale reference, not the frame's maximum.
    var invReference: Float
}

/// The B&W mixer's hue band centres, in degrees, in slider order
/// (red, orange, yellow, green, aqua, blue, purple, magenta), plus the
/// slider-to-gain law that goes with them.
///
/// This is the Swift mirror of `kBandCenters` in `BWMix.metal`; the GUI's
/// targeted adjustment tool needs the same band math the shader uses, so the
/// numbers live in exactly one place per language and
/// `GPUStageTests.testBandCentresMatchTheShader` pins them together.
///
/// The three primaries and the three secondaries sit on their exact HSV angles
/// (0/120/240 and 60/180/300); Orange and Purple are the midpoints of the two
/// 60° gaps that would otherwise be unrepresented. Wave 2 moved Purple 280→270
/// and Magenta 320→300 so that a pure magenta pixel lands on the Magenta slider
/// instead of being split 50/50 with Purple (audit `bwmix-toning.json` #5).
/// Adobe does not publish the real centres — this is a documented approximation.
public enum BWMixBands {
    public static let centers: [Double] = [0, 30, 60, 120, 180, 240, 270, 300]

    /// Slider index order matching `EditState.BWMix.sliders`.
    public static let names = ["Red", "Orange", "Yellow", "Green",
                               "Aqua", "Blue", "Purple", "Magenta"]

    /// Stops of gray gain at slider ±100 on a fully saturated pixel.
    public static let maxEV: Double = 3

    /// Exponent applied to HSV saturation before it weights the gain. `< 1`
    /// because the 1/2.2 encode used for the HSV decomposition *lowers*
    /// saturation, so a linear weight leaves ordinary subjects (skies, foliage,
    /// skin) barely responsive — audit `bwmix-toning.json` #0.
    public static let saturationExponent: Double = 0.6

    /// `s^0.6` has an unbounded derivative at `s = 0`, which turns the half-float
    /// quantisation of a near-neutral gradient into visible steps. Below the knee
    /// the weight is the straight line through `(knee, knee^exponent)`, so the
    /// derivative is capped at `knee^(exponent−1)` (≈4.8 at knee 0.02).
    public static let saturationKnee: Double = 0.02

    /// Saturation weight `w(s)`, exactly as `grSatWeight` computes it.
    public static func saturationWeight(_ s: Double) -> Double {
        let s = min(max(s, 0), 1)
        if s >= saturationKnee { return pow(s, saturationExponent) }
        return s * pow(saturationKnee, saturationExponent - 1)
    }

    /// Gray gain for a blended slider value (−100…100) at a given saturation:
    /// `2^(maxEV · mix/100 · w(sat))`. The Swift mirror of `bwMixKernel`.
    public static func gain(mixAmount: Double, saturation: Double) -> Double {
        exp2(maxEV * (mixAmount / 100) * saturationWeight(saturation))
    }
}

/// The split-tone crossover, mirrored from `toningKernel`.
///
/// The two weights are **complementary** across a band of half-width
/// `crossoverHalfWidth` centred on the balance pivot, so `shadow + highlight`
/// is exactly 1 through the midrange and there is no untinted band — before
/// wave 2 they were two independent smoothsteps that were both zero at the
/// pivot (audit `bwmix-toning.json` #1). Both are then faded out at the very
/// ends so extreme black and extreme white stay neutral.
///
/// `GPUStageTests.testToningWeightsMatchTheShader` pins this against the kernel.
public enum ToningWeights {
    /// Half-width of the crossover in `t = sqrt(Y)`. 0.35 approximates
    /// Lightroom's Blending = 50, which is the value legacy Split Toning
    /// settings are remapped onto.
    public static let crossoverHalfWidth: Double = 0.35

    /// Where the crossover sits, for `balance` in −100…100.
    public static func pivot(balance: Double) -> Double {
        min(max(0.5 - 0.35 * (min(max(balance, -100), 100) / 100), 0.08), 0.92)
    }

    /// Quintic smootherstep, clamped — `grSmootherstep` in `Common.metal`.
    static func smootherstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = min(max((x - e0) / max(e1 - e0, 1e-6), 0), 1)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// Shadow and highlight weights at tonal position `t = sqrt(Y)`.
    /// They sum to 1 wherever the endpoint fade is inactive.
    public static func weights(t: Double, balance: Double = 0)
        -> (shadow: Double, highlight: Double) {
        let p = pivot(balance: balance)
        let h = smootherstep(p - crossoverHalfWidth, p + crossoverHalfWidth, t)
        // Cubic smoothstep, as in the shader's endpoint fades.
        func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
            let u = min(max((x - e0) / (e1 - e0), 0), 1)
            return u * u * (3 - 2 * u)
        }
        let fade = smoothstep(0, 0.08, t) * (1 - smoothstep(0.92, 1, t))
        return ((1 - h) * fade, h * fade)
    }
}

enum StageConstants {
    /// Split-tone authority: saturation 100 -> 0.75 mix toward the tint vector.
    static let toningStrength: Float = 0.75
    /// See `ToningWeights.crossoverHalfWidth`.
    static let toningCrossoverHalfWidth = Float(ToningWeights.crossoverHalfWidth)
    /// How much of the tint's luminance excursion is normalised away.
    /// 1 = the exactly-chroma-only stage we had, 0 = the raw tint. 0.5 keeps
    /// about half the excursion, which is the LR-like behaviour Adobe's own
    /// "use Luminance to undo it" guidance implies (audit #2).
    static let toningLumaPreserve: Float = 0.5
}
