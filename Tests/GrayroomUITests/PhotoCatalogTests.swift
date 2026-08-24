import Foundation
import GrayroomCore
import GrayroomLibrary
import XCTest
@testable import GrayroomUI

/// A throwaway library in `NSTemporaryDirectory()`, with the files it points at.
private final class TempCatalog {
    let directory: URL
    let library: Library

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grayroom-catalog-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        library = try Library(url: directory.appendingPathComponent("library.sqlite"))
    }

    /// Distinct bytes per name, so every file hashes differently.
    @discardableResult
    func writeFile(_ name: String, bytes: String? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data((bytes ?? name).utf8).write(to: url)
        return url
    }

    /// Imports `name` with a stubbed probe (the bytes are not a real image) and
    /// returns its photo id.
    @discardableResult
    func importFile(_ name: String, capturedAt: Date? = nil, bytes: String? = nil) throws -> Int64 {
        let url = try writeFile(name, bytes: bytes)
        let importer = Importer(library: library) { _ in
            PhotoMetadata(width: 6000, height: 4000, capturedAt: capturedAt)
        }
        return try importer.importFile(at: url).photoID
    }

    func tearDown() {
        try? library.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

final class PhotoCatalogTests: XCTestCase {
    private var temp: TempCatalog!

    override func setUpWithError() throws {
        temp = try TempCatalog()
    }

    override func tearDown() {
        temp.tearDown()
        temp = nil
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + offset)
    }

    // MARK: - Loading

    /// The three location counts a real library actually contains: a photo with
    /// one path, a photo with two (the same bytes at two places), and a photo
    /// the library remembers but has no file for.
    func testLoadResolvesZeroOneAndTwoLocations() throws {
        let one = try temp.importFile("one.dng", capturedAt: date(0))
        let two = try temp.importFile("two.dng", capturedAt: date(60))
        // The same bytes at a second path: one photo, two locations.
        let copy = try temp.writeFile("copy-of-two.dng", bytes: "two.dng")
        let second = try Importer(library: temp.library, probe: { _ in PhotoMetadata() })
            .importFile(at: copy)
        XCTAssertEqual(second.photoID, two)
        XCTAssertFalse(second.isNewPhoto)
        // …and one whose every location has been removed.
        let none = try temp.importFile("gone.dng", capturedAt: date(120))
        for location in try temp.library.locations(for: none) {
            if let id = location.id { _ = try temp.library.removeLocation(id: id) }
        }

        let catalog = PhotoCatalog()
        try catalog.load(from: temp.library)

        XCTAssertEqual(catalog.count, 3)
        XCTAssertEqual(catalog.photo(id: one)?.firstLocation,
                       temp.directory.appendingPathComponent("one.dng").path)
        // MIN(path): "copy-of-two.dng" sorts before "two.dng".
        XCTAssertEqual(catalog.photo(id: two)?.firstLocation,
                       temp.directory.appendingPathComponent("copy-of-two.dng").path)
        XCTAssertNil(catalog.photo(id: none)?.firstLocation)
        XCTAssertNil(catalog.photo(id: none)?.url)
        // *Every* path, sorted — the Folders panel files one photo under each
        // directory it has a file in.
        XCTAssertEqual(catalog.photo(id: one)?.locations,
                       [temp.directory.appendingPathComponent("one.dng").path])
        XCTAssertEqual(catalog.photo(id: two)?.locations,
                       [temp.directory.appendingPathComponent("copy-of-two.dng").path,
                        temp.directory.appendingPathComponent("two.dng").path])
        XCTAssertEqual(catalog.photo(id: none)?.locations, [])
        XCTAssertEqual(catalog.photo(id: one)?.originalName, "one.dng")
        XCTAssertEqual(catalog.photo(id: one)?.width, 6000)
    }

    func testLoadCountsDevelopmentsAndCollectsTags() throws {
        let bare = try temp.importFile("bare.dng", capturedAt: date(0))
        let developed = try temp.importFile("developed.dng", capturedAt: date(60))
        _ = try temp.library.addDevelopment(photoID: developed, edit: .init())
        _ = try temp.library.addDevelopment(photoID: developed, edit: .init())
        _ = try temp.library.addTag(photoID: developed, name: "portrait")
        _ = try temp.library.addTag(photoID: developed, name: "berlin")

        let catalog = PhotoCatalog()
        try catalog.load(from: temp.library)

        XCTAssertEqual(catalog.photo(id: bare)?.developmentCount, 0)
        XCTAssertEqual(catalog.photo(id: bare)?.tags, [])
        XCTAssertEqual(catalog.photo(id: developed)?.developmentCount, 2)
        // Alphabetical, not insertion order.
        XCTAssertEqual(catalog.photo(id: developed)?.tags, ["berlin", "portrait"])
    }

    func testLoadOfAnEmptyLibraryIsEmpty() throws {
        let catalog = PhotoCatalog()
        try catalog.load(from: temp.library)
        XCTAssertTrue(catalog.isEmpty)
        XCTAssertNil(catalog.photo(id: 1))
        XCTAssertNil(catalog.index(of: 1))
    }

    // MARK: - Order

    func testUndatedPhotosSortLastAndTiesBreakOnID() throws {
        let late = try temp.importFile("late.dng", capturedAt: date(600))
        let undatedA = try temp.importFile("undated-a.dng")
        let early = try temp.importFile("early.dng", capturedAt: date(0))
        let undatedB = try temp.importFile("undated-b.dng")

        let catalog = PhotoCatalog()
        try catalog.load(from: temp.library)

        XCTAssertEqual(catalog.ids, [early, late, undatedA, undatedB])
        XCTAssertEqual(catalog.index(of: early), 0)
        XCTAssertEqual(catalog.index(of: undatedB), 3)
    }

    /// Two frames from the same burst carry the same EXIF second; the row id
    /// then decides, so the order is stable across loads.
    func testEqualCaptureDatesBreakOnID() throws {
        let first = try temp.importFile("a.dng", capturedAt: date(0))
        let second = try temp.importFile("b.dng", capturedAt: date(0))
        let catalog = PhotoCatalog()
        try catalog.load(from: temp.library)
        XCTAssertEqual(catalog.ids, [first, second])
        XCTAssertLessThan(first, second)
    }

    // MARK: - Colour

    func testSetColorWritesTheDatabaseAndUpdatesRAM() throws {
        let a = try temp.importFile("a.dng", capturedAt: date(0))
        let b = try temp.importFile("b.dng", capturedAt: date(60))
        let c = try temp.importFile("c.dng", capturedAt: date(120))
        let catalog = PhotoCatalog()
        try catalog.load(from: temp.library)

        try catalog.setColor(.green, for: [a, c], in: temp.library)

        XCTAssertEqual(catalog.photo(id: a)?.color, .green)
        XCTAssertEqual(catalog.photo(id: c)?.color, .green)
        XCTAssertEqual(catalog.photo(id: b)?.color, .unlabeled)
        XCTAssertEqual(try temp.library.photo(id: a)?.color, .green)
        XCTAssertEqual(try temp.library.photo(id: c)?.color, .green)
        XCTAssertEqual(try temp.library.photo(id: b)?.color, .unlabeled)

        // Clearing is the same path with `.unlabeled`.
        try catalog.setColor(.unlabeled, for: [a, c], in: temp.library)
        XCTAssertEqual(catalog.photo(id: a)?.color, .unlabeled)
        XCTAssertEqual(try temp.library.photo(id: a)?.color, .unlabeled)

        // A fresh load agrees — the write really landed.
        let reloaded = PhotoCatalog()
        try reloaded.load(from: temp.library)
        XCTAssertTrue(reloaded.photos.allSatisfy { $0.color == .unlabeled })
    }

    func testSetColorOfNothingIsANoOp() throws {
        let a = try temp.importFile("a.dng", capturedAt: date(0))
        let catalog = PhotoCatalog()
        try catalog.load(from: temp.library)
        try catalog.setColor(.red, for: [], in: temp.library)
        XCTAssertEqual(catalog.photo(id: a)?.color, .unlabeled)
    }

    /// The write is attempted first, so a label that cannot be stored is not
    /// shown as though it had been.
    func testSetColorForAnUnknownPhotoThrowsAndChangesNothing() throws {
        let a = try temp.importFile("a.dng", capturedAt: date(0))
        let catalog = PhotoCatalog()
        try catalog.load(from: temp.library)
        XCTAssertThrowsError(try catalog.setColor(.blue, for: [a, 9999], in: temp.library))
        XCTAssertEqual(catalog.photo(id: a)?.color, .unlabeled)
        XCTAssertEqual(try temp.library.photo(id: a)?.color, .unlabeled)
    }

    // MARK: - Upsert

    func testApplyInsertsInSortedPosition() {
        let catalog = PhotoCatalog(photos: [
            CatalogPhoto(id: 1, originalName: "a", capturedAt: date(0)),
            CatalogPhoto(id: 3, originalName: "c", capturedAt: date(120)),
            CatalogPhoto(id: 9, originalName: "z", capturedAt: nil),
        ])
        catalog.apply(CatalogPhoto(id: 2, originalName: "b", capturedAt: date(60)))
        XCTAssertEqual(catalog.ids, [1, 2, 3, 9])
        // An undated arrival goes after every dated one, and after the undated
        // photo with the lower id.
        catalog.apply(CatalogPhoto(id: 4, originalName: "y", capturedAt: nil))
        XCTAssertEqual(catalog.ids, [1, 2, 3, 4, 9])
        XCTAssertEqual(catalog.index(of: 9), 4)
        XCTAssertEqual(catalog.count, 5)
    }

    func testApplyUpdatesInPlaceAndKeepsOrder() {
        let catalog = PhotoCatalog(photos: [
            CatalogPhoto(id: 1, originalName: "a", capturedAt: date(0)),
            CatalogPhoto(id: 2, originalName: "b", capturedAt: date(60)),
            CatalogPhoto(id: 3, originalName: "c", capturedAt: date(120)),
        ])
        var updated = catalog.photo(id: 2)!
        updated.color = .purple
        updated.developmentCount = 1
        catalog.apply(updated)
        XCTAssertEqual(catalog.ids, [1, 2, 3])
        XCTAssertEqual(catalog.photo(id: 2)?.color, .purple)
        XCTAssertEqual(catalog.photo(id: 2)?.developmentCount, 1)
        XCTAssertEqual(catalog.count, 3)
    }

    /// The one update that does move a photo: its capture date.
    func testApplyResortsWhenTheCaptureDateChanges() {
        let catalog = PhotoCatalog(photos: [
            CatalogPhoto(id: 1, originalName: "a", capturedAt: date(0)),
            CatalogPhoto(id: 2, originalName: "b", capturedAt: date(60)),
            CatalogPhoto(id: 3, originalName: "c", capturedAt: date(120)),
        ])
        var moved = catalog.photo(id: 1)!
        moved.capturedAt = date(600)
        catalog.apply(moved)
        XCTAssertEqual(catalog.ids, [2, 3, 1])
        XCTAssertEqual(catalog.index(of: 1), 2)
    }

    func testRemoveKeepsTheIndexConsistent() {
        let catalog = PhotoCatalog(photos: [
            CatalogPhoto(id: 1, originalName: "a", capturedAt: date(0)),
            CatalogPhoto(id: 2, originalName: "b", capturedAt: date(60)),
            CatalogPhoto(id: 3, originalName: "c", capturedAt: date(120)),
        ])
        catalog.remove(id: 1)
        XCTAssertEqual(catalog.ids, [2, 3])
        XCTAssertNil(catalog.index(of: 1))
        XCTAssertEqual(catalog.index(of: 3), 1)
    }

    func testSetDevelopmentCount() {
        let catalog = PhotoCatalog(photos: [
            CatalogPhoto(id: 1, originalName: "a", capturedAt: date(0)),
        ])
        catalog.setDevelopmentCount(1, for: 1)
        XCTAssertEqual(catalog.photo(id: 1)?.developmentCount, 1)
        catalog.setDevelopmentCount(1, for: 99)   // unknown id: no crash, no change
        XCTAssertEqual(catalog.count, 1)
    }
}
