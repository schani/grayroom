import AppKit
import CoreGraphics
import GrayroomCanvas
import GrayroomUI
import XCTest

/// Repro (a): a real click at a known place on a real window must produce the
/// normalised image point the user is *looking at*.
///
/// Every expectation here is stated in user-visible terms — "the visual top of
/// the canvas is the top of the image", "dragging down moves the image down" —
/// and computed from the window layout by hand, never from the code under test.
final class CanvasEventPathTests: XCTestCase {
    private var h: CanvasHarness!
    private let portrait = CGSize(width: 1600, height: 2400)

    override func setUpWithError() throws {
        h = try CanvasHarness()
        h.canvas.setImageSize(portrait)
    }

    override func tearDown() {
        h = nil
        super.tearDown()
    }

    /// Documents the layout the rest of the file reasons about, so a failure
    /// elsewhere cannot be blamed on an unexpected window geometry.
    func testHarnessLayoutIsWhatTheOtherTestsAssume() {
        XCTAssertEqual(h.canvas.bounds.size, CGSize(width: 800, height: 600))
        // Content view of a titled window: origin at the window's bottom-left,
        // the title bar lives above it.
        XCTAssertEqual(h.canvasRectInWindow, CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertTrue(h.canvas.isFlipped)
        XCTAssertGreaterThan(h.scale, 0)
        print("[harness] backingScaleFactor = \(h.scale), backing size = \(h.backingSize)")
        XCTAssertEqual(h.canvas.transform.viewSize, h.backingSize)
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), h.fitZoom(imageSize: portrait))
    }

    func testWindowRoutesClicksToTheCanvas() {
        XCTAssertTrue(h.send(.leftMouseDown, at: h.windowPoint(rightOf: 400, below: 300)),
                      "hit-testing did not land on the canvas — the rest of the suite is void")
        h.send(.leftMouseUp, at: h.windowPoint(rightOf: 400, below: 300))
    }

    // MARK: - Brush coordinates

    /// The heart of the bug report: where does a brush click land?
    func testBrushClickAtVisualTopOfCanvasPaintsAtTopOfImage() {
        h.canvas.tool = .brush
        h.click(rightOf: 400, below: 0)                // visually at the very top
        XCTAssertEqual(h.handler.begins.count, 1)
        let p = h.handler.begins[0].point
        print("[top click] normalized = \(p)")
        XCTAssertLessThan(p.y, 0.02, "a click at the top of the view must paint at the top of the image")
        XCTAssertGreaterThanOrEqual(p.y, -0.005)
        XCTAssertClose(p.x, 0.5, 1e-3)
    }

    func testBrushClickAtVisualBottomOfCanvasPaintsAtBottomOfImage() {
        h.canvas.tool = .brush
        // 599.5, not 600: the canvas rect is half-open, so a click at exactly
        // its bottom edge hit-tests to nothing (verified separately).
        h.click(rightOf: 400, below: 599.5)
        let p = h.handler.begins[0].point
        print("[bottom click] normalized = \(p)")
        XCTAssertGreaterThan(p.y, 0.98, "a click at the bottom of the view must paint at the bottom")
        XCTAssertLessThanOrEqual(p.y, 1.005)
    }

    /// A stroke painted in the visual top-left quadrant must have every one of
    /// its points inside the image's top-left quadrant. This is exactly what the
    /// user did and did not get.
    func testStrokeInVisualTopLeftQuadrantStaysInImageTopLeftQuadrant() {
        h.canvas.tool = .brush
        // Fitted portrait in a 4:3 canvas: the image occupies the middle third
        // horizontally, so "left half of the image" is not "left half of the
        // canvas". Walk a diagonal across the image's top-left quadrant.
        let z = h.fitZoom(imageSize: portrait)
        let drawnW = portrait.width * z / h.scale      // points
        let drawnH = portrait.height * z / h.scale
        let originX = (800 - drawnW) / 2
        let originY = (600 - drawnH) / 2

        var points: [CGPoint] = []
        for t in stride(from: 0.10, through: 0.40, by: 0.05) {
            points.append(CGPoint(x: originX + drawnW * CGFloat(t),
                                  y: originY + drawnH * CGFloat(t)))
        }
        h.send(.leftMouseDown, at: h.windowPoint(rightOf: points[0].x, below: points[0].y))
        for p in points.dropFirst() {
            h.send(.leftMouseDragged, at: h.windowPoint(rightOf: p.x, below: p.y))
        }
        h.send(.leftMouseUp, at: h.windowPoint(rightOf: points.last!.x, below: points.last!.y))

        let all = [h.handler.begins[0].point] + h.handler.extends
        print("[top-left stroke] normalized = \(all.map { (round($0.x * 1000) / 1000, round($0.y * 1000) / 1000) })")
        XCTAssertEqual(all.count, points.count)
        for (i, n) in all.enumerated() {
            XCTAssertGreaterThan(n.x, 0.0, "point \(i) x")
            XCTAssertLessThan(n.x, 0.5, "point \(i) x — must stay in the LEFT half")
            XCTAssertGreaterThan(n.y, 0.0, "point \(i) y")
            XCTAssertLessThan(n.y, 0.5, "point \(i) y — must stay in the TOP half")
        }
        XCTAssertEqual(h.handler.endCount, 1)
    }

    /// Absolute, hand-computed positions across the whole canvas.
    func testClickPositionsMatchHandComputedGeometry() {
        h.canvas.tool = .brush
        let probes: [(CGFloat, CGFloat)] = [
            (0, 0), (799.5, 0), (0, 599.5), (799.5, 599.5),
            (400, 300), (300, 150), (500, 450), (400, 100),
        ]
        for (dx, dy) in probes {
            h.handler.begins.removeAll()
            h.click(rightOf: dx, below: dy)
            let got = h.handler.begins[0].point
            let want = h.expectedNormalizedAtFit(imageSize: portrait, rightOf: dx, below: dy)
            XCTAssertClose(got.x, want.x, 1e-3, "x at (\(dx),\(dy))")
            XCTAssertClose(got.y, want.y, 1e-3, "y at (\(dx),\(dy))")
        }
    }

    /// Monotonicity: no matter what the arithmetic is, moving the mouse *down*
    /// on screen must increase the image y.
    func testNormalizedYIncreasesAsTheMouseMovesDown() {
        h.canvas.tool = .brush
        var ys: [CGFloat] = []
        for dy in stride(from: CGFloat(50), through: 550, by: 50) {
            h.handler.begins.removeAll()
            h.click(rightOf: 400, below: dy)
            ys.append(h.handler.begins[0].point.y)
        }
        for i in 1..<ys.count {
            XCTAssertGreaterThan(ys[i], ys[i - 1], "y must grow downward (step \(i)): \(ys)")
        }
    }

    // MARK: - Pan direction

    func testDraggingDownMovesTheImageDown() {
        // Fit exactly fills the height here, so panning would be clamped away.
        // Double-click to 1:1 first — that is also what a user does.
        h.click(rightOf: 400, below: 300, clickCount: 2)
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), 1, 1e-6)
        let before = h.canvas.transform.center

        h.send(.leftMouseDown, at: h.windowPoint(rightOf: 400, below: 300))
        h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 400, below: 400))  // 100 pt DOWN
        h.send(.leftMouseUp, at: h.windowPoint(rightOf: 400, below: 400))

        let after = h.canvas.transform.center
        print("[pan down] center \(before) -> \(after)")
        // Dragging down drags the image down with the cursor, so the image point
        // sitting under the view centre moves *up* the image.
        XCTAssertLessThan(after.y, before.y,
                          "dragging down must move the image DOWN (centre.y decreases)")
        XCTAssertClose(after.y, before.y - 100 * h.scale, 1e-6)
    }

    func testDraggingUpMovesTheImageUp() {
        h.click(rightOf: 400, below: 300, clickCount: 2)
        let before = h.canvas.transform.center
        h.send(.leftMouseDown, at: h.windowPoint(rightOf: 400, below: 400))
        h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 400, below: 300))  // 100 pt UP
        h.send(.leftMouseUp, at: h.windowPoint(rightOf: 400, below: 300))
        let after = h.canvas.transform.center
        XCTAssertGreaterThan(after.y, before.y)
        XCTAssertClose(after.y, before.y + 100 * h.scale, 1e-6)
    }

    func testDraggingBothAxesOnALandscapeImage() throws {
        let landscape = CGSize(width: 2400, height: 1600)
        h.canvas.setImageSize(landscape)
        h.click(rightOf: 400, below: 300, clickCount: 2)   // fit -> 1:1
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), 1, 1e-6)
        let before = h.canvas.transform.center

        h.send(.leftMouseDown, at: h.windowPoint(rightOf: 400, below: 300))
        h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 450, below: 350))  // right + down
        h.send(.leftMouseUp, at: h.windowPoint(rightOf: 450, below: 350))

        let after = h.canvas.transform.center
        print("[pan landscape] center \(before) -> \(after)")
        XCTAssertLessThan(after.x, before.x, "dragging right must move the image RIGHT")
        XCTAssertLessThan(after.y, before.y, "dragging down must move the image DOWN")
        XCTAssertClose(after.x, before.x - 50 * h.scale, 1e-6)
        XCTAssertClose(after.y, before.y - 50 * h.scale, 1e-6)
    }

    // MARK: - Targeted tool

    func testTargetedDragUpReportsPositivePixels() {
        h.canvas.tool = .targeted
        h.send(.leftMouseDown, at: h.windowPoint(rightOf: 400, below: 300))
        h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 400, below: 200))  // UP
        h.send(.leftMouseUp, at: h.windowPoint(rightOf: 400, below: 200))
        XCTAssertEqual(h.handler.targetedDrags.count, 1)
        XCTAssertGreaterThan(h.handler.targetedDrags[0], 0, "up must brighten")
        XCTAssertClose(CGFloat(h.handler.targetedDrags[0]), 100 * h.scale, 1e-6)
    }
}
