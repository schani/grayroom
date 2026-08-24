import Foundation
import GrayroomLibrary
import XCTest
@testable import GrayroomCLI

/// `grayroom import`, run end to end against a throwaway library.
///
/// These go through the real `Importer` and the real decoder probe — the
/// command builds its own — so the files have to be real images.
final class ImportCommandTests: XCTestCase {
    private var temp: TempLibrary!
    private var library: Library { temp.library }

    override func setUpWithError() throws {
        temp = try TempLibrary()
    }

    override func tearDown() {
        temp.tearDown()
        temp = nil
    }

    // MARK: - Happy path

    func testImportingAFileAddsAPhotoAndReportsIt() throws {
        let file = try temp.writeImage("a.jpg")
        let output = try temp.run(["import", file.path])

        let photos = try library.photos()
        XCTAssertEqual(photos.count, 1)
        let photo = try XCTUnwrap(photos.first)
        XCTAssertEqual(try library.locations(for: try XCTUnwrap(photo.id)).map(\.path),
                       [file.standardizedFileURL.path])

        XCTAssertTrue(output.stdout.contains("added"), output.stdout)
        XCTAssertTrue(output.stdout.contains(String(photo.hashHexString.prefix(12))), output.stdout)
        XCTAssertTrue(output.stdout.contains(file.standardizedFileURL.path), output.stdout)
        XCTAssertTrue(output.stdout.contains("1 file(s): 1 added, 0 exists, 0 repointed; 1 new photo(s)"),
                      output.stdout)
    }

    /// The dimensions come off the real probe, not out of thin air.
    func testTheImportedPhotoCarriesItsDecodedSize() throws {
        let file = try temp.writeImage("a.jpg", width: 40, height: 24)
        try temp.run(["import", file.path])

        let photo = try XCTUnwrap(library.photos().first)
        XCTAssertEqual(photo.width, 40)
        XCTAssertEqual(photo.height, 24)
        XCTAssertEqual(photo.originalName, "a.jpg")
        XCTAssertGreaterThan(photo.byteSize, 0)
    }

    func testReimportingTheSamePathReportsExistsAndAddsNothing() throws {
        let file = try temp.writeImage("a.jpg")
        try temp.run(["import", file.path])
        let output = try temp.run(["import", file.path])

        XCTAssertEqual(try library.photos().count, 1)
        XCTAssertTrue(output.stdout.contains("exists"), output.stdout)
        XCTAssertTrue(output.stdout.contains("1 file(s): 0 added, 1 exists, 0 repointed; 0 new photo(s)"),
                      output.stdout)
    }

    /// Identity is the hash, so the same bytes at a second path is one photo
    /// with two locations — a new *location*, not a new photo.
    func testTheSameBytesAtASecondPathAddALocationButNotAPhoto() throws {
        let first = try temp.writeImage("a.jpg")
        try temp.run(["import", first.path])
        let second = temp.directory.appendingPathComponent("copy/a.jpg")
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: first, to: second)

        let output = try temp.run(["import", second.path])

        XCTAssertEqual(try library.photos().count, 1)
        let id = try XCTUnwrap(library.photos().first?.id)
        XCTAssertEqual(try library.locations(for: id).count, 2)
        XCTAssertTrue(output.stdout.contains("1 file(s): 1 added, 0 exists, 0 repointed; 0 new photo(s)"),
                      output.stdout)
    }

    /// Different bytes at a path the library already knows means the file was
    /// replaced: the location is repointed at the new photo rather than left
    /// describing something that is no longer there.
    func testChangedBytesAtAKnownPathAreReportedAsRepointed() throws {
        let file = try temp.writeImage("a.jpg", seed: 0)
        try temp.run(["import", file.path])
        let originalID = try XCTUnwrap(library.photos().first?.id)

        try FileManager.default.removeItem(at: file)
        _ = try temp.writeImage("a.jpg", width: 33, height: 21, seed: 77)
        let output = try temp.run(["import", file.path])

        XCTAssertTrue(output.stdout.contains("repointed"), output.stdout)
        XCTAssertTrue(output.stdout.contains("0 added, 0 exists, 1 repointed; 1 new photo(s)"),
                      output.stdout)
        XCTAssertEqual(try library.photos().count, 2)
        XCTAssertTrue(try library.locations(for: originalID).isEmpty,
                      "the old photo should have lost the path")
        let location = try XCTUnwrap(library.location(atPath: file.standardizedFileURL.path))
        XCTAssertNotEqual(location.photoId, originalID)
    }

    // MARK: - Directories

    func testImportingADirectoryWalksItAndSkipsNonImages() throws {
        try temp.writeImage("shoot/one.jpg")
        try temp.writeImage("shoot/deep/two.jpg", width: 20, height: 20)
        try temp.writeFile("shoot/notes.txt", Data("not an image".utf8))

        let output = try temp.run(["import", temp.directory.appendingPathComponent("shoot").path])

        XCTAssertEqual(try library.photos().count, 2)
        XCTAssertFalse(output.stdout.contains("notes.txt"), output.stdout)
        XCTAssertTrue(output.stdout.contains("2 file(s): 2 added"), output.stdout)
    }

    func testNoRecursiveStaysInTheTopDirectory() throws {
        try temp.writeImage("shoot/one.jpg")
        try temp.writeImage("shoot/deep/two.jpg", width: 20, height: 20)

        let shoot = temp.directory.appendingPathComponent("shoot").path
        try temp.run(["import", shoot, "--no-recursive"])

        XCTAssertEqual(try library.photos().map(\.originalName), ["one.jpg"])
    }

    // MARK: - Failures

    /// A path that is not there is reported and skipped; the other arguments
    /// still import.
    func testAMissingPathIsSkippedWithoutAbortingTheRun() throws {
        let file = try temp.writeImage("a.jpg")
        let output = try temp.run(["import", "/nope/missing.dng", file.path])

        XCTAssertEqual(try library.photos().count, 1)
        XCTAssertTrue(output.stderr.contains("skipped (not found): /nope/missing.dng"),
                      output.stderr)
        XCTAssertTrue(output.stdout.contains("1 skipped"), output.stdout)
    }

    /// A file the decoder cannot open is skipped, not fatal.
    func testAnUndecodableFileIsSkipped() throws {
        let good = try temp.writeImage("a.jpg")
        let bad = try temp.writeFile("broken.jpg", Data(repeating: 0x7f, count: 64))

        let output = try temp.run(["import", bad.path, good.path])

        XCTAssertEqual(try library.photos().map(\.originalName), ["a.jpg"])
        XCTAssertTrue(output.stderr.contains("skipped"), output.stderr)
        XCTAssertTrue(output.stdout.contains("1 skipped"), output.stdout)
    }

    func testImportNeedsAtLeastOnePath() {
        XCTAssertThrowsError(try Grayroom.parseAsRoot(["import"]))
    }

    /// A `--library` that cannot be opened is a usage error naming the path,
    /// not a stack of Swift error descriptions.
    func testAnUnopenableLibraryIsAUsageError() throws {
        let file = try temp.writeImage("a.jpg")
        let notADatabase = try temp.writeFile("garbage.sqlite",
                                              Data(repeating: 0x41, count: 4096))
        assertCommandFails(["import", file.path, "--library", notADatabase.path],
                           contains: "could not open library")
    }
}
