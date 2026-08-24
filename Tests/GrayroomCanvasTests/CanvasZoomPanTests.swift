import AppKit
import CoreGraphics
import GrayroomCanvas
import GrayroomUI
import XCTest

/// The view→image mapping and the zoom/pan gestures that move it, asserted the
/// way a user states them: "the point under the cursor stays under the cursor",
/// "the image cannot be dragged off its own edge", "the whole picture fits".
///
/// Every expectation is either hand-derived from the window layout or a
/// round-trip, never a second call to the function under test.
final class CanvasZoomPanTests: XCTestCase {
    private var h: CanvasHarness!

    /// Larger than the canvas on both axes at 1:1, so clamping never masks the
    /// behaviour a test is about.
    private let big = CGSize(width: 4000, height: 3000)
    private let portrait = CGSize(width: 1600, height: 2400)
    private let landscape = CGSize(width: 2400, height: 1600)

    override func setUpWithError() throws {
        h = try CanvasHarness()
    }

    override func tearDown() {
        h = nil
        super.tearDown()
    }

    /// Where the canvas says a visual location lands, taken through the real
    /// event path rather than by calling the transform.
    private func normalizedOfClick(rightOf dx: CGFloat, below dy: CGFloat) -> CGPoint {
        h.canvas.tool = .brush
        h.handler.begins.removeAll()
        h.click(rightOf: dx, below: dy)
        return h.handler.begins[0].point
    }

    // MARK: - Coordinate round-trips

    /// For a grid of visual locations, at four zoom/pan states and in both
    /// orientations, a real click reports the normalised point the documented
    /// mapping puts there — and mapping that answer back to the screen returns
    /// the pixel that was clicked.
    func testCoordinateRoundTripsAtEveryZoomAndPanState() {
        let probes: [(CGFloat, CGFloat)] = [
            (0, 0), (799.5, 0), (0, 599.5), (799.5, 599.5),
            (400, 300), (137, 421), (655, 88), (250, 500),
        ]
        for imageSize in [portrait, landscape, big] {
            h.canvas.setImageSize(imageSize)
            let states: [(String, () -> Void)] = [
                ("fit", { self.h.canvas.zoomToFit() }),
                ("1:1", { self.h.canvas.zoomToActualSize() }),
                ("zoomed in at a corner", {
                    self.h.canvas.zoomToActualSize()
                    self.h.magnify(rightOf: 200, below: 150, by: 1.4)
                }),
                ("zoomed out then panned", {
                    self.h.canvas.zoomToActualSize()
                    self.h.magnify(rightOf: 400, below: 300, by: -0.35)
                    self.h.canvas.tool = .pan
                    self.h.drag(through: [(400, 300), (330, 210)])
                }),
            ]
            for (label, apply) in states {
                apply()
                let t = h.canvas.transform
                XCTAssertEqual(t.imageSize, imageSize, "\(imageSize) \(label): image size drifted")
                for (dx, dy) in probes {
                    let got = normalizedOfClick(rightOf: dx, below: dy)
                    let want = h.expectedNormalized(rightOf: dx, below: dy,
                                                    zoom: t.zoom, center: t.center,
                                                    imageSize: imageSize)
                    XCTAssertClose(got.x, want.x, 1e-3, "\(imageSize) \(label) x at (\(dx),\(dy))")
                    XCTAssertClose(got.y, want.y, 1e-3, "\(imageSize) \(label) y at (\(dx),\(dy))")

                    // …and back: the canvas must draw that image point at the
                    // device pixel the click happened on.
                    let back = t.viewPoint(fromNormalized: got)
                    let clicked = h.backingPoint(rightOf: dx, below: dy)
                    XCTAssertClose(back.x, clicked.x, 1e-3,
                                   "\(imageSize) \(label) round-trip x at (\(dx),\(dy))")
                    XCTAssertClose(back.y, clicked.y, 1e-3,
                                   "\(imageSize) \(label) round-trip y at (\(dx),\(dy))")
                }
            }
        }
    }

    /// Orientation, with no arithmetic on the expectation side: whatever the
    /// zoom and pan, the left half of the canvas is a smaller image x than the
    /// right half, and the top a smaller image y than the bottom.
    func testUpIsUpAndLeftIsLeftInEveryState() {
        for imageSize in [portrait, landscape] {
            h.canvas.setImageSize(imageSize)
            for (label, apply): (String, () -> Void) in [
                ("fit", { self.h.canvas.zoomToFit() }),
                ("1:1", { self.h.canvas.zoomToActualSize() }),
                ("pinched in", {
                    self.h.canvas.zoomToActualSize()
                    self.h.magnify(rightOf: 400, below: 300, by: 1.2)
                }),
            ] {
                apply()
                let left = normalizedOfClick(rightOf: 100, below: 300)
                let right = normalizedOfClick(rightOf: 700, below: 300)
                let top = normalizedOfClick(rightOf: 400, below: 60)
                let bottom = normalizedOfClick(rightOf: 400, below: 540)
                XCTAssertLessThan(left.x, right.x, "\(imageSize) \(label): left must be left")
                XCTAssertLessThan(top.y, bottom.y, "\(imageSize) \(label): up must be up")
                XCTAssertClose(left.y, right.y, 1e-6, "\(imageSize) \(label): no shear")
                XCTAssertClose(top.x, bottom.x, 1e-6, "\(imageSize) \(label): no shear")
            }
        }
    }

    /// At fit the drawn image's own corners are the image's corners — the
    /// letterbox is derived from the layout, not from the transform.
    func testFittedImageCornersMapToTheImageCorners() {
        for imageSize in [portrait, landscape] {
            h.canvas.setImageSize(imageSize)
            h.canvas.zoomToFit()
            let z = h.fitZoom(imageSize: imageSize)
            let drawnW = imageSize.width * z / h.scale        // points
            let drawnH = imageSize.height * z / h.scale
            let originX = (800 - drawnW) / 2
            let originY = (600 - drawnH) / 2

            let topLeft = normalizedOfClick(rightOf: originX, below: originY)
            XCTAssertClose(topLeft.x, 0, 1e-3, "\(imageSize) top-left x")
            XCTAssertClose(topLeft.y, 0, 1e-3, "\(imageSize) top-left y")

            let bottomRight = normalizedOfClick(rightOf: originX + drawnW - 0.5,
                                                below: originY + drawnH - 0.5)
            XCTAssertClose(bottomRight.x, 1, 2e-3, "\(imageSize) bottom-right x")
            XCTAssertClose(bottomRight.y, 1, 2e-3, "\(imageSize) bottom-right y")
        }
    }

    // MARK: - Zoom to fit / 1:1

    func testZoomToFitShowsTheWholeImageCentred() {
        for imageSize in [portrait, landscape, big] {
            h.canvas.setImageSize(imageSize)
            h.canvas.zoomToActualSize()
            h.drag(through: [(400, 300), (100, 100)])       // wander off centre
            h.canvas.zoomToFit()
            let t = h.canvas.transform
            XCTAssertClose(CGFloat(t.zoom), h.fitZoom(imageSize: imageSize), 1e-9,
                           "\(imageSize) fit zoom")
            XCTAssertClose(t.center.x, imageSize.width / 2, 1e-9, "\(imageSize) centre x")
            XCTAssertClose(t.center.y, imageSize.height / 2, 1e-9, "\(imageSize) centre y")
            // Both corners of the image are on screen, which is what "fit" means.
            let tl = t.viewPoint(fromImage: .zero)
            let br = t.viewPoint(fromImage: CGPoint(x: imageSize.width, y: imageSize.height))
            XCTAssertGreaterThanOrEqual(tl.x, -1e-6)
            XCTAssertGreaterThanOrEqual(tl.y, -1e-6)
            XCTAssertLessThanOrEqual(br.x, h.backingSize.width + 1e-6)
            XCTAssertLessThanOrEqual(br.y, h.backingSize.height + 1e-6)
        }
    }

    /// 1:1 is one image pixel per device pixel: a 100-device-pixel step across
    /// the screen is a 100-pixel step across the image.
    func testZoomToActualSizeIsOneImagePixelPerDevicePixel() {
        h.canvas.setImageSize(big)
        h.canvas.zoomToActualSize()
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), 1, 1e-12)

        let a = normalizedOfClick(rightOf: 300, below: 200)
        let b = normalizedOfClick(rightOf: 350, below: 240)   // +50 pt = +100 device px
        XCTAssertClose((b.x - a.x) * big.width, 100, 1e-6)
        XCTAssertClose((b.y - a.y) * big.height, 80, 1e-6)
    }

    /// Going to 1:1 from the fitted view keeps the middle of the picture in the
    /// middle of the screen — the anchor is the view centre.
    func testZoomToActualSizeAnchorsOnTheViewCentre() {
        h.canvas.setImageSize(big)
        h.canvas.zoomToFit()
        let before = normalizedOfClick(rightOf: 400, below: 300)
        h.canvas.zoomToActualSize()
        let after = normalizedOfClick(rightOf: 400, below: 300)
        XCTAssertClose(after.x, before.x, 1e-9)
        XCTAssertClose(after.y, before.y, 1e-9)
    }

    // MARK: - Zoom at the cursor

    /// A pinch keeps the picture under the fingers under the fingers.
    func testMagnifyKeepsThePointUnderTheCursorFixed() {
        h.canvas.setImageSize(big)
        h.canvas.zoomToActualSize()
        for (dx, dy) in [(CGFloat(200), CGFloat(150)), (600, 450), (400, 300)] {
            let before = normalizedOfClick(rightOf: dx, below: dy)
            let zoomBefore = h.canvas.transform.zoom
            h.magnify(rightOf: dx, below: dy, by: 0.5)
            XCTAssertClose(CGFloat(h.canvas.transform.zoom), CGFloat(zoomBefore * 1.5), 1e-9,
                           "pinch must multiply the zoom by 1 + magnification")
            let after = normalizedOfClick(rightOf: dx, below: dy)
            XCTAssertClose(after.x, before.x, 1e-6, "pinch moved the image under the cursor (x)")
            XCTAssertClose(after.y, before.y, 1e-6, "pinch moved the image under the cursor (y)")
            h.canvas.zoomToActualSize()
        }
    }

    /// A pinch out shrinks by the same rule.
    func testMagnifyOutShrinksAndStillAnchors() {
        h.canvas.setImageSize(big)
        h.canvas.zoomToActualSize()
        let before = normalizedOfClick(rightOf: 400, below: 300)
        h.magnify(rightOf: 400, below: 300, by: -0.25)
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), 0.75, 1e-9)
        let after = normalizedOfClick(rightOf: 400, below: 300)
        XCTAssertClose(after.x, before.x, 1e-6)
        XCTAssertClose(after.y, before.y, 1e-6)
    }

    /// Command-scroll is the mouse-wheel zoom, and it anchors the same way.
    func testCommandScrollZoomsAtTheCursor() {
        h.canvas.setImageSize(big)
        h.canvas.zoomToActualSize()
        let before = normalizedOfClick(rightOf: 250, below: 180)
        h.scroll(rightOf: 250, below: 180, deltaY: 20, precise: true, modifiers: .command)
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), CGFloat(exp(20 * 0.01)), 1e-9,
                       "precise command-scroll: zoom *= exp(dy/100)")
        let after = normalizedOfClick(rightOf: 250, below: 180)
        XCTAssertClose(after.x, before.x, 1e-6)
        XCTAssertClose(after.y, before.y, 1e-6)
    }

    /// A notched wheel reports far coarser deltas, so it gets a 4x gain.
    func testCommandScrollWithACoarseWheelGetsTheLineGain() {
        h.canvas.setImageSize(big)
        h.canvas.zoomToActualSize()
        h.scroll(rightOf: 400, below: 300, deltaY: 3, precise: false, modifiers: .command)
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), CGFloat(exp(3 * 4 * 0.01)), 1e-9)
    }

    /// Scrolling down (negative dy) zooms out.
    func testCommandScrollDownZoomsOut() {
        h.canvas.setImageSize(big)
        h.canvas.zoomToActualSize()
        h.scroll(rightOf: 400, below: 300, deltaY: -30, precise: true, modifiers: .command)
        XCTAssertLessThan(h.canvas.transform.zoom, 1)
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), CGFloat(exp(-0.3)), 1e-9)
    }

    /// The zoom stops: a pinch cannot go past the documented limits.
    func testZoomIsClampedToTheAllowedRange() {
        h.canvas.setImageSize(big)
        h.canvas.zoomToActualSize()
        for _ in 0..<40 { h.magnify(rightOf: 400, below: 300, by: 0.9) }
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), CGFloat(CanvasTransform.maxZoom), 1e-9)
        for _ in 0..<200 { h.magnify(rightOf: 400, below: 300, by: -0.5) }
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), CGFloat(CanvasTransform.minZoom), 1e-9)
    }

    // MARK: - Plain scroll = pan

    func testPreciseScrollPansByTheDeltaInDevicePixels() {
        h.canvas.setImageSize(big)
        h.canvas.zoomToActualSize()
        let before = h.canvas.transform.center
        h.scroll(rightOf: 400, below: 300, deltaX: 10, deltaY: 20, precise: true)
        let after = h.canvas.transform.center
        // The image follows the scroll, so the point at the view centre moves the
        // other way — by the delta in device pixels, at 1:1 one per image pixel.
        XCTAssertClose(after.x, before.x - 10 * h.scale, 1e-9)
        XCTAssertClose(after.y, before.y - 20 * h.scale, 1e-9)
    }

    func testCoarseScrollPansEightTimesFurtherPerLine() {
        h.canvas.setImageSize(big)
        h.canvas.zoomToActualSize()
        let before = h.canvas.transform.center
        h.scroll(rightOf: 400, below: 300, deltaX: 1, deltaY: 2, precise: false)
        let after = h.canvas.transform.center
        XCTAssertClose(after.x, before.x - 8 * h.scale, 1e-9)
        XCTAssertClose(after.y, before.y - 16 * h.scale, 1e-9)
    }

    /// A scroll pan does not change the zoom, and it moves the picture on screen
    /// in the direction of the scroll.
    func testScrollPanMovesThePictureNotTheZoom() {
        h.canvas.setImageSize(big)
        h.canvas.zoomToActualSize()
        let before = normalizedOfClick(rightOf: 400, below: 300)
        h.scroll(rightOf: 400, below: 300, deltaX: 0, deltaY: 25, precise: true)
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), 1, 1e-12, "a plain scroll must not zoom")
        let after = normalizedOfClick(rightOf: 400, below: 300)
        XCTAssertLessThan(after.y, before.y,
                          "scrolling with a positive dy drags the image down, so the "
                          + "centre shows a point further up the image")
    }

    // MARK: - Pan clamping

    /// You cannot drag the picture off its own edge: shove it far past the
    /// top-left and the image's top-left corner lands exactly on the canvas's.
    func testPanClampsAtTheImageEdges() {
        h.canvas.setImageSize(big)
        h.canvas.zoomToActualSize()

        // Repeated in-bounds strokes, because a drag to a point outside the
        // canvas is not a drag AppKit would route here.
        for _ in 0..<10 { h.drag(through: [(100, 100), (700, 550)]) }   // way down-right
        var t = h.canvas.transform
        var corner = t.viewPoint(fromImage: .zero)
        XCTAssertClose(corner.x, 0, 1e-6, "the image's left edge must stop at the canvas's")
        XCTAssertClose(corner.y, 0, 1e-6, "the image's top edge must stop at the canvas's")

        for _ in 0..<10 { h.drag(through: [(700, 550), (100, 100)]) }   // way up-left
        t = h.canvas.transform
        corner = t.viewPoint(fromImage: CGPoint(x: big.width, y: big.height))
        XCTAssertClose(corner.x, h.backingSize.width, 1e-6,
                       "the image's right edge must stop at the canvas's")
        XCTAssertClose(corner.y, h.backingSize.height, 1e-6,
                       "the image's bottom edge must stop at the canvas's")
    }

    /// A scroll pan is clamped by the same rule.
    func testScrollPanIsClampedToo() {
        h.canvas.setImageSize(big)
        h.canvas.zoomToActualSize()
        for _ in 0..<50 { h.scroll(rightOf: 400, below: 300, deltaX: 200, deltaY: 200) }
        let corner = h.canvas.transform.viewPoint(fromImage: .zero)
        XCTAssertClose(corner.x, 0, 1e-6)
        XCTAssertClose(corner.y, 0, 1e-6)
    }

    /// When the whole picture is on screen there is nothing to pan: it stays
    /// centred, on both axes, however hard it is dragged.
    func testAFittedImageCannotBePanned() {
        for imageSize in [portrait, landscape, big] {
            h.canvas.setImageSize(imageSize)
            let centre = h.canvas.transform.center
            h.drag(through: [(400, 300), (700, 550), (100, 50)])
            h.scroll(rightOf: 400, below: 300, deltaX: 400, deltaY: 400)
            XCTAssertEqual(h.canvas.transform.center, centre,
                           "\(imageSize): a fitted image must stay centred")
        }
    }

    /// The portrait fit fills the height exactly, so its vertical axis is pinned
    /// while the horizontal one is free at 1:1 — clamping is per axis.
    func testClampingIsPerAxis() {
        h.canvas.setImageSize(portrait)                     // 1600x2400 in a 1600x1200 view
        h.canvas.zoomToActualSize()
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), 1, 1e-12)
        let before = h.canvas.transform.center
        h.drag(through: [(400, 300), (700, 200)])           // right and up
        let after = h.canvas.transform.center
        XCTAssertEqual(after.x, before.x,
                       "the image is exactly as wide as the canvas: x is pinned")
        XCTAssertClose(after.y, before.y + 100 * h.scale, 1e-6, "y is free")
    }

    // MARK: - Double click

    /// Lightroom's double click: fit → 100 % at the clicked point, and back to
    /// fit (re-centred) on the next one.
    func testDoubleClickTogglesFitAndActualSizeAnchoredAtTheClick() {
        h.canvas.setImageSize(big)
        h.canvas.zoomToFit()
        let before = normalizedOfClick(rightOf: 220, below: 170)

        h.canvas.tool = .pan
        h.click(rightOf: 220, below: 170, clickCount: 2)
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), 1, 1e-9)
        let after = normalizedOfClick(rightOf: 220, below: 170)
        XCTAssertClose(after.x, before.x, 1e-6, "double click must zoom in at the click")
        XCTAssertClose(after.y, before.y, 1e-6)

        h.canvas.tool = .pan
        h.click(rightOf: 220, below: 170, clickCount: 2)
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), h.fitZoom(imageSize: big), 1e-9)
        XCTAssertEqual(h.canvas.transform.center, CGPoint(x: big.width / 2, y: big.height / 2))
    }

    /// A double click cancels the drag it started, so the mouse-up and any
    /// stray drag afterwards do nothing.
    func testADoubleClickLeavesNoDragBehind() {
        h.canvas.setImageSize(big)
        h.canvas.tool = .pan
        h.send(.leftMouseDown, at: h.windowPoint(rightOf: 400, below: 300), clickCount: 2)
        let afterZoom = h.canvas.transform
        h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 200, below: 100))
        XCTAssertEqual(h.canvas.transform, afterZoom,
                       "the drag that follows a double click must not pan")
        h.send(.leftMouseUp, at: h.windowPoint(rightOf: 200, below: 100))
        XCTAssertEqual(h.handler.endCount, 0)
        XCTAssertEqual(h.handler.targetedEndCount, 0)
    }

    /// A double click on an image that already fits at 100 % re-fits rather than
    /// magnifying past 1:1.
    func testDoubleClickOnASmallImageStaysAtFit() {
        let small = CGSize(width: 400, height: 300)          // smaller than the 1600x1200 canvas
        h.canvas.setImageSize(small)
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), 1, 1e-12, "fit never magnifies past 1:1")
        h.canvas.tool = .pan
        h.click(rightOf: 400, below: 300, clickCount: 2)
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), 1, 1e-12)
    }

    // MARK: - Transform notifications

    /// Every transform change is reported to the owner, because the zoom readout
    /// in the title bar is driven from it.
    func testEveryTransformChangeIsHandedToTheHandler() {
        h.handler.reset()
        h.canvas.setImageSize(big)
        XCTAssertEqual(h.handler.transforms.count, 1)
        h.canvas.zoomToActualSize()
        h.canvas.zoomToFit()
        h.magnify(rightOf: 400, below: 300, by: 0.2)
        h.scroll(rightOf: 400, below: 300, deltaY: 5)
        XCTAssertEqual(h.handler.transforms.count, 5)
        XCTAssertEqual(h.handler.transforms.last, h.canvas.transform)
    }

    /// Resizing the drawable re-fits a fitted view and keeps the zoom otherwise.
    func testDrawableResizeKeepsTheFraming() {
        h.canvas.setImageSize(big)
        h.canvas.mtkView(h.canvas, drawableSizeWillChange: CGSize(width: 800, height: 800))
        XCTAssertEqual(h.canvas.transform.viewSize, CGSize(width: 800, height: 800))
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), 800 / 4000, 1e-9,
                       "a fitted canvas re-fits when it is resized")

        h.canvas.zoomToActualSize()
        h.canvas.mtkView(h.canvas, drawableSizeWillChange: CGSize(width: 400, height: 400))
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), 1, 1e-12,
                       "a zoomed canvas keeps its zoom across a resize")
        XCTAssertEqual(h.canvas.transform.viewSize, CGSize(width: 400, height: 400))
    }

    /// A degenerate drawable size must not divide by zero.
    func testAZeroDrawableSizeIsFloored() {
        h.canvas.setImageSize(big)
        h.canvas.mtkView(h.canvas, drawableSizeWillChange: .zero)
        XCTAssertEqual(h.canvas.transform.viewSize, CGSize(width: 1, height: 1))
        XCTAssertTrue(h.canvas.transform.zoom.isFinite)
    }

    /// The canvas is built, handed an image and driven before it is ever put in
    /// a window — nothing in the geometry may depend on there being one, and
    /// with no window to ask, one point is one device pixel.
    func testACanvasWithNoWindowWorksAtAScaleOfOne() throws {
        let v = CanvasNSView(device: h.device,
                             commandQueue: try XCTUnwrap(h.device.makeCommandQueue()))
        let recorder = RecordingHandler()
        v.handler = recorder
        v.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertNil(v.window)

        v.setImageSize(big)
        XCTAssertEqual(v.transform.viewSize, CGSize(width: 800, height: 600),
                       "the view size is the bounds, unscaled")
        XCTAssertClose(CGFloat(v.transform.zoom), 800 / big.width, 1e-9)

        v.zoomToActualSize()
        let before = v.transform.center
        v.scrollWheel(with: SyntheticGestureEvent(type: .scrollWheel,
                                                  location: CGPoint(x: 400, y: 300),
                                                  window: nil, deltaX: 10, deltaY: 20))
        XCTAssertClose(v.transform.center.x, before.x - 10, 1e-9)
        XCTAssertClose(v.transform.center.y, before.y - 20, 1e-9)

        // A click maps at one image pixel per point, so a 100-point step across
        // the view is a 100-pixel step across the image.
        v.tool = .brush
        func down(x: CGFloat) -> CGPoint {
            let e = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: x, y: 200),
                                       modifierFlags: [], timestamp: 0, windowNumber: 0,
                                       context: nil, eventNumber: Int(x), clickCount: 1,
                                       pressure: 1)!
            v.mouseDown(with: e)
            return recorder.begins.last!.point
        }
        let a = down(x: 100), b = down(x: 200)
        XCTAssertClose((b.x - a.x) * big.width, 100, 1e-6)
        XCTAssertClose((b.y - a.y) * big.height, 0, 1e-6)
    }

    /// Moving to a display with a different backing scale re-derives the view
    /// size from the bounds.
    func testBackingPropertyChangeResizesTheTransform() {
        h.canvas.setImageSize(big)
        h.canvas.mtkView(h.canvas, drawableSizeWillChange: CGSize(width: 123, height: 456))
        h.canvas.viewDidChangeBackingProperties()
        XCTAssertEqual(h.canvas.transform.viewSize, h.backingSize)
    }
}
