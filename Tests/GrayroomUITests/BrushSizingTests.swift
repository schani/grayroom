import CoreGraphics
import GrayroomCore
import XCTest
@testable import GrayroomUI

final class BrushSizingTests: XCTestCase {
    let image = CGSize(width: 2560, height: 1707)

    func testDiameterIsAFractionOfTheLongEdge() {
        XCTAssertEqual(BrushSizing.diameterPixels(size: 0.1, imageSize: image), 256, accuracy: 1e-9)
        // Portrait orientation: the long edge is the height.
        let portrait = CGSize(width: 1707, height: 2560)
        XCTAssertEqual(BrushSizing.diameterPixels(size: 0.1, imageSize: portrait), 256,
                       accuracy: 1e-9)
    }

    func testDiameterRoundTrip() {
        for d in [8.0, 55.0, 900.0] {
            let s = BrushSizing.size(forDiameterPixels: d, imageSize: image)
            XCTAssertEqual(BrushSizing.diameterPixels(size: s, imageSize: image), d, accuracy: 1e-6)
        }
        // Outside the size range it clamps rather than round-tripping: a
        // sub-pixel brush is not a brush.
        XCTAssertEqual(BrushSizing.size(forDiameterPixels: 1, imageSize: image),
                       BrushSizing.sizeRange.lowerBound)
        XCTAssertEqual(BrushSizing.size(forDiameterPixels: 99_999, imageSize: image),
                       BrushSizing.sizeRange.upperBound)
    }

    func testScreenRadiusTracksZoom() {
        let fit = CanvasTransform.fitting(imageSize: image, viewSize: CGSize(width: 1600, height: 1200))
        let r = BrushSizing.screenRadius(size: 0.1, transform: fit)
        XCTAssertEqual(r, 128 * fit.zoom, accuracy: 1e-9)
        let zoomed = fit.scaled(by: 2, anchorView: CGPoint(x: 800, y: 600))
        XCTAssertEqual(BrushSizing.screenRadius(size: 0.1, transform: zoomed), 2 * r, accuracy: 1e-9)
    }

    func testInnerRadiusMatchesTheRasteriser() {
        // Hard brush: one pixel of antialiasing, never a jaggy disc.
        XCTAssertEqual(BrushSizing.innerRadius(radius: 20, feather: 0), 19, accuracy: 1e-9)
        // Fully feathered: falloff from the centre.
        XCTAssertEqual(BrushSizing.innerRadius(radius: 20, feather: 100), 0, accuracy: 1e-9)
        XCTAssertEqual(BrushSizing.innerRadius(radius: 20, feather: 50), 10, accuracy: 1e-9)
        // Sub-pixel brush cannot go negative.
        XCTAssertGreaterThanOrEqual(BrushSizing.innerRadius(radius: 0.4, feather: 0), 0)
    }

    func testBracketKeysStepMultiplicativelyAndClamp() {
        let s = BrushSizing.adjustedSize(0.05, steps: 1)
        XCTAssertEqual(s, 0.05 * BrushSizing.sizeStepFactor, accuracy: 1e-12)
        XCTAssertEqual(BrushSizing.adjustedSize(s, steps: -1), 0.05, accuracy: 1e-12)
        XCTAssertEqual(BrushSizing.adjustedSize(0.5, steps: 100), BrushSizing.sizeRange.upperBound)
        XCTAssertEqual(BrushSizing.adjustedSize(0.5, steps: -100), BrushSizing.sizeRange.lowerBound)
    }

    func testFeatherStepsAndClamps() {
        XCTAssertEqual(BrushSizing.adjustedFeather(50, steps: 2), 60, accuracy: 1e-12)
        XCTAssertEqual(BrushSizing.adjustedFeather(98, steps: 1), 100, accuracy: 1e-12)
        XCTAssertEqual(BrushSizing.adjustedFeather(2, steps: -1), 0, accuracy: 1e-12)
    }

    func testPointSpacingIsAQuarterDiameterButNeverSubPixel() {
        XCTAssertEqual(BrushSizing.pointSpacingPixels(size: 0.1, imageSize: image), 64,
                       accuracy: 1e-9)
        XCTAssertEqual(BrushSizing.pointSpacingPixels(size: 0.002, imageSize: CGSize(width: 100, height: 60)),
                       1, accuracy: 1e-9)
    }

    func testShouldAppendUsesImagePixelDistance() {
        // 64 px spacing at size 0.1 on a 2560 px long edge; normalised x step of
        // 0.02 is 51 px (too close), 0.03 is 77 px (far enough).
        let p0 = CGPoint(x: 0.5, y: 0.5)
        XCTAssertFalse(BrushSizing.shouldAppend(point: CGPoint(x: 0.52, y: 0.5), after: p0,
                                                size: 0.1, imageSize: image))
        XCTAssertTrue(BrushSizing.shouldAppend(point: CGPoint(x: 0.53, y: 0.5), after: p0,
                                               size: 0.1, imageSize: image))
        // y is scaled by the *height*, so the same normalised step is a shorter
        // distance on a landscape frame.
        XCTAssertFalse(BrushSizing.shouldAppend(point: CGPoint(x: 0.5, y: 0.53), after: p0,
                                                size: 0.1, imageSize: image))
    }

    func testPressureFallsBackToFullForAMouse() {
        XCTAssertEqual(BrushSizing.normalizedPressure(0), 1)
        XCTAssertEqual(BrushSizing.normalizedPressure(0.5), 0.5)
        XCTAssertEqual(BrushSizing.normalizedPressure(3), 1)
    }
}
