import Foundation
import GrayroomCore
import XCTest
@testable import GrayroomLibrary

final class ImporterTests: XCTestCase {
    private var temp: TempLibrary!
    private var library: Library { temp.library }

    override func setUpWithError() throws {
        temp = try TempLibrary()
    }

    override func tearDown() {
        temp.tearDown()
        temp = nil
    }

    private func importer(_ metadata: PhotoMetadata = PhotoMetadata()) -> Importer {
        Importer(library: library, probe: stubProbe(metadata))
    }

    // MARK: - Identity

    func testSameBytesAtTwoPathsIsOnePhotoWithTwoLocations() throws {
        let bytes = Data("one photo, two paths".utf8)
        let a = try temp.writeFile("a/IMG.raw", bytes)
        let b = try temp.writeFile("b/COPY.raw", bytes)
        let importer = self.importer()

        let first = try importer.importFile(at: a)
        let second = try importer.importFile(at: b)

        XCTAssertTrue(first.isNewPhoto)
        XCTAssertEqual(first.location, .added)
        XCTAssertFalse(second.isNewPhoto)
        XCTAssertEqual(second.location, .added)
        XCTAssertEqual(first.photoID, second.photoID)

        XCTAssertEqual(try library.photos().count, 1)
        let paths = try library.locations(for: first.photoID).map(\.path)
        XCTAssertEqual(Set(paths), [a.standardizedFileURL.path, b.standardizedFileURL.path])

        // The name recorded is the one the photo came in under.
        let photo = try XCTUnwrap(library.photo(id: first.photoID))
        XCTAssertEqual(photo.originalName, "IMG.raw")
        XCTAssertEqual(photo.byteSize, Int64(bytes.count))
    }

    func testReimportingTheSamePathIsANoOp() throws {
        let url = try temp.writeFile("IMG.raw", Data("stable bytes".utf8))
        let importer = self.importer()

        let first = try importer.importFile(at: url)
        let again = try importer.importFile(at: url)

        XCTAssertTrue(first.isNewPhoto)
        XCTAssertFalse(again.isNewPhoto)
        XCTAssertEqual(again.location, .unchanged)
        XCTAssertEqual(first.photoID, again.photoID)
        XCTAssertEqual(try library.photos().count, 1)
        XCTAssertEqual(try library.locations(for: first.photoID).count, 1)
    }

    /// The bytes at a recorded path changed: the path now describes the new
    /// photo, and the outcome names the photo it was taken from.
    func testChangedBytesAtAKnownPathRepointTheLocation() throws {
        let url = try temp.writeFile("IMG.raw", Data("first bytes".utf8))
        let importer = self.importer()
        let first = try importer.importFile(at: url)

        try Data("second bytes".utf8).write(to: url)
        let second = try importer.importFile(at: url)

        XCTAssertTrue(second.isNewPhoto)
        XCTAssertNotEqual(second.photoID, first.photoID)
        XCTAssertEqual(second.location, .repointed(fromPhotoID: first.photoID))
        XCTAssertEqual(try library.locations(for: first.photoID).count, 0)
        XCTAssertEqual(try library.locations(for: second.photoID).map(\.path),
                       [url.standardizedFileURL.path])
    }

    func testDifferentBytesAreDifferentPhotos() throws {
        let a = try temp.writeFile("a.raw", Data("alpha".utf8))
        let b = try temp.writeFile("b.raw", Data("beta".utf8))
        let importer = self.importer()
        let first = try importer.importFile(at: a)
        let second = try importer.importFile(at: b)
        XCTAssertNotEqual(first.photoID, second.photoID)
        XCTAssertEqual(try library.photos().count, 2)
    }

    func testPathsAreStoredAbsoluteAndStandardized() throws {
        let url = try temp.writeFile("dir/IMG.raw", Data("standardize me".utf8))
        let messy = temp.directory
            .appendingPathComponent("dir")
            .appendingPathComponent("..")
            .appendingPathComponent("dir")
            .appendingPathComponent("IMG.raw")
        let result = try importer().importFile(at: messy)
        let locations = try library.locations(for: result.photoID)
        XCTAssertEqual(locations.map(\.path), [url.standardizedFileURL.path])
    }

    // MARK: - Metadata

    func testMetadataAndCameraAreRecorded() throws {
        let captured = Date(timeIntervalSince1970: 1_700_000_000)
        let metadata = PhotoMetadata(
            width: 9528,
            height: 6328,
            capturedAt: captured,
            cameraMake: "Leica Camera AG",
            cameraModel: "LEICA M11",
            latitude: 48.2082,
            longitude: 16.3738,
            altitude: 171)
        let url = try temp.writeFile("M11.raw", Data("leica".utf8))
        let result = try importer(metadata).importFile(at: url)

        let photo = try XCTUnwrap(library.photo(id: result.photoID))
        XCTAssertEqual(photo.width, 9528)
        XCTAssertEqual(photo.height, 6328)
        XCTAssertEqual(photo.capturedAt?.timeIntervalSince1970 ?? 0,
                       captured.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(photo.latitude ?? 0, 48.2082, accuracy: 1e-9)
        XCTAssertEqual(photo.longitude ?? 0, 16.3738, accuracy: 1e-9)
        XCTAssertEqual(photo.altitude ?? 0, 171, accuracy: 1e-9)

        let cameraID = try XCTUnwrap(photo.cameraId)
        let camera = try XCTUnwrap(library.camera(id: cameraID))
        XCTAssertEqual(camera.make, "Leica Camera AG")
        XCTAssertEqual(camera.model, "LEICA M11")
    }

    func testCameraIsFoundOrCreatedOnce() throws {
        let metadata = PhotoMetadata(cameraMake: "Leica Camera AG", cameraModel: "LEICA M11")
        let importer = self.importer(metadata)
        let a = try importer.importFile(at: try temp.writeFile("1.raw", Data("1".utf8)))
        let b = try importer.importFile(at: try temp.writeFile("2.raw", Data("2".utf8)))
        let first = try XCTUnwrap(library.photo(id: a.photoID)).cameraId
        let second = try XCTUnwrap(library.photo(id: b.photoID)).cameraId
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try library.allCameras().count, 1)
    }

    func testCameraIsSkippedWhenMakeOrModelIsMissing() throws {
        let onlyMake = PhotoMetadata(cameraMake: "Leica Camera AG", cameraModel: "")
        let a = try importer(onlyMake).importFile(at: try temp.writeFile("1.raw", Data("1".utf8)))
        XCTAssertNil(try XCTUnwrap(library.photo(id: a.photoID)).cameraId)

        let neither = PhotoMetadata()
        let b = try importer(neither).importFile(at: try temp.writeFile("2.raw", Data("2".utf8)))
        XCTAssertNil(try XCTUnwrap(library.photo(id: b.photoID)).cameraId)
        XCTAssertEqual(try library.allCameras().count, 0)
    }

    func testLensIsRecordedAndFoundOrCreatedOnce() throws {
        let metadata = PhotoMetadata(cameraMake: "Leica Camera AG", cameraModel: "LEICA M11",
                                     lensMake: "Leica Camera AG",
                                     lensModel: "Summilux-M 1:1.4/35 ASPH.")
        let importer = self.importer(metadata)
        let a = try importer.importFile(at: try temp.writeFile("1.raw", Data("1".utf8)))
        let b = try importer.importFile(at: try temp.writeFile("2.raw", Data("2".utf8)))

        let lensID = try XCTUnwrap(XCTUnwrap(library.photo(id: a.photoID)).lensId)
        XCTAssertEqual(try XCTUnwrap(library.photo(id: b.photoID)).lensId, lensID)
        let lens = try XCTUnwrap(library.lens(id: lensID))
        XCTAssertEqual(lens.make, "Leica Camera AG")
        XCTAssertEqual(lens.model, "Summilux-M 1:1.4/35 ASPH.")
        XCTAssertEqual(try library.allLenses().count, 1)
        // The lens is its own dimension: the camera row is untouched by it.
        XCTAssertEqual(try library.allCameras().count, 1)
    }

    /// A model with no make is a lens; a make with no model is not.
    func testALensNeedsOnlyItsModel() throws {
        let modelOnly = PhotoMetadata(lensModel: "Summicron 50")
        let a = try importer(modelOnly).importFile(at: try temp.writeFile("1.raw",
                                                                         Data("1".utf8)))
        let lensID = try XCTUnwrap(XCTUnwrap(library.photo(id: a.photoID)).lensId)
        XCTAssertEqual(try library.lens(id: lensID)?.make, "")
        XCTAssertEqual(try library.lens(id: lensID)?.model, "Summicron 50")

        let makeOnly = PhotoMetadata(lensMake: "Leica Camera AG", lensModel: "  ")
        let b = try importer(makeOnly).importFile(at: try temp.writeFile("2.raw",
                                                                        Data("2".utf8)))
        XCTAssertNil(try XCTUnwrap(library.photo(id: b.photoID)).lensId)

        let neither = PhotoMetadata()
        let c = try importer(neither).importFile(at: try temp.writeFile("3.raw",
                                                                        Data("3".utf8)))
        XCTAssertNil(try XCTUnwrap(library.photo(id: c.photoID)).lensId)
        XCTAssertEqual(try library.allLenses().count, 1)
    }

    /// The importer's own probe reads the same two EXIF fields the decoder
    /// reports, so a file with a lens comes in with one.
    func testTheRealProbeCarriesTheLensThrough() throws {
        guard let url = testDataURL("L1000003.DNG") else {
            throw XCTSkip("testdata/L1000003.DNG not present (set GRAYROOM_TEST_DNG to override)")
        }
        let metadata = try Importer.probeRAW(url)
        guard let model = metadata.lensModel else {
            throw XCTSkip("\(url.lastPathComponent) carries no EXIF lens")
        }
        XCTAssertFalse(model.isEmpty)

        let photoID = try Importer(library: library).importFile(at: url).photoID
        let lensID = try XCTUnwrap(XCTUnwrap(library.photo(id: photoID)).lensId)
        XCTAssertEqual(try library.lens(id: lensID)?.model, model)
        XCTAssertEqual(try library.lens(id: lensID)?.make, metadata.lensMake ?? "")
    }

    // MARK: - Directories

    func testImportDirectoryPicksUpOnlyRAWFiles() throws {
        try temp.writeFile("shoot/one.dng", Data("dng one".utf8))
        try temp.writeFile("shoot/notes.txt", Data("not a photo".utf8))
        try temp.writeFile("shoot/nested/two.dng", Data("dng two".utf8))

        let root = temp.directory.appendingPathComponent("shoot")
        let flat = try importer().importDirectory(at: root, recursive: false)
        XCTAssertEqual(flat.count, 1)

        let deep = try importer().importDirectory(at: root, recursive: true)
        XCTAssertEqual(deep.count, 2)
        XCTAssertEqual(try library.photos().count, 2)
    }

    func testImportDirectoryRejectsAFile() throws {
        let url = try temp.writeFile("one.dng", Data("dng".utf8))
        XCTAssertThrowsError(try importer().importDirectory(at: url))
    }

    // MARK: - Real RAW

    func testImportRealDNG() throws {
        guard let url = testDataURL("L1000003.DNG") else {
            throw XCTSkip("testdata/L1000003.DNG not present (set GRAYROOM_TEST_DNG to override)")
        }
        XCTAssertTrue(Importer.isSupportedImage(url))
        let result = try Importer(library: library).importFile(at: url)
        XCTAssertTrue(result.isNewPhoto)

        let photo = try XCTUnwrap(library.photo(id: result.photoID))
        XCTAssertGreaterThan(photo.byteSize, 0)
        XCTAssertGreaterThan(photo.width ?? 0, 1000)
        XCTAssertGreaterThan(photo.height ?? 0, 1000)
        XCTAssertNotNil(photo.capturedAt)
        let cameraID = try XCTUnwrap(photo.cameraId)
        let camera = try XCTUnwrap(library.camera(id: cameraID))
        XCTAssertFalse(camera.make.isEmpty)
        XCTAssertFalse(camera.model.isEmpty)

        // Same file, second time: no new photo, no new location.
        let again = try Importer(library: library).importFile(at: url)
        XCTAssertFalse(again.isNewPhoto)
        XCTAssertEqual(again.location, .unchanged)
    }
}
