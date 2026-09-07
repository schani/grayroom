import CoreGraphics
import CoreImage
import Foundation
import Metal
import simd

/// What one click of the white balance selector found.
public struct WhiteBalancePick: Equatable, Sendable {
    public let whiteBalance: EditState.WhiteBalance
    /// The 5×5 mean of the sampled area, linear, as decoded with the edit's
    /// current white balance.
    public let sample: SIMD3<Double>

    /// Any channel of the sample at or above `WhiteBalancePicker.clipLevel`:
    /// Lightroom refuses these, because a clipped channel no longer says what
    /// colour the area was.
    public var isClipped: Bool { sample.max() >= WhiteBalancePicker.clipLevel }

    public init(whiteBalance: EditState.WhiteBalance, sample: SIMD3<Double>) {
        self.whiteBalance = whiteBalance
        self.sample = sample
    }
}

/// Lightroom's eyedropper: the temp/tint that render a clicked area neutral.
///
/// Two paths, for the same reason `ImageDecoder` has two. A RAW has an
/// illuminant to name, and `CIRAWFilter` names it itself — `neutralLocation`
/// makes the decoder solve for the white balance that neutralises a point, and
/// `neutralTemperature` / `neutralTint` then read it back in the units the
/// sliders use. A rendered image has no sensor data to reinterpret, so the
/// sample's own chromaticity is converted to a temperature and tint and the
/// relative shift the standard decode path applies is set to it.
public enum WhiteBalancePicker {
    public static let clipLevel = 0.98
    /// A 5×5 mean, as in Lightroom — one pixel of a demosaiced frame is noise.
    static let sampleSide = 5
    /// The sample comes off a small decode: a 5×5 average of a 100 MP frame is
    /// a different question from the one the user asked by clicking.
    static let sampleMaxDimension = 512

    /// - Parameter normalized: (x right, y down) in the oriented image, 0…1 —
    ///   the point the canvas reports.
    public static func pick(url: URL, edit: EditState, normalized: CGPoint,
                            decoder: ImageDecoder) throws -> WhiteBalancePick {
        let p = CGPoint(x: min(max(normalized.x, 0), 1), y: min(max(normalized.y, 0), 1))
        let sample = try mean(url: url, edit: edit, at: p, decoder: decoder)
        if let filter = try ImageDecoder.rawFilter(url: url) {
            return WhiteBalancePick(whiteBalance: rawWhiteBalance(filter, at: p), sample: sample)
        }
        let whiteBalance = try standardWhiteBalance(url: url, edit: edit, at: p,
                                                    asShotSample: sample, decoder: decoder)
        return WhiteBalancePick(whiteBalance: whiteBalance, sample: sample)
    }

    // MARK: - RAW

    /// `neutralLocation` in the **oriented** output image, whose origin Core
    /// Image puts at the bottom left — so the caller's y, which runs down, is
    /// flipped here and nowhere else.
    static func rawWhiteBalance(_ filter: CIRAWFilter, at p: CGPoint) -> EditState.WhiteBalance {
        if let extent = filter.outputImage?.extent, !extent.isEmpty, !extent.isInfinite {
            filter.neutralLocation = CGPoint(
                x: extent.minX + p.x * extent.width,
                y: extent.minY + (1 - p.y) * extent.height)
        }
        return clamped(temperature: Double(filter.neutralTemperature),
                       tint: Double(filter.neutralTint))
    }

    // MARK: - Rendered images

    /// The sample's own temperature and tint, refined against the decode.
    ///
    /// The conversion inverts a chromaticity model; `CITemperatureAndTint`
    /// applies a chromatic adaptation. They agree closely but not exactly, so
    /// a residual cast is measured and added back in mirek/tint space, which is
    /// the space both axes are linear in.
    static func standardWhiteBalance(url: URL, edit: EditState, at p: CGPoint,
                                     asShotSample: SIMD3<Double>,
                                     decoder: ImageDecoder) throws -> EditState.WhiteBalance {
        var probe = edit
        probe.whiteBalance = EditState.WhiteBalance()
        let asShot = edit.whiteBalance == EditState.WhiteBalance()
            ? asShotSample
            : try mean(url: url, edit: probe, at: p, decoder: decoder)

        var result = clamped(sliderValues(for: asShot))
        for _ in 0..<2 {
            probe.whiteBalance = result
            let residual = try mean(url: url, edit: probe, at: p, decoder: decoder)
            guard cast(residual) > 0.01 else { break }
            let shift = sliderValues(for: residual)
            let mirek = 1e6 / (result.temperature ?? ImageDecoder.standardNeutralTemperature)
                + 1e6 / shift.temperature - 1e6 / CorrelatedColorTemperature.d65.temperature
            result = clamped((temperature: 1e6 / mirek, tint: (result.tint ?? 0) + shift.tint))
        }
        return result
    }

    /// Slider values for a linear RGB sample: its own temperature, and its tint
    /// stated relative to D65's so that an already-neutral sample asks for no
    /// correction at all.
    static func sliderValues(for rgb: SIMD3<Double>) -> (temperature: Double, tint: Double) {
        let (x, y) = CorrelatedColorTemperature.chromaticity(linearRGB: rgb)
        let measured = CorrelatedColorTemperature.temperatureAndTint(x: x, y: y)
        return (measured.temperature, measured.tint - CorrelatedColorTemperature.d65.tint)
    }

    /// How far from neutral a sample is, as a fraction.
    static func cast(_ rgb: SIMD3<Double>) -> Double {
        guard rgb.y > 1e-6 else { return 0 }
        return max(abs(rgb.x / rgb.y - 1), abs(rgb.z / rgb.y - 1))
    }

    // MARK: - Sampling

    static func mean(url: URL, edit: EditState, at p: CGPoint,
                     decoder: ImageDecoder) throws -> SIMD3<Double> {
        let decoded = try decoder.decode(url: url, edit: edit, maxDimension: sampleMaxDimension)
        return try mean(decoded.texture, at: p)
    }

    /// The 5×5 mean around a normalized point of a linear texture in image
    /// order. Public so the app's self-test can ask the same question of the
    /// canvas's own render.
    public static func mean(_ texture: MTLTexture, at p: CGPoint) throws -> SIMD3<Double> {
        let radius = sampleSide / 2
        let cx = Int((Double(p.x) * Double(texture.width)).rounded(.down))
        let cy = Int((Double(p.y) * Double(texture.height)).rounded(.down))
        let region = try TextureReadback.readRegion(texture,
                                                    x: cx - radius, y: cy - radius,
                                                    width: sampleSide, height: sampleSide)
        var total = SIMD3<Double>(repeating: 0)
        for i in stride(from: 0, to: region.pixels.count, by: 4) {
            total += SIMD3<Double>(Double(region.pixels[i]),
                                   Double(region.pixels[i + 1]),
                                   Double(region.pixels[i + 2]))
        }
        return total / Double(region.width * region.height)
    }

    static func clamped(temperature: Double, tint: Double) -> EditState.WhiteBalance {
        clamped((temperature, tint))
    }

    static func clamped(_ v: (temperature: Double, tint: Double)) -> EditState.WhiteBalance {
        EditState.WhiteBalance(temperature: min(max(v.temperature, 2000), 50000),
                               tint: min(max(v.tint, -150), 150))
    }
}
