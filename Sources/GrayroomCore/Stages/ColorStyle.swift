import Foundation

/// What a colour style does, in the four blocks the research decomposes every
/// look into (`research/color-styles.md`): a tone curve, global chroma, an
/// 8-band hue/saturation/luminance table and a split tone.
///
/// Band arrays are in `BWMixBands.names` order — R O Y G Aq B P M.
public struct ColorStyleParameters: Equatable, Sendable {
    /// −100…100, S-curve strength; negative flattens.
    public var contrast: Double
    /// −100…100; positive lifts the black point, negative crushes it.
    public var blacks: Double
    /// 0…100, highlight roll-off.
    public var shoulder: Double
    /// −100…100, global chroma.
    public var saturation: Double
    /// −100…100, chroma weighted toward the low-chroma end.
    public var vibrance: Double
    /// 0…100, darkens saturated colour and leaves neutrals alone.
    public var density: Double
    /// 8 values, degrees, ±45. Positive is toward the next band
    /// (red → orange → yellow …).
    public var bandHue: [Double]
    /// 8 values, −100…100.
    public var bandSaturation: [Double]
    /// 8 values, −100…100. The B&W mixer's gain law, with the colour kept.
    public var bandLuminance: [Double]
    /// As `EditState.Toning`.
    public var shadowHue: Double
    public var shadowSaturation: Double
    public var highlightHue: Double
    public var highlightSaturation: Double
    public var balance: Double

    public init(contrast: Double = 0, blacks: Double = 0, shoulder: Double = 0,
                saturation: Double = 0, vibrance: Double = 0, density: Double = 0,
                bandHue: [Double] = Array(repeating: 0, count: 8),
                bandSaturation: [Double] = Array(repeating: 0, count: 8),
                bandLuminance: [Double] = Array(repeating: 0, count: 8),
                shadowHue: Double = 0, shadowSaturation: Double = 0,
                highlightHue: Double = 0, highlightSaturation: Double = 0,
                balance: Double = 0) {
        self.contrast = contrast
        self.blacks = blacks
        self.shoulder = shoulder
        self.saturation = saturation
        self.vibrance = vibrance
        self.density = density
        self.bandHue = bandHue
        self.bandSaturation = bandSaturation
        self.bandLuminance = bandLuminance
        self.shadowHue = shadowHue
        self.shadowSaturation = shadowSaturation
        self.highlightHue = highlightHue
        self.highlightSaturation = highlightSaturation
        self.balance = balance
    }

    /// Every block off: what `.neutral` would be if it ran a pass.
    public static let identity = ColorStyleParameters()

    /// Every value inside its documented range, and three bands of eight.
    public var isWithinRanges: Bool {
        func inRange(_ v: Double, _ lo: Double, _ hi: Double) -> Bool { v >= lo && v <= hi }
        guard inRange(contrast, -100, 100), inRange(blacks, -100, 100),
              inRange(shoulder, 0, 100), inRange(saturation, -100, 100),
              inRange(vibrance, -100, 100), inRange(density, 0, 100),
              inRange(shadowHue, 0, 360), inRange(shadowSaturation, 0, 100),
              inRange(highlightHue, 0, 360), inRange(highlightSaturation, 0, 100),
              inRange(balance, -100, 100) else { return false }
        guard bandHue.count == 8, bandSaturation.count == 8, bandLuminance.count == 8
        else { return false }
        return bandHue.allSatisfy { inRange($0, -45, 45) }
            && bandSaturation.allSatisfy { inRange($0, -100, 100) }
            && bandLuminance.allSatisfy { inRange($0, -100, 100) }
    }

    /// One style's table, one argument per block. `split` is shadow (hue,
    /// saturation), highlight (hue, saturation), balance.
    private static func table(
        curve: (contrast: Double, blacks: Double, shoulder: Double),
        chroma: (saturation: Double, vibrance: Double, density: Double),
        hue: [Double], sat: [Double], lum: [Double],
        split: (shadow: (Double, Double), highlight: (Double, Double), balance: Double)
            = ((0, 0), (0, 0), 0)
    ) -> ColorStyleParameters {
        ColorStyleParameters(
            contrast: curve.contrast, blacks: curve.blacks, shoulder: curve.shoulder,
            saturation: chroma.saturation, vibrance: chroma.vibrance,
            density: chroma.density,
            bandHue: hue, bandSaturation: sat, bandLuminance: lum,
            shadowHue: split.shadow.0, shadowSaturation: split.shadow.1,
            highlightHue: split.highlight.0, highlightSaturation: split.highlight.1,
            balance: split.balance)
    }

    /// The ten tables. Band columns are R O Y G Aq B P M throughout; each
    /// number is meant to be tunable on its own.
    public static func parameters(for style: EditState.ColorStyle) -> ColorStyleParameters {
        switch style {
        case .neutral:
            return .identity

        case .vividSlide:               // Velvia 50
            return table(curve: (contrast: 100, blacks: -35, shoulder: 65),
                         chroma: (saturation: 8, vibrance: 5, density: 45),
                         hue: [0, 0, 10, 15, 0, 0, 0, 0],
                         sat: [10, 0, 0, 12, 0, 12, 0, 0],
                         lum: [-10, 0, 0, -20, 0, -15, 0, 0],
                         split: (shadow: (120, 5), highlight: (300, 6), balance: 0))

        case .chrome:                  // Kodachrome 64
            return table(curve: (contrast: 80, blacks: -35, shoulder: 40),
                         chroma: (saturation: 5, vibrance: 5, density: 50),
                         hue: [-8, 0, 0, -12, 0, 0, 0, 0],
                         sat: [15, 0, 0, 5, -10, -10, 0, 0],
                         lum: [-10, 0, 0, -10, 0, 0, 0, 0])

        case .mutedChrome:             // Classic Chrome
            return table(curve: (contrast: 70, blacks: -15, shoulder: 35),
                         chroma: (saturation: -30, vibrance: 10, density: 35),
                         hue: [5, -5, 0, -15, 0, -15, 0, 0],
                         sat: [-15, -20, -15, -20, 0, -10, 0, 0],
                         lum: [-10, 0, 0, -5, 0, -15, 0, 0],
                         split: (shadow: (200, 8), highlight: (0, 0), balance: 0))

        case .portraitNegative:        // Portra 400
            return table(curve: (contrast: 15, blacks: 22, shoulder: 50),
                         chroma: (saturation: -5, vibrance: 20, density: 15),
                         hue: [10, 8, 0, -15, 0, 0, 0, 0],
                         sat: [-10, -5, 0, -20, 0, -15, 0, -10],
                         lum: [0, 10, 10, 5, 0, 0, 0, 0],
                         split: (shadow: (40, 8), highlight: (40, 14), balance: 10))

        case .pastelNegative:           // Pro 400H
            return table(curve: (contrast: 5, blacks: 18, shoulder: 45),
                         chroma: (saturation: -18, vibrance: 10, density: 10),
                         hue: [-8, -10, 10, 25, 5, 0, 0, 0],
                         sat: [-15, -15, -10, 0, 15, 15, 0, 0],
                         lum: [0, 0, 0, 15, 10, 10, 0, 0],
                         split: (shadow: (190, 12), highlight: (0, 0), balance: -10))

        case .nostalgicNegative:       // Nostalgic Neg, Gold 200
            return table(curve: (contrast: 25, blacks: 18, shoulder: 35),
                         chroma: (saturation: 25, vibrance: 5, density: 25),
                         hue: [0, 5, 0, -25, 0, 5, 0, 0],
                         sat: [0, 25, 25, 5, -15, -20, 0, 10],
                         lum: [0, 10, 15, -5, 0, -10, 0, 0],
                         split: (shadow: (35, 16), highlight: (40, 14), balance: 0))

        case .retroNegative:            // Classic Neg, Superia X-TRA 400
            return table(curve: (contrast: 80, blacks: -25, shoulder: 55),
                         chroma: (saturation: -30, vibrance: 10, density: 35),
                         hue: [12, 0, 0, -15, 0, -25, 0, -10],
                         sat: [5, 0, 0, 5, 5, 0, 0, 5],
                         lum: [0, 0, 5, -10, 0, -10, 0, 0],
                         split: (shadow: (35, 16), highlight: (200, 12), balance: 0))

        case .softCinema:              // Eterna
            return table(curve: (contrast: -15, blacks: 16, shoulder: 70),
                         chroma: (saturation: -20, vibrance: 15, density: 15),
                         hue: [0, 0, 0, -5, 0, -10, 0, 0],
                         sat: [0, 0, 0, -20, 0, 0, -25, -25],
                         lum: [0, 0, 0, 0, 0, 0, 0, 0])

        case .tealAndOrange:            // the Hollywood grade
            return table(curve: (contrast: 85, blacks: -30, shoulder: 50),
                         chroma: (saturation: -12, vibrance: 10, density: 35),
                         hue: [0, 0, 0, -20, 20, -35, 0, 0],
                         sat: [0, 18, 8, -20, 12, 8, -15, -15],
                         lum: [0, 12, 0, -10, 0, -10, 0, 0],
                         split: (shadow: (200, 22), highlight: (35, 12), balance: -15))

        case .bleachBypass:            // ENR, Eterna Bleach Bypass
            return table(curve: (contrast: 100, blacks: -35, shoulder: 45),
                         chroma: (saturation: -78, vibrance: 0, density: 40),
                         hue: [0, 0, 0, 0, 0, 0, 0, 0],
                         sat: [0, 0, 0, 0, 0, 0, 0, 0],
                         lum: [0, 0, 0, 0, 0, 0, 0, 0],
                         split: (shadow: (210, 8), highlight: (210, 4), balance: 0))
        }
    }
}

/// The CPU mirror of the style curve in `Style.metal`, and the band-luminance
/// gain law. Contrast, the shoulder and blacks act on the **gamma-encoded**
/// value, which is where a pivot and a lifted toe mean what they look like.
public enum ColorStyleCurve {
    /// Encode exponent the curve is defined on.
    public static let gamma = 2.2
    /// Encoded mid grey. Contrast leaves it fixed.
    public static let pivot = pow(0.18, 1 / gamma)
    /// Slope at the pivot at contrast ±100.
    public static let contrastReach = 1.6
    /// Encoded value black reaches at blacks +100.
    public static let blackLift = 0.12
    /// Encoded value that becomes black at blacks −100.
    public static let blackCrush = 0.06
    /// At shoulder 100 the knee sits at `1 − shoulderReach`.
    public static let shoulderReach = 0.5

    /// Contrast, then the shoulder, then blacks, on an encoded 0…1 value.
    ///
    /// Contrast is a power law about the pivot, so it raises the *mean* slope
    /// rather than trading the ends against each other; the price is that it
    /// pushes white past 1, and the shoulder is what pulls it back. Shoulder 0
    /// is a hard clamp.
    public static func apply(encoded e: Double,
                             contrast: Double, blacks: Double, shoulder: Double) -> Double {
        let slope = pow(contrastReach, min(max(contrast, -100), 100) / 100)
        var e = pivot * pow(e / pivot, slope)

        let s = min(max(shoulder, 0), 100) / 100
        if s > 0 {
            let k = 1 - shoulderReach * s
            if e > k { e = k + (1 - k) * (1 - exp(-(e - k) / (1 - k))) }
        }
        e = min(max(e, 0), 1)

        let b = min(max(blacks, -100), 100) / 100
        if b >= 0 {
            e = blackLift * b + e * (1 - blackLift * b)
        } else {
            let crush = blackCrush * (-b)
            e = max(e - crush, 0) / (1 - crush)
        }
        return e
    }

    /// The same curve on a linear value. It acts on the SDR range only:
    /// anything above SDR white is headroom and passes through additively, so
    /// the mapping stays continuous and monotonic.
    public static func applyLinear(_ c: Double,
                                   contrast: Double, blacks: Double, shoulder: Double) -> Double {
        let lo = min(max(c, 0), 1)
        let curved = apply(encoded: pow(lo, 1 / gamma),
                           contrast: contrast, blacks: blacks, shoulder: shoulder)
        return pow(curved, gamma) + (max(c, 0) - lo)
    }

    /// Stops of gain at band luminance ±100 on a fully saturated pixel. Half
    /// the B&W mixer's reach: this one keeps the colour, so it has to stay
    /// inside what the chroma block can follow.
    public static let bandLuminanceEV = 1.5

    /// `2^(bandLuminanceEV · amount/100 · w(sat))`, the mixer's gain law with
    /// the colour kept. The Swift mirror of step 2 of `styleKernel`.
    public static func bandLuminanceGain(amount: Double, saturation: Double) -> Double {
        exp2(bandLuminanceEV * (amount / 100) * BWMixBands.saturationWeight(saturation))
    }
}

/// The CPU mirror of the style stage's chroma block — `grStyleChroma` in
/// `Style.metal` — and the constants it runs on, which travel to the kernel in
/// `StyleUniforms`.
///
/// It works in OKLab: scaling `ab` scales chroma at a fixed hue and a fixed
/// perceptual lightness. Scaling around luminance in linear RGB does neither,
/// and hits the gamut wall on greens around ×1.4.
public enum ColorStyleChroma {
    /// OKLab chroma at which vibrance is half weight.
    public static let vibranceChroma = 0.08
    /// Helmholtz–Kohlrausch coupling: how much of a chroma change comes back
    /// out of `L`, so a pixel keeps the lightness it looked like.
    public static let hkGain = 0.10
    /// Fraction of `L` density 100 takes off a fully saturated colour.
    public static let densityReach = 0.35
    /// OKLab chroma at which density reaches full strength.
    public static let densityChroma = 0.25
    /// Bisection steps of the gamut shrink.
    public static let gamutSteps = 8

    /// Ottosson's linear sRGB → OKLab.
    public static func linearToOKLab(_ rgb: SIMD3<Double>) -> SIMD3<Double> {
        let lms = SIMD3<Double>(
            0.4122214708 * rgb.x + 0.5363325363 * rgb.y + 0.0514459929 * rgb.z,
            0.2119034982 * rgb.x + 0.6806995451 * rgb.y + 0.1073969566 * rgb.z,
            0.0883024619 * rgb.x + 0.2817188376 * rgb.y + 0.6299787005 * rgb.z)
        let c = SIMD3<Double>(cbrt(lms.x), cbrt(lms.y), cbrt(lms.z))
        return SIMD3<Double>(
            0.2104542553 * c.x + 0.7936177850 * c.y - 0.0040720468 * c.z,
            1.9779984951 * c.x - 2.4285922050 * c.y + 0.4505937099 * c.z,
            0.0259040371 * c.x + 0.7827717662 * c.y - 0.8086757660 * c.z)
    }

    /// Its inverse.
    public static func okLabToLinear(_ lab: SIMD3<Double>) -> SIMD3<Double> {
        var c = SIMD3<Double>(
            lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z,
            lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z,
            lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z)
        c *= c * c
        return SIMD3<Double>(
             4.0767416621 * c.x - 3.3077115913 * c.y + 0.2309699292 * c.z,
            -1.2684380046 * c.x + 2.6097574011 * c.y - 0.3413193965 * c.z,
            -0.0041960863 * c.x - 0.7034186147 * c.y + 1.7076147010 * c.z)
    }

    /// The whole block for one pixel whose band values are already resolved:
    /// `hueDegrees` is the band's rotation, `chromaScale` its own multiplier.
    /// `saturation` and `vibrance` are −100…100, `density` 0…100.
    public static func apply(rgb: SIMD3<Double>, hueDegrees: Double, chromaScale: Double,
                             vibrance: Double, saturation: Double,
                             density: Double) -> SIMD3<Double> {
        let lab = linearToOKLab(rgb)
        var ab = SIMD2<Double>(lab.y, lab.z)
        let c = (ab.x * ab.x + ab.y * ab.y).squareRoot()

        if hueDegrees != 0 {
            let th = hueDegrees * .pi / 180
            let cs = cos(th), sn = sin(th)
            ab = SIMD2<Double>(ab.x * cs - ab.y * sn, ab.x * sn + ab.y * cs)
        }

        let w = 1 / (1 + (c / vibranceChroma) * (c / vibranceChroma))
        let k = chromaScale * max(0, 1 + saturation / 100) * (1 + vibrance / 100 * w)
        ab *= k
        let c2 = c * k

        var l = lab.x * (1 + hkGain * c) / (1 + hkGain * c2)
        l *= 1 - densityReach * (density / 100) * min(c2 / densityChroma, 1)

        func toLinear(_ f: Double) -> SIMD3<Double> {
            okLabToLinear(SIMD3<Double>(l, ab.x * f, ab.y * f))
        }
        var out = toLinear(1)
        if out.min() < 0 {
            var lo = 0.0, hi = 1.0
            for _ in 0..<gamutSteps {
                let mid = 0.5 * (lo + hi)
                if toLinear(mid).min() >= 0 { lo = mid } else { hi = mid }
            }
            out = toLinear(lo)
        }
        return SIMD3<Double>(max(out.x, 0), max(out.y, 0), max(out.z, 0))
    }
}
