import AppKit
import CoreGraphics
import GrayroomCanvas
import GrayroomCore
import GrayroomUI

/// `GRAYROOM_SELFTEST=wb` — see `SelfTest.Mode.whiteBalance`.
extension SelfTest {
    // MARK: - The white balance selector test

    /// `GRAYROOM_SELFTEST=wb swift run GrayroomApp <copy-of-file.DNG>`
    ///
    /// Drives Lightroom's `W` and Escape as real keystrokes, clicks the canvas
    /// with a real mouse event, and reads the canvas's own texture back: the
    /// only check that the point the eyedropper was aimed at is the point that
    /// came out neutral on screen.
    static func runWhiteBalance(canvas: CanvasNSView, model: AppModel) {
        guard let window = canvas.window else { fail("canvas has no window") }
        let store = model.store
        var failures: [String] = []
        /// Where the click lands, and where the render is read back.
        let target = CGPoint(x: 0.3, y: 0.7)

        func check(_ ok: Bool, _ what: String) {
            log("wb self-test: \(ok ? "PASS" : "FAIL") — \(what)")
            if !ok { failures.append(what) }
        }
        func state(_ label: String) {
            log("wb self-test: \(label): tool=\(model.tool) "
                + "temperature=\(String(describing: store.edit.whiteBalance.temperature)) "
                + "tint=\(String(describing: store.edit.whiteBalance.tint)) "
                + "asShot=\(store.isAsShotWhiteBalance) "
                + "status='\(model.statusMessage ?? "")' canUndo=\(store.canUndo)")
        }
        /// r/g and b/g of the canvas's 5×5 around the clicked point.
        func rendered() -> (Double, Double)? {
            guard let texture = canvas.imageTexture,
                  let rgb = try? WhiteBalancePicker.mean(texture, at: target),
                  rgb.y > 1e-6 else { return nil }
            return (rgb.x / rgb.y, rgb.z / rgb.y)
        }
        func press(_ characters: String, virtualKey: CGKeyCode) {
            sendKey(characters, modifiers: [], window: window, virtualKey: virtualKey,
                    viaQueue: true)
        }

        let steps: [() -> Void] = [
            {
                store.replace(EditState(), named: nil)
                model.tool = .pan
            },
            {
                state("after the reset")
                check(store.isAsShotWhiteBalance, "the app opens on the as-shot white balance")
                check(controlFrame(named: "wb-picker") != nil,
                      "the White Balance panel has an eyedropper")
                press("w", virtualKey: 13)
            },
            {
                state("after W")
                check(model.tool == .whiteBalance, "W armed the eyedropper")
                press("w", virtualKey: 13)
            },
            {
                state("after W again")
                check(model.tool == .pan, "W put it away")
                press("w", virtualKey: 13)
            },
            {
                state("after W a third time")
                check(model.tool == .whiteBalance, "…and armed it again")
                sendKey("\u{1b}", modifiers: [], window: window, virtualKey: 53, viaQueue: true)
            },
            {
                state("after Escape")
                check(model.tool == .pan, "Escape put the eyedropper away")
                press("w", virtualKey: 13)
            },
            {
                state("before the click")
                clickCanvas(canvas: canvas, window: window, model: model, normalized: target)
            },
            {
                state("after the click")
                check(store.edit.whiteBalance.temperature != nil,
                      "the click set a white balance")
                check(model.tool == .pan, "…and put the eyedropper away, as Lightroom does")
                check(model.statusMessage?.contains(" K") == true, "…and said what it picked")
                if let (rg, bg) = rendered() {
                    log(String(format: "wb self-test: canvas at (%.2f, %.2f): r/g %.4f b/g %.4f",
                               target.x, target.y, rg, bg))
                    check(abs(rg - 1) < 0.05 && abs(bg - 1) < 0.05,
                          "the canvas is drawing that area neutral")
                } else {
                    check(false, "the canvas texture could not be read")
                }
                sendKey("z", modifiers: .command, window: window)
            },
            {
                state("after Cmd-Z")
                check(store.isAsShotWhiteBalance, "the pick was one undo step")
            },
        ]

        runSteps(steps, model: model) {
            if failures.isEmpty {
                log("wb self-test: PASS (all \(steps.count) checkpoints)")
                exit(0)
            }
            log("wb self-test: FAILED — \(failures.count) check(s): "
                + failures.joined(separator: "; "))
            exit(4)
        }
    }

    /// A real click at a normalised image point, through the window — the same
    /// geometry `paintStroke` aims with.
    static func clickCanvas(canvas: CanvasNSView, window: NSWindow, model: AppModel,
                            normalized n: CGPoint) {
        let point = windowPoint(canvas: canvas, window: window, model: model, normalized: n)
        log(String(format: "wb self-test: clicking (%.2f, %.2f) at window point (%.1f, %.1f)",
                   n.x, n.y, point.x, point.y))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            clickCounter += 1
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil,
                eventNumber: clickCounter, clickCount: 1, pressure: 1)
            else { fail("could not synthesize \(type)") }
            window.sendEvent(event)
        }
    }
}
