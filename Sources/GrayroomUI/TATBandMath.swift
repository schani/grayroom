import Foundation
import GrayroomCore

/// The band math behind the targeted adjustment tool (drag on the image to move
/// the B&W mixer sliders for the colour under the cursor).
///
/// It has to agree with `BWMix.metal`, because the whole point of the tool is
/// that dragging on a red roof moves whatever slider actually darkens that roof.
/// The shader computes
///
/// ```
/// mixAmount = mix(sliders[j], sliders[j+1], smoothstep(t))
/// ```
///
/// where `j` brackets the pixel's hue in `BWMixBands.centers` and `t` is the
/// position between the two centres. So the sensitivity of `mixAmount` to the
/// two sliders is `(1 − w)` and `w`, with `w = smoothstep(t)`.
///
/// A drag asks for one number (move *this* pixel by `delta`) and has two knobs
/// to do it with, so the system is underdetermined. The choice made here is the
/// **minimum-norm** solution — the smallest pair of slider moves that hits the
/// target exactly:
///
/// ```
/// Δ_lower = delta · (1−w) / ((1−w)² + w²)
/// Δ_upper = delta ·   w   / ((1−w)² + w²)
/// ```
///
/// Two properties fall out, and both are what the tool needs. The moves stay in
/// proportion to the weights, so a hue sitting on a band centre moves that band
/// and nothing else; and `mixAmount` at the sampled hue changes by exactly
/// `delta`, so the drag has the same gain wherever on the hue circle it starts.
/// (The naive `delta · weight` split fails the second one: it delivers only
/// `(1−w)² + w²` of what was asked, i.e. half the gain in the middle of a band.)
public enum TATBandMath {
    /// The two sliders a hue lands between, and how the delta splits.
    public struct Split: Equatable {
        /// Index into `EditState.BWMix.sliders` (0 = red … 7 = magenta).
        public let lowerIndex: Int
        public let upperIndex: Int
        /// Share of the delta going to `upperIndex`; `1 − upperWeight` goes to
        /// `lowerIndex`. Always in `0…1`.
        public let upperWeight: Double

        public var lowerWeight: Double { 1 - upperWeight }

        /// `‖weights‖²`, the normaliser that makes the applied delta exact.
        /// Ranges from 0.5 (mid-band) to 1 (on a centre).
        public var weightNormSquared: Double {
            lowerWeight * lowerWeight + upperWeight * upperWeight
        }

        /// How much each of the two sliders moves for a requested `delta`.
        public func sliderDeltas(for delta: Double) -> (lower: Double, upper: Double) {
            let n = max(weightNormSquared, 1e-9)
            return (delta * lowerWeight / n, delta * upperWeight / n)
        }
    }

    /// Slider units per pixel of vertical drag. A full-scale ±100 move then
    /// takes 200 px of drag, which is about a third of a canvas height.
    public static let unitsPerDragPixel: Double = 0.5

    /// The two bracketing bands for a hue in degrees, matching `grBandMix`.
    public static func split(hueDegrees: Double) -> Split {
        let centers = BWMixBands.centers
        let h = hueDegrees.truncatingRemainder(dividingBy: 360).nonNegativeDegrees
        var j = centers.count - 1
        for i in 0..<(centers.count - 1) where h >= centers[i] && h < centers[i + 1] {
            j = i
            break
        }
        let c0 = centers[j]
        let c1 = (j == centers.count - 1) ? 360.0 : centers[j + 1]
        let t = min(max((h - c0) / (c1 - c0), 0), 1)
        let w = t * t * (3 - 2 * t)          // smoothstep, as in the shader
        return Split(lowerIndex: j, upperIndex: (j + 1) % centers.count, upperWeight: w)
    }

    /// HSV hue (degrees) and saturation of a **linear** RGB triple, computed the
    /// way `bwMixKernel` computes it: gamma-encode with 1/2.2 first, so the hue
    /// of a deep-shadow pixel is the hue you can see rather than the hue the
    /// linear numbers imply.
    public static func hueSaturation(linearRGB rgb: (Double, Double, Double))
        -> (hue: Double, saturation: Double) {
        let r = pow(min(max(rgb.0, 0), 64), 1.0 / 2.2)
        let g = pow(min(max(rgb.1, 0), 64), 1.0 / 2.2)
        let b = pow(min(max(rgb.2, 0), 64), 1.0 / 2.2)
        let mx = max(r, max(g, b))
        let mn = min(r, min(g, b))
        let d = mx - mn
        let sat = mx > 1e-6 ? d / mx : 0
        guard d >= 1e-6 else { return (0, sat) }
        var h: Double
        if mx == r {
            h = ((g - b) / d).truncatingRemainder(dividingBy: 6)
        } else if mx == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        h *= 60
        if h < 0 { h += 360 }
        return (h, sat)
    }

    /// Applies a drag delta to the eight mixer sliders, splitting it between the
    /// two bands that bracket `hueDegrees`. Every slider is clamped to ±100, so
    /// dragging into the stop simply stops.
    public static func applying(delta: Double,
                                hueDegrees: Double,
                                to sliders: [Double]) -> [Double] {
        precondition(sliders.count == 8)
        let s = split(hueDegrees: hueDegrees)
        let d = s.sliderDeltas(for: delta)
        var out = sliders
        out[s.lowerIndex] = (out[s.lowerIndex] + d.lower).clampedToSliderRange
        out[s.upperIndex] = (out[s.upperIndex] + d.upper).clampedToSliderRange
        return out
    }

    /// Convenience for the drag: `dragPixels` is positive when the cursor moves
    /// **up** (brighten, like Lightroom).
    public static func delta(forDragPixels dragPixels: Double) -> Double {
        dragPixels * unitsPerDragPixel
    }
}

extension Double {
    fileprivate var nonNegativeDegrees: Double { self < 0 ? self + 360 : self }
    fileprivate var clampedToSliderRange: Double { Swift.min(Swift.max(self, -100), 100) }
}

// MARK: - Slider array <-> BWMix

extension EditState.BWMix {
    /// The eight sliders **unclamped**, in band order. (`sliders` on the core
    /// type clamps; for round-tripping through the UI we want the raw values.)
    public var sliderValues: [Double] {
        [red, orange, yellow, green, aqua, blue, purple, magenta]
    }

    public mutating func setSliderValues(_ v: [Double]) {
        precondition(v.count == 8)
        red = v[0]; orange = v[1]; yellow = v[2]; green = v[3]
        aqua = v[4]; blue = v[5]; purple = v[6]; magenta = v[7]
    }

    /// A writable accessor by band index, for building eight identical rows of UI.
    public subscript(band index: Int) -> Double {
        get { sliderValues[index] }
        set {
            var v = sliderValues
            v[index] = newValue
            setSliderValues(v)
        }
    }
}
