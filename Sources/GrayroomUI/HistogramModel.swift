import Foundation
import GrayroomCore

/// Everything the histogram panel draws, precomputed off the view so it can be
/// unit-tested: the plotted heights and the two clipping warnings.
public struct HistogramModel: Equatable {
    /// 256 values in `0…1`, ready to be turned into a `Path`.
    public let heights: [Double]
    public let shadowClippedFraction: Double
    public let highlightClippedFraction: Double
    public let shadowClippedPixels: Int
    public let highlightClippedPixels: Int

    /// Lightroom's triangles light as soon as the image *contains* clipped
    /// pixels — Adobe documents the indicator's colour states but no percentage,
    /// and in practice a handful of blown pixels lights it. That is what makes
    /// "push Whites until the triangle just lights" a usable white-point
    /// procedure.
    ///
    /// Wave 3 (audit `decode-output` #1) replaced a 0.1 %-of-frame gate with an
    /// absolute count. The fraction was both far too high — ~3 000 clipped
    /// pixels on the 2560 px preview, ~24 000 on a 24 MP export, so a small
    /// blown sky patch or a blown light source never lit it — and
    /// resolution-*dependent*, which meant the preview and the export disagreed
    /// about whether the same edit clipped. 32 pixels is "more than a stuck
    /// pixel or a decode artefact, less than anything a photographer would call
    /// clean".
    public static let clipWarningPixels = 32

    public var shadowClipping: Bool { shadowClippedPixels >= HistogramModel.clipWarningPixels }
    public var highlightClipping: Bool { highlightClippedPixels >= HistogramModel.clipWarningPixels }

    public static let empty = HistogramModel(heights: [Double](repeating: 0, count: 256),
                                             shadowClippedFraction: 0,
                                             highlightClippedFraction: 0,
                                             shadowClippedPixels: 0,
                                             highlightClippedPixels: 0)

    public init(heights: [Double],
                shadowClippedFraction: Double,
                highlightClippedFraction: Double,
                shadowClippedPixels: Int = 0,
                highlightClippedPixels: Int = 0) {
        self.heights = heights
        self.shadowClippedFraction = shadowClippedFraction
        self.highlightClippedFraction = highlightClippedFraction
        self.shadowClippedPixels = shadowClippedPixels
        self.highlightClippedPixels = highlightClippedPixels
    }

    /// Linear heights normalised against the **98th percentile** of bins 1…254,
    /// clamped to 1.
    ///
    /// Two things have to be defended against, and a percentile handles both.
    /// Normalising against the true peak lets one spike — a flat sky, or the
    /// clipped bin 0/255 — squash the rest of the plot to nothing. Going log
    /// instead (which is what `Histogram.asciiPlot` does, where it belongs:
    /// 32 rows of ASCII) fixes that but flattens everything toward the top, so a
    /// 3 MP frame reads as a solid block. Linear against a high percentile keeps
    /// the shape readable and only clips the handful of bins above it.
    public init(_ h: Histogram) {
        let bins = h.bins
        guard bins.count == 256 else { self = .empty; return }
        let interior = bins[1..<255].sorted()
        let index = Int((Double(interior.count - 1) * 0.98).rounded(.down))
        let reference = Double(max(interior[index], 1))
        heights = bins.map { min(Double($0) / reference, 1.0) }
        shadowClippedFraction = h.shadowClippedFraction
        highlightClippedFraction = h.highlightClippedFraction
        shadowClippedPixels = h.shadowClippedPixels
        highlightClippedPixels = h.highlightClippedPixels
    }
}
