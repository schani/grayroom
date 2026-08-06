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
    var endCount = 0
    var targetedBegins: [CGPoint] = []
    var targetedDrags: [Double] = []
    var transforms: [CanvasTransform] = []
    var keyCommands: [CanvasKeyCommand] = []

    func canvasTransformChanged(_ transform: CanvasTransform) { transforms.append(transform) }
    func canvasBeginStroke(atNormalized p: CGPoint, pressure: Double, erase: Bool) {
        begins.append(Begin(point: p, pressure: pressure, erase: erase))
    }
    func canvasExtendStroke(toNormalized p: CGPoint, pressure: Double) { extends.append(p) }
    func canvasEndStroke() { endCount += 1 }
    func canvasBeginTargeted(atNormalized p: CGPoint) { targetedBegins.append(p) }
    func canvasDragTargeted(dragPixels: Double) { targetedDrags.append(dragPixels) }
    func canvasEndTargeted() {}
    func canvasKeyCommand(_ command: CanvasKeyCommand) { keyCommands.append(command) }
    func canvasBeforeAfterHeld(_ held: Bool) {}
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

    private func event(_ type: NSEvent.EventType, at p: CGPoint,
                       clickCount: Int, modifiers: NSEvent.ModifierFlags) -> NSEvent {
        eventNumber += 1
        guard let e = NSEvent.mouseEvent(with: type,
                                         location: p,
                                         modifierFlags: modifiers,
                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                         windowNumber: window.windowNumber,
                                         context: nil,
                                         eventNumber: eventNumber,
                                         clickCount: clickCount,
                                         pressure: 1) else {
            fatalError("could not synthesize \(type)")
        }
        return e
    }

    /// Routes through the window, so hit-testing and responder lookup run for
    /// real. Returns whether the canvas was the view AppKit picked.
    @discardableResult
    func send(_ type: NSEvent.EventType, at p: CGPoint,
              clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        let hit = window.contentView?.hitTest(p) === canvas
        window.sendEvent(event(type, at: p, clickCount: clickCount, modifiers: modifiers))
        return hit
    }

    func click(rightOf dx: CGFloat, below dy: CGFloat,
               clickCount: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        let p = windowPoint(rightOf: dx, below: dy)
        send(.leftMouseDown, at: p, clickCount: clickCount, modifiers: modifiers)
        send(.leftMouseUp, at: p, clickCount: clickCount, modifiers: modifiers)
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
}

func XCTAssertClose(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 1e-4,
                    _ message: String = "",
                    file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(Double(a), Double(b), accuracy: Double(tol), message, file: file, line: line)
}
