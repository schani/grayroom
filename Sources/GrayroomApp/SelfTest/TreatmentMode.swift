import AppKit
import GrayroomCanvas
import GrayroomCore
import GrayroomUI

/// `GRAYROOM_SELFTEST=treatment` — see `SelfTest.Mode.treatment`.
extension SelfTest {
    // MARK: - The treatment test

    /// `GRAYROOM_SELFTEST=treatment swift run GrayroomApp <copy-of-file.DNG>`
    ///
    /// Drives Lightroom's `V` as a real keystroke through the menu-bar key
    /// equivalent path, clicks the Style rows, and reads the canvas's own
    /// texture: the only check that the treatment the sidebar and the menu are
    /// drawing is the treatment the pipeline rendered.
    static func runTreatment(canvas: CanvasNSView, model: AppModel) {
        guard let window = canvas.window else { fail("canvas has no window") }
        let store = model.store
        var failures: [String] = []
        var neutralSaturation = 0.0

        func check(_ ok: Bool, _ what: String) {
            log("treatment self-test: \(ok ? "PASS" : "FAIL") — \(what)")
            if !ok { failures.append(what) }
        }
        /// What the canvas is showing, as one number. `nan` when it is showing
        /// nothing, which fails every comparison below rather than passing one.
        func saturation() -> Double { canvas.imageTexture.flatMap(meanSaturation) ?? .nan }
        /// SwiftUI writes a command item's tick when AppKit asks the menu to
        /// bring itself up to date — which key-equivalent matching does, and a
        /// plain `update()` does not — so ask first, the way matching would.
        func convertItem() -> NSMenuItem? {
            for top in NSApp.mainMenu?.items ?? [] {
                if let menu = top.submenu { menu.delegate?.menuNeedsUpdate?(menu) }
            }
            return menuItems { $0.title == "Convert to Black & White" }.first
        }
        func state(_ label: String) {
            log("treatment self-test: \(label): treatment=\(store.edit.treatment.rawValue) "
                + "style=\(store.edit.style.rawValue) tool=\(model.tool) "
                + String(format: "saturation=%.4f ", saturation())
                + "menu=\(convertItem().map { "\($0.state.rawValue)" } ?? "missing") "
                + "canUndo=\(store.canUndo)")
        }

        dumpMenus()

        let steps: [() -> Void] = [
            {
                store.replace(EditState(), named: nil)
                model.tool = .pan
            },
            {
                state("after the reset")
                check(store.edit.treatment == .blackAndWhite, "the app opens black & white")
                check(saturation() < 0.005, "the canvas is drawing grey")
                check(controlFrame(named: "treatment") != nil, "the Treatment picker is there")
                check(controlFrame(named: "bw-mix") != nil, "the B&W Mix panel is there")
                check(controlFrame(named: "style-vividSlide") == nil,
                      "the Style panel is not shown under Black & White")
                check(convertItem() != nil, "Photo › Convert to Black & White exists")
                check(convertItem()?.state == .on, "…and is ticked")
                sendKey("v", modifiers: [], window: window, virtualKey: 9)
            },
            {
                state("after V")
                check(store.edit.treatment == .color, "V switched to colour")
                check(store.edit.style == .neutral, "the style is still Neutral")
                neutralSaturation = saturation()
                check(neutralSaturation > 0.02, "the canvas is drawing colour")
                check(controlFrame(named: "bw-mix") == nil, "the B&W Mix panel went away")
                check(controlFrame(named: "style-neutral") != nil, "the Style panel came up")
                check(controlFrame(named: "style-vividSlide") != nil, "…with a row per style")
                check(convertItem()?.state == .off, "the menu item lost its tick")
                check(store.canUndo, "the treatment toggle is undoable")
                clickProbe(named: "style-vividSlide")
            },
            {
                state("after clicking Vivid Slide")
                check(store.edit.style == .vividSlide, "the row picked the style")
                check(saturation() > neutralSaturation, "…and the render got more saturated")
                clickProbe(named: "style-bleachBypass")
            },
            {
                state("after clicking Bleach Bypass")
                check(store.edit.style == .bleachBypass, "the row picked the style")
                // −75 % chroma reads as ~0.55 of neutral here: the split tone's
                // cool cast and the steep curve keep some spread in the metric.
                check(saturation() < 0.75 * neutralSaturation, "…and the render lost saturation")
                sendKey("t", modifiers: [], window: window, virtualKey: 17)
            },
            {
                state("after T under colour")
                check(model.tool == .pan, "the targeted tool is refused under colour")
                check(model.statusMessage?.contains("B&W") == true, "…and says why")
                sendKey("v", modifiers: [], window: window, virtualKey: 9)
            },
            {
                state("after V again")
                check(store.edit.treatment == .blackAndWhite, "V switched back")
                check(store.edit.style == .bleachBypass, "the style is kept, inert")
                check(saturation() < 0.005, "the canvas is drawing grey again")
                check(controlFrame(named: "bw-mix") != nil, "the B&W Mix panel is back")
                check(controlFrame(named: "style-vividSlide") == nil, "the Style panel went away")
                check(convertItem()?.state == .on, "the menu item is ticked again")
                sendKey("t", modifiers: [], window: window, virtualKey: 17)
            },
            {
                state("after T under black & white")
                check(model.tool == .targeted, "the targeted tool is allowed again")
                model.tool = .pan
                sendKey("z", modifiers: .command, window: window)
            },
            {
                state("after Cmd-Z")
                check(store.edit.treatment == .color, "the treatment toggle was one undo step")
                sendKey("z", modifiers: .command, window: window)
            },
            {
                state("after Cmd-Z")
                check(store.edit.style == .vividSlide, "the style click was one undo step")
            },
        ]

        runSteps(steps, model: model) {
            if failures.isEmpty {
                log("treatment self-test: PASS (all \(steps.count) checkpoints)")
                exit(0)
            }
            log("treatment self-test: FAILED — \(failures.count) check(s): "
                + failures.joined(separator: "; "))
            exit(4)
        }
    }
}
