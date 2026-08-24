import Foundation
import GRDB
import GrayroomCore
import XCTest
@testable import GrayroomLibrary

/// The library operations whose *failure* is the interesting half, plus the
/// lookups nothing else exercises.
final class LibraryErrorPathTests: XCTestCase {
    private var temp: TempLibrary!
    private var library: Library { temp.library }

    override func setUpWithError() throws {
        temp = try TempLibrary()
    }

    override func tearDown() {
        temp.tearDown()
        temp = nil
    }

    @discardableResult
    private func photo(_ name: String) throws -> Int64 {
        let url = try temp.writeFile(name, Data(name.utf8))
        return try Importer(library: library, probe: stubProbe()).importFile(at: url).photoID
    }

    // MARK: - Developments

    /// Updating a development that is not there must throw rather than silently
    /// do nothing: the caller believes it has just saved the user's work.
    func testUpdatingAMissingDevelopmentThrows() throws {
        XCTAssertThrowsError(try library.updateDevelopment(id: 404, edit: EditState())) { error in
            guard case LibraryError.noSuchDevelopment(let id) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertEqual(id, 404)
        }
    }

    func testDeletingAMissingDevelopmentReportsFalse() throws {
        XCTAssertFalse(try library.deleteDevelopment(id: 404))
        let id = try photo("a.dng")
        let stored = try library.addDevelopment(photoID: id, edit: EditState())
        XCTAssertTrue(try library.deleteDevelopment(id: try XCTUnwrap(stored.id)))
        XCTAssertFalse(try library.deleteDevelopment(id: try XCTUnwrap(stored.id)),
                       "deleting it twice is not an error, but it is not a delete either")
    }

    /// The ordinal counter is `MAX + 1`, so a deleted development leaves a hole
    /// rather than making the next one reuse its number.
    func testOrdinalsDoNotReuseADeletedNumber() throws {
        let id = try photo("a.dng")
        let first = try library.addDevelopment(photoID: id, edit: EditState())
        let second = try library.addDevelopment(photoID: id, edit: EditState())
        XCTAssertEqual([first.ordinal, second.ordinal], [1, 2])

        try library.deleteDevelopment(id: try XCTUnwrap(second.id))
        let third = try library.addDevelopment(photoID: id, edit: EditState())
        XCTAssertEqual(third.ordinal, 2, "the highest live ordinal is 1, so the next is 2")

        try library.deleteDevelopment(id: try XCTUnwrap(first.id))
        let fourth = try library.addDevelopment(photoID: id, edit: EditState())
        XCTAssertEqual(fourth.ordinal, 3, "#2 is still live, so this is #3")
    }

    // MARK: - Tags

    func testTaggingAMissingPhotoThrows() {
        XCTAssertThrowsError(try library.addTag(photoID: 404, name: "street")) { error in
            guard case LibraryError.noSuchPhoto(let id) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertEqual(id, 404)
        }
    }

    /// A tag row must not be created for a photo that does not exist.
    func testAFailedTagLeavesNoTagBehind() throws {
        XCTAssertThrowsError(try library.addTag(photoID: 404, name: "orphan"))
        XCTAssertTrue(try library.allTags().isEmpty)
    }

    func testAWhitespaceOnlyTagNameThrows() throws {
        let id = try photo("a.dng")
        for name in ["", "   ", "\n\t"] {
            XCTAssertThrowsError(try library.addTag(photoID: id, name: name)) { error in
                guard case LibraryError.emptyTagName = error else {
                    return XCTFail("wrong error \(error)")
                }
            }
        }
    }

    func testRemovingATagFromAPhotoThatDoesNotCarryItIsFalse() throws {
        let id = try photo("a.dng")
        XCTAssertFalse(try library.removeTag(photoID: id, name: "street"))
        try library.addTag(photoID: id, name: "street")
        XCTAssertTrue(try library.removeTag(photoID: id, name: " STREET "))
    }

    // MARK: - Locations

    func testLocationLookupByPath() throws {
        let id = try photo("a.dng")
        let path = temp.directory.appendingPathComponent("a.dng").standardizedFileURL.path

        let found = try XCTUnwrap(library.location(atPath: path))
        XCTAssertEqual(found.photoId, id)
        XCTAssertEqual(found.url.path, path, "Location.url is its path")

        XCTAssertNil(try library.location(atPath: "/nowhere/a.dng"))
        // The stored path is standardized, so an unstandardized spelling of the
        // same file does not match this raw lookup.
        XCTAssertNil(try library.location(atPath: path + "/../a.dng"))
    }

    func testRemovingAMissingLocationIsFalse() throws {
        XCTAssertFalse(try library.removeLocation(id: 404))
    }

    // MARK: - Cameras

    func testCameraFindOrCreateIsIdempotentAndOrdered() throws {
        let first = try library.camera(make: "Leica", model: "M11")
        let again = try library.camera(make: "Leica", model: "M11")
        XCTAssertEqual(first.id, again.id)

        try library.camera(make: "Nikon", model: "Z8")
        try library.camera(make: "Leica", model: "M10")
        XCTAssertEqual(try library.allCameras().map { "\($0.make) \($0.model)" },
                       ["Leica M10", "Leica M11", "Nikon Z8"])

        XCTAssertNil(try library.camera(id: 404))
    }

    // MARK: - Hash lookups

    func testHashLookupsRejectMalformedHex() throws {
        try photo("a.dng")
        XCTAssertNil(try library.photo(withHashHexString: "abc"), "odd length")
        XCTAssertNil(try library.photo(withHashHexString: "zz"), "not hex")
        XCTAssertTrue(try library.photos(withHashPrefix: "").isEmpty)
        XCTAssertTrue(try library.photos(withHashPrefix: "nothex").isEmpty)
    }

    func testHashPrefixMatchingIsCaseInsensitiveAndOrderedByID() throws {
        let tail = String(repeating: "0", count: 60)
        let ids = try library.dbPool.write { db -> [Int64] in
            var out: [Int64] = []
            for suffix in ["abcd", "abce", "abcf"] {
                var record = Photo(hash: FileHash.data(fromHexString: suffix + tail)!,
                                   byteSize: 1, originalName: "\(suffix).dng")
                try record.insert(db)
                out.append(record.id!)
            }
            return out
        }
        XCTAssertEqual(try library.photos(withHashPrefix: "abc").map(\.id), ids.map { $0 })
        XCTAssertEqual(try library.photos(withHashPrefix: "ABCD").map(\.id), [ids[0]])
        XCTAssertEqual(try library.photos(withHashPrefix: "abcd" + tail).map(\.id), [ids[0]])
    }

    // MARK: - Snapshot

    /// `firstLocation` is defined as the lexicographically first path, not
    /// "whichever row came back first", so a library opens the same file every
    /// launch.
    func testFirstLocationIsTheLexicographicallyFirstPath() throws {
        let id = try photo("m.dng")
        try library.addLocation(photoID: id, path: "/zzz/m.dng")
        try library.addLocation(photoID: id, path: "/aaa/m.dng")

        let summary = try XCTUnwrap(library.catalogSnapshot().summaries[id])
        XCTAssertEqual(summary.locations.first, "/aaa/m.dng")
        XCTAssertEqual(summary.firstLocation, "/aaa/m.dng")
        XCTAssertEqual(summary.locations.count, 3)

        XCTAssertNil(PhotoSummary().firstLocation)
    }

    // MARK: - Colour

    func testBulkColourIsAllOrNothing() throws {
        let a = try photo("a.dng")
        let b = try photo("b.dng")
        try library.setColor(.green, photoIDs: [a, b])
        XCTAssertEqual(try library.photo(id: a)?.color, .green)

        // One bad id rolls the whole transaction back.
        XCTAssertThrowsError(try library.setColor(.red, photoIDs: [a, 404, b]))
        XCTAssertEqual(try library.photo(id: a)?.color, .green)
        XCTAssertEqual(try library.photo(id: b)?.color, .green)
    }

    // MARK: - Error messages

    /// These are what the CLI and the app show, so they are part of the API.
    func testErrorMessages() {
        XCTAssertEqual(LibraryError.noSuchPhoto(7).description, "no photo with id 7")
        XCTAssertEqual(LibraryError.noSuchDevelopment(9).description, "no development with id 9")
        XCTAssertEqual(LibraryError.emptyTagName.description, "a tag name cannot be empty")
        XCTAssertEqual(LibraryError.notADirectory(URL(fileURLWithPath: "/tmp/x")).description,
                       "not a directory: /tmp/x")
    }
}
