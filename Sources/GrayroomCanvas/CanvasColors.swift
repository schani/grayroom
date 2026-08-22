import Foundation

/// The canvas's own colours — the letterbox backdrop, the mask overlay tint —
/// authored as sRGB and decoded to linear.
///
/// They have to be decoded because the drawable is **extended linear sRGB**: the
/// fragment shader hands the window server linear light now, not encoded values,
/// so an sRGB-authored 0.09 written straight through would be drawn as linear
/// 0.09, i.e. roughly three times too bright. Decoding keeps every one of these
/// looking exactly the way it did on the old 8-bit encoded drawable.
///
/// Pure arithmetic, in Swift, interpolated into the shader source, so the two
/// cannot drift and `CanvasColorTests` can pin the numbers.
public enum CanvasColors {
    /// IEC 61966-2-1 sRGB -> linear.
    public static func srgbToLinear(_ c: Double) -> Double {
        let v = min(max(c, 0), 1)
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    /// The backdrop outside the image, as authored (sRGB).
    public static let backdropSRGB: (Double, Double, Double) = (0.09, 0.09, 0.10)
    /// The mask overlay tint, as authored (sRGB).
    public static let overlaySRGB: (Double, Double, Double) = (1.0, 0.15, 0.15)

    public static let backdropLinear = decode(backdropSRGB)
    public static let overlayLinear = decode(overlaySRGB)

    private static func decode(_ c: (Double, Double, Double)) -> (Double, Double, Double) {
        (srgbToLinear(c.0), srgbToLinear(c.1), srgbToLinear(c.2))
    }

    /// `float3(r, g, b)` literal for the shader source.
    static func msl(_ c: (Double, Double, Double)) -> String {
        String(format: "float3(%.8ff, %.8ff, %.8ff)", c.0, c.1, c.2)
    }
}
