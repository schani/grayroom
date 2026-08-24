import Foundation
import XCTest
@testable import GrayroomUI

/// The Library module's two views without a window: entering and leaving the
/// loupe, the arrows walking the filtered list, the selection following the
/// loupe, and the grid's scroll position surviving a trip through Develop.
final class LibraryLoupeStateTests: XCTestCase {

    private func photo(_ id: Int64, _ locations: String...) -> CatalogPhoto {
        CatalogPhoto(id: id, originalName: "photo-\(id).dng", locations: locations.sorted())
    }

    private var library: [CatalogPhoto] {
        [
            photo(1, "/pics/2024/a.dng"),
            photo(2, "/pics/2024/b.dng"),
            photo(3, "/pics/2025/c.dng"),
            photo(4, "/pics/2024/d.dng"),
        ]
    }

    private func browser() -> LibraryBrowserState {
        let state = LibraryBrowserState()
        state.rebuild(from: library)
        return state
    }

    // MARK: - Entering and leaving

    func testTheLibraryStartsInTheGrid() {
        XCTAssertEqual(browser().viewMode, .grid)
        XCTAssertNil(browser().loupePhotoID)
    }

    /// `e` with nothing named opens the loupe on the selection's anchor —
    /// Lightroom's active photo, the one it draws lighter than the rest of a
    /// multi-selection.
    func testEnteringUsesTheActivePhoto() {
        let state = browser()
        state.clickPhoto(2, modifiers: [])
        state.clickPhoto(4, modifiers: .shift)
        XCTAssertEqual(state.highlightedPhotoIDs, [2, 3, 4])

        XCTAssertEqual(state.enterLoupe(), 2)
        XCTAssertEqual(state.viewMode, .loupe)
        XCTAssertEqual(state.loupePhotoID, 2)
        // The loupe *is* the selection: one photo, so `g` comes back to it.
        XCTAssertEqual(state.highlightedPhotoIDs, [2])
    }

    func testEnteringWithNothingHighlightedTakesTheFirstCell() {
        let state = browser()
        XCTAssertEqual(state.enterLoupe(), 1)
        XCTAssertEqual(state.highlightedPhotoIDs, [1])
    }

    func testEnteringAnEmptyGridStaysInTheGrid() {
        let state = LibraryBrowserState()
        XCTAssertNil(state.enterLoupe())
        XCTAssertEqual(state.viewMode, .grid)
    }

    /// A photo the selected source does not show cannot be the loupe's.
    func testEnteringOnAPhotoOutsideTheFilterIsRefused() {
        let state = browser()
        state.selection = .folder(path: "/pics/2024")
        XCTAssertNil(state.enterLoupe(on: 3))
        XCTAssertEqual(state.viewMode, .grid)
    }

    func testExitingReturnsThePhotoToScrollTo() {
        let state = browser()
        state.enterLoupe(on: 3)
        XCTAssertEqual(state.exitLoupe(), 3)
        XCTAssertEqual(state.viewMode, .grid)
        XCTAssertEqual(state.highlightedPhotoIDs, [3])
    }

    // MARK: - The Folders panel

    /// Lightroom's `E` gives the photo the whole window: the panel is not there.
    /// It comes back on `g` exactly as it was, which is what makes this a
    /// *derived* fact rather than a saved-and-restored one — nothing writes to
    /// the preference on the way in, so there is nothing to get wrong on the way
    /// out.
    func testTheLoupeHidesTheFoldersPanelAndTheGridBringsItBack() {
        let state = browser()
        XCTAssertTrue(state.isSidebarShowing)

        state.enterLoupe(on: 2)
        XCTAssertFalse(state.isSidebarShowing, "the loupe fills the window")
        XCTAssertTrue(state.isSidebarVisible, "…without forgetting the panel was showing")

        state.exitLoupe()
        XCTAssertTrue(state.isSidebarShowing, "g brings it back")
    }

    /// The other direction: a panel the user had hidden stays hidden.
    func testAHiddenPanelStaysHiddenAcrossTheLoupe() {
        let state = browser()
        state.isSidebarVisible = false
        XCTAssertFalse(state.isSidebarShowing)

        state.enterLoupe(on: 2)
        XCTAssertFalse(state.isSidebarShowing)
        state.exitLoupe()
        XCTAssertFalse(state.isSidebarShowing, "g does not show a panel that was hidden")
        XCTAssertFalse(state.isSidebarVisible)
    }

    /// A photo that leaves the grid takes the loupe with it — and the panel has
    /// to come back with the grid, not stay collapsed because the way out was
    /// not a keystroke.
    func testTheFallbackToTheGridBringsThePanelBackToo() {
        let state = browser()
        state.enterLoupe(on: 3)
        XCTAssertFalse(state.isSidebarShowing)
        state.selection = .folder(path: "/pics/2024")
        XCTAssertEqual(state.viewMode, .grid)
        XCTAssertTrue(state.isSidebarShowing)
    }

    // MARK: - Which view owns the canvas

    /// The loupe draws the same `CanvasNSView` the develop view does, so the
    /// zoom keys, the zoom gestures and the zoom percentage have to be routed to
    /// it while it is up. This is the state half of that routing; the self-test
    /// drives the real keys at the real window.
    func testTheLoupeOwnsTheCanvasAndTheGridDoesNot() {
        let state = browser()
        XCTAssertFalse(state.ownsCanvas, "the grid has no canvas")
        state.enterLoupe(on: 1)
        XCTAssertTrue(state.ownsCanvas)
        state.stepLoupe(1)
        XCTAssertTrue(state.ownsCanvas, "…all the way along the walk")
        state.exitLoupe()
        XCTAssertFalse(state.ownsCanvas)
    }

    func testReturningFromDevelopLeavesTheCanvasToDevelop() {
        let state = browser()
        state.enterLoupe(on: 1)
        XCTAssertTrue(state.ownsCanvas)
        // `d` from the loupe: the browser leaves the loupe, and the develop
        // view's canvas is the one on screen again.
        state.exitLoupe()
        XCTAssertFalse(state.ownsCanvas)
        XCTAssertTrue(state.isSidebarShowing)
    }

    // MARK: - The arrows

    func testTheArrowsWalkTheFilteredOrderAndStopAtBothEnds() {
        let state = browser()
        state.selection = .folder(path: "/pics/2024")
        XCTAssertEqual(state.visiblePhotoIDs, [1, 2, 4])
        state.enterLoupe(on: 1)

        // Left at the first photo: nothing moves, no wrap.
        XCTAssertEqual(state.stepLoupe(-1), 1)
        XCTAssertEqual(state.stepLoupe(1), 2)
        // 3 is in the other folder, so it is not in this walk.
        XCTAssertEqual(state.stepLoupe(1), 4)
        XCTAssertEqual(state.stepLoupe(1), 4)
        XCTAssertEqual(state.loupePositionLabel, "3 / 3")
    }

    func testTheSelectionFollowsTheLoupe() {
        let state = browser()
        state.enterLoupe(on: 1)
        state.stepLoupe(1)
        state.stepLoupe(1)
        XCTAssertEqual(state.loupePhotoID, 3)
        XCTAssertEqual(state.highlightedPhotoIDs, [3])
        XCTAssertEqual(state.photoSelection.count, 1)
        // …so `g` comes back to the photo the loupe was showing.
        XCTAssertEqual(state.exitLoupe(), 3)
    }

    func testTheArrowsOpenTheLoupeWhenNothingIsShowing() {
        let state = browser()
        XCTAssertEqual(state.stepLoupe(1), 1)
    }

    // MARK: - The position label

    func testThePositionLabelCountsFromOne() {
        let state = browser()
        state.enterLoupe(on: 1)
        XCTAssertEqual(state.loupePositionLabel, "1 / 4")
        state.stepLoupe(1)
        XCTAssertEqual(state.loupePositionLabel, "2 / 4")
        // Back in the grid it is a count again, as the bottom bar always was.
        state.exitLoupe()
        XCTAssertEqual(state.loupePositionLabel, "4 photos")
    }

    // MARK: - The catalog moving under the loupe

    func testAPhotoThatLeavesTheGridTakesTheLoupeWithIt() {
        let state = browser()
        state.enterLoupe(on: 3)
        state.selection = .folder(path: "/pics/2024")
        XCTAssertEqual(state.viewMode, .grid)
        XCTAssertNil(state.loupePhotoID)
    }

    func testAPhotoDeletedFromTheCatalogTakesTheLoupeWithIt() {
        let state = browser()
        state.enterLoupe(on: 4)
        state.rebuild(from: Array(library.prefix(3)))
        XCTAssertEqual(state.viewMode, .grid)
        XCTAssertNil(state.loupePhotoID)
    }

    /// Coming back from a loupe that *walked* names the cell to scroll into
    /// view: the arrows may have gone a long way from where the grid was left.
    func testReturningFromAWalkedLoupeNamesThePhotoToScrollTo() {
        let state = browser()
        state.clickPhoto(1, modifiers: [])
        state.enterLoupe()
        state.stepLoupe(1)
        XCTAssertEqual(state.exitLoupe(), 2)
        XCTAssertEqual(state.viewMode, .grid)
    }

    /// Coming back from a loupe that never moved names nothing. The grid is
    /// not taken out of the window while the loupe has it, so it is still
    /// showing the cell the loupe opened on — and scrolling to it anyway would
    /// centre a grid that is already right.
    func testReturningFromAnUnmovedLoupeScrollsToNothing() {
        let state = browser()
        state.clickPhoto(3, modifiers: [])
        XCTAssertEqual(state.enterLoupe(), 3)
        XCTAssertNil(state.exitLoupe())
        XCTAssertEqual(state.viewMode, .grid)
        XCTAssertEqual(state.highlightedPhotoIDs, [3])
    }

    /// The loupe entered on a photo the grid was *not* anchored on — `e` from
    /// the develop view — is a move, so the grid is scrolled to it on the way
    /// out even though the loupe never walked.
    func testReturningFromALoupeEnteredElsewhereScrollsToThePhoto() {
        let state = browser()
        state.clickPhoto(1, modifiers: [])
        XCTAssertEqual(state.enterLoupe(on: 4), 4)
        XCTAssertEqual(state.exitLoupe(), 4)
    }
}
