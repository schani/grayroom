import AppKit
import GrayroomCanvas
import GrayroomUI
import Observation

/// `GRAYROOM_SELFTEST=undo` — see `SelfTest.Mode.undo`.
extension SelfTest {
    // MARK: - The undo test

    /// `GRAYROOM_SELFTEST=undo swift run GrayroomApp <copy-of-file.DNG>`
    ///
    /// Paints a stroke, then drives **Cmd-Z / Cmd-Shift-Z as key events through
    /// `NSApp.sendEvent`** — the same path a real keystroke takes, menu-bar key
    /// equivalent matching and menu-item enablement included. That matters
    /// because a disabled menu item swallows its shortcut silently: the bug
    /// reproduces here and nowhere in the unit tests.
    static func runUndo(canvas: CanvasNSView, model: AppModel) {
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

    static func strokeCount(_ store: EditStateStore) -> Int {
        store.edit.masks.reduce(0) { $0 + $1.strokes.count }
    }

    /// What the menu bar thinks of an item right now — the thing that decides
    /// whether the key equivalent fires at all.
    static func menuItemState(_ title: String) -> String {
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

    /// Logs every Observation notification for `canUndo` / `canRedo`, i.e. every
    /// moment SwiftUI would re-evaluate the Edit menu's `.disabled(…)`.
    static func trackUndoAvailability(_ store: EditStateStore) {
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
}
