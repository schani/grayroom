import AppKit
import CoreGraphics
import GrayroomCanvas
import GrayroomUI
import Metal
import XCTest

/// The canvas's keyboard shortcuts, its cursor, and the uniforms the cursor ring
/// and the mask overlay are drawn from.
final class CanvasKeyAndCursorTests: XCTestCase {
    private var h: CanvasHarness!
    private let image = CGSize(width: 4000, height: 3000)

    override func setUpWithError() throws {
        h = try CanvasHarness()
        h.canvas.setImageSize(image)
    }

    override func tearDown() {
        h = nil
        super.tearDown()
    }

    // MARK: - Key commands

    /// Lightroom's canvas keys, each pressed for real and routed by AppKit to
    /// the first responder.
    func testEveryCanvasKeyDispatchesItsCommand() {
        let table: [(chars: String, modifiers: NSEvent.ModifierFlags, want: String)] = [
            ("b", [], "toggleBrush"),
            ("B", [.shift], "toggleBrush"),
            ("t", [], "toggleTargeted"),
            ("T", [.shift], "toggleTargeted"),
            ("[", [], "sizeStep(-1)"),
            ("]", [], "sizeStep(1)"),
            ("{", [], "sizeStep(-1)"),
            ("}", [], "sizeStep(1)"),
            ("[", [.shift], "featherStep(-1)"),
            ("]", [.shift], "featherStep(1)"),
            ("0", [], "fit"),
            ("1", [], "actualSize"),
            ("6", [], "colorLabel(1)"),
            ("7", [], "colorLabel(2)"),
            ("8", [], "colorLabel(3)"),
            ("9", [], "colorLabel(4)"),
        ]
        for entry in table {
            h.handler.reset()
            XCTAssertTrue(h.sendKey(.keyDown, entry.chars, modifiers: entry.modifiers),
                          "the canvas must be the first responder for '\(entry.chars)'")
            XCTAssertEqual(h.handler.keyCommands.map(\.testDescription), [entry.want],
                           "'\(entry.chars)' \(entry.modifiers)")
        }
    }

    /// `6`–`9` are Lightroom's red/yellow/green/blue; `5` is not a colour label
    /// there and must not become one here.
    func testKeysWithNoCanvasMeaningAreLeftToTheResponderChain() {
        for chars in ["q", "5", "2"] {
            h.handler.reset()
            h.keyDown(chars)
            XCTAssertEqual(h.handler.keyCommands.count, 0, "'\(chars)' must not be a canvas command")
            XCTAssertEqual(h.handler.beforeAfterHeld.count, 0)
        }
    }

    /// A key press that carries no characters at all — a dead key, a lone
    /// modifier — must not crash the switch.
    func testAKeyPressWithNoCharactersIsHarmless() {
        h.handler.reset()
        h.keyDown("", characters: "")
        h.keyUp("")
        XCTAssertEqual(h.handler.keyCommands.count, 0)
        XCTAssertEqual(h.handler.beforeAfterHeld.count, 0)
    }

    /// The zoom keys move the *view* through the handler, not by themselves —
    /// the owner routes them back — so the canvas must only report them.
    func testTheZoomKeysOnlyReportAndDoNotMoveTheView() {
        h.canvas.zoomToActualSize()
        let t = h.canvas.transform
        h.keyDown("0")
        h.keyDown("1")
        XCTAssertEqual(h.canvas.transform, t)
        XCTAssertEqual(h.handler.keyCommands.map(\.testDescription), ["fit", "actualSize"])
    }

    // MARK: - Before/after

    /// `\` is a *hold*: the comparison is on while the key is down and off the
    /// moment it comes up.
    func testBackslashShowsTheBeforeImageWhileItIsHeld() {
        h.handler.reset()
        h.keyDown("\\")
        XCTAssertEqual(h.handler.beforeAfterHeld, [true])
        h.keyUp("\\")
        XCTAssertEqual(h.handler.beforeAfterHeld, [true, false])
        h.keyDown("\\")
        XCTAssertEqual(h.handler.beforeAfterHeld, [true, false, true])
        h.keyUp("\\")
        XCTAssertEqual(h.handler.beforeAfterHeld, [true, false, true, false])
    }

    /// Holding a key makes AppKit repeat the key-down; the comparison must be
    /// turned on once, not once per repeat.
    func testHoldingBackslashDoesNotRepeatTheToggle() {
        h.handler.reset()
        h.keyDown("\\")
        for _ in 0..<5 { h.keyDown("\\", isARepeat: true) }
        XCTAssertEqual(h.handler.beforeAfterHeld, [true],
                       "an auto-repeat must not re-announce the hold")
        h.keyUp("\\")
        XCTAssertEqual(h.handler.beforeAfterHeld, [true, false])
    }

    /// `\` is not a mode: releasing any other key leaves the comparison alone.
    func testReleasingSomeOtherKeyDoesNotEndTheComparison() {
        h.handler.reset()
        h.keyDown("\\")
        h.keyUp("b")
        XCTAssertEqual(h.handler.beforeAfterHeld, [true])
        h.keyUp("\\")
        XCTAssertEqual(h.handler.beforeAfterHeld, [true, false])
    }

    // MARK: - Cursor

    func testTheCursorSaysWhatTheToolDoes() {
        h.canvas.tool = .pan
        XCTAssertEqual(h.canvas.toolCursor, NSCursor.openHand)
        h.canvas.tool = .brush
        XCTAssertEqual(h.canvas.toolCursor, NSCursor.crosshair)
        h.canvas.tool = .targeted
        XCTAssertEqual(h.canvas.toolCursor, NSCursor.crosshair)
        // The real path AppKit takes; it must install the same cursor.
        for tool in CanvasTool.allCases {
            h.canvas.tool = tool
            h.window.resetCursorRects()
            XCTAssertEqual(h.canvas.toolCursor,
                           tool == .pan ? NSCursor.openHand : NSCursor.crosshair)
        }
    }

    func testTheToolsAreNamedForTheUI() {
        XCTAssertEqual(CanvasTool.allCases.map(\.label), ["Pan", "Brush", "Targeted"])
        XCTAssertEqual(CanvasTool(rawValue: "brush"), .brush)
    }

    /// Tracking areas are rebuilt, not accumulated — an extra one would deliver
    /// every mouse-move twice.
    func testTrackingAreasAreReplacedNotStacked() {
        h.canvas.updateTrackingAreas()
        h.canvas.updateTrackingAreas()
        h.canvas.updateTrackingAreas()
        XCTAssertEqual(h.canvas.trackingAreas.count, 1)
        let area = try? XCTUnwrap(h.canvas.trackingAreas.first)
        XCTAssertTrue(area?.options.contains(.mouseMoved) ?? false)
        XCTAssertTrue(area?.options.contains(.mouseEnteredAndExited) ?? false)
        XCTAssertTrue(area?.owner === h.canvas)
    }

    func testTheCanvasTakesTheKeyboardAndTheFirstClick() {
        XCTAssertTrue(h.canvas.acceptsFirstResponder)
        XCTAssertTrue(h.canvas.acceptsFirstMouse(for: nil))
        XCTAssertTrue(h.canvas.isFlipped)
        // A click on an inactive window paints straight away rather than only
        // activating the window.
        h.canvas.tool = .brush
        h.click(rightOf: 400, below: 300)
        XCTAssertEqual(h.handler.begins.count, 1)
        XCTAssertTrue(h.window.firstResponder === h.canvas)
    }

    // MARK: - The brush cursor ring

    /// The ring is drawn where the pointer is, at the brush's on-screen size.
    func testTheBrushRingFollowsThePointerAtTheBrushSize() {
        h.canvas.zoomToActualSize()
        h.canvas.tool = .brush
        h.canvas.brushSize = 0.08
        h.canvas.brushFeather = 40

        h.moveMouse(rightOf: 250, below: 175)
        let u = h.canvas.currentUniforms()
        let p = h.backingPoint(rightOf: 250, below: 175)
        XCTAssertEqual(Double(u.cursor.x), Double(p.x), accuracy: 1e-3)
        XCTAssertEqual(Double(u.cursor.y), Double(p.y), accuracy: 1e-3)

        // Diameter is a fraction of the image's long edge, halved for a radius
        // and scaled by the zoom: 0.08 * 4000 / 2 * 1 device pixels.
        let radius = 0.08 * 4000 / 2 * h.canvas.transform.zoom
        XCTAssertEqual(Double(u.cursorRadius), radius, accuracy: 1e-2)
        // Feather 40 means the falloff starts at 60 % of the radius.
        XCTAssertEqual(Double(u.cursorInner), 0.6 * radius, accuracy: 1e-2)
    }

    /// Zooming in makes the ring bigger by the same factor — the brush is sized
    /// in image pixels, not screen pixels.
    func testTheRingScalesWithTheZoom() {
        h.canvas.tool = .brush
        h.canvas.brushSize = 0.05
        h.canvas.zoomToActualSize()
        h.moveMouse(rightOf: 400, below: 300)
        let at1 = Double(h.canvas.currentUniforms().cursorRadius)
        h.magnify(rightOf: 400, below: 300, by: 1.0)          // 2x
        h.moveMouse(rightOf: 400, below: 300)
        let at2 = Double(h.canvas.currentUniforms().cursorRadius)
        XCTAssertEqual(at2, 2 * at1, accuracy: 1e-3)
    }

    /// A ring smaller than a couple of pixels would vanish, so it has a floor —
    /// and the falloff never eats the whole ring.
    func testTheRingHasAMinimumVisibleSize() {
        h.canvas.tool = .brush
        h.canvas.zoomToFit()
        h.canvas.brushSize = 0.002                            // the smallest brush there is
        h.moveMouse(rightOf: 400, below: 300)
        let u = h.canvas.currentUniforms()
        XCTAssertEqual(Double(u.cursorRadius), 2, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(Double(u.cursorInner), 0)
        XCTAssertLessThanOrEqual(Double(u.cursorInner), Double(u.cursorRadius))
    }

    /// A hard brush is filled to the edge; a fully feathered one has no hard
    /// core at all.
    func testFeatherSetsWhereTheFalloffStarts() {
        h.canvas.zoomToActualSize()
        h.canvas.tool = .brush
        h.canvas.brushSize = 0.1
        h.moveMouse(rightOf: 400, below: 300)

        h.canvas.brushFeather = 0
        var u = h.canvas.currentUniforms()
        XCTAssertEqual(Double(u.cursorInner), Double(u.cursorRadius) - 1, accuracy: 1e-3,
                       "a hard brush is solid to within a pixel of its edge")

        h.canvas.brushFeather = 100
        u = h.canvas.currentUniforms()
        XCTAssertEqual(Double(u.cursorInner), 0, accuracy: 1e-9,
                       "a fully feathered brush has no hard core")
    }

    /// Only the brush has a ring, and it goes away when the pointer leaves.
    func testTheRingIsOnlyThereForTheBrushAndOnlyWhileThePointerIs() {
        h.canvas.tool = .pan
        h.moveMouse(rightOf: 400, below: 300)
        XCTAssertEqual(h.canvas.currentUniforms().cursor, SIMD2<Float>(-1, -1))
        XCTAssertEqual(h.canvas.currentUniforms().cursorRadius, 0)

        h.canvas.tool = .targeted
        h.moveMouse(rightOf: 400, below: 300)
        XCTAssertEqual(h.canvas.currentUniforms().cursor, SIMD2<Float>(-1, -1))

        h.canvas.tool = .brush
        h.moveMouse(rightOf: 400, below: 300)
        XCTAssertNotEqual(h.canvas.currentUniforms().cursor, SIMD2<Float>(-1, -1))

        h.exitMouse()
        XCTAssertEqual(h.canvas.currentUniforms().cursor, SIMD2<Float>(-1, -1),
                       "the ring must not be left behind when the pointer leaves")
    }

    /// A click and a drag place the ring too, so it does not jump back to the
    /// last mouse-moved while a stroke is being painted.
    func testTheRingFollowsAStrokeAsWellAsAHover() {
        h.canvas.zoomToActualSize()
        h.canvas.tool = .brush
        h.send(.leftMouseDown, at: h.windowPoint(rightOf: 200, below: 150))
        XCTAssertEqual(Double(h.canvas.currentUniforms().cursor.x),
                       Double(h.backingPoint(rightOf: 200, below: 150).x), accuracy: 1e-3)
        h.send(.leftMouseDragged, at: h.windowPoint(rightOf: 260, below: 210))
        XCTAssertEqual(Double(h.canvas.currentUniforms().cursor.x),
                       Double(h.backingPoint(rightOf: 260, below: 210).x), accuracy: 1e-3)
        XCTAssertEqual(Double(h.canvas.currentUniforms().cursor.y),
                       Double(h.backingPoint(rightOf: 260, below: 210).y), accuracy: 1e-3)
        h.send(.leftMouseUp, at: h.windowPoint(rightOf: 260, below: 210))
    }

    // MARK: - Uniforms

    /// The uniforms restate the transform the input path uses — the display and
    /// the input mapping have to invert the same numbers.
    func testTheUniformsMirrorTheTransform() {
        h.canvas.zoomToActualSize()
        h.magnify(rightOf: 300, below: 200, by: 0.75)
        let t = h.canvas.transform
        let u = h.canvas.currentUniforms()
        XCTAssertEqual(Double(u.viewSize.x), Double(t.viewSize.width), accuracy: 1e-3)
        XCTAssertEqual(Double(u.viewSize.y), Double(t.viewSize.height), accuracy: 1e-3)
        XCTAssertEqual(Double(u.imageSize.x), Double(t.imageSize.width), accuracy: 1e-3)
        XCTAssertEqual(Double(u.imageSize.y), Double(t.imageSize.height), accuracy: 1e-3)
        XCTAssertEqual(Double(u.center.x), Double(t.center.x), accuracy: 1e-2)
        XCTAssertEqual(Double(u.center.y), Double(t.center.y), accuracy: 1e-2)
        XCTAssertEqual(Double(u.zoom), t.zoom, accuracy: 1e-6)
    }

    /// A degenerate image size must not divide by zero in the shader.
    func testADegenerateImageSizeIsFlooredInTheUniforms() {
        h.canvas.setImageSize(.zero)
        let u = h.canvas.currentUniforms()
        XCTAssertEqual(u.imageSize.x, 1)
        XCTAssertEqual(u.imageSize.y, 1)
    }

    /// Above 2x the actual image pixels are shown rather than a smoothed lie.
    func testNearestSamplingKicksInAtTwoTimes() {
        h.canvas.zoomToActualSize()
        XCTAssertEqual(h.canvas.currentUniforms().nearest, 0)
        h.magnify(rightOf: 400, below: 300, by: 0.99)         // 1.99x
        XCTAssertEqual(h.canvas.currentUniforms().nearest, 0)
        h.canvas.zoomToActualSize()
        h.magnify(rightOf: 400, below: 300, by: 1.0)          // 2x exactly
        XCTAssertEqual(h.canvas.currentUniforms().nearest, 1)
    }

    /// The mask overlay is only drawn when it is both asked for and available.
    func testTheOverlayNeedsBothTheSwitchAndACoverageTexture() throws {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                                                         width: 16, height: 16,
                                                         mipmapped: false)
        d.usage = .shaderRead
        let coverage = try XCTUnwrap(h.device.makeTexture(descriptor: d))

        XCTAssertEqual(h.canvas.currentUniforms().overlay, 0)
        h.canvas.showOverlay = true
        XCTAssertEqual(h.canvas.currentUniforms().overlay, 0, "no mask, no overlay")
        h.canvas.coverageTexture = coverage
        XCTAssertEqual(h.canvas.currentUniforms().overlay, 1)
        h.canvas.showOverlay = false
        XCTAssertEqual(h.canvas.currentUniforms().overlay, 0)
        h.canvas.coverageTexture = nil
        XCTAssertEqual(h.canvas.currentUniforms().overlay, 0)
    }

    /// The on-screen draw path — the one `draw(in:)` runs every frame — with a
    /// real drawable behind it.
    func testTheViewDrawsAFrameThroughItsOwnDrawPath() throws {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                         width: 64, height: 48,
                                                         mipmapped: false)
        d.usage = .shaderRead
        d.storageMode = .shared
        h.canvas.imageTexture = try XCTUnwrap(h.device.makeTexture(descriptor: d))
        h.canvas.coverageTexture = nil
        h.canvas.tool = .brush
        h.moveMouse(rightOf: 400, below: 300)
        // No assertion beyond "it drew": a Metal validation failure or a nil
        // drawable would trap or abort the process here.
        h.canvas.draw()
        h.canvas.showOverlay = true
        h.canvas.draw()
        XCTAssertNotNil(h.canvas.currentDrawable)
    }
}
