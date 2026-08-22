import AppKit
import CoreGraphics
import GrayroomCanvas
import GrayroomCore
import GrayroomUI
import ImageIO
import Metal
import Observation
import UniformTypeIdentifiers

/// `GRAYROOM_SELFTEST=paint|undo swift run GrayroomApp <file.DNG>`
///
/// Two whole-app repros, each in its own process: `paint` (a stroke drawn with
/// real mouse events) and `undo` (Cmd-Z / Cmd-Shift-Z pushed through the real
/// menu-bar key-equivalent path). Both print PASS/FAIL lines and exit non-zero
/// on failure.
///
/// Repro (c): the whole app, in its own process, painting a stroke with real
/// `NSEvent`s and then telling you — on stdout, in the library and in a
/// screenshot of its own window — where that stroke went.
///
/// It exists because the unit tests can only prove that the canvas's *own* math
/// is self-consistent. This is the only check that runs the real SwiftUI window,
/// the real toolbar/sidebar layout, the real decode and the real presented
/// drawable, i.e. the thing the user actually reported on.
///
/// Nothing here is reachable without the environment variable, and it writes a
/// development into the real library for whatever RAW it was pointed at.
enum SelfTest {
    enum Mode: String {
        /// Repro (c): a stroke painted with real `NSEvent`s.
        case paint
        /// Repro (d): Cmd-Z / Cmd-Shift-Z pushed through the real menu-bar key
        /// equivalent path, which is where the undo bug actually lived.
        case undo
    }

    static var mode: Mode? {
        ProcessInfo.processInfo.environment["GRAYROOM_SELFTEST"].flatMap(Mode.init(rawValue:))
    }

    static var isRequested: Bool { mode != nil }

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
            switch mode {
            case .paint, nil: run(canvas: canvas, model: model)
            case .undo: runUndo(canvas: canvas, model: model)
            }
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

        // A clean slate: whatever edit was stored must not colour the result.
        prepareForPainting(model)
        // So the screenshot *shows* where the paint landed, not just where the
        // cursor was.
        model.showMaskOverlay = true

        let targets = paintStroke(canvas: canvas, window: window, model: model)
        settle(model) { finish(canvas: canvas, window: window, model: model, targets: targets) }
    }

    /// Empty edit, one mask, brush tool — the starting point of both self-tests.
    private static func prepareForPainting(_ model: AppModel) {
        model.store.replace(EditState(), named: nil)
        model.store.addMask()
        model.updateBrush { $0.size = 0.06; $0.feather = 50; $0.flow = 100; $0.density = 100 }
        model.tool = .brush
    }

    /// Paints a diagonal across the image's top-left quadrant with synthesized
    /// mouse events and returns the normalized points it aimed at.
    @discardableResult
    private static func paintStroke(canvas: CanvasNSView, window: NSWindow,
                                    model: AppModel) -> [CGPoint] {
        let imageSize = model.previewSize

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
        return targets
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
        model.saveNow()

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

    // MARK: - The undo test

    /// `GRAYROOM_SELFTEST=undo swift run GrayroomApp <copy-of-file.DNG>`
    ///
    /// Paints a stroke, then drives **Cmd-Z / Cmd-Shift-Z as key events through
    /// `NSApp.sendEvent`** — the same path a real keystroke takes, menu-bar key
    /// equivalent matching and menu-item enablement included. That matters
    /// because a disabled menu item swallows its shortcut silently: the bug
    /// reproduces here and nowhere in the unit tests.
    private static func runUndo(canvas: CanvasNSView, model: AppModel) {
        guard let window = canvas.window else { fail("canvas has no window") }
        let store = model.store
        var failures: [String] = []

        func check(_ ok: Bool, _ what: String) {
            log("undo self-test: \(ok ? "PASS" : "FAIL") — \(what)")
            if !ok { failures.append(what) }
        }
        func state(_ label: String) {
            log("undo self-test: \(label): canUndo=\(store.canUndo) canRedo=\(store.canRedo) "
                + "menuUndo=\(menuItemState("Undo")) menuRedo=\(menuItemState("Redo")) "
                + "strokes=\(strokeCount(store)) exposure=\(store.edit.tone.exposure)")
        }

        trackUndoAvailability(store)
        dumpMenus()
        prepareForPainting(model)
        state("after setup")
        paintStroke(canvas: canvas, window: window, model: model)

        let steps: [() -> Void] = [
            {
                state("after painting")
                check(strokeCount(store) == 1, "a stroke was painted")
                check(store.canUndo, "canUndo is true after painting")
                check(menuItemState("Undo") == "enabled", "the Undo menu item is live")
                check(menuItemState("Redo") == "DISABLED", "the Redo menu item is greyed out")
                sendKey("z", modifiers: .command, window: window)
            },
            {
                state("after Cmd-Z")
                check(strokeCount(store) == 0, "Cmd-Z removed the stroke")
                check(store.canRedo, "canRedo is true after undoing")
                check(menuItemState("Redo") == "enabled", "the Redo menu item went live")
                sendKey("z", modifiers: [.command, .shift], window: window)
            },
            {
                state("after Cmd-Shift-Z")
                check(strokeCount(store) == 1, "Cmd-Shift-Z restored the stroke")
                // A slider-style change made through the store API, undone
                // through the keyboard.
                store.perform("Exposure") { $0.tone.exposure = 1.25 }
            },
            {
                state("after the exposure change")
                check(store.edit.tone.exposure == 1.25, "the exposure change applied")
                sendKey("z", modifiers: .command, window: window)
            },
            {
                state("after Cmd-Z")
                check(store.edit.tone.exposure == 0, "Cmd-Z reverted the exposure change")
                check(strokeCount(store) == 1, "…and left the stroke alone")
            },
        ]

        runSteps(steps, model: model) {
            if failures.isEmpty {
                log("undo self-test: PASS (all \(steps.count) checkpoints)")
                exit(0)
            }
            log("undo self-test: FAILED — \(failures.count) check(s): "
                + failures.joined(separator: "; "))
            exit(4)
        }
    }

    private static func strokeCount(_ store: EditStateStore) -> Int {
        store.edit.masks.reduce(0) { $0 + $1.strokes.count }
    }

    /// Runs each step with a settle (render/decode quiescence) in between.
    private static func runSteps(_ steps: [() -> Void], model: AppModel,
                                 then done: @escaping () -> Void) {
        guard let first = steps.first else { done(); return }
        first()
        settle(model) { runSteps(Array(steps.dropFirst()), model: model, then: done) }
    }

    /// Pushes a real keystroke into the app.
    ///
    /// The event is built as a **`CGEvent`** and converted with
    /// `NSEvent(cgEvent:)`, not with `NSEvent.keyEvent(with:…)`. That is not
    /// incidental: AppKit's menu key-equivalent matching consults the event's
    /// underlying CGEvent (key code plus the current keyboard layout), so a
    /// hand-rolled `NSEvent` with the "right" character strings matches
    /// differently from a real keystroke — measured here: a hand-rolled
    /// Cmd-Shift-Z matched nothing at all, while the CGEvent-shaped one matches
    /// Redo. A self-test that used the hand-rolled form would report a bug the
    /// user does not have, or miss one they do.
    ///
    /// `NSApp.sendEvent` is the same entry point the window server uses, so this
    /// goes through menu key-equivalent matching, item validation and all.
    private static func sendKey(_ characters: String, modifiers: NSEvent.ModifierFlags,
                                window: NSWindow) {
        log("undo self-test: sending key \(describe(modifiers))\(characters)")
        guard let source = CGEventSource(stateID: .privateState) else {
            fail("could not make a CGEventSource")
        }
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        for isDown in [true, false] {
            guard let cg = CGEvent(keyboardEventSource: source, virtualKey: 6 /* Z */,
                                   keyDown: isDown) else { fail("could not make a CGEvent") }
            cg.flags = flags
            guard let event = NSEvent(cgEvent: cg) else { fail("CGEvent -> NSEvent failed") }
            if isDown {
                log("undo self-test:   event characters='\(event.characters ?? "")' "
                    + "ignoringModifiers='\(event.charactersIgnoringModifiers ?? "")' "
                    + "flags=\(event.modifierFlags.rawValue)")
            }
            NSApp.sendEvent(event)
        }
    }

    private static func describe(_ modifiers: NSEvent.ModifierFlags) -> String {
        (modifiers.contains(.command) ? "Cmd-" : "") + (modifiers.contains(.shift) ? "Shift-" : "")
    }

    /// What the menu bar thinks of an item right now — the thing that decides
    /// whether the key equivalent fires at all.
    private static func menuItemState(_ title: String) -> String {
        guard let main = NSApp.mainMenu else { return "no-main-menu" }
        for top in main.items {
            guard let submenu = top.submenu else { continue }
            submenu.update()
            if let item = submenu.items.first(where: { $0.title == title }) {
                return item.isEnabled ? "enabled" : "DISABLED"
            }
        }
        return "missing"
    }

    /// Every menu item AppKit currently has, with the facts that decide whether
    /// a key equivalent fires: enablement, autoenabling, target and action.
    private static func dumpMenus() {
        guard let main = NSApp.mainMenu else {
            log("undo self-test: NSApp.mainMenu is nil")
            return
        }
        for top in main.items {
            guard let submenu = top.submenu else { continue }
            submenu.update()
            log("undo self-test: menu '\(top.title)' autoenables=\(submenu.autoenablesItems)")
            for item in submenu.items where !item.isSeparatorItem {
                log("undo self-test:   item '\(item.title)' enabled=\(item.isEnabled) "
                    + "key='\(item.keyEquivalent)' mask=\(item.keyEquivalentModifierMask.rawValue) "
                    + "action=\(item.action.map(String.init(describing:)) ?? "nil") "
                    + "target=\(item.target.map { String(describing: type(of: $0)) } ?? "nil")")
            }
        }
    }

    /// Logs every Observation notification for `canUndo` / `canRedo`, i.e. every
    /// moment SwiftUI would re-evaluate the Edit menu's `.disabled(…)`.
    private static func trackUndoAvailability(_ store: EditStateStore) {
        withObservationTracking {
            _ = store.canUndo
            _ = store.canRedo
        } onChange: {
            DispatchQueue.main.async {
                log("undo self-test: observation fired -> canUndo=\(store.canUndo) "
                    + "canRedo=\(store.canRedo)")
                trackUndoAvailability(store)
            }
        }
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

        // The drawable is display-linear `rgba16Float`, so the screenshot has to
        // be encoded here: sRGB, tone-mapped by a plain clip at SDR white (this
        // is a debugging artefact, not an HDR deliverable).
        var halfs = [Float16](repeating: 0, count: w * h * 4)
        halfs.withUnsafeMutableBytes {
            target.getBytes($0.baseAddress!,
                            bytesPerRow: w * 4 * MemoryLayout<Float16>.size,
                            from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        }
        func encode(_ v: Float16) -> UInt8 {
            let c = min(max(Double(v), 0), 1)
            let s = c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
            return UInt8(min(max((s * 255).rounded(), 0), 255))
        }
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            bytes[i * 4] = encode(halfs[i * 4])
            bytes[i * 4 + 1] = encode(halfs[i * 4 + 1])
            bytes[i * 4 + 2] = encode(halfs[i * 4 + 2])
        }
        let info: CGBitmapInfo = [CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)]
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)
                                      ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info,
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

    /// A trace line from elsewhere in the app, printed only while a self-test is
    /// running so the normal app stays silent.
    static func note(_ message: String) {
        guard isRequested else { return }
        log("trace: " + message)
    }

    private static func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    private static func fail(_ message: String) -> Never {
        log("self-test FAILED: \(message)")
        exit(2)
    }
}





