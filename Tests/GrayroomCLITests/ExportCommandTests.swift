import CoreGraphics
import Foundation
import GrayroomCore
import GrayroomLibrary
import ImageIO
import XCTest
@testable import GrayroomCLI

/// `grayroom export`: several photos out of the library into one folder.
final class ExportCommandTests: XCTestCase {
    private var temp: TempLibrary!
    private var directory: URL!

    override func setUpWithError() throws {
        try requireRenderer()
        temp = try TempLibrary()
        directory = temp.directory.appendingPathComponent("exported", isDirectory: true)
    }

    override func tearDown() {
        temp?.tearDown()
        temp = nil
        directory = nil
    }

    private func names() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    /// Two photos, addressed the two ways a `<photo>` argument can be: by path
    /// and by id. The folder does not have to exist.
    func testExportWritesOneFilePerPhotoNamedAfterTheOriginal() throws {
        let a = try temp.writeImage("a.jpg", width: 32, height: 24)
        let b = try temp.writeImage("b.jpg", width: 40, height: 30, seed: 9)
        try temp.run(["import", a.path, b.path])
        let id = try PhotoRef.resolveID(b.path, in: temp.library)

        let result = try temp.run(["export", a.path, "\(id)", "--to", directory.path])

        XCTAssertEqual(try names(), ["a.png", "b.png"])
        XCTAssertEqual(result.lines.map { URL(fileURLWithPath: $0).lastPathComponent },
                       ["a.png", "b.png"])
        XCTAssertTrue(result.stderr.contains("exported 2 of 2"), result.stderr)

        let source = try XCTUnwrap(
            CGImageSourceCreateWithURL(directory.appendingPathComponent("b.png") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual([image.width, image.height], [40, 30], "full resolution")
    }

    func testTheFormatOptionPicksTheExtensionAndTheBitDepth() throws {
        let a = try temp.writeImage("a.jpg", width: 32, height: 24)
        try temp.run(["import", a.path])

        try temp.run(["export", a.path, "--to", directory.path, "--format", "tiff16"])

        XCTAssertEqual(try names(), ["a.tif"])
        let source = try XCTUnwrap(
            CGImageSourceCreateWithURL(directory.appendingPathComponent("a.tif") as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.bitsPerComponent, 16)
    }

    /// Exporting the same photo twice never overwrites — Lightroom's "-2".
    func testASecondExportOfTheSamePhotoIsNumbered() throws {
        let a = try temp.writeImage("a.jpg", width: 32, height: 24)
        try temp.run(["import", a.path])

        try temp.run(["export", a.path, "--to", directory.path])
        try temp.run(["export", a.path, "--to", directory.path])

        XCTAssertEqual(try names(), ["a-2.png", "a.png"])
    }

    func testExportRefetchesAnEvictedOriginal() throws {
        let a = try temp.writeImage("a.jpg", width: 32, height: 24)
        let b = try temp.writeImage("b.jpg", width: 40, height: 30, seed: 9)
        try temp.run(["import", a.path, b.path])
        let first = try PhotoRef.resolveID(a.path, in: temp.library)
        let photo = try XCTUnwrap(temp.library.photo(id: first))
        let storage = try OriginalStorage.resolved(for: temp.library)
        try FileManager.default.removeItem(at: storage.cacheURL(for: photo))

        let result = try temp.run(["export", "\(first)", b.path, "--to", directory.path])

        XCTAssertEqual(try names(), ["a.png", "b.png"])
        XCTAssertTrue(result.stderr.contains("exported 2"), result.stderr)
    }

    func testItRefusesAPhotoItCannotResolve() {
        temp.assertFails(["export", "nosuchphoto", "--to", directory.path],
                         contains: "no photo matches")
    }

    func testOutOfRangeOptionsAreRejectedAtParseTime() {
        for args in [["export", "1", "--to", "out", "--quality", "1.5"],
                     ["export", "1", "--to", "out", "--quality", "-0.1"],
                     ["export", "--to", "out"]] {
            XCTAssertThrowsError(try Grayroom.parseAsRoot(args), "\(args)")
        }
    }
}
