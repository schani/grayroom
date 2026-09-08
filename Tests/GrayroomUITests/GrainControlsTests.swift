import GrayroomCore
import XCTest
@testable import GrayroomUI

final class GrainControlsTests: XCTestCase {
    func testGrainDragIsOneUndoablePipelineEdit() {
        var edit = EditState()
        edit.grain.amount = 60
        let store = EditStateStore(edit: edit)
        var invalidations: [RenderInvalidation] = []
        store.onChange = { invalidations.append($0) }

        store.beginGesture()
        store.update { $0.grain.size = 45 }
        store.update { $0.grain.size = 80 }
        store.endGesture(named: "Grain Size")

        XCTAssertEqual(store.edit.grain.size, 80)
        XCTAssertEqual(invalidations, [.pipeline, .pipeline])
        XCTAssertEqual(store.undoManager.undoActionName, "Grain Size")

        store.undo()
        XCTAssertEqual(store.edit.grain.size, 25)
        store.redo()
        XCTAssertEqual(store.edit.grain.size, 80)
    }

    func testResettingOneGrainControlPreservesTheOthers() {
        var edit = EditState()
        edit.grain.amount = 60
        edit.grain.size = 80
        let store = EditStateStore(edit: edit)

        store.perform("Grain Size") { $0.grain.size = 25 }

        XCTAssertEqual(store.edit.grain.amount, 60)
        XCTAssertEqual(store.edit.grain.size, 25)
        store.undo()
        XCTAssertEqual(store.edit.grain.size, 80)
    }
}
