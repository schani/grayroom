import Foundation

/// A chromaticity's correlated colour temperature and tint, by Robertson's
/// isotemperature lines — the arithmetic of Adobe's
/// `dng_temperature::Set_xy_coord`, table included.
///
/// The table is 31 isotherms: reciprocal megakelvin (mirek), the locus point in
/// CIE 1960 (u, v), and the isotherm's slope. A coordinate is placed between the
/// two lines it falls between, and the temperature is interpolated *in mirek*,
/// which is the axis the lines are evenly spread on. Tint is the signed distance
/// along the interpolated isotherm, scaled by −3000: positive is a green white
/// point, i.e. the magenta correction Lightroom's slider shows.
public enum CorrelatedColorTemperature {
    private struct Isotherm {
        let r: Double
        let u: Double
        let v: Double
        let t: Double
    }

    private static let table: [Isotherm] = [
        Isotherm(r: 0, u: 0.18006, v: 0.26352, t: -0.24341),
        Isotherm(r: 10, u: 0.18066, v: 0.26589, t: -0.25479),
        Isotherm(r: 20, u: 0.18133, v: 0.26846, t: -0.26876),
        Isotherm(r: 30, u: 0.18208, v: 0.27119, t: -0.28539),
        Isotherm(r: 40, u: 0.18293, v: 0.27407, t: -0.30470),
        Isotherm(r: 50, u: 0.18388, v: 0.27709, t: -0.32675),
        Isotherm(r: 60, u: 0.18494, v: 0.28021, t: -0.35156),
        Isotherm(r: 70, u: 0.18611, v: 0.28342, t: -0.37915),
        Isotherm(r: 80, u: 0.18740, v: 0.28668, t: -0.40955),
        Isotherm(r: 90, u: 0.18880, v: 0.28997, t: -0.44278),
        Isotherm(r: 100, u: 0.19032, v: 0.29326, t: -0.47888),
        Isotherm(r: 125, u: 0.19462, v: 0.30141, t: -0.58204),
        Isotherm(r: 150, u: 0.19962, v: 0.30921, t: -0.70471),
        Isotherm(r: 175, u: 0.20525, v: 0.31647, t: -0.84901),
        Isotherm(r: 200, u: 0.21142, v: 0.32312, t: -1.0182),
        Isotherm(r: 225, u: 0.21807, v: 0.32909, t: -1.2168),
        Isotherm(r: 250, u: 0.22511, v: 0.33439, t: -1.4512),
        Isotherm(r: 275, u: 0.23247, v: 0.33904, t: -1.7298),
        Isotherm(r: 300, u: 0.24010, v: 0.34308, t: -2.0637),
        Isotherm(r: 325, u: 0.24792, v: 0.34655, t: -2.4681),
        Isotherm(r: 350, u: 0.25591, v: 0.34951, t: -2.9641),
        Isotherm(r: 375, u: 0.26400, v: 0.35200, t: -3.5814),
        Isotherm(r: 400, u: 0.27218, v: 0.35407, t: -4.3633),
        Isotherm(r: 425, u: 0.28039, v: 0.35577, t: -5.3762),
        Isotherm(r: 450, u: 0.28863, v: 0.35714, t: -6.7262),
        Isotherm(r: 475, u: 0.29685, v: 0.35823, t: -8.5955),
        Isotherm(r: 500, u: 0.30505, v: 0.35907, t: -11.324),
        Isotherm(r: 525, u: 0.31320, v: 0.35968, t: -15.628),
        Isotherm(r: 550, u: 0.32129, v: 0.36011, t: -23.325),
        Isotherm(r: 575, u: 0.32931, v: 0.36038, t: -40.770),
        Isotherm(r: 600, u: 0.33724, v: 0.36051, t: -116.45),
    ]

    private static let tintScale = -3000.0
    private static let tintLimit = 150.0

    /// D65 — the sRGB white, and the reference the picker states its tint
    /// against so that "no correction" is tint 0.
    public static let d65 = temperatureAndTint(x: 0.3127, y: 0.3290)

    public static func temperatureAndTint(x: Double,
                                          y: Double) -> (temperature: Double, tint: Double) {
        let denominator = 1.5 - x + 6 * y
        guard denominator != 0 else { return (d65.temperature, d65.tint) }
        let u = 2 * x / denominator
        let v = 3 * y / denominator

        var lastDT = 0.0, lastDU = 0.0, lastDV = 0.0
        for index in 1..<table.count {
            // The isotherm's direction, as a unit vector.
            var du = 1.0
            var dv = table[index].t
            var length = (1 + dv * dv).squareRoot()
            du /= length
            dv /= length

            var uu = u - table[index].u
            var vv = v - table[index].v
            // Signed distance from the isotherm.
            var dt = -uu * dv + vv * du
            guard dt <= 0 || index == table.count - 1 else {
                lastDT = dt
                lastDU = du
                lastDV = dv
                continue
            }
            dt = -min(dt, 0)
            let f = index == 1 ? 0 : dt / (lastDT + dt)

            let temperature = 1e6 / (table[index - 1].r * f + table[index].r * (1 - f))
            uu = u - (table[index - 1].u * f + table[index].u * (1 - f))
            vv = v - (table[index - 1].v * f + table[index].v * (1 - f))
            du = du * (1 - f) + lastDU * f
            dv = dv * (1 - f) + lastDV * f
            length = (du * du + dv * dv).squareRoot()
            du /= length
            dv /= length
            let tint = min(max((uu * du + vv * dv) * tintScale, -tintLimit), tintLimit)
            return (temperature, tint)
        }
        return (d65.temperature, d65.tint)
    }

    /// Linear sRGB (Rec.709 primaries, D65) → CIE xy.
    public static func chromaticity(linearRGB rgb: SIMD3<Double>) -> (x: Double, y: Double) {
        let r = max(rgb.x, 0), g = max(rgb.y, 0), b = max(rgb.z, 0)
        let X = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let Y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let Z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        let sum = X + Y + Z
        guard sum > 0 else { return (0.3127, 0.3290) }
        return (X / sum, Y / sum)
    }
}
