import CoreGraphics
import XCTest
@testable import GrayroomUI

final class CanvasTransformTests: XCTestCase {
    let image = CGSize(width: 2560, height: 1707)
    let view = CGSize(width: 1600, height: 1200)

    func makeFit() -> CanvasTransform {
        CanvasTransform.fitting(imageSize: image, viewSize: view)
    }

    func testFitShowsTheWholeImageCentred() {
        let t = makeFit()
        XCTAssertEqual(t.zoom, 1600.0 / 2560.0, accuracy: 1e-12)
        XCTAssertTrue(t.isFit)
        // The four image corners land inside the view.
        for c in [CGPoint(x: 0, y: 0), CGPoint(x: 2560, y: 0),
                  CGPoint(x: 0, y: 1707), CGPoint(x: 2560, y: 1707)] {
            let v = t.viewPoint(fromImage: c)
            XCTAssertGreaterThanOrEqual(v.x, -0.001)
            XCTAssertLessThanOrEqual(v.x, view.width + 0.001)
            XCTAssertGreaterThanOrEqual(v.y, -0.001)
            XCTAssertLessThanOrEqual(v.y, view.height + 0.001)
        }
        // The image centre is at the view centre.
        let mid = t.viewPoint(fromImage: CGPoint(x: 1280, y: 853.5))
        XCTAssertEqual(mid.x, 800, accuracy: 1e-6)
        XCTAssertEqual(mid.y, 600, accuracy: 1e-6)
    }

    func testFitNeverEnlarges() {
        let t = CanvasTransform.fitting(imageSize: CGSize(width: 100, height: 80),
                                        viewSize: view)
        XCTAssertEqual(t.zoom, 1.0, accuracy: 1e-12)
    }

    func testRoundTripViewImageView() {
        var t = makeFit()
        t = t.scaled(by: 3, anchorView: CGPoint(x: 400, y: 300))
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 1599, y: 1199), CGPoint(x: 733, y: 91)] {
            let back = t.viewPoint(fromImage: t.imagePoint(fromView: p))
            XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
            XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        }
    }

    func testNormalizedCoordinatesMatchTheMaskConvention() {
        let t = makeFit()
        // Top-left image corner -> (0, 0); bottom-right -> (1, 1). y runs down.
        let topLeft = t.viewPoint(fromImage: .zero)
        XCTAssertEqual(t.normalizedPoint(fromView: topLeft).x, 0, accuracy: 1e-9)
        XCTAssertEqual(t.normalizedPoint(fromView: topLeft).y, 0, accuracy: 1e-9)
        let bottomRight = t.viewPoint(fromImage: CGPoint(x: 2560, y: 1707))
        XCTAssertEqual(t.normalizedPoint(fromView: bottomRight).x, 1, accuracy: 1e-9)
        XCTAssertEqual(t.normalizedPoint(fromView: bottomRight).y, 1, accuracy: 1e-9)
        // And the inverse.
        let v = t.viewPoint(fromNormalized: CGPoint(x: 0.25, y: 0.75))
        XCTAssertEqual(t.normalizedPoint(fromView: v).x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(t.normalizedPoint(fromView: v).y, 0.75, accuracy: 1e-9)
    }

    func testZoomIsAnchoredAtTheCursor() {
        let t = makeFit()
        // Pick an anchor away from the centre, and well inside so clamping
        // cannot interfere.
        let anchor = CGPoint(x: 900, y: 650)
        let before = t.imagePoint(fromView: anchor)
        let zoomed = t.scaled(by: 2.5, anchorView: anchor)
        let after = zoomed.imagePoint(fromView: anchor)
        XCTAssertEqual(after.x, before.x, accuracy: 1e-6)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-6)
        XCTAssertEqual(zoomed.zoom, t.zoom * 2.5, accuracy: 1e-9)
    }

    func testZoomIsClampedToTheAllowedRange() {
        let t = makeFit()
        XCTAssertEqual(t.scaled(by: 1e6, anchorView: .zero).zoom, CanvasTransform.maxZoom,
                       accuracy: 1e-9)
        XCTAssertEqual(t.scaled(by: 1e-6, anchorView: .zero).zoom,
                       min(CanvasTransform.minZoom, t.fitZoom), accuracy: 1e-9)
    }

    func testPanMovesTheImageWithTheCursor() {
        var t = makeFit().scaled(by: 4, anchorView: CGPoint(x: 800, y: 600))
        let imageAtCentreBefore = t.imagePoint(fromView: CGPoint(x: 800, y: 600))
        t = t.panned(byViewDelta: CGSize(width: 40, height: 0))
        let imageAtCentreAfter = t.imagePoint(fromView: CGPoint(x: 800, y: 600))
        // Dragging right shows content further left.
        XCTAssertEqual(imageAtCentreAfter.x, imageAtCentreBefore.x - 40 / t.zoom, accuracy: 1e-6)
        XCTAssertEqual(imageAtCentreAfter.y, imageAtCentreBefore.y, accuracy: 1e-6)
    }

    func testPanCannotDragTheImageOffTheView() {
        var t = makeFit().scaled(by: 4, anchorView: CGPoint(x: 800, y: 600))
        for _ in 0..<50 { t = t.panned(byViewDelta: CGSize(width: 500, height: 500)) }
        // The top-left corner of the image cannot get past the top-left of the view.
        let corner = t.viewPoint(fromImage: .zero)
        XCTAssertEqual(corner.x, 0, accuracy: 1e-6)
        XCTAssertEqual(corner.y, 0, accuracy: 1e-6)
        for _ in 0..<100 { t = t.panned(byViewDelta: CGSize(width: -500, height: -500)) }
        let far = t.viewPoint(fromImage: CGPoint(x: image.width, y: image.height))
        XCTAssertEqual(far.x, view.width, accuracy: 1e-6)
        XCTAssertEqual(far.y, view.height, accuracy: 1e-6)
    }

    func testAnAxisSmallerThanTheViewStaysCentred() {
        // At fit, the 1707-tall image is 1000 view px tall in a 1200 px view.
        let t = makeFit().panned(byViewDelta: CGSize(width: 0, height: 300))
        XCTAssertEqual(t.center.y, image.height / 2, accuracy: 1e-9)
        XCTAssertEqual(t.center.x, image.width / 2, accuracy: 1e-9)
    }

    func testDoubleClickTogglesFitAndActualSize() {
        let t = makeFit()
        let anchor = CGPoint(x: 400, y: 300)
        let hundred = t.toggledFitAndActualSize(anchorView: anchor)
        XCTAssertEqual(hundred.zoom, 1.0, accuracy: 1e-12)
        XCTAssertEqual(hundred.zoomPercent, 100, accuracy: 1e-9)
        let back = hundred.toggledFitAndActualSize(anchorView: anchor)
        XCTAssertTrue(back.isFit)
        XCTAssertEqual(back.zoom, t.zoom, accuracy: 1e-12)
    }

    func testResizeKeepsFitFittingAndKeepsZoomOtherwise() {
        let fit = makeFit()
        let bigger = fit.resized(viewSize: CGSize(width: 2000, height: 1400))
        XCTAssertTrue(bigger.isFit)
        XCTAssertEqual(bigger.zoom, 2000.0 / 2560.0, accuracy: 1e-12)

        let zoomed = fit.scaled(by: 4, anchorView: CGPoint(x: 100, y: 100))
        let resized = zoomed.resized(viewSize: CGSize(width: 2000, height: 1400))
        XCTAssertEqual(resized.zoom, zoomed.zoom, accuracy: 1e-12)
    }

    func testContainsImagePoint() {
        let t = makeFit()
        XCTAssertTrue(t.containsImagePoint(view: CGPoint(x: 800, y: 600)))
        // Left of the letterboxed image.
        XCTAssertFalse(t.containsImagePoint(view: CGPoint(x: 0, y: 0)))
    }
}
