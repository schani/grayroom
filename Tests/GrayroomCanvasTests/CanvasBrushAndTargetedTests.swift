import AppKit
import CoreGraphics
import GrayroomCanvas
import GrayroomUI
import Metal
import XCTest

/// The two tools that act on the picture rather than on the view: the brush
/// (which must land on the right full-resolution pixel, at the right pressure,
/// adding or erasing) and the targeted adjustment (whose drag has to move the
/// B&W mixer the way the user pushed).
final class CanvasBrushAndTargetedTests: XCTestCase {
    private var h: CanvasHarness!
    /// Bigger than the canvas at 1:1 on both axes, so nothing here is clamped.
    private let image = CGSize(width: 4000, height: 3000)

    override func setUpWithError() throws {
        h = try CanvasHarness()
        h.canvas.setImageSize(image)
    }

    override func tearDown() {
        h = nil
        super.tearDown()
    }

    // MARK: - Full-resolution mapping

    /// A stroke reports **full-resolution** image coordinates, whatever the zoom
    /// and pan — that is the space the mask is rasterised in.
    func testStrokePointsAreFullResolutionImagePixels() {
        h.canvas.zoomToActualSize()
        h.magnify(rightOf: 300, below: 200, by: 2.0)         // zoom 3
        h.canvas.tool = .pan
        h.drag(through: [(400, 300), (330, 250)])            // and off centre
        XCTAssertClose(CGFloat(h.canvas.transform.zoom), 3, 1e-9)

        let t = h.canvas.transform
        let path: [(CGFloat, CGFloat)] = [(120, 90), (200, 140), (310, 260), (455, 380)]
        h.canvas.tool = .brush
        h.handler.reset()
        h.drag(through: path)

        let got = [h.handler.begins[0].point] + h.handler.extends
        XCTAssertEqual(got.count, path.count)
        for (i, (dx, dy)) in path.enumerated() {
            let want = h.expectedNormalized(rightOf: dx, below: dy, zoom: t.zoom,
                                            center: t.center, imageSize: image)
            // Stated in image pixels, which is what the caller multiplies up to.
            XCTAssertClose(got[i].x * image.width, want.x * image.width, 1e-2, "point \(i) px x")
            XCTAssertClose(got[i].y * image.height, want.y * image.height, 1e-2, "point \(i) px y")
        }
        XCTAssertEqual(h.handler.endCount, 1)
        XCTAssertEqual(h.canvas.transform, t, "painting must not move the view")
    }

    /// At 1:1 a one-device-pixel step on screen is a one-pixel step in the
    /// full-resolution image — no preview scale sneaks in.
    func testOneDevicePixelIsOneImagePixelAtActualSize() {
        h.canvas.zoomToActualSize()
        h.canvas.tool = .brush
        h.drag(through: [(300, 200), (300.5, 200)])          // +1 device px in x
        let a = h.handler.begins[0].point, b = h.handler.extends[0]
        XCTAssertClose((b.x - a.x) * image.width, 1, 1e-6)
        XCTAssertClose((b.y - a.y) * image.height, 0, 1e-6)
    }

    /// A draft texture is a *smaller* stand-in for the same image; the stroke
    /// still has to be authored against the full-resolution frame.
    func testADraftTextureDoesNotChangeStrokeCoordinates() throws {
        h.canvas.zoomToActualSize()
        h.canvas.tool = .brush
        h.click(rightOf: 300, below: 200)
        let full = h.handler.begins[0].point

        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                         width: 400, height: 300,
                                                         mipmapped: false)
        d.usage = .shaderRead
        h.canvas.imageTexture = try XCTUnwrap(h.device.makeTexture(descriptor: d))
        h.handler.reset()
        h.click(rightOf: 300, below: 200)
        XCTAssertEqual(h.handler.begins[0].point, full)
        XCTAssertEqual(h.canvas.transform.imageSize, image)
    }

    // MARK: - Pressure

    /// A tablet's pressure is handed through untouched; the caller decides what
    /// a zero means.
    func testPressureReachesTheHandlerUnchanged() {
        h.canvas.tool = .brush
        for p in [Float(0), 0.25, 0.42, 1] {
            h.handler.reset()
            h.click(rightOf: 400, below: 300, pressure: p)
            XCTAssertEqual(h.handler.begins.count, 1)
            XCTAssertEqual(h.handler.begins[0].pressure, Double(p), accuracy: 1e-6,
                           "begin pressure \(p)")
        }
    }

    /// Pressure varies along a stroke, so every extended point carries its own.
    func testPressureIsCarriedByEveryPointOfAStroke() {
        h.canvas.tool = .brush
        h.send(.leftMouseDown, at: h.windowPoint(rightOf: 300, below: 200), pressure: 0.1)
        h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 320, below: 210), pressure: 0.6)
        h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 340, below: 220), pressure: 0.9)
        h.send(.leftMouseUp, at: h.windowPoint(rightOf: 340, below: 220), pressure: 0.9)
        XCTAssertEqual(h.handler.begins[0].pressure, 0.1, accuracy: 1e-6)
        XCTAssertEqual(h.handler.extendPressures.count, 2)
        XCTAssertEqual(h.handler.extendPressures[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(h.handler.extendPressures[1], 0.9, accuracy: 1e-6)
    }

    // MARK: - Eraser

    /// Erasing is either the mode (the `e` toggle) or the option key — Lightroom
    /// spells it both ways, and either is enough.
    func testEraseIsSetByTheEraserModeOrByTheOptionKey() {
        h.canvas.tool = .brush
        let cases: [(eraser: Bool, option: Bool, erase: Bool)] = [
            (false, false, false),
            (true, false, true),
            (false, true, true),
            (true, true, true),
        ]
        for c in cases {
            h.handler.reset()
            h.canvas.eraserActive = c.eraser
            h.click(rightOf: 400, below: 300, modifiers: c.option ? [.option] : [])
            XCTAssertEqual(h.handler.begins.count, 1)
            XCTAssertEqual(h.handler.begins[0].erase, c.erase,
                           "eraserActive=\(c.eraser) option=\(c.option)")
        }
    }

    /// The erase flag belongs to the stroke, so it is decided once at mouse-down
    /// and does not have to be repeated for every extension.
    func testTheEraseFlagIsDecidedAtTheStartOfTheStroke() {
        h.canvas.tool = .brush
        h.canvas.eraserActive = true
        h.drag(through: [(300, 200), (320, 220), (340, 240)])
        XCTAssertEqual(h.handler.begins.count, 1)
        XCTAssertTrue(h.handler.begins[0].erase)
        XCTAssertEqual(h.handler.extends.count, 2)
        XCTAssertEqual(h.handler.endCount, 1)
    }

    // MARK: - Tool isolation

    /// The brush does not move the view, and the pan tool does not paint.
    func testEachToolDoesOnlyItsOwnJob() {
        h.canvas.zoomToActualSize()
        let t = h.canvas.transform

        h.canvas.tool = .brush
        h.drag(through: [(400, 300), (300, 200)])
        XCTAssertEqual(h.canvas.transform, t, "the brush must not pan")
        XCTAssertEqual(h.handler.begins.count, 1)

        h.handler.reset()
        h.canvas.tool = .pan
        h.drag(through: [(400, 300), (300, 200)])
        XCTAssertEqual(h.handler.begins.count, 0, "the pan tool must not paint")
        XCTAssertEqual(h.handler.endCount, 0)
        XCTAssertNotEqual(h.canvas.transform, t)

        h.handler.reset()
        h.canvas.tool = .targeted
        h.drag(through: [(400, 300), (300, 200)])
        XCTAssertEqual(h.handler.begins.count, 0, "the targeted tool must not paint")
        XCTAssertEqual(h.handler.targetedBegins.count, 1)
    }

    /// A drag with no button down behind it — the mouse-up already ended the
    /// gesture — must do nothing at all.
    func testADragWithNoGestureBehindItIsIgnored() {
        h.canvas.zoomToActualSize()
        h.canvas.tool = .pan
        h.drag(through: [(400, 300), (350, 250)])
        let t = h.canvas.transform
        h.handler.reset()
        h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 100, below: 100))
        h.send(.leftMouseUp, at: h.windowPoint(rightOf: 100, below: 100))
        XCTAssertEqual(h.canvas.transform, t)
        XCTAssertEqual(h.handler.begins.count, 0)
        XCTAssertEqual(h.handler.endCount, 0)
        XCTAssertEqual(h.handler.targetedDrags.count, 0)
        XCTAssertEqual(h.handler.targetedEndCount, 0)
    }

    // MARK: - Targeted adjustment

    /// The gesture begins on the pixel that was clicked — that is the colour the
    /// adjustment is about.
    func testTargetedBeginsOnTheClickedPixel() {
        h.canvas.zoomToActualSize()
        let t = h.canvas.transform
        h.canvas.tool = .targeted
        h.send(.leftMouseDown, at: h.windowPoint(rightOf: 260, below: 190))
        h.send(.leftMouseUp, at: h.windowPoint(rightOf: 260, below: 190))
        XCTAssertEqual(h.handler.targetedBegins.count, 1)
        let want = h.expectedNormalized(rightOf: 260, below: 190, zoom: t.zoom,
                                        center: t.center, imageSize: image)
        XCTAssertClose(h.handler.targetedBegins[0].x, want.x, 1e-6)
        XCTAssertClose(h.handler.targetedBegins[0].y, want.y, 1e-6)
        XCTAssertEqual(h.handler.targetedEndCount, 1)
        XCTAssertEqual(h.canvas.transform, t, "the targeted tool must not pan")
    }

    /// Up brightens, down darkens, measured from the *start* of the drag so the
    /// gesture is absolute rather than incremental.
    func testTargetedDragIsMeasuredFromTheStartAndUpIsPositive() {
        h.canvas.tool = .targeted
        h.send(.leftMouseDown, at: h.windowPoint(rightOf: 400, below: 300))
        h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 400, below: 250))   // 50 pt up
        h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 400, below: 200))   // 100 pt up
        h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 400, below: 380))   // 80 pt down
        h.send(.leftMouseUp, at: h.windowPoint(rightOf: 400, below: 380))
        XCTAssertEqual(h.handler.targetedDrags.count, 3)
        XCTAssertClose(CGFloat(h.handler.targetedDrags[0]), 50 * h.scale, 1e-6)
        XCTAssertClose(CGFloat(h.handler.targetedDrags[1]), 100 * h.scale, 1e-6)
        XCTAssertClose(CGFloat(h.handler.targetedDrags[2]), -80 * h.scale, 1e-6)
        XCTAssertEqual(h.handler.targetedEndCount, 1)
    }

    /// Horizontal movement is not part of the gesture.
    func testTargetedIgnoresHorizontalMovement() {
        h.canvas.tool = .targeted
        h.send(.leftMouseDown, at: h.windowPoint(rightOf: 400, below: 300))
        h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 120, below: 300))
        h.send(.leftMouseUp, at: h.windowPoint(rightOf: 120, below: 300))
        XCTAssertEqual(h.handler.targetedDrags, [0])
    }

    /// The whole point of the tool: dragging **up** on a colour must raise the
    /// mixer sliders that brighten it, and dragging down must lower them. This
    /// runs the canvas's drag output through the same band math the app does.
    func testTargetedDragMovesTheBWMixInTheDirectionOfTheDrag() {
        let baseline = [Double](repeating: 0, count: 8)
        let dragPoints: CGFloat = 50
        // 0° is the red band centre, 45° sits between orange (30°) and yellow (60°).
        for hue in [0.0, 45.0, 210.0] {
            let s = TATBandMath.split(hueDegrees: hue)

            h.canvas.tool = .targeted
            h.handler.reset()
            h.send(.leftMouseDown, at: h.windowPoint(rightOf: 400, below: 400))
            h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 400, below: 400 - dragPoints))
            h.send(.leftMouseUp, at: h.windowPoint(rightOf: 400, below: 400 - dragPoints))
            let up = TATBandMath.applying(delta: TATBandMath.delta(forDragPixels:
                                                                    h.handler.targetedDrags[0]),
                                          hueDegrees: hue, to: baseline)

            h.handler.reset()
            h.send(.leftMouseDown, at: h.windowPoint(rightOf: 400, below: 400 - dragPoints))
            h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 400, below: 400))  // back DOWN
            h.send(.leftMouseUp, at: h.windowPoint(rightOf: 400, below: 400))
            let down = TATBandMath.applying(delta: TATBandMath.delta(forDragPixels:
                                                                      h.handler.targetedDrags[0]),
                                            hueDegrees: hue, to: baseline)

            // The bands that bracket the hue move, and only those.
            for i in 0..<8 where i != s.lowerIndex && i != s.upperIndex {
                XCTAssertEqual(up[i], 0, "hue \(hue): band \(i) must not move")
                XCTAssertEqual(down[i], 0, "hue \(hue): band \(i) must not move")
            }
            // What the shader will actually do to a pixel of this hue: the
            // weighted blend of the two bands. Up brightens it, down darkens it,
            // by the same amount.
            let upMix = s.lowerWeight * up[s.lowerIndex] + s.upperWeight * up[s.upperIndex]
            let downMix = s.lowerWeight * down[s.lowerIndex] + s.upperWeight * down[s.upperIndex]
            XCTAssertGreaterThan(upMix, 0, "hue \(hue): dragging up must brighten")
            XCTAssertLessThan(downMix, 0, "hue \(hue): dragging down must darken")
            XCTAssertEqual(upMix, -downMix, accuracy: 1e-9, "hue \(hue): symmetric")
            // …and by exactly what that many points of drag asks for.
            XCTAssertEqual(upMix,
                           TATBandMath.delta(forDragPixels: Double(dragPoints * h.scale)),
                           accuracy: 1e-9,
                           "hue \(hue): the gain must not depend on where in the band it is")
        }
    }
}
