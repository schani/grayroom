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
    /// Slider unit -> gray gain. 0.008 gives ±0.8 gain at ±100 on a fully
    /// saturated pixel.
    var gainPerUnit: Float
}

struct ToningUniforms {
    var shadowHue: Float
    var shadowSat: Float
    var highlightHue: Float
    var highlightSat: Float
    var balance: Float
    var strength: Float
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
    var invMaxAbs: Float
}

enum StageConstants {
    /// B&W mix authority: ±100 slider -> ±0.8 gray gain at full saturation.
    static let bwGainPerUnit: Float = 0.008
    /// Split-tone authority: saturation 100 -> 0.75 mix toward the pure hue.
    static let toningStrength: Float = 0.75
}
