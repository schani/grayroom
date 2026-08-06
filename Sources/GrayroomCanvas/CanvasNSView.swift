import AppKit
import CoreGraphics
import GrayroomUI
import Metal
import MetalKit
import simd

/// What a click-drag on the canvas does.
public enum CanvasTool: String, CaseIterable {
    case pan, brush, targeted

    public var label: String {
        switch self {
        case .pan: return "Pan"
        case .brush: return "Brush"
        case .targeted: return "Targeted"
        }
    }
}

public enum CanvasKeyCommand {
    case toggleBrush
    case toggleTargeted
    case toggleEraser
    case sizeStep(Int)
    case featherStep(Int)
    case fit
    case actualSize
}

public protocol CanvasInputHandler: AnyObject {
    func canvasTransformChanged(_ transform: CanvasTransform)
    func canvasBeginStroke(atNormalized p: CGPoint, pressure: Double, erase: Bool)
    func canvasExtendStroke(toNormalized p: CGPoint, pressure: Double)
    func canvasEndStroke()
    func canvasBeginTargeted(atNormalized p: CGPoint)
    func canvasDragTargeted(dragPixels: Double)
    func canvasEndTargeted()
    func canvasKeyCommand(_ command: CanvasKeyCommand)
    func canvasBeforeAfterHeld(_ held: Bool)
}

/// Uniforms for `Canvas.metal`. `float2`s first so the Swift and MSL layouts
/// agree without padding games.
public struct CanvasUniforms {
    public var viewSize = SIMD2<Float>(1, 1)
    public var imageSize = SIMD2<Float>(1, 1)
    public var center = SIMD2<Float>(0, 0)
    public var cursor = SIMD2<Float>(-1, -1)
    public var zoom: Float = 1
    public var overlay: Float = 0
    public var cursorRadius: Float = 0
    public var cursorInner: Float = 0
    public var nearest: Float = 0
    public init() {}
}

/// The image canvas: one window-sized `MTKView` that draws the current output
/// texture as a textured quad with a zoom/pan transform in the shader.
///
/// Deliberately **not** a giant view in an `NSScrollView` — see
/// `research/mac-app-stack.md` §4. The drawable stays window-sized at every zoom
/// level, so memory is constant and the 16 384 px texture limit is irrelevant.
///
/// Drawing is on demand (`isPaused` + `enableSetNeedsDisplay`), never a 60 Hz
/// treadmill: nothing animates, so a frame is only worth drawing when the
/// texture, the transform or the cursor changed.
public final class CanvasNSView: MTKView {
    public weak var handler: CanvasInputHandler?

    public var tool: CanvasTool = .pan { didSet { updateCursorVisibility() } }
    public var eraserActive = false { didSet { needsDisplay = true } }

    public private(set) var transform = CanvasTransform(imageSize: CGSize(width: 1, height: 1),
                                                 viewSize: CGSize(width: 1, height: 1),
                                                 zoom: 1, center: .zero)

    /// Brush diameter as a fraction of the image long edge, for the cursor ring.
    public var brushSize: Double = 0.05 { didSet { needsDisplay = true } }
    public var brushFeather: Double = 50 { didSet { needsDisplay = true } }

    public var imageTexture: MTLTexture? { didSet { needsDisplay = true } }
    public var coverageTexture: MTLTexture? { didSet { needsDisplay = true } }
    public var showOverlay = false { didSet { needsDisplay = true } }

    private var pipelineState: MTLRenderPipelineState?
    private let commandQueue: MTLCommandQueue
    private var cursorLocation: CGPoint?
    private var trackingArea: NSTrackingArea?

    // Drag state
    private enum Drag {
        case none
        case pan(lastView: CGPoint)
        case paint
        case targeted(startView: CGPoint)
    }
    private var drag: Drag = .none
    private var backslashHeld = false

    public init(device: MTLDevice, commandQueue: MTLCommandQueue) {
        self.commandQueue = commandQueue
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        // Tag the drawable sRGB so the window server colour-matches it to the
        // display profile (wave 3, audit `decode-output` #9). Without this the
        // pipeline's sRGB-encoded values were handed to the display raw and
        // interpreted in *its* space: on a P3 or wider panel every toned image
        // was drawn noticeably more saturated than the exported sRGB file, so
        // the split-toning sliders lied about the result. A neutral B&W frame is
        // unaffected either way (R = G = B is the same neutral in any RGB
        // space). This is also the hook to change for EDR previews later.
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        clearColor = MTLClearColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1)
        layer?.isOpaque = true
        delegate = self
        buildPipeline()
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) { fatalError("not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildPipeline() {
        guard let device else { return }
        do {
            let library = try device.makeLibrary(source: CanvasShaders.source, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "canvasVertex")
            d.fragmentFunction = library.makeFunction(name: "canvasFragment")
            d.colorAttachments[0].pixelFormat = colorPixelFormat
            pipelineState = try device.makeRenderPipelineState(descriptor: d)
        } catch {
            NSLog("Grayroom: canvas shader failed to compile: \(error)")
        }
    }

    // MARK: - Transform

    /// Called when a new image is loaded: refit.
    public func setImageSize(_ size: CGSize) {
        transform = CanvasTransform.fitting(imageSize: size, viewSize: backingSize)
        handler?.canvasTransformChanged(transform)
        needsDisplay = true
    }

    private var backingSize: CGSize {
        let scale = window?.backingScaleFactor ?? 1
        return CGSize(width: max(bounds.width * scale, 1),
                      height: max(bounds.height * scale, 1))
    }

    private func setTransform(_ t: CanvasTransform) {
        transform = t
        handler?.canvasTransformChanged(t)
        needsDisplay = true
    }

    public func zoomToFit() {
        setTransform(CanvasTransform.fitting(imageSize: transform.imageSize, viewSize: backingSize))
    }

    public func zoomToActualSize() {
        setTransform(transform.zoomed(to: 1, anchorView: CGPoint(x: backingSize.width / 2,
                                                                 y: backingSize.height / 2)))
    }

    /// Device-pixel location of an event in this view.
    ///
    /// NOT `convertToBacking(_ point:)`: for a flipped view that returns a
    /// *negated* y (backing space is bottom-up), which inverted vertical pan
    /// and scrambled brush coordinates. Scale explicitly instead — the local
    /// point is already in this view's flipped (y-down) coordinates.
    private func backingPoint(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 1
        return CGPoint(x: local.x * scale, y: local.y * scale)
    }

    // MARK: - Tracking / cursor

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        setTransform(transform.resized(viewSize: backingSize))
    }

    private func updateCursorVisibility() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    public override func resetCursorRects() {
        // In brush mode the ring *is* the cursor, so hide the arrow.
        if tool == .brush {
            addCursorRect(bounds, cursor: .crosshair)
        } else if tool == .targeted {
            addCursorRect(bounds, cursor: .crosshair)
        } else {
            addCursorRect(bounds, cursor: .openHand)
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        cursorLocation = backingPoint(event)
        if tool == .brush { needsDisplay = true }
    }

    public override func mouseExited(with event: NSEvent) {
        cursorLocation = nil
        needsDisplay = true
    }

    // MARK: - Mouse

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = backingPoint(event)
        cursorLocation = p

        if event.clickCount == 2 {
            setTransform(transform.toggledFitAndActualSize(anchorView: p))
            drag = .none
            return
        }

        switch tool {
        case .brush:
            let erase = eraserActive || event.modifierFlags.contains(.option)
            handler?.canvasBeginStroke(atNormalized: transform.normalizedPoint(fromView: p),
                                       pressure: Double(event.pressure), erase: erase)
            drag = .paint
        case .targeted:
            handler?.canvasBeginTargeted(atNormalized: transform.normalizedPoint(fromView: p))
            drag = .targeted(startView: p)
        case .pan:
            drag = .pan(lastView: p)
        }
    }

    public override func mouseDragged(with event: NSEvent) {
        let p = backingPoint(event)
        cursorLocation = p
        switch drag {
        case .none:
            break
        case .pan(let last):
            setTransform(transform.panned(byViewDelta: CGSize(width: p.x - last.x,
                                                              height: p.y - last.y)))
            drag = .pan(lastView: p)
        case .paint:
            handler?.canvasExtendStroke(toNormalized: transform.normalizedPoint(fromView: p),
                                        pressure: Double(event.pressure))
        case .targeted(let start):
            // Up brightens, like Lightroom's TAT. y is down, so negate.
            handler?.canvasDragTargeted(dragPixels: Double(start.y - p.y))
        }
        if tool == .brush { needsDisplay = true }
    }

    public override func mouseUp(with event: NSEvent) {
        switch drag {
        case .paint: handler?.canvasEndStroke()
        case .targeted: handler?.canvasEndTargeted()
        default: break
        }
        drag = .none
    }

    // MARK: - Zoom / pan gestures

    public override func scrollWheel(with event: NSEvent) {
        let p = backingPoint(event)
        if event.modifierFlags.contains(.command) {
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 4
            setTransform(transform.scaled(by: exp(Double(dy) * 0.01), anchorView: p))
        } else {
            var dx = event.scrollingDeltaX
            var dy = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas { dx *= 8; dy *= 8 }
            let scale = window?.backingScaleFactor ?? 1
            setTransform(transform.panned(byViewDelta: CGSize(width: dx * scale, height: dy * scale)))
        }
    }

    public override func magnify(with event: NSEvent) {
        let p = backingPoint(event)
        setTransform(transform.scaled(by: 1 + Double(event.magnification), anchorView: p))
    }

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, let c = chars.first else {
            super.keyDown(with: event)
            return
        }
        let shift = event.modifierFlags.contains(.shift)
        switch c {
        case "\\":
            if !backslashHeld {
                backslashHeld = true
                handler?.canvasBeforeAfterHeld(true)
            }
        case "b", "B": handler?.canvasKeyCommand(.toggleBrush)
        case "t", "T": handler?.canvasKeyCommand(.toggleTargeted)
        case "e", "E": handler?.canvasKeyCommand(.toggleEraser)
        case "[", "{": handler?.canvasKeyCommand(shift ? .featherStep(-1) : .sizeStep(-1))
        case "]", "}": handler?.canvasKeyCommand(shift ? .featherStep(1) : .sizeStep(1))
        case "0": handler?.canvasKeyCommand(.fit)
        case "1": handler?.canvasKeyCommand(.actualSize)
        default: super.keyDown(with: event)
        }
    }

    public override func keyUp(with event: NSEvent) {
        if event.charactersIgnoringModifiers?.first == "\\" {
            backslashHeld = false
            handler?.canvasBeforeAfterHeld(false)
        } else {
            super.keyUp(with: event)
        }
    }

    // MARK: - Uniforms

    /// The uniforms the next frame will be drawn with. Public so a test can
    /// check them against the transform the input path uses.
    public func currentUniforms() -> CanvasUniforms { makeUniforms() }

    private func makeUniforms() -> CanvasUniforms {
        var u = CanvasUniforms()
        // `transform.viewSize`, NOT `backingSize`: the display and the input
        // mapping have to invert *the same* transform, or a click lands
        // somewhere other than where the pixel under it was drawn. The two
        // agree in the steady state, but `bounds` and the drawable size do not
        // change atomically (a live resize updates them from different
        // callbacks), and this is the number `CanvasTransform` was inverted
        // with when the event arrived.
        let vs = transform.viewSize
        u.viewSize = SIMD2<Float>(Float(vs.width), Float(vs.height))
        u.imageSize = SIMD2<Float>(Float(max(transform.imageSize.width, 1)),
                                   Float(max(transform.imageSize.height, 1)))
        u.center = SIMD2<Float>(Float(transform.center.x), Float(transform.center.y))
        u.zoom = Float(transform.zoom)
        u.overlay = (showOverlay && coverageTexture != nil) ? 1 : 0
        // Above 2x, show the actual preview pixels rather than a smoothed lie.
        u.nearest = transform.zoom >= 2 ? 1 : 0
        if tool == .brush, let cursor = cursorLocation {
            let r = BrushSizing.screenRadius(size: brushSize, transform: transform)
            u.cursor = SIMD2<Float>(Float(cursor.x), Float(cursor.y))
            u.cursorRadius = Float(max(r, 2))
            u.cursorInner = Float(BrushSizing.innerRadius(radius: max(r, 2), feather: brushFeather))
        }
        return u
    }
}

// MARK: - Drawing

extension CanvasNSView: MTKViewDelegate {
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        setTransform(transform.resized(viewSize: CGSize(width: max(size.width, 1),
                                                        height: max(size.height, 1))))
    }

    public func draw(in view: MTKView) {
        guard let descriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let buffer = commandQueue.makeCommandBuffer() else { return }
        encodeCanvas(into: descriptor, commandBuffer: buffer)
        buffer.present(drawable)
        buffer.commit()
    }

    /// Encodes one canvas frame into `descriptor`'s colour attachment.
    ///
    /// Split out of `draw(in:)` so the closed-loop display-vs-input test can
    /// render into an offscreen texture through *exactly* the same uniforms,
    /// pipeline state and shader that the screen sees. Nothing here may consult
    /// the drawable: the only geometry input is `transform`.
    public func encodeCanvas(into descriptor: MTLRenderPassDescriptor,
                             commandBuffer buffer: MTLCommandBuffer) {
        guard let pipelineState,
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        if let image = imageTexture {
            var u = makeUniforms()
            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(image, index: 0)
            encoder.setFragmentTexture(coverageTexture ?? image, index: 1)
            encoder.setFragmentBytes(&u, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
    }
}
