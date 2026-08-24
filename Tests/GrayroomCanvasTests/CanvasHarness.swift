import AppKit
import CoreGraphics
import GrayroomCanvas
import GrayroomUI
import Metal
import XCTest

/// Records everything `CanvasNSView` hands to its owner, so a test can assert on
/// what a real click actually produced.
final class RecordingHandler: CanvasInputHandler {
    struct Begin {
        var point: CGPoint
        var pressure: Double
        var erase: Bool
    }

    var begins: [Begin] = []
    var extends: [CGPoint] = []
    var extendPressures: [Double] = []
    var endCount = 0
    var targetedBegins: [CGPoint] = []
    var targetedDrags: [Double] = []
    var targetedEndCount = 0
    var transforms: [CanvasTransform] = []
    var keyCommands: [CanvasKeyCommand] = []
    var beforeAfterHeld: [Bool] = []

    func canvasTransformChanged(_ transform: CanvasTransform) { transforms.append(transform) }
    func canvasBeginStroke(atNormalized p: CGPoint, pressure: Double, erase: Bool) {
        begins.append(Begin(point: p, pressure: pressure, erase: erase))
    }
    func canvasExtendStroke(toNormalized p: CGPoint, pressure: Double) {
        extends.append(p)
        extendPressures.append(pressure)
    }
    func canvasEndStroke() { endCount += 1 }
    func canvasBeginTargeted(atNormalized p: CGPoint) { targetedBegins.append(p) }
    func canvasDragTargeted(dragPixels: Double) { targetedDrags.append(dragPixels) }
    func canvasEndTargeted() { targetedEndCount += 1 }
    func canvasKeyCommand(_ command: CanvasKeyCommand) { keyCommands.append(command) }
    func canvasBeforeAfterHeld(_ held: Bool) { beforeAfterHeld.append(held) }

    func reset() {
        begins.removeAll(); extends.removeAll(); extendPressures.removeAll()
        endCount = 0
        targetedBegins.removeAll(); targetedDrags.removeAll(); targetedEndCount = 0
        transforms.removeAll(); keyCommands.removeAll(); beforeAfterHeld.removeAll()
    }
}

/// `CanvasKeyCommand` carries payloads and is not `Equatable`; this is the
/// test-side spelling used in assertions.
extension CanvasKeyCommand {
    var testDescription: String {
        switch self {
        case .toggleBrush: return "toggleBrush"
        case .toggleTargeted: return "toggleTargeted"
        case .toggleEraser: return "toggleEraser"
        case .sizeStep(let n): return "sizeStep(\(n))"
        case .featherStep(let n): return "featherStep(\(n))"
        case .fit: return "fit"
        case .actualSize: return "actualSize"
        case .colorLabel(let n): return "colorLabel(\(n))"
        }
    }
}

/// An `NSEvent` for the scroll and gesture types AppKit gives no public
/// constructor for. Only the accessors `CanvasNSView` actually reads are
/// overridden; everything else stays `NSEvent`'s.
///
/// `NSEvent(cgEvent:)` can build a real scroll event, but it comes back with a
/// `nil` window and a *screen* `locationInWindow`, which is exactly the piece
/// the canvas's coordinate conversion is being tested on. A subclass is the
/// only way to hand `scrollWheel(with:)` a window-relative point.
final class SyntheticGestureEvent: NSEvent {
    private let kind: NSEvent.EventType
    private let mag: CGFloat
    private let loc: CGPoint
    private weak var win: NSWindow?
    private let dx: CGFloat
    private let dy: CGFloat
    private let precise: Bool
    private let flags: NSEvent.ModifierFlags

    init(type: NSEvent.EventType, magnification: CGFloat = 0, location: CGPoint,
         window: NSWindow?, deltaX: CGFloat = 0, deltaY: CGFloat = 0,
         precise: Bool = true, modifiers: NSEvent.ModifierFlags = []) {
        self.kind = type
        self.mag = magnification
        self.loc = location
        self.win = window
        self.dx = deltaX
        self.dy = deltaY
        self.precise = precise
        self.flags = modifiers
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var type: NSEvent.EventType { kind }
    override var magnification: CGFloat { mag }
    override var locationInWindow: NSPoint { loc }
    override var window: NSWindow? { win }
    override var windowNumber: Int { win?.windowNumber ?? 0 }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var timestamp: TimeInterval { 0 }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var deltaX: CGFloat { dx }
    override var deltaY: CGFloat { dy }
    override var phase: NSEvent.Phase { [] }
    override var momentumPhase: NSEvent.Phase { [] }
}

/// A real `NSWindow` with a real `CanvasNSView` as its content view, driven by
/// real `NSEvent`s through `NSWindow.sendEvent`.
///
/// This is deliberately *not* a mock: the bug this suite exists for lived in the
/// AppKit event-coordinate conversion, which only a real window/view/event
/// triple exercises. Synthetic `CGEvent`s are not used — they are silently
/// dropped without accessibility permission — but `NSEvent.mouseEvent` +
/// `sendEvent` stays entirely inside this process.
final class CanvasHarness {
    let window: NSWindow
    let canvas: CanvasNSView
    let handler = RecordingHandler()
    let device: MTLDevice

    /// Content size in *points*.
    let contentSize: CGSize

    private var eventNumber = 0

    init(contentSize: CGSize = CGSize(width: 800, height: 600)) throws {
        _ = NSApplication.shared
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        self.device = device
        self.contentSize = contentSize
        canvas = CanvasNSView(device: device, commandQueue: device.makeCommandQueue()!)
        canvas.handler = handler
        window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 120, y: 140), size: contentSize),
                          styleMask: [.titled],
                          backing: .buffered,
                          defer: false)
        // ARC + `isReleasedWhenClosed == true` (the default for a programmatic
        // NSWindow) double-frees on `close()`.
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        // `NSWindow.sendEvent` drops mouse events for a window that was never
        // ordered in (verified: 0 of 1 events delivered while `isVisible` is
        // false, 1 of 1 after `orderFront`). The window is never made key, so
        // the test run does not steal focus.
        window.orderFront(nil)
        window.layoutIfNeeded()
        canvas.layoutSubtreeIfNeeded()
    }

    deinit { window.close() }

    var scale: CGFloat { window.backingScaleFactor }

    /// Canvas size in device pixels — the space `CanvasTransform` works in.
    var backingSize: CGSize {
        CGSize(width: canvas.bounds.width * scale, height: canvas.bounds.height * scale)
    }

    /// The canvas rect in the window's base (y-**up**) coordinate system. This is
    /// the ground truth the test's expectations are built on: a *larger* window y
    /// is visually *higher* on screen, always.
    var canvasRectInWindow: CGRect { canvas.convert(canvas.bounds, to: nil) }

    /// Window point for a location `dx` points to the right of, and `dy` points
    /// *below*, the canvas's visually top-left corner.
    func windowPoint(rightOf dx: CGFloat, below dy: CGFloat) -> CGPoint {
        let r = canvasRectInWindow
        return CGPoint(x: r.minX + dx, y: r.maxY - dy)
    }

    // MARK: - Events

    func event(_ type: NSEvent.EventType, at p: CGPoint,
               clickCount: Int, modifiers: NSEvent.ModifierFlags,
               pressure: Float = 1) -> NSEvent {
        eventNumber += 1
        guard let e = NSEvent.mouseEvent(with: type,
                                         location: p,
                                         modifierFlags: modifiers,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber,
                                         context: nil,
                                         eventNumber: eventNumber,
                                         clickCount: clickCount,
                                         pressure: pressure) else {
            fatalError("could not synthesize \(type)")
        }
        return e
    }

    /// Routes through the window, so hit-testing and responder lookup run for
    /// real. Returns whether the canvas was the view AppKit picked.
    @discardableResult
    func send(_ type: NSEvent.EventType, at p: CGPoint,
              clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = [],
              pressure: Float = 1) -> Bool {
        let hit = window.contentView?.hitTest(p) === canvas
        window.sendEvent(event(type, at: p, clickCount: clickCount,
                               modifiers: modifiers, pressure: pressure))
        return hit
    }

    func click(rightOf dx: CGFloat, below dy: CGFloat,
               clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = [],
               pressure: Float = 1) {
        let p = windowPoint(rightOf: dx, below: dy)
        send(.leftMouseDown, at: p, clickCount: clickCount, modifiers: modifiers,
             pressure: pressure)
        send(.leftMouseUp, at: p, clickCount: clickCount, modifiers: modifiers,
             pressure: pressure)
    }

    /// A press-and-drag-and-release through a list of visual canvas locations.
    func drag(through points: [(CGFloat, CGFloat)], modifiers: NSEvent.ModifierFlags = [],
              pressure: Float = 1) {
        precondition(!points.isEmpty)
        send(.leftMouseDown, at: windowPoint(rightOf: points[0].0, below: points[0].1),
             modifiers: modifiers, pressure: pressure)
        for p in points.dropFirst() {
            send(.leftMouseDragged, at: windowPoint(rightOf: p.0, below: p.1),
                 modifiers: modifiers, pressure: pressure)
        }
        let last = points[points.count - 1]
        send(.leftMouseUp, at: windowPoint(rightOf: last.0, below: last.1), modifiers: modifiers,
             pressure: pressure)
    }

    // MARK: - Keyboard

    /// AppKit's key routing needs a first responder; the window is deliberately
    /// never made key (that would steal focus), and `sendEvent` still reaches the
    /// responder chain.
    @discardableResult
    func sendKey(_ type: NSEvent.EventType, _ charsIgnoringModifiers: String,
                 characters: String? = nil,
                 modifiers: NSEvent.ModifierFlags = [],
                 isARepeat: Bool = false) -> Bool {
        window.makeFirstResponder(canvas)
        guard let e = NSEvent.keyEvent(with: type,
                                       location: .zero,
                                       modifierFlags: modifiers,
                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber,
                                       context: nil,
                                       characters: characters ?? charsIgnoringModifiers,
                                       charactersIgnoringModifiers: charsIgnoringModifiers,
                                       isARepeat: isARepeat,
                                       keyCode: 0) else {
            fatalError("could not synthesize \(type)")
        }
        window.sendEvent(e)
        return window.firstResponder === canvas
    }

    func keyDown(_ chars: String, characters: String? = nil,
                 modifiers: NSEvent.ModifierFlags = [], isARepeat: Bool = false) {
        sendKey(.keyDown, chars, characters: characters, modifiers: modifiers,
                isARepeat: isARepeat)
    }

    func keyUp(_ chars: String, modifiers: NSEvent.ModifierFlags = []) {
        sendKey(.keyUp, chars, modifiers: modifiers)
    }

    // MARK: - Scroll / pinch

    /// A scroll wheel / trackpad scroll at a visual canvas location.
    ///
    /// Routed through `sendEvent`, so AppKit's hit-testing picks the view.
    func scroll(rightOf dx: CGFloat, below dy: CGFloat,
                deltaX: CGFloat = 0, deltaY: CGFloat = 0,
                precise: Bool = true, modifiers: NSEvent.ModifierFlags = []) {
        let e = SyntheticGestureEvent(type: .scrollWheel,
                                      location: windowPoint(rightOf: dx, below: dy),
                                      window: window, deltaX: deltaX, deltaY: deltaY,
                                      precise: precise, modifiers: modifiers)
        window.sendEvent(e)
    }

    /// A pinch at a visual canvas location.
    ///
    /// Delivered straight to the view: `NSWindow.sendEvent` hands gesture events
    /// to the gesture-recogniser machinery, which drops a synthetic one (verified
    /// — the zoom did not move), so routing it through the window would test
    /// nothing.
    func magnify(rightOf dx: CGFloat, below dy: CGFloat, by magnification: CGFloat) {
        let e = SyntheticGestureEvent(type: .magnify, magnification: magnification,
                                      location: windowPoint(rightOf: dx, below: dy),
                                      window: window)
        canvas.magnify(with: e)
    }

    /// Mouse-moved and mouse-exited are tracking-area callbacks; AppKit only
    /// generates them for a key window under a real pointer, so they are
    /// delivered to the view directly.
    func moveMouse(rightOf dx: CGFloat, below dy: CGFloat) {
        canvas.mouseMoved(with: event(.mouseMoved, at: windowPoint(rightOf: dx, below: dy),
                                      clickCount: 0, modifiers: []))
    }

    func exitMouse() {
        eventNumber += 1
        guard let e = NSEvent.enterExitEvent(with: .mouseExited,
                                             location: windowPoint(rightOf: 0, below: 0),
                                             modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber,
                                             context: nil,
                                             eventNumber: eventNumber,
                                             trackingNumber: 0,
                                             userData: nil) else {
            fatalError("could not synthesize mouseExited")
        }
        canvas.mouseExited(with: e)
    }

    // MARK: - Ground-truth geometry (derived from first principles, not from
    // CanvasTransform)

    /// The zoom the canvas must be at after `setImageSize` — the whole image
    /// fits, never magnified past 1:1.
    func fitZoom(imageSize: CGSize) -> CGFloat {
        min(min(backingSize.width / imageSize.width, backingSize.height / imageSize.height), 1)
    }

    /// Where a visual point on the canvas lands in normalised image coordinates
    /// when the image is fitted: hand-derived from the layout, so it is an
    /// independent statement of what the user sees.
    func expectedNormalizedAtFit(imageSize: CGSize,
                                 rightOf dx: CGFloat, below dy: CGFloat) -> CGPoint {
        let z = fitZoom(imageSize: imageSize)
        let drawnW = imageSize.width * z, drawnH = imageSize.height * z
        // The fitted image is centred in the canvas; its top-left corner sits
        // this many device pixels right of / below the canvas's top-left corner.
        let originX = (backingSize.width - drawnW) / 2
        let originY = (backingSize.height - drawnH) / 2
        return CGPoint(x: (dx * scale - originX) / drawnW,
                       y: (dy * scale - originY) / drawnH)
    }

    /// A visual canvas location in device pixels. Valid because the canvas is
    /// flipped and its rect starts at the window origin — both asserted by
    /// `testHarnessLayoutIsWhatTheOtherTestsAssume`.
    func backingPoint(rightOf dx: CGFloat, below dy: CGFloat) -> CGPoint {
        CGPoint(x: dx * scale, y: dy * scale)
    }

    /// Normalised image point that must be under a visual canvas location for a
    /// given zoom/centre, restating the documented mapping
    /// `image = (view − viewSize/2) / zoom + centre` rather than calling it.
    func expectedNormalized(rightOf dx: CGFloat, below dy: CGFloat,
                            zoom: Double, center: CGPoint, imageSize: CGSize) -> CGPoint {
        let v = backingPoint(rightOf: dx, below: dy)
        let img = CGPoint(x: (v.x - backingSize.width / 2) / CGFloat(zoom) + center.x,
                          y: (v.y - backingSize.height / 2) / CGFloat(zoom) + center.y)
        return CGPoint(x: img.x / imageSize.width, y: img.y / imageSize.height)
    }
}

func XCTAssertClose(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 1e-4,
                    _ message: String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(Double(a), Double(b), accuracy: Double(tol), message, file: file, line: line)
}
