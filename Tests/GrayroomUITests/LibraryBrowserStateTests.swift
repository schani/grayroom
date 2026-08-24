import Foundation
import XCTest
@testable import GrayroomUI

/// The Library module's browser without a window: the Folders panel's selection
/// and disclosure state, what they leave in the grid, what the bottom bar says,
/// and what happens to the grid's highlight when the filter moves under it.
final class LibraryBrowserStateTests: XCTestCase {

    private func photo(_ id: Int64, _ locations: String...) -> CatalogPhoto {
        CatalogPhoto(id: id, originalName: "photo-\(id).dng", locations: locations.sorted())
    }

    /// Two folders under one root, one photo filed in both, and one photo the
    /// library has no file for.
    private var library: [CatalogPhoto] {
        [
            photo(1, "/pics/2024/a.dng"),
            photo(2, "/pics/2024/b.dng"),
            photo(3, "/pics/2025/c.dng"),
            photo(4, "/pics/2024/d.dng", "/pics/2025/d.dng"),
            photo(5),
        ]
    }

    private func browser(_ photos: [CatalogPhoto]? = nil) -> LibraryBrowserState {
        let state = LibraryBrowserState()
        state.rebuild(from: photos ?? library)
        return state
    }

    // MARK: - Sources

    func testStartsOnTheWholeCatalog() {
        let state = LibraryBrowserState()
        XCTAssertEqual(state.selection, .all)
        XCTAssertEqual(state.visiblePhotoIDs, [])
        XCTAssertEqual(state.countLabel, "0 photos")
        XCTAssertTrue(state.isSidebarVisible)

        state.rebuild(from: library)
        XCTAssertEqual(state.selection, .all)
        XCTAssertEqual(state.visiblePhotoIDs, [1, 2, 3, 4, 5])
        XCTAssertEqual(state.countLabel, "5 photos")
        XCTAssertEqual(state.folders.totalCount, 5)
        XCTAssertEqual(state.folders.missingCount, 1)
    }

    func testSelectingAFolderFiltersTheGrid() {
        let state = browser()
        state.selection = .folder(path: "/pics/2024")
        XCTAssertEqual(state.visiblePhotoIDs, [1, 2, 4])
        XCTAssertEqual(state.visiblePhotos(from: library).map(\.id), [1, 2, 4])
        XCTAssertEqual(state.countLabel, "3 photos")
        XCTAssertTrue(state.isVisible(4))
        XCTAssertFalse(state.isVisible(3))

        // A parent folder means everything below it.
        state.selection = .folder(path: "/pics")
        XCTAssertEqual(state.visiblePhotoIDs, [1, 2, 3, 4])
        XCTAssertEqual(state.countLabel, "4 photos")

        state.selection = .missing
        XCTAssertEqual(state.visiblePhotoIDs, [5])
        XCTAssertEqual(state.countLabel, "1 photo")

        state.selection = .all
        XCTAssertEqual(state.visiblePhotoIDs, [1, 2, 3, 4, 5])
    }

    /// The catalog is handed back untouched for "All Photographs" — the common
    /// case copies nothing.
    func testVisiblePhotosReadsThroughToTheCatalog() {
        let state = browser()
        var photos = library
        photos[0].color = .red
        XCTAssertEqual(state.visiblePhotos(from: photos).map(\.color).first, .red)
        state.selection = .folder(path: "/pics/2024")
        XCTAssertEqual(state.visiblePhotos(from: photos).map(\.color).first, .red)
    }

    // MARK: - The grid's highlight

    func testHighlightIsPrunedWhenTheFilterMoves() {
        let state = browser()
        state.selectAllPhotos()
        XCTAssertEqual(state.highlightedPhotoIDs, [1, 2, 3, 4, 5])
        XCTAssertEqual(state.countLabel, "5 photos · 5 selected")

        state.selection = .folder(path: "/pics/2025")
        XCTAssertEqual(state.visiblePhotoIDs, [3, 4])
        XCTAssertEqual(state.highlightedPhotoIDs, [3, 4],
                       "only the photos still on screen keep the ring")
        XCTAssertEqual(state.countLabel, "2 photos · 2 selected")

        state.selection = .missing
        XCTAssertEqual(state.highlightedPhotoIDs, [])
        XCTAssertEqual(state.countLabel, "1 photo")
    }

    func testSelectionCommandsSpanTheVisibleListOnly() {
        let state = browser()
        state.selection = .folder(path: "/pics/2024")

        state.clickPhoto(1, modifiers: [])
        XCTAssertEqual(state.highlightedPhotoIDs, [1])
        // A shift-range runs over the *filtered* list: 1, 2, 4 — photo 3 is in
        // the catalog between them and is not in this folder.
        state.clickPhoto(4, modifiers: .shift)
        XCTAssertEqual(state.highlightedPhotoIDs, [1, 2, 4])
        XCTAssertEqual(state.countLabel, "3 photos · 3 selected")

        state.clickPhoto(2, modifiers: .command)
        XCTAssertEqual(state.highlightedPhotoIDs, [1, 4])

        state.selectAllPhotos()
        XCTAssertEqual(state.highlightedPhotoIDs, [1, 2, 4], "⌘A takes the folder, not the library")
    }

    func testArrowsWalkTheVisibleList() {
        let state = browser()
        state.selection = .folder(path: "/pics/2024")
        state.clickPhoto(1, modifiers: [])

        XCTAssertEqual(state.movePhotoHighlight(dx: 1, dy: 0, columns: 3), 2)
        XCTAssertEqual(state.highlightedPhotoIDs, [2])
        // Right again lands on 4, not on 3: 3 is in another folder.
        XCTAssertEqual(state.movePhotoHighlight(dx: 1, dy: 0, columns: 3), 4)
        XCTAssertEqual(state.highlightedPhotoIDs, [4])
        // And it stops at the end of the filtered list.
        XCTAssertEqual(state.movePhotoHighlight(dx: 1, dy: 0, columns: 3), 4)

        XCTAssertEqual(state.extendPhotoHighlight(dx: -1, dy: 0, columns: 3), 2)
        XCTAssertEqual(state.highlightedPhotoIDs, [2, 4])
    }

    /// Coming back from Develop re-highlights the photo that was open — unless
    /// the selected folder is not showing it.
    func testSelectPhotosIgnoresWhatIsNotOnScreen() {
        let state = browser()
        state.selection = .folder(path: "/pics/2024")
        state.selectPhotos([1])
        XCTAssertEqual(state.highlightedPhotoIDs, [1])
        state.selectPhotos([3])
        XCTAssertEqual(state.highlightedPhotoIDs, [1], "photo 3 is in another folder")
    }

    // MARK: - Rebuilding

    /// The selected source is the module's state: an import, a develop trip, a
    /// reload — none of them move it.
    func testRebuildKeepsTheSelectedFolder() {
        let state = browser()
        state.selection = .folder(path: "/pics/2025")
        state.clickPhoto(3, modifiers: [])

        var grown = library
        grown.append(photo(6, "/pics/2025/e.dng"))
        state.rebuild(from: grown)

        XCTAssertEqual(state.selection, .folder(path: "/pics/2025"))
        XCTAssertEqual(state.visiblePhotoIDs, [3, 4, 6])
        XCTAssertEqual(state.highlightedPhotoIDs, [3], "and the highlight with it")
        XCTAssertEqual(state.folders.node(at: "/pics/2025")?.count, 3)
    }

    /// A folder whose last photo is gone is gone; the panel falls back to the
    /// whole catalog rather than showing an empty grid for a row that is not
    /// there any more.
    func testRebuildFallsBackToAllWhenTheFolderVanishes() {
        let state = browser()
        state.selection = .folder(path: "/pics/2025")
        XCTAssertEqual(state.visiblePhotoIDs, [3, 4])

        state.rebuild(from: [photo(1, "/pics/2024/a.dng")])
        XCTAssertEqual(state.selection, .all)
        XCTAssertEqual(state.visiblePhotoIDs, [1])
        XCTAssertEqual(state.highlightedPhotoIDs, [])
    }

    /// A photo whose last location is taken away leaves its folder and turns up
    /// under Missing.
    func testRebuildMovesAPhotoIntoMissing() {
        let state = browser()
        state.selection = .missing
        XCTAssertEqual(state.visiblePhotoIDs, [5])

        var lost = library
        lost[2] = photo(3)                      // photo 3 loses its file
        state.rebuild(from: lost)
        XCTAssertEqual(state.folders.missingCount, 2)
        XCTAssertEqual(state.visiblePhotoIDs, [3, 5])
        XCTAssertEqual(state.countLabel, "2 photos")
        XCTAssertNil(state.folders.node(at: "/pics/2025/c.dng"))
    }

    // MARK: - Disclosure

    func testVolumesOpenOnceAndStayAsTheUserLeavesThem() {
        let state = browser()
        let root = state.folders.roots[0].id
        XCTAssertTrue(state.isExpanded(root), "a volume the panel has not seen before opens")
        XCTAssertFalse(state.isExpanded("/pics"), "and nothing below it does")

        state.setExpanded(root, false)
        state.rebuild(from: library)
        XCTAssertFalse(state.isExpanded(root), "a rebuild does not re-open what was closed")

        state.expandAncestors(of: "/pics/2024")
        XCTAssertTrue(state.isExpanded(root))
        XCTAssertTrue(state.isExpanded("/pics"))
        XCTAssertTrue(state.isExpanded("/pics/2024"))
    }

    func testSidebarVisibilityIsPlainState() {
        let state = browser()
        state.isSidebarVisible = false
        state.selection = .folder(path: "/pics/2024")
        XCTAssertFalse(state.isSidebarVisible, "hiding the panel does not change the source")
        XCTAssertEqual(state.visiblePhotoIDs, [1, 2, 4], "…or what the grid shows")
    }
}
