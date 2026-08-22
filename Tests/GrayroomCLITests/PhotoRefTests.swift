import Foundation
import GrayroomLibrary
import XCTest
@testable import GrayroomCLI

final class PhotoRefTests: XCTestCase {
    private var temp: TempLibrary!
    private var library: Library { temp.library }

    override func setUpWithError() throws {
        temp = try TempLibrary()
    }

    override func tearDown() {
        temp.tearDown()
        temp = nil
    }

    func testResolvesAnID() throws {
        let url = try temp.writeFile("a.dng", Data("a".utf8))
        let id = try temp.importFile(url)
        XCTAssertEqual(try PhotoRef.resolveID(String(id), in: library), id)
    }

    func testResolvesAHashPrefix() throws {
        let url = try temp.writeFile("a.dng", Data("a".utf8))
        let id = try temp.importFile(url)
        let photo = try XCTUnwrap(library.photo(id: id))

        // A short prefix, and the same prefix in the other case.
        let prefix = String(photo.hashHexString.prefix(8))
        XCTAssertEqual(try PhotoRef.resolveID(prefix, in: library), id)
        XCTAssertEqual(try PhotoRef.resolveID(prefix.uppercased(), in: library), id)
        XCTAssertEqual(try PhotoRef.resolveID(photo.hashHexString, in: library), id)
    }

    func testAmbiguousHashPrefixThrows() throws {
        let common = "abcd"
        let tail = String(repeating: "0", count: 64 - common.count - 1)
        try temp.insertPhoto(hashHex: common + "1" + tail)
        try temp.insertPhoto(hashHex: common + "2" + tail)

        XCTAssertThrowsError(try PhotoRef.resolveID(common, in: library)) { error in
            guard case PhotoRefError.ambiguousPrefix(let token, let matches) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertEqual(token, common)
            XCTAssertEqual(matches.count, 2)
        }
        // One digit more and it is unambiguous again.
        XCTAssertNoThrow(try PhotoRef.resolveID(common + "1", in: library))
    }

    func testResolvesAFilePath() throws {
        let url = try temp.writeFile("a.dng", Data("a".utf8))
        let id = try temp.importFile(url)
        XCTAssertEqual(try PhotoRef.resolveID(url.path, in: library), id)

        // The same bytes at another path resolve to the same photo even before
        // that path is imported: identity is the hash, not the location.
        let copy = try temp.writeFile("elsewhere/a.dng", Data("a".utf8))
        XCTAssertEqual(try PhotoRef.resolveID(copy.path, in: library), id)
    }

    func testAFileTheLibraryHasNeverSeenThrows() throws {
        let url = try temp.writeFile("stranger.dng", Data("stranger".utf8))
        XCTAssertThrowsError(try PhotoRef.resolveID(url.path, in: library)) { error in
            guard case PhotoRefError.fileNotInLibrary = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    func testUnknownTokenThrows() {
        XCTAssertThrowsError(try PhotoRef.resolveID("ff00ff00", in: library)) { error in
            guard case PhotoRefError.notFound = error else {
                return XCTFail("wrong error \(error)")
            }
        }
        XCTAssertThrowsError(try PhotoRef.resolveID("not a photo", in: library)) { error in
            guard case PhotoRefError.notFound = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    /// The spellings overlap — `1` is both a plausible id and a plausible hash
    /// prefix — and the id is what `ls` prints, so the id wins.
    func testAnIDBeatsAHashPrefix() throws {
        let byID = try temp.insertPhoto(hashHex: String(repeating: "e", count: 64),
                                        name: "first.dng")
        let byPrefix = try temp.insertPhoto(hashHex: "1" + String(repeating: "0", count: 63),
                                            name: "second.dng")
        XCTAssertEqual(byID, 1, "the first insert should own id 1")

        XCTAssertEqual(try PhotoRef.resolveID("1", in: library), byID)
        // The other photo is still reachable by a longer prefix.
        XCTAssertEqual(try PhotoRef.resolveID("10", in: library), byPrefix)
    }

    /// A directory is not a photo, and must not be hashed as if it were.
    func testADirectoryIsNotAPhoto() {
        XCTAssertThrowsError(try PhotoRef.resolveID(temp.directory.path, in: library)) { error in
            guard case PhotoRefError.notFound = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }
}
