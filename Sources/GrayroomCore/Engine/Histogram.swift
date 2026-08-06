import Foundation

/// A 256-bin luminance histogram of the output-referred image plus clipping counts.
public struct Histogram: Equatable, Sendable {
    public let bins: [UInt32]           // 256 entries
    public let pixelCount: Int
    public let shadowClippedPixels: Int
    public let highlightClippedPixels: Int

    public init(bins: [UInt32], pixelCount: Int,
                shadowClippedPixels: Int, highlightClippedPixels: Int) {
        self.bins = bins
        self.pixelCount = pixelCount
        self.shadowClippedPixels = shadowClippedPixels
        self.highlightClippedPixels = highlightClippedPixels
    }

    public var shadowClippedFraction: Double {
        pixelCount > 0 ? Double(shadowClippedPixels) / Double(pixelCount) : 0
    }
    public var highlightClippedFraction: Double {
        pixelCount > 0 ? Double(highlightClippedPixels) / Double(pixelCount) : 0
    }

    /// Mean luminance in 0…1, reconstructed from the bin centres.
    public var meanLuminance: Double {
        guard pixelCount > 0 else { return 0 }
        var acc = 0.0
        for (i, n) in bins.enumerated() {
            acc += (Double(i) + 0.5) / 256.0 * Double(n)
        }
        return acc / Double(pixelCount)
    }

    /// A `rows`-tall ASCII rendering, 64 columns (each column = 4 bins).
    public func asciiPlot(rows: Int = 32, columns: Int = 64) -> String {
        let perColumn = max(1, bins.count / columns)
        var cols = [Double](repeating: 0, count: columns)
        for i in 0..<bins.count {
            cols[min(i / perColumn, columns - 1)] += Double(bins[i])
        }
        let peak = cols.max() ?? 0
        // Log scale keeps both the bulk and the tails readable.
        let scaled = cols.map { peak > 0 ? log1p($0) / log1p(peak) : 0 }

        var out = ""
        for r in stride(from: rows, to: 0, by: -1) {
            let threshold = Double(r - 1) / Double(rows)
            var line = "|"
            for v in scaled {
                line += v > threshold ? "#" : " "
            }
            out += line + "|\n"
        }
        out += "+" + String(repeating: "-", count: columns) + "+\n"
        out += " 0.0" + String(repeating: " ", count: max(0, columns - 10)) + "  1.0\n"
        return out
    }

    public var summary: String {
        String(
            format: "pixels=%d mean=%.4f shadowClipped=%.3f%% highlightClipped=%.3f%%",
            pixelCount, meanLuminance,
            shadowClippedFraction * 100, highlightClippedFraction * 100)
    }
}
