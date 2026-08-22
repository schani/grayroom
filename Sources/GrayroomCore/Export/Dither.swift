import Foundation

/// Dither for the 8-bit quantisation step (wave 3, audit `decode-output` #8).
///
/// Lightroom dithers when it quantises to 8 bits, which is why its JPEGs of
/// smooth skies do not band the way naive rounding does. It bites harder here
/// than in a colour app: a monochrome sky has no chroma noise to break up the
/// contours, and the tone/clarity stages are smooth analytic functions that
/// produce very clean gradients — a ramp that spans three output codes over a
/// thousand pixels comes out as three hard bands.
///
/// ## What this does
///
/// Stochastic rounding: the value picks between the two codes that bracket it,
/// with probability equal to its fractional part.
///
/// ```
/// s = clamp(v, 0, 1) · 255
/// out = floor(s) + (u < frac(s) ? 1 : 0),   u ~ U[0, 1)
/// ```
///
/// This is *not* the textbook `round(s + u₁ − u₂)` triangular-PDF dither, and
/// the reason is worth stating: TPDF noise of ±1 LSB moves an exactly
/// representable value to a neighbouring code with probability 1/8 regardless of
/// how exact it is. In a monochrome app that means pure black speckling to 1 and
/// a clipped highlight speckling to 254 — a far worse artefact than the banding
/// it fixes, and one that no amount of clamping to the bracketing pair repairs
/// (a value 1e-7 of a code away still gets the full 1/8).
///
/// Stochastic rounding keeps every property that matters here — the mean is
/// preserved *exactly* (`E[out] = s`), the result never leaves the two
/// bracketing codes, and the choice is uncorrelated between neighbouring pixels,
/// so a contour dissolves into noise — while degenerating gracefully to "do
/// nothing" as the fractional part goes to zero. Its one theoretical cost
/// against TPDF is that the noise power is signal-dependent (variance
/// `frac·(1−frac)`, so it vanishes on exact codes and peaks mid-interval); that
/// modulation is precisely the behaviour wanted at the ends of the scale.
///
/// ## Where it is applied
///
/// At the one 8-bit output point there is: `ImageWriter.makeCGImage`'s 8-bit
/// branch. The canvas draws into an `rgba16Float` drawable, which has no
/// quantisation step to dither at. Deliberately **not** in `outputKernel`
/// either — dithering an output-referred texture would be pointless work, and
/// the value it produces is the one the exporter quantises. Also not in
/// `ImageWriter.writeGray`, which writes data (mask coverage) rather than a
/// picture.
///
/// The noise is a hash of `(x, y, channel)`, so it is deterministic: the same
/// image exports to the same bytes every time and the tests can assert on it.
public enum Dither {

    /// 32-bit integer hash (the "lowbias32" finaliser) of a pixel/channel/draw.
    @inline(__always)
    public static func hash(x: Int, y: Int, channel: Int, salt: UInt32 = 0) -> UInt32 {
        var h = UInt32(truncatingIfNeeded: x) &* 0x0468_2D9B
            ^ UInt32(truncatingIfNeeded: y) &* 0x1276_3F1D
            ^ UInt32(truncatingIfNeeded: channel) &* 0x27D4_EB2F
            ^ salt &* 0x9E37_79B1
        h ^= h >> 16
        h = h &* 0x7FEB_352D
        h ^= h >> 15
        h = h &* 0x846C_A68B
        h ^= h >> 16
        return h
    }

    /// Uniform in `[0, 1)` from a hash word.
    @inline(__always)
    public static func uniform(_ h: UInt32) -> Double { Double(h) * (1.0 / 4_294_967_296.0) }

    /// The dither draw for this pixel and channel, uniform in `[0, 1)`.
    @inline(__always)
    public static func noise(x: Int, y: Int, channel: Int) -> Double {
        uniform(hash(x: x, y: y, channel: channel, salt: 0x51A7))
    }

    /// Quantises `v` (0…1) to an 8-bit code with the dither above.
    @inline(__always)
    public static func quantize8(_ v: Float, x: Int, y: Int, channel: Int) -> UInt8 {
        let s = Double(min(max(v, 0), 1)) * 255
        let lo = s.rounded(.down)
        let step = noise(x: x, y: y, channel: channel) < (s - lo) ? 1.0 : 0.0
        return UInt8(min(lo + step, 255))
    }
}
