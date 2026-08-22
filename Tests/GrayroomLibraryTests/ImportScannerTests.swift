import Foundation
import XCTest
@testable import GrayroomLibrary

final class ImportScannerTests: XCTestCase {
    private var temp: TempLibrary!
    private var library: Library { temp.library }

    override func setUpWithError() throws {
        temp = try TempLibrary()
    }

    override func tearDown() {
        temp.tearDown()
        temp = nil
    }

    private func importer() -> Importer {
        Importer(library: library, probe: stubProbe())
    }

    private func names(_ urls: [URL]) -> [String] { urls.map(\.lastPathComponent) }

    // MARK: - Scanning

    /// Standard formats are first-class now, not a RAW-only app with
    /// exceptions: the scanner takes anything the decoder will open.
    func testScanFindsStandardFormatsAlongsideRAW() throws {
        for name in ["shoot/a.dng", "shoot/b.jpg", "shoot/c.jpeg", "shoot/d.tiff",
                     "shoot/e.tif", "shoot/f.png", "shoot/g.heic", "shoot/h.heif",
                     "shoot/i.NEF"] {
            try temp.writeFile(name, Data(name.utf8))
        }
        for name in ["shoot/notes.txt", "shoot/sidecar.xmp", "shoot/edit.grayroom.json",
                     "shoot/anim.gif", "shoot/doc.pdf", "shoot/logo.svg"] {
            try temp.writeFile(name, Data(name.utf8))
        }
        let root = temp.directory.appendingPathComponent("shoot")
        XCTAssertEqual(names(try ImportScanner.scan(directory: root, recursive: false)),
                       ["a.dng", "b.jpg", "c.jpeg", "d.tiff", "e.tif", "f.png",
                        "g.heic", "h.heif", "i.NEF"])
    }

    func testIsSupportedImageCoversBothPaths() {
        for name in ["a.dng", "a.NEF", "a.jpg", "a.jpeg", "a.png", "a.tiff", "a.tif",
                     "a.heic", "a.heif"] {
            XCTAssertTrue(Importer.isSupportedImage(URL(fileURLWithPath: "/x/\(name)")), name)
        }
        for name in ["a.txt", "a.xmp", "a.gif", "a.pdf", "a.svg", "a.mp4"] {
            XCTAssertFalse(Importer.isSupportedImage(URL(fileURLWithPath: "/x/\(name)")), name)
        }
    }

    func testScanFindsRAWFilesOnlyAndSortsThemByPath() throws {
        try temp.writeFile("shoot/b.dng", Data("two".utf8))
        try temp.writeFile("shoot/a.dng", Data("one".utf8))
        try temp.writeFile("shoot/notes.txt", Data("not a photo".utf8))
        try temp.writeFile("shoot/sidecar.xmp", Data("<x/>".utf8))

        let root = temp.directory.appendingPathComponent("shoot")
        let found = try ImportScanner.scan(directory: root, recursive: false)
        XCTAssertEqual(names(found), ["a.dng", "b.dng"])
    }

    func testScanRecursesOnlyWhenAsked() throws {
        try temp.writeFile("shoot/one.dng", Data("dng one".utf8))
        try temp.writeFile("shoot/nested/two.dng", Data("dng two".utf8))
        try temp.writeFile("shoot/nested/deeper/three.dng", Data("dng three".utf8))

        let root = temp.directory.appendingPathComponent("shoot")
        XCTAssertEqual(names(try ImportScanner.scan(directory: root, recursive: false)),
                       ["one.dng"])
        // Sorted by full path: shoot/nested/deeper < shoot/nested/two < shoot/one.
        XCTAssertEqual(names(try ImportScanner.scan(directory: root, recursive: true)),
                       ["three.dng", "two.dng", "one.dng"])
    }

    func testScanReturnsStandardizedAbsolutePaths() throws {
        try temp.writeFile("shoot/one.dng", Data("dng".utf8))
        let messy = temp.directory
            .appendingPathComponent("shoot")
            .appendingPathComponent("..")
            .appendingPathComponent("shoot")
        let found = try ImportScanner.scan(directory: messy, recursive: false)
        XCTAssertEqual(found.map(\.path),
                       [temp.directory.appendingPathComponent("shoot/one.dng")
                           .standardizedFileURL.path])
    }

    func testScanRejectsAFile() throws {
        let url = try temp.writeFile("one.dng", Data("dng".utf8))
        XCTAssertThrowsError(try ImportScanner.scan(directory: url, recursive: false))
    }

    func testScanOfAnEmptyDirectoryIsEmpty() throws {
        let empty = temp.directory.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertEqual(try ImportScanner.scan(directory: empty, recursive: true), [])
    }

    // MARK: - importFiles

    func testImportFilesReportsProgressPerFile() throws {
        let urls = try (0..<4).map { try temp.writeFile("f\($0).dng", Data("photo \($0)".utf8)) }
        var steps: [(Int, Int)] = []
        var newPhotos = 0
        let results = importer().importFiles(urls, progress: { done, total, outcome in
            steps.append((done, total))
            if case .success(let result) = outcome, result.isNewPhoto { newPhotos += 1 }
        })
        XCTAssertEqual(results.count, 4)
        XCTAssertEqual(newPhotos, 4)
        XCTAssertEqual(steps.map(\.0), [1, 2, 3, 4])
        XCTAssertEqual(steps.map(\.1), [4, 4, 4, 4])
        XCTAssertEqual(try library.photos().count, 4)
    }

    /// One bad file does not abandon the rest of the card.
    func testImportFilesKeepsGoingAfterAFailure() throws {
        let good = try temp.writeFile("good.dng", Data("good".utf8))
        let missing = temp.directory.appendingPathComponent("gone.dng")
        let alsoGood = try temp.writeFile("also.dng", Data("also".utf8))

        var failures = 0
        let results = importer().importFiles([good, missing, alsoGood],
                                             progress: { _, _, outcome in
            if case .failure = outcome { failures += 1 }
        })
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(try library.photos().count, 2)
    }

    func testImportFilesStopsWhenCancelled() throws {
        let urls = try (0..<6).map { try temp.writeFile("f\($0).dng", Data("photo \($0)".utf8)) }
        var seen = 0
        let results = importer().importFiles(urls, progress: { done, _, _ in seen = done },
                                             isCancelled: { seen >= 2 })
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(seen, 2)
        XCTAssertEqual(try library.photos().count, 2)
    }

    func testImportFilesCancelledBeforeTheFirstFileImportsNothing() throws {
        let urls = try (0..<3).map { try temp.writeFile("f\($0).dng", Data("photo \($0)".utf8)) }
        let results = importer().importFiles(urls, isCancelled: { true })
        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(try library.photos().count, 0)
    }

    // MARK: - A real JPEG through the real probe

    /// The importer's default probe now has to work on a rendered image, not
    /// just a RAW: width and height have to come out populated.
    func testARealJPEGImportsWithItsDimensions() throws {
        let url = try temp.writeJPEG("shoot/render.jpg", width: 40, height: 24)
        XCTAssertTrue(Importer.isSupportedImage(url))
        let result = try Importer(library: library).importFile(at: url)
        XCTAssertTrue(result.isNewPhoto)
        let photo = try XCTUnwrap(library.photo(id: result.photoID))
        XCTAssertEqual(photo.width, 40)
        XCTAssertEqual(photo.height, 24)
        XCTAssertGreaterThan(photo.byteSize, 0)
        XCTAssertEqual(photo.originalName, "render.jpg")
    }

    func testScanAndImportMixedFormats() throws {
        try temp.writeJPEG("mixed/one.jpg", width: 8, height: 8)
        try temp.writeJPEG("mixed/two.png", width: 8, height: 8, type: .png)
        try temp.writeFile("mixed/notes.txt", Data("skip me".utf8))
        let root = temp.directory.appendingPathComponent("mixed")
        let found = try ImportScanner.scan(directory: root, recursive: false)
        XCTAssertEqual(names(found), ["one.jpg", "two.png"])
        let results = Importer(library: library).importFiles(found)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(try library.photos().count, 2)
    }

    // MARK: - Precomputed hashes

    /// The import window has already hashed every file to decide what is new;
    /// re-reading a card to hash it a second time would double the slowest part
    /// of the operation.
    func testAPrecomputedHashIsUsedInsteadOfRehashing() throws {
        let url = try temp.writeFile("one.dng", Data("dng".utf8))
        let hash = try FileHash.sha256HexString(of: url)
        let result = try importer().importFile(at: url, precomputedHash: hash)
        let photo = try XCTUnwrap(library.photo(id: result.photoID))
        XCTAssertEqual(FileHash.hexString(photo.hash), hash)
        XCTAssertEqual(try library.photo(withHashHexString: hash)?.id, result.photoID)
    }

    func testImportFilesPassesEachFileItsOwnPrecomputedHash() throws {
        let a = try temp.writeFile("a.dng", Data("alpha".utf8))
        let b = try temp.writeFile("b.dng", Data("beta".utf8))
        let hashes = [
            a.standardizedFileURL: try FileHash.sha256HexString(of: a),
            b.standardizedFileURL: try FileHash.sha256HexString(of: b),
        ]
        let results = importer().importFiles([a, b], precomputedHashes: hashes)
        XCTAssertEqual(results.count, 2)
        XCTAssertNotEqual(results[0].photoID, results[1].photoID)
        for (url, hash) in hashes {
            let photo = try XCTUnwrap(library.photo(withHashHexString: hash))
            XCTAssertEqual(try library.locations(for: photo.id!).map(\.path), [url.path])
        }
    }

    /// A file the caller has no hash for still gets imported — it is just
    /// hashed here instead.
    func testAMissingPrecomputedHashFallsBackToHashing() throws {
        let a = try temp.writeFile("a.dng", Data("alpha".utf8))
        let b = try temp.writeFile("b.dng", Data("beta".utf8))
        let hashes = [a.standardizedFileURL: try FileHash.sha256HexString(of: a)]
        XCTAssertEqual(importer().importFiles([a, b], precomputedHashes: hashes).count, 2)
        XCTAssertEqual(try library.photos().count, 2)
        XCTAssertNotNil(try library.photo(withHashHexString: FileHash.sha256HexString(of: b)))
    }

    // MARK: - Hash identity, with and without locations

    /// The import window's "already imported" test is: a photo with these bytes
    /// **and** at least one location. Removing every location leaves a photo
    /// the library remembers but has no file for, and offering to add one back
    /// is then correct.
    func testAPhotoCanKnowAHashWithNoLocations() throws {
        let url = try temp.writeFile("shoot/one.dng", Data("dng".utf8))
        let hash = try FileHash.sha256HexString(of: url)
        let result = try importer().importFile(at: url)
        XCTAssertEqual(try library.locations(for: result.photoID).count, 1)

        for location in try library.locations(for: result.photoID) {
            XCTAssertTrue(try library.removeLocation(id: location.id!))
        }
        XCTAssertNotNil(try library.photo(withHashHexString: hash))
        XCTAssertTrue(try library.locations(for: result.photoID).isEmpty)
    }

    // MARK: - importDirectory still works on top of the split

    func testImportDirectoryUsesTheScanner() throws {
        try temp.writeFile("shoot/one.dng", Data("dng one".utf8))
        try temp.writeFile("shoot/notes.txt", Data("not a photo".utf8))
        try temp.writeFile("shoot/nested/two.dng", Data("dng two".utf8))

        let root = temp.directory.appendingPathComponent("shoot")
        XCTAssertEqual(try importer().importDirectory(at: root, recursive: false).count, 1)
        XCTAssertEqual(try importer().importDirectory(at: root, recursive: true).count, 2)
        XCTAssertEqual(try library.photos().count, 2)
    }
}
