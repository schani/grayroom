import CoreGraphics
import Foundation
import GrayroomCore

/// Brush geometry: the conversions between the resolution-independent
/// `BrushParams.size` (diameter as a fraction of the image long edge) and the
/// pixel numbers the cursor and the stroke sampler need.
public enum BrushSizing {
    /// `size` is a *diameter fraction*; below ~0.2 % of the long edge a stamp is
    /// sub-pixel at preview resolution, above 1 it covers the whole frame.
    public static let sizeRange: ClosedRange<Double> = 0.002...1.0
    public static let featherRange: ClosedRange<Double> = 0...100

    /// One press of `[` / `]`. Multiplicative, so the brush feels the same at
    /// every scale; 12 % is about 6 presses per doubling.
    public static let sizeStepFactor: Double = 1.12
    /// One press of shift-`[` / shift-`]`.
    public static let featherStep: Double = 5

    /// Brush diameter in image pixels.
    public static func diameterPixels(size: Double, imageSize: CGSize) -> Double {
        clampSize(size) * Double(max(imageSize.width, imageSize.height))
    }

    /// Inverse of `diameterPixels`, for a "size in px" readout the user can type.
    public static func size(forDiameterPixels d: Double, imageSize: CGSize) -> Double {
        let longEdge = Double(max(imageSize.width, imageSize.height))
        guard longEdge > 0 else { return sizeRange.lowerBound }
        return clampSize(d / longEdge)
    }

    /// Brush radius on screen, in device pixels, at the current canvas zoom.
    /// This is what the cursor ring is drawn from.
    public static func screenRadius(size: Double, transform: CanvasTransform) -> Double {
        diameterPixels(size: size, imageSize: transform.imageSize) * 0.5 * transform.zoom
    }

    /// The inner (full-opacity) radius, i.e. where the falloff starts. Mirrors
    /// `MaskRasterizer`: `inner = min(hardness · radius, radius − 1)`.
    public static func innerRadius(radius: Double, feather: Double) -> Double {
        let hardness = 1 - min(max(feather, 0), 100) / 100
        return max(0, min(hardness * radius, radius - 1))
    }

    /// `[` / `]`: `steps` is signed.
    public static func adjustedSize(_ size: Double, steps: Int) -> Double {
        clampSize(size * pow(sizeStepFactor, Double(steps)))
    }

    /// shift-`[` / shift-`]`.
    public static func adjustedFeather(_ feather: Double, steps: Int) -> Double {
        min(max(feather + featherStep * Double(steps), featherRange.lowerBound),
            featherRange.upperBound)
    }

    public static func clampSize(_ s: Double) -> Double {
        min(max(s, sizeRange.lowerBound), sizeRange.upperBound)
    }

    // MARK: - Stroke sampling

    /// Minimum distance, **in image pixels**, between two authored stroke
    /// points.
    ///
    /// The rasteriser stamps every `0.15 · diameter` along the polyline and
    /// interpolates between authored points, so authoring at a quarter of a
    /// diameter loses nothing visually while keeping the point list — and
    /// therefore the stored edit, the undo snapshot and the O(pixels × stamps)
    /// rasterisation — an order of magnitude smaller than raw mouse events.
    public static func pointSpacingPixels(size: Double, imageSize: CGSize) -> Double {
        max(1, 0.25 * diameterPixels(size: size, imageSize: imageSize))
    }

    /// Should a freshly sampled cursor position become a new stroke point?
    public static func shouldAppend(point: CGPoint,
                                    after previous: CGPoint,
                                    size: Double,
                                    imageSize: CGSize) -> Bool {
        let dx = (point.x - previous.x) * imageSize.width
        let dy = (point.y - previous.y) * imageSize.height
        let spacing = pointSpacingPixels(size: size, imageSize: imageSize)
        return dx * dx + dy * dy >= spacing * spacing
    }

    /// NSEvent pressure is 0 for a mouse and 0…1 for a tablet; a zero would
    /// collapse the stamp radius to nothing, so anything non-positive means
    /// "no tablet, full pressure".
    public static func normalizedPressure(_ raw: Double) -> Double {
        raw > 0.001 ? min(raw, 1) : 1
    }
}
