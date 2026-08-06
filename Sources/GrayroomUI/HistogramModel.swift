import Foundation
import GrayroomCore

/// Everything the histogram panel draws, precomputed off the view so it can be
/// unit-tested: the plotted heights and the two clipping warnings.
public struct HistogramModel: Equatable {
    /// 256 values in `0…1`, ready to be turned into a `Path`.
    public let heights: [Double]
    public let shadowClippedFraction: Double
    public let highlightClippedFraction: Double

    /// Lightroom lights its clipping triangles at "a few pixels"; 0.1 % of the
    /// frame is a defensible reading of that and is what PLAN.md asked for.
    public static let clipWarningFraction: Double = 0.001

    public var shadowClipping: Bool { shadowClippedFraction > HistogramModel.clipWarningFraction }
    public var highlightClipping: Bool { highlightClippedFraction > HistogramModel.clipWarningFraction }

    public static let empty = HistogramModel(heights: [Double](repeating: 0, count: 256),
                                             shadowClippedFraction: 0,
                                             highlightClippedFraction: 0)

    public init(heights: [Double], shadowClippedFraction: Double, highlightClippedFraction: Double) {
        self.heights = heights
        self.shadowClippedFraction = shadowClippedFraction
        self.highlightClippedFraction = highlightClippedFraction
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
    }
}
