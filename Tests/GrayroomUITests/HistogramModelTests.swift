import Foundation
import GrayroomCore
import XCTest
@testable import GrayroomUI

final class HistogramModelTests: XCTestCase {
    func makeHistogram(bins: [UInt32], shadow: Int = 0, highlight: Int = 0) -> Histogram {
        Histogram(bins: bins,
                  pixelCount: Int(bins.reduce(0, &+)),
                  shadowClippedPixels: shadow,
                  highlightClippedPixels: highlight)
    }

    func testHeightsAreNormalisedAndBounded() {
        var bins = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 { bins[i] = UInt32(i * 10) }
        let m = HistogramModel(makeHistogram(bins: bins))
        XCTAssertEqual(m.heights.count, 256)
        XCTAssertTrue(m.heights.allSatisfy { $0 >= 0 && $0 <= 1 })
        XCTAssertEqual(m.heights[0], 0, accuracy: 1e-12)
        // The interior peak (bin 254) reaches the top.
        XCTAssertEqual(m.heights[254], 1, accuracy: 1e-12)
        // Monotone input -> monotone plot.
        for i in 1..<255 { XCTAssertGreaterThanOrEqual(m.heights[i], m.heights[i - 1]) }
    }

    func testAHugeClippedSpikeDoesNotFlattenThePlot() {
        var bins = [UInt32](repeating: 100, count: 256)
        bins[255] = 10_000_000          // a blown sky
        let m = HistogramModel(makeHistogram(bins: bins))
        // The interior is normalised against itself, so it still reads full scale.
        XCTAssertEqual(m.heights[128], 1, accuracy: 1e-12)
        // The spike is clamped rather than allowed to set the scale.
        XCTAssertEqual(m.heights[255], 1, accuracy: 1e-12)
    }

    /// The gate is an absolute pixel count, not a fraction: Lightroom's triangles
    /// light on essentially any clipped pixel, and a fraction would make the
    /// preview and the full-resolution export disagree about the same edit.
    func testClipWarningsFireOnAHandfulOfPixels() {
        let bins = [UInt32](repeating: 100, count: 256)   // 25 600 pixels
        XCTAssertEqual(HistogramModel.clipWarningPixels, 32)

        let quiet = HistogramModel(makeHistogram(bins: bins, shadow: 31, highlight: 0))
        XCTAssertFalse(quiet.shadowClipping)
        XCTAssertFalse(quiet.highlightClipping)

        // 32 pixels = 0.125 % of this frame, and 0.00013 % of a 24 MP one: both
        // light the triangle.
        let loud = HistogramModel(makeHistogram(bins: bins, shadow: 32, highlight: 40))
        XCTAssertTrue(loud.shadowClipping)
        XCTAssertTrue(loud.highlightClipping)

        // Resolution independence: the same absolute count on a 100× bigger
        // frame still fires, where the old 0.1 % gate would not have.
        let big = Histogram(bins: [UInt32](repeating: 10_000, count: 256),
                            pixelCount: 2_560_000,
                            shadowClippedPixels: 40, highlightClippedPixels: 0)
        XCTAssertTrue(HistogramModel(big).shadowClipping)
        XCTAssertLessThan(HistogramModel(big).shadowClippedFraction, 0.001)
    }

    func testEmptyHistogramIsSafe() {
        let m = HistogramModel(makeHistogram(bins: [UInt32](repeating: 0, count: 256)))
        XCTAssertTrue(m.heights.allSatisfy { $0 == 0 })
        XCTAssertFalse(m.shadowClipping)
        XCTAssertEqual(HistogramModel.empty.heights.count, 256)
    }

    func testWrongBinCountFallsBackToEmpty() {
        let m = HistogramModel(makeHistogram(bins: [1, 2, 3]))
        XCTAssertEqual(m.heights, HistogramModel.empty.heights)
    }

    /// In HDR the plot's axis runs to the EDR ceiling, so the panel marks where
    /// SDR white fell — everything right of the mark is headroom an SDR export
    /// would clip. The kernel bins `sRGBEncode(Y/W)`, so the mark is
    /// `sRGBEncode(1/W)`: 0.537 at W = 4, i.e. just past the middle of the plot.
    func testSDRWhiteMarkerPosition() {
        XCTAssertNil(HistogramModel.sdrWhiteMarkerPosition(displayWhite: 1))
        XCTAssertNil(HistogramModel.sdrWhiteMarkerPosition(displayWhite: 0.5))

        let atFour = try? XCTUnwrap(HistogramModel.sdrWhiteMarkerPosition(displayWhite: 4))
        XCTAssertEqual(atFour ?? 0, 0.5370, accuracy: 5e-4)
        XCTAssertEqual(HistogramModel.sdrWhiteMarkerPosition(displayWhite: 2) ?? 0,
                       0.7354, accuracy: 5e-4)

        // Monotone: more headroom pushes SDR white further left, never off the
        // plot.
        var previous = 1.0
        for w in stride(from: 1.25, through: 16.0, by: 0.25) {
            let p = HistogramModel.sdrWhiteMarkerPosition(displayWhite: w) ?? 0
            XCTAssertLessThan(p, previous)
            XCTAssertGreaterThan(p, 0)
            previous = p
        }

        // It is the same transfer function the histogram kernel applies.
        XCTAssertEqual(HistogramModel.sRGBEncode(1), 1, accuracy: 1e-12)
        XCTAssertEqual(HistogramModel.sRGBEncode(0), 0, accuracy: 1e-12)
        XCTAssertEqual(HistogramModel.sRGBEncode(0.5), 0.7354, accuracy: 5e-4)
    }
}

final class RenderInvalidationTests: XCTestCase {
    func testWhiteBalanceIsTheOnlyThingThatForcesADecode() {
        var a = EditState()
        var b = a
        XCTAssertEqual(RenderInvalidation.between(a, b), .none)

        b.tone.exposure = 1
        XCTAssertEqual(RenderInvalidation.between(a, b), .pipeline)

        b = a
        b.masks = [Mask(strokes: [Stroke(brush: BrushParams(), polyline: [(0, 0), (1, 1)])])]
        XCTAssertEqual(RenderInvalidation.between(a, b), .pipeline)

        b = a
        b.whiteBalance.temperature = 6500
        XCTAssertEqual(RenderInvalidation.between(a, b), .decode)

        // As-shot (nil) and an explicit value are different states.
        a.whiteBalance.tint = 0
        XCTAssertEqual(RenderInvalidation.between(EditState(), a), .decode)
    }

    func testInvalidationOrdersAndMerges() {
        XCTAssertLessThan(RenderInvalidation.none, RenderInvalidation.pipeline)
        XCTAssertLessThan(RenderInvalidation.pipeline, RenderInvalidation.decode)
        var i = RenderInvalidation.none
        i.merge(.pipeline)
        i.merge(.none)
        XCTAssertEqual(i, .pipeline)
        i.merge(.decode)
        XCTAssertEqual(i, .decode)
    }

    func testDecodeKeyIgnoresEverythingButFileWhiteBalanceAndSize() {
        let url = URL(fileURLWithPath: "/tmp/a.DNG")
        var a = EditState()
        a.tone.exposure = 2
        a.clarity = 50
        let k1 = DecodeKey(url: url, edit: a, maxDimension: 2560)
        let k2 = DecodeKey(url: url, edit: EditState(), maxDimension: 2560)
        XCTAssertEqual(k1, k2)

        var b = EditState()
        b.whiteBalance.temperature = 6500
        XCTAssertNotEqual(DecodeKey(url: url, edit: b, maxDimension: 2560), k2)
        XCTAssertNotEqual(DecodeKey(url: url, edit: a, maxDimension: nil), k1)
        XCTAssertNotEqual(DecodeKey(url: URL(fileURLWithPath: "/tmp/b.DNG"), edit: a,
                                    maxDimension: 2560), k1)
    }
}
