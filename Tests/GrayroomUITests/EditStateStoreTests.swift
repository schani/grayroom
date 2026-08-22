import CoreGraphics
import GrayroomCore
import XCTest
@testable import GrayroomUI

final class EditStateStoreTests: XCTestCase {
    func makeStore() -> EditStateStore {
        // The store groups its own undo registrations, so no test setup is
        // needed for deterministic one-step-per-gesture undo.
        EditStateStore()
    }

    // MARK: - Change notification

    func testLiveUpdateFiresOnChangeWithTheRightCost() {
        let store = makeStore()
        var seen: [RenderInvalidation] = []
        store.onChange = { seen.append($0) }

        store.update { $0.tone.exposure = 1 }
        store.update { $0.clarity = 30 }
        store.update { $0.whiteBalance.temperature = 6500 }
        // A no-op must not fire at all.
        store.update { $0.clarity = 30 }

        XCTAssertEqual(seen, [.pipeline, .pipeline, .decode])
        XCTAssertEqual(store.revision, 3)
    }

    func testDirtyFlagTracksUnsavedChanges() {
        let store = makeStore()
        XCTAssertFalse(store.isDirty)
        store.update { $0.tone.contrast = 10 }
        XCTAssertTrue(store.isDirty)
        store.markSaved()
        XCTAssertFalse(store.isDirty)
    }

    // MARK: - Undo granularity

    func testADragIsOneUndoStep() {
        let store = makeStore()
        store.beginGesture()
        for i in 1...50 { store.update { $0.tone.exposure = Double(i) / 50 } }
        store.endGesture(named: "Exposure")

        XCTAssertEqual(store.edit.tone.exposure, 1, accuracy: 1e-12)
        XCTAssertTrue(store.canUndo)
        store.undo()
        XCTAssertEqual(store.edit.tone.exposure, 0, accuracy: 1e-12)
        XCTAssertFalse(store.canUndo)
        XCTAssertTrue(store.canRedo)
        store.redo()
        XCTAssertEqual(store.edit.tone.exposure, 1, accuracy: 1e-12)
    }

    func testAGestureThatChangedNothingRegistersNothing() {
        let store = makeStore()
        store.beginGesture()
        store.update { $0.tone.exposure = 0 }      // no change
        store.endGesture(named: "Exposure")
        XCTAssertFalse(store.canUndo)
    }

    func testUndoRedoRoundTripsSeveralSteps() {
        let store = makeStore()
        store.perform("A") { $0.tone.exposure = 1 }
        store.perform("B") { $0.clarity = 40 }
        store.perform("C") { $0.bwMix.red = -25 }

        store.undo(); store.undo(); store.undo()
        XCTAssertEqual(store.edit, EditState())
        XCTAssertFalse(store.canUndo)

        store.redo(); store.redo(); store.redo()
        XCTAssertEqual(store.edit.tone.exposure, 1)
        XCTAssertEqual(store.edit.clarity, 40)
        XCTAssertEqual(store.edit.bwMix.red, -25)
    }

    func testUndoFiresOnChangeSoTheCanvasRepaints() {
        let store = makeStore()
        store.perform("WB") { $0.whiteBalance.temperature = 7000 }
        var seen: [RenderInvalidation] = []
        store.onChange = { seen.append($0) }
        store.undo()
        XCTAssertEqual(seen, [.decode])   // undoing a WB change costs a re-decode
    }

    func testReplaceWithoutANameClearsTheUndoStackAndStaysClean() {
        let store = makeStore()
        store.perform("A") { $0.tone.exposure = 1 }
        XCTAssertTrue(store.canUndo)
        XCTAssertTrue(store.isDirty)

        var loaded = EditState()
        loaded.clarity = 30
        var seen: [RenderInvalidation] = []
        store.onChange = { seen.append($0) }
        store.replace(loaded, named: nil)

        XCTAssertFalse(store.canUndo)
        XCTAssertEqual(store.edit, loaded)
        // Loading a stored edit must repaint...
        XCTAssertEqual(seen, [.pipeline])
        // ...but must not set the dirty flag, or opening an image would
        // immediately queue a save of what was just loaded.
        XCTAssertFalse(store.isDirty)
    }

    // MARK: - Undo availability

    /// `canUndo` / `canRedo` are stored mirrors of the undo manager now; every
    /// path that moves the stack has to keep them honest.
    func testUndoAvailabilityTracksTheStack() {
        let store = makeStore()
        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.canRedo)

        store.perform("A") { $0.tone.exposure = 1 }
        XCTAssertTrue(store.canUndo)
        XCTAssertFalse(store.canRedo)

        store.perform("B") { $0.clarity = 40 }
        XCTAssertTrue(store.canUndo)
        XCTAssertFalse(store.canRedo, "a fresh edit ends the redo branch")

        store.undo()
        XCTAssertTrue(store.canUndo)
        XCTAssertTrue(store.canRedo)

        store.undo()
        XCTAssertFalse(store.canUndo, "the stack is at the bottom")
        XCTAssertTrue(store.canRedo)

        store.redo()
        XCTAssertTrue(store.canUndo)
        XCTAssertTrue(store.canRedo)

        store.redo()
        XCTAssertTrue(store.canUndo)
        XCTAssertFalse(store.canRedo, "the stack is at the top")
    }

    func testAvailabilityMirrorsTheUndoManagerAfterAGesture() {
        let store = makeStore()
        store.beginGesture()
        store.update { $0.tone.exposure = 1 }
        XCTAssertFalse(store.canUndo, "a gesture in progress is not yet undoable")
        store.endGesture(named: "Exposure")
        XCTAssertTrue(store.canUndo)
        XCTAssertEqual(store.canUndo, store.undoManager.canUndo)
        XCTAssertEqual(store.canRedo, store.undoManager.canRedo)
    }

    func testReplaceWithoutANameClearsBothDirections() {
        let store = makeStore()
        store.perform("A") { $0.tone.exposure = 1 }
        store.undo()
        XCTAssertTrue(store.canRedo)

        store.replace(EditState(), named: nil)
        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.canRedo)
    }

    /// A named replace is an ordinary undoable edit.
    func testReplaceWithANameIsUndoable() {
        let store = makeStore()
        var loaded = EditState()
        loaded.clarity = 30
        store.replace(loaded, named: "Paste Settings")
        XCTAssertTrue(store.canUndo)
        store.undo()
        XCTAssertEqual(store.edit, EditState())
        XCTAssertFalse(store.canUndo)
        XCTAssertTrue(store.canRedo)
    }

    // MARK: - White balance

    func testAsShotIsShownWhenTheEditIsNil() {
        let store = makeStore()
        store.asShotTemperature = 5123
        store.asShotTint = 7
        XCTAssertTrue(store.isAsShotWhiteBalance)
        XCTAssertEqual(store.effectiveTemperature, 5123)
        XCTAssertEqual(store.effectiveTint, 7)

        store.update { $0.whiteBalance.temperature = 8000 }
        XCTAssertFalse(store.isAsShotWhiteBalance)
        XCTAssertEqual(store.effectiveTemperature, 8000)

        store.resetWhiteBalanceToAsShot()
        XCTAssertTrue(store.isAsShotWhiteBalance)
        XCTAssertNil(store.edit.whiteBalance.temperature)
        XCTAssertNil(store.edit.whiteBalance.tint)
        XCTAssertEqual(store.effectiveTemperature, 5123)
    }

    // MARK: - Masks

    func testAddAndDeleteMask() {
        let store = makeStore()
        let id = store.addMask()
        XCTAssertEqual(store.edit.masks.count, 1)
        XCTAssertEqual(store.selectedMaskID, id)
        XCTAssertEqual(store.selectedMaskIndex, 0)
        XCTAssertEqual(store.edit.masks[0].name, "Mask 1")

        store.addMask()
        XCTAssertEqual(store.edit.masks.map(\.name), ["Mask 1", "Mask 2"])

        store.deleteMask(id: id)
        XCTAssertEqual(store.edit.masks.map(\.name), ["Mask 2"])
        XCTAssertEqual(store.selectedMaskID, store.edit.masks[0].id)

        store.undo()
        XCTAssertEqual(store.edit.masks.count, 2)
    }

    /// The crash scenario: SwiftUI evaluates a mask-adjustment binding after
    /// the mask it was created for has been deleted. The safe accessors must
    /// no-op / return 0, never trap.
    func testMaskAdjustmentAccessorsSurviveDeletion() {
        let store = makeStore()
        let id = store.addMask()
        store.setMaskAdjustment(\.exposure, to: 1.5)
        XCTAssertEqual(store.maskAdjustment(\.exposure), 1.5)

        store.deleteMask(id: id)
        XCTAssertTrue(store.edit.masks.isEmpty)
        XCTAssertNil(store.selectedMaskID)

        // Stale evaluations after deletion: harmless.
        XCTAssertEqual(store.maskAdjustment(\.exposure), 0)
        store.setMaskAdjustment(\.contrast, to: 50)
        XCTAssertTrue(store.edit.masks.isEmpty)
    }

    /// Deleting the selected mask must move the selection off it *before* the
    /// mutation is observable, and select a sensible neighbour.
    func testDeleteSelectedMaskRetargetsSelectionBeforeMutation() {
        let store = makeStore()
        let a = store.addMask()
        let b = store.addMask()
        let c = store.addMask()

        store.selectedMaskID = b
        var selectionSeenDuringChange: UUID?
        store.onChange = { _ in selectionSeenDuringChange = store.selectedMaskID }
        store.deleteMask(id: b)
        // The onChange fired by the deletion must already see a live selection.
        XCTAssertNotEqual(selectionSeenDuringChange, b)
        XCTAssertEqual(store.selectedMaskID, c, "selection moves to the next mask")

        store.selectedMaskID = c
        store.deleteMask(id: c)
        XCTAssertEqual(store.selectedMaskID, a, "deleting the last falls back to the previous")

        store.deleteMask(id: a)
        XCTAssertNil(store.selectedMaskID)
    }

    func testNextMaskNameSkipsTakenNames() {
        XCTAssertEqual(EditStateStore.nextMaskName(existing: []), "Mask 1")
        XCTAssertEqual(EditStateStore.nextMaskName(existing: ["Mask 1", "Mask 3"]), "Mask 2")
        XCTAssertEqual(EditStateStore.nextMaskName(existing: ["sky"]), "Mask 1")
    }

    // MARK: - Strokes

    func testAStrokeIsOneUndoStepAndRespectsSpacing() {
        let store = makeStore()
        store.addMask()
        store.brush = BrushParams(size: 0.1, feather: 40, flow: 80, density: 90)
        let image = CGSize(width: 2000, height: 1000)   // long edge 2000 -> 200 px brush

        XCTAssertTrue(store.beginStroke(at: CGPoint(x: 0.1, y: 0.5), pressure: 0, erase: false))
        // 50 px spacing threshold; mouse events 12 px apart are dropped until
        // they add up.
        for i in 1...20 {
            store.extendStroke(to: CGPoint(x: 0.1 + Double(i) * 0.006, y: 0.5),
                               pressure: 0, imageSize: image)
        }
        store.endStroke()

        let stroke = store.edit.masks[0].strokes[0]
        XCTAssertEqual(stroke.brush, BrushParams(size: 0.1, feather: 40, flow: 80, density: 90))
        XCTAssertFalse(stroke.erase)
        // 0.006 * 2000 = 12 px per event, spacing 50 px -> a point every 5
        // events: 20 events become 4 points, plus the one from mouse-down.
        XCTAssertEqual(stroke.points.count, 5)
        XCTAssertEqual(stroke.points[0].pressure, 1)   // mouse: no pressure -> full

        // One undo step for the whole stroke.
        store.undo()
        XCTAssertTrue(store.edit.masks[0].strokes.isEmpty)
        store.redo()
        XCTAssertEqual(store.edit.masks[0].strokes.count, 1)
    }

    func testPaintingWithoutASelectedMaskDoesNothing() {
        let store = makeStore()
        XCTAssertFalse(store.beginStroke(at: CGPoint(x: 0.5, y: 0.5), pressure: 1, erase: false))
        XCTAssertTrue(store.edit.masks.isEmpty)
    }

    func testEraserStrokeIsMarked() {
        let store = makeStore()
        store.addMask()
        _ = store.beginStroke(at: CGPoint(x: 0.5, y: 0.5), pressure: 1, erase: true)
        store.endStroke()
        XCTAssertTrue(store.edit.masks[0].strokes[0].erase)
    }

    // MARK: - JSON interop

    func testTheStoreRoundTripsThroughTheJSONFormat() throws {
        let store = makeStore()
        store.perform("Edit") {
            $0.tone.exposure = 0.4
            $0.bwMix.blue = -50
            $0.toning.shadowHue = 215
            $0.toning.shadowSaturation = 12
        }
        store.addMask()
        _ = store.beginStroke(at: CGPoint(x: 0.2, y: 0.3), pressure: 0.6, erase: false)
        store.endStroke()

        let data = try store.edit.jsonData()
        let reloaded = try EditState.decode(from: data)
        XCTAssertEqual(reloaded, store.edit)
    }
}
