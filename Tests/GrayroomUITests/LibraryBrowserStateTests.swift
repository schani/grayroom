import Foundation
import XCTest
@testable import GrayroomUI

final class LibraryBrowserStateTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = .current
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private var photos: [CatalogPhoto] {
        [
            CatalogPhoto(id: 1, originalName: "1.dng", capturedAt: date(2024, 1, 2)),
            CatalogPhoto(id: 2, originalName: "2.dng", capturedAt: date(2024, 1, 3)),
            CatalogPhoto(id: 3, originalName: "3.dng", capturedAt: date(2025, 2, 4)),
            CatalogPhoto(id: 4, originalName: "4.dng"),
        ]
    }

    func testStartsOnWholeCatalogAndExpandsYears() {
        let state = LibraryBrowserState()
        state.rebuild(from: photos)
        XCTAssertEqual(state.visiblePhotoIDs, [1, 2, 3, 4])
        XCTAssertEqual(state.expandedFolders, ["2024", "2025"])
        XCTAssertEqual(state.countLabel, "4 photos")
    }

    func testSelectingDateFiltersAndPrunesHighlight() {
        let state = LibraryBrowserState()
        state.rebuild(from: photos)
        state.photoSelection.select([1, 3])
        state.selection = .folder(path: "2024/01")
        XCTAssertEqual(state.visiblePhotoIDs, [1, 2])
        XCTAssertEqual(state.highlightedPhotoIDs, [1])
        XCTAssertEqual(state.countLabel, "2 photos · 1 selected")

        state.selection = .missing
        XCTAssertEqual(state.visiblePhotoIDs, [4])
    }

    func testVanishedDateFallsBackToAll() {
        let state = LibraryBrowserState()
        state.rebuild(from: photos)
        state.selection = .folder(path: "2025")
        state.rebuild(from: Array(photos.prefix(2)))
        XCTAssertEqual(state.selection, .all)
        XCTAssertEqual(state.visiblePhotoIDs, [1, 2])
    }

    func testSelectionCommandsUseVisibleDate() {
        let state = LibraryBrowserState()
        state.rebuild(from: photos)
        state.selection = .folder(path: "2024")
        state.selectAllPhotos()
        XCTAssertEqual(state.highlightedPhotoIDs, [1, 2])
    }
}
