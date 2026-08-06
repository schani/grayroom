import Foundation

// Swift mirrors of the shader uniform structs. Scalar-only layouts, so the
// default Swift struct layout matches Metal's.

struct ToneUniforms {
    var minEV: Float
    var maxEV: Float
    var gainBelow: Float
    var gainAbove: Float
    var lutSize: UInt32
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

enum StageConstants {
    /// B&W mix authority: ±100 slider -> ±0.8 gray gain at full saturation.
    static let bwGainPerUnit: Float = 0.008
    /// Split-tone authority: saturation 100 -> 0.75 mix toward the pure hue.
    static let toningStrength: Float = 0.75
}
