import XCTest
@testable import GrayroomUI

final class GridDragFilesTests: XCTestCase {
    private func photo(_ id: Int64, _ locations: [String]) -> CatalogPhoto {
        CatalogPhoto(id: id, originalName: "photo\(id).DNG", locations: locations)
    }

    private var library: [CatalogPhoto] {
        [photo(3, ["/a/three.DNG"]), photo(1, ["/a/one.DNG"]), photo(2, ["/a/two.DNG"])]
    }

    func testADragCarriesTheFilesOfThePhotosItNames() {
        let files = GridDragFiles.files(for: [1, 2], from: library, exists: { _ in true })
        XCTAssertEqual(files.map(\.url.path), ["/a/one.DNG", "/a/two.DNG"])
    }

    /// The grid's order, not the order the ids came in.
    func testTheFilesComeOutInGridOrder() {
        let files = GridDragFiles.files(for: [2, 3, 1], from: library, exists: { _ in true })
        XCTAssertEqual(files.map(\.url.path), ["/a/three.DNG", "/a/one.DNG", "/a/two.DNG"])
    }

    /// The library keeps every path it has seen a photo at; the drag wants the
    /// one that is there now.
    func testAPhotoContributesItsFirstLocationThatIsOnDisk() {
        let moved = [photo(1, ["/gone/one.DNG", "/here/one.DNG"])]
        let files = GridDragFiles.files(for: [1], from: moved, exists: { $0.hasPrefix("/here") })
        XCTAssertEqual(files.map(\.url.path), ["/here/one.DNG"])
    }

    func testAPhotoWithNoFileOnDiskDragsNothing() {
        let missing = [photo(1, ["/gone/one.DNG"]), photo(2, ["/a/two.DNG"])]
        let files = GridDragFiles.files(for: [1, 2], from: missing,
                                        exists: { $0 == "/a/two.DNG" })
        XCTAssertEqual(files.map(\.url.path), ["/a/two.DNG"])
    }

    func testAPhotoTheLibraryHasNoPathForAtAllDragsNothing() {
        XCTAssertTrue(GridDragFiles.files(for: [9], from: [photo(9, [])],
                                          exists: { _ in true }).isEmpty)
    }
}
