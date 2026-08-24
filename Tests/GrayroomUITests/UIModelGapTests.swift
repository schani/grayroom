import Foundation
import GrayroomCore
import GrayroomLibrary
import XCTest
@testable import GrayroomUI

/// Shift-arrow in the *import* grid.
///
/// The rule itself lives in `GridSelection` and is tested there over an
/// explicit order; what is untested is that the import window hands it the
/// **visible** order — so a hidden row can never end up inside a range the user
/// dragged over rows they can see.
final class ImportSelectionExtendTests: XCTestCase {
    private func url(_ name: String) -> URL { URL(fileURLWithPath: "/cards/A/\(name)") }

    private func selection(imported: Set<String> = []) -> ImportSelection {
        let names = ["a.dng", "b.dng", "c.dng", "d.dng", "e.dng", "f.dng"]
        var selection = ImportSelection(entries: names.map {
            ImportEntry(url: url($0), status: imported.contains($0) ? .alreadyImported : .new)
        })
        selection.sort = .filename
        return selection
    }

    private func highlighted(_ selection: ImportSelection) -> [String] {
        selection.visibleEntries.filter { selection.highlighted.contains($0.url) }
            .map(\.filename)
    }

    func testShiftArrowGrowsAndShrinksOneRangeFromTheAnchor() {
        var selection = self.selection()
        selection.click(url("b.dng"))

        selection.extendHighlight(dx: 1, dy: 0, columns: 3)
        XCTAssertEqual(highlighted(selection), ["b.dng", "c.dng"])
        selection.extendHighlight(dx: 1, dy: 0, columns: 3)
        XCTAssertEqual(highlighted(selection), ["b.dng", "c.dng", "d.dng"])
        // Back the other way: the anchor stays, the moving end walks.
        selection.extendHighlight(dx: -1, dy: 0, columns: 3)
        XCTAssertEqual(highlighted(selection), ["b.dng", "c.dng"])
        selection.extendHighlight(dx: -1, dy: 0, columns: 3)
        XCTAssertEqual(highlighted(selection), ["b.dng"])
        selection.extendHighlight(dx: -1, dy: 0, columns: 3)
        XCTAssertEqual(highlighted(selection), ["a.dng", "b.dng"])
    }

    func testShiftArrowDownExtendsByARow() {
        var selection = self.selection()
        selection.click(url("a.dng"))
        selection.extendHighlight(dx: 0, dy: 1, columns: 3)
        XCTAssertEqual(highlighted(selection), ["a.dng", "b.dng", "c.dng", "d.dng"])
    }

    /// The range spans what the grid is *showing*: with "hide already imported"
    /// on, the hidden rows are not in it.
    func testShiftArrowSpansTheVisibleListOnly() {
        var selection = self.selection(imported: ["b.dng", "c.dng"])
        XCTAssertTrue(selection.hideImported)
        XCTAssertEqual(selection.visibleEntries.map(\.filename),
                       ["a.dng", "d.dng", "e.dng", "f.dng"])

        selection.click(url("a.dng"))
        selection.extendHighlight(dx: 1, dy: 0, columns: 4)
        XCTAssertEqual(highlighted(selection), ["a.dng", "d.dng"])
        XCTAssertFalse(selection.highlighted.contains(url("b.dng")))
    }

    func testShiftArrowOnAnEmptyGridDoesNothing() {
        var selection = ImportSelection(entries: [])
        selection.extendHighlight(dx: 1, dy: 0, columns: 3)
        XCTAssertTrue(selection.highlighted.isEmpty)
    }

    /// The sort menu's labels — user-visible strings that pair with the cases.
    func testEverySortOrderHasATitleAndAnID() {
        XCTAssertEqual(ImportSortOrder.allCases.map(\.title),
                       ["Capture Time", "Checked State", "File Name"])
        for order in ImportSortOrder.allCases {
            XCTAssertEqual(order.id, order.rawValue)
        }
    }

    func testAnEntryIsIdentifiedByItsURL() {
        let entry = ImportEntry(url: url("a.dng"))
        XCTAssertEqual(entry.id, url("a.dng"))
        XCTAssertEqual(entry.filename, "a.dng")
    }
}

/// `PhotoCatalog`'s in-place mutations, which is how the grid stays current
/// without a reload.
final class PhotoCatalogFingerprintTests: XCTestCase {

    private func photo(id: Int64, fingerprint: Data? = nil,
                       developmentCount: Int = 0) -> CatalogPhoto {
        CatalogPhoto(id: id,
                     hash: Data([UInt8(truncatingIfNeeded: id), 0xAB]),
                     originalName: "\(id).dng",
                     capturedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(id)),
                     locations: ["/photos/\(id).dng"],
                     developmentCount: developmentCount,
                     developmentFingerprint: fingerprint)
    }

    /// The cell is keyed by the fingerprint, so moving it is what makes the
    /// grid ask for a preview of the edit that was just saved.
    func testSetDevelopmentFingerprintMovesIt() {
        let catalog = PhotoCatalog(photos: [photo(id: 1), photo(id: 2)])

        var edit = EditState()
        edit.tone.exposure = 1
        catalog.setDevelopmentFingerprint(edit.fingerprint, for: 1)

        XCTAssertEqual(catalog.photos[0].developmentFingerprint, edit.fingerprint)
        XCTAssertNil(catalog.photos[1].developmentFingerprint, "the other photo is untouched")

        // Deleting the development sends the cell back to the embedded preview.
        catalog.setDevelopmentFingerprint(nil, for: 1)
        XCTAssertNil(catalog.photos[0].developmentFingerprint)
    }

    func testSetDevelopmentFingerprintForAnUnknownPhotoIsANoOp() {
        let catalog = PhotoCatalog(photos: [photo(id: 1)])
        catalog.setDevelopmentFingerprint(Data([1, 2, 3]), for: 99)
        XCTAssertNil(catalog.photos[0].developmentFingerprint)
    }

    /// Lowercase hex — how the CLI addresses this photo.
    func testHashHexString() {
        XCTAssertEqual(photo(id: 1).hashHexString, "01ab")
        XCTAssertEqual(photo(id: 1).url?.path, "/photos/1.dng")
        XCTAssertEqual(photo(id: 1).firstLocation, "/photos/1.dng")
    }
}

/// The mask commands on `EditStateStore` that the mask list drives.
final class EditStateStoreMaskTests: XCTestCase {

    func testSelectedMaskFollowsTheSelection() {
        let store = EditStateStore()
        XCTAssertNil(store.selectedMask)

        let first = store.addMask()
        XCTAssertEqual(store.selectedMask?.id, first)
        XCTAssertEqual(store.selectedMask?.name, "Mask 1")

        let second = store.addMask()
        XCTAssertEqual(store.selectedMask?.id, second)

        store.selectedMaskID = first
        XCTAssertEqual(store.selectedMask?.name, "Mask 1")

        // A stale selection resolves to nothing rather than trapping.
        store.deleteMask(id: first)
        XCTAssertNotEqual(store.selectedMask?.id, first)
        store.selectedMaskID = first
        XCTAssertNil(store.selectedMask)
    }

    /// Disabling a mask is an undoable edit of its own, and it names itself so
    /// the Undo menu says what it will undo.
    func testSetMaskEnabledIsUndoableAndNamed() {
        let store = EditStateStore()
        let id = store.addMask()
        XCTAssertTrue(store.edit.masks[0].enabled)

        store.setMaskEnabled(id: id, false)
        XCTAssertFalse(store.edit.masks[0].enabled)
        XCTAssertEqual(store.undoManager.undoActionName, "Disable Mask")

        store.setMaskEnabled(id: id, true)
        XCTAssertTrue(store.edit.masks[0].enabled)
        XCTAssertEqual(store.undoManager.undoActionName, "Enable Mask")

        // Each of the two is its own step.
        store.undo()
        XCTAssertFalse(store.edit.masks[0].enabled)
        store.undo()
        XCTAssertTrue(store.edit.masks[0].enabled)

        // Setting it to what it already is changes nothing, so it registers
        // nothing: the Undo menu must not fill up with no-ops.
        let name = store.undoManager.undoActionName
        store.setMaskEnabled(id: id, true)
        XCTAssertEqual(store.undoManager.undoActionName, name)
    }

    func testSetMaskEnabledForAnUnknownMaskIsANoOp() {
        let store = EditStateStore()
        let id = store.addMask()
        let before = store.edit
        store.setMaskEnabled(id: UUID(), false)
        XCTAssertEqual(store.edit, before)
        XCTAssertTrue(store.edit.masks.first { $0.id == id }?.enabled ?? false)
    }
}
