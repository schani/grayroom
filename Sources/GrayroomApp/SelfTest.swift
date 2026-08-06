import AppKit
import CoreGraphics
import GrayroomCanvas
import GrayroomCore
import GrayroomUI
import ImageIO
import Metal
import UniformTypeIdentifiers

/// `GRAYROOM_SELFTEST=paint swift run GrayroomApp <file.DNG>`
///
/// Repro (c): the whole app, in its own process, painting a stroke with real
/// `NSEvent`s and then telling you — on stdout, in the sidecar and in a
/// screenshot of its own window — where that stroke went.
///
/// It exists because the unit tests can only prove that the canvas's *own* math
/// is self-consistent. This is the only check that runs the real SwiftUI window,
/// the real toolbar/sidebar layout, the real decode and the real presented
/// drawable, i.e. the thing the user actually reported on.
///
/// Nothing here is reachable without the environment variable, and the sidecar it
/// writes goes next to whatever RAW it was pointed at — point it at a *copy*.
enum SelfTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["GRAYROOM_SELFTEST"] == "paint"
    }

    private static var outputDirectory: URL {
        let path = ProcessInfo.processInfo.environment["GRAYROOM_SELFTEST_OUT"] ?? "out"
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static var deadline = Date().addingTimeInterval(120)

    static func startIfRequested() {
        guard isRequested else { return }
        log("self-test: waiting for the first render")
        poll()
    }

    // MARK: - Waiting

    private static func poll() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let model = AppModel.shared
            guard Date() < deadline else { fail("timed out waiting for the first render") }
            guard let canvas = findCanvas(), canvas.window != nil,
                  model.previewSize != .zero, canvas.imageTexture != nil,
                  !model.isDecoding, !model.isRendering else {
                poll()
                return
            }
            run(canvas: canvas, model: model)
        }
    }

    private static func findCanvas() -> CanvasNSView? {
        func search(_ view: NSView) -> CanvasNSView? {
            if let c = view as? CanvasNSView { return c }
            for sub in view.subviews { if let c = search(sub) { return c } }
            return nil
        }
        for window in NSApp.windows {
            if let root = window.contentView, let c = search(root) { return c }
        }
        return nil
    }

    private static func settle(_ model: AppModel, then body: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if model.isRendering || model.isDecoding, Date() < deadline {
                settle(model, then: body)
            } else {
                body()
            }
        }
    }

    // MARK: - The test

    private static func run(canvas: CanvasNSView, model: AppModel) {
        guard let window = canvas.window else { fail("canvas has no window") }
        let imageSize = model.previewSize

        // A clean slate: whatever sidecar was on disk must not colour the result.
        model.store.replace(EditState(), named: nil)
        model.store.addMask()
        model.updateBrush { $0.size = 0.06; $0.feather = 50; $0.flow = 100; $0.density = 100 }
        model.tool = .brush
        // So the screenshot *shows* where the paint landed, not just where the
        // cursor was.
        model.showMaskOverlay = true

        // --- Ground truth, computed from the window layout only -------------
        // Where the fitted image sits inside the canvas, in device pixels:
        let scale = window.backingScaleFactor
        let viewW = canvas.bounds.width * scale
        let viewH = canvas.bounds.height * scale
        let zoom = min(min(viewW / imageSize.width, viewH / imageSize.height), 1)
        let drawnW = imageSize.width * zoom
        let drawnH = imageSize.height * zoom
        let originX = (viewW - drawnW) / 2
        let originY = (viewH - drawnH) / 2
        // The canvas rect in the window's y-**up** base coordinates:
        let rect = canvas.convert(canvas.bounds, to: nil)

        /// Normalised image point -> window point, without touching
        /// `CanvasTransform`.
        func windowPoint(normalized n: CGPoint) -> CGPoint {
            let deviceX = originX + n.x * drawnW          // from the canvas's left
            let deviceY = originY + n.y * drawnH          // *below* the canvas's top
            return CGPoint(x: rect.minX + deviceX / scale,
                           y: rect.maxY - deviceY / scale)
        }

        // A diagonal across the image's TOP-LEFT quadrant.
        let targets: [CGPoint] = stride(from: 0.20, through: 0.36, by: 0.02)
            .map { CGPoint(x: $0, y: $0) }
        log(String(format: "self-test: preview %.0fx%.0f, canvas %.0fx%.0f device px, zoom %.4f",
                   imageSize.width, imageSize.height, viewW, viewH, zoom))
        log("self-test: intended normalized points = "
            + targets.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) }.joined(separator: " "))

        // --- Paint with real events -----------------------------------------
        var number = 0
        func send(_ type: NSEvent.EventType, at p: CGPoint) {
            number += 1
            guard let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: number, clickCount: 1, pressure: 1)
            else { fail("could not synthesize \(type)") }
            window.sendEvent(e)
        }

        send(.leftMouseDown, at: windowPoint(normalized: targets[0]))
        for t in targets.dropFirst() { send(.leftMouseDragged, at: windowPoint(normalized: t)) }
        send(.leftMouseUp, at: windowPoint(normalized: targets.last!))

        settle(model) { finish(canvas: canvas, window: window, model: model, targets: targets) }
    }

    private static func finish(canvas: CanvasNSView, window: NSWindow,
                               model: AppModel, targets: [CGPoint]) {
        guard let stroke = model.store.edit.masks.last?.strokes.last else {
            fail("no stroke was recorded — the events never reached the canvas")
        }
        log("self-test: recorded normalized points = "
            + stroke.points.map { String(format: "(%.3f,%.3f)", $0.x, $0.y) }.joined(separator: " "))
        let xs = stroke.points.map(\.x), ys = stroke.points.map(\.y)
        log(String(format: "self-test: x range %.3f…%.3f, y range %.3f…%.3f",
                   xs.min()!, xs.max()!, ys.min()!, ys.max()!))

        log("self-test: showMaskOverlay=\(model.showMaskOverlay) "
            + "canvas.showOverlay=\(canvas.showOverlay) "
            + "coverageTexture=\(canvas.coverageTexture != nil) "
            + "selectedMaskIndex=\(String(describing: model.store.selectedMaskIndex))")

        try? FileManager.default.createDirectory(at: outputDirectory,
                                                 withIntermediateDirectories: true)
        model.saveSidecarNow()
        if let url = model.imageURL {
            log("self-test: sidecar = \(EditState.sidecarURL(forRAW: url).path)")
        }

        writeWindowScreenshot(window: window)
        writeCanvasRender(canvas: canvas)

        // Non-zero only if the stroke is not where it was aimed; the numeric
        // coverage check lives in the shell script that drives this.
        let ok = zip(stroke.points, targets).allSatisfy {
            abs($0.x - $1.x) < 0.01 && abs($0.y - $1.y) < 0.01
        } && stroke.points.count == targets.count
        log("self-test: points match intent = \(ok)")
        exit(ok ? 0 : 3)
    }

    // MARK: - Output

    private static func writeWindowScreenshot(window: NSWindow) {
        let url = outputDirectory.appendingPathComponent("selftest-paint.png")
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                  CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]) else {
            log("self-test: CGWindowListCreateImage returned nil "
                + "(screen-recording permission?) — see selftest-canvas.png instead")
            return
        }
        write(image, to: url)
        log("self-test: wrote \(url.path) (\(image.width)x\(image.height))")
    }

    /// The canvas alone, re-rendered offscreen through the very same shader and
    /// uniforms the window is showing. Always available, no permissions needed.
    private static func writeCanvasRender(canvas: CanvasNSView) {
        guard let device = canvas.device, let queue = device.makeCommandQueue() else { return }
        let size = canvas.transform.viewSize
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: canvas.colorPixelFormat,
                                                         width: w, height: h, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .shared
        guard let target = device.makeTexture(descriptor: d),
              let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = canvas.clearColor
        pass.colorAttachments[0].storeAction = .store
        canvas.encodeCanvas(into: pass, commandBuffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!, bytesPerRow: w * 4,
                            from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        let info: CGBitmapInfo = [.byteOrder32Little,
                                  CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)]
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return }
        let url = outputDirectory.appendingPathComponent("selftest-canvas.png")
        write(image, to: url)
        log("self-test: wrote \(url.path) (\(w)x\(h))")
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString,
                                                         1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    private static func fail(_ message: String) -> Never {
        log("self-test FAILED: \(message)")
        exit(2)
    }
}





