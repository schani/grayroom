import Foundation
import GrayroomCore
import XCTest
@testable import GrayroomLibrary

final class PreviewStoreTests: XCTestCase {
    private var temp: TempLibrary!
    private var library: Library { temp.library }
    private var store: PreviewStore!

    override func setUpWithError() throws {
        temp = try TempLibrary()
        store = try PreviewStore.open(for: library)
    }

    override func tearDown() {
        try? store.close()
        store = nil
        temp.tearDown()
        temp = nil
    }

    /// Not real JPEG — the store is a byte bucket and never decodes what it
    /// holds; that is `PreviewBuilder`'s job.
    private func jpeg(_ seed: UInt8, count: Int = 64) -> Data {
        Data((0..<count).map { UInt8(($0 &* 7 &+ Int(seed)) % 256) })
    }

    @discardableResult
    private func makePhoto(_ name: String) throws -> Int64 {
        let url = try temp.writeFile(name, Data(name.utf8))
        return try Importer(library: library, probe: stubProbe()).importFile(at: url).photoID
    }

    // MARK: - Location

    func testLivesBesideTheLibrary() {
        XCTAssertEqual(store.url.lastPathComponent, "previews.sqlite")
        XCTAssertEqual(store.url.deletingLastPathComponent().path,
                       library.url.deletingLastPathComponent().path)
        XCTAssertEqual(store.url, library.previewsURL)
    }

    // MARK: - Round trip

    func testStoreAndReadBackAnEmbeddedPreview() throws {
        let bytes = jpeg(3, count: 128)
        try store.store(photoID: 7, source: .embedded, fingerprint: nil,
                        width: 512, height: 341, jpeg: bytes)

        let row = try XCTUnwrap(try store.preview(for: 7))
        XCTAssertEqual(row.source, .embedded)
        XCTAssertNil(row.fingerprint)
        XCTAssertEqual(row.width, 512)
        XCTAssertEqual(row.height, 341)
        XCTAssertEqual(row.jpeg, bytes)
        XCTAssertEqual(try store.count, 1)
        XCTAssertEqual(try store.totalBytes, Int64(bytes.count))
    }

    func testStoreAndReadBackARenderedPreview() throws {
        var edit = EditState()
        edit.tone.exposure = 1.5
        let bytes = jpeg(9)
        try store.store(photoID: 11, source: .rendered, fingerprint: edit.fingerprint,
                        width: 341, height: 512, jpeg: bytes)

        let row = try XCTUnwrap(try store.preview(for: 11))
        XCTAssertEqual(row.source, .rendered)
        XCTAssertEqual(row.fingerprint, edit.fingerprint)
        XCTAssertEqual(row.width, 341)
        XCTAssertEqual(row.height, 512)
        XCTAssertEqual(row.jpeg, bytes)
    }

    func testAnUnknownPhotoHasNoPreview() throws {
        XCTAssertNil(try store.preview(for: 4711))
        XCTAssertEqual(try store.count, 0)
        XCTAssertEqual(try store.totalBytes, 0)
    }

    // MARK: - Upsert

    func testStoringAgainReplacesTheRow() throws {
        var edit = EditState()
        edit.clarity = 30
        try store.store(photoID: 5, source: .embedded, fingerprint: nil,
                        width: 512, height: 512, jpeg: jpeg(1, count: 40))
        try store.store(photoID: 5, source: .rendered, fingerprint: edit.fingerprint,
                        width: 256, height: 512, jpeg: jpeg(2, count: 90))

        XCTAssertEqual(try store.count, 1, "a photo has one preview, not a history of them")
        let row = try XCTUnwrap(try store.preview(for: 5))
        XCTAssertEqual(row.source, .rendered)
        XCTAssertEqual(row.fingerprint, edit.fingerprint)
        XCTAssertEqual(row.width, 256)
        XCTAssertEqual(row.jpeg, jpeg(2, count: 90))
        XCTAssertEqual(try store.totalBytes, 90)
    }

    /// An embedded preview is the camera's picture, not a rendition of an edit,
    /// so it must never carry a fingerprint — a row that did would claim to be
    /// current for a development it is not a picture of.
    func testAnEmbeddedPreviewNeverKeepsAFingerprint() throws {
        var edit = EditState()
        edit.tone.exposure = -1
        try store.store(photoID: 2, source: .embedded, fingerprint: edit.fingerprint,
                        width: 512, height: 288, jpeg: jpeg(4))

        XCTAssertNil(try store.preview(for: 2)?.fingerprint)
    }

    // MARK: - Deletion

    func testDelete() throws {
        try store.store(photoID: 1, source: .embedded, fingerprint: nil,
                        width: 512, height: 512, jpeg: jpeg(1))
        try store.store(photoID: 2, source: .embedded, fingerprint: nil,
                        width: 512, height: 512, jpeg: jpeg(2))

        XCTAssertTrue(try store.delete(photoID: 1))
        XCTAssertNil(try store.preview(for: 1))
        XCTAssertNotNil(try store.preview(for: 2))
        XCTAssertEqual(try store.count, 1)
        XCTAssertFalse(try store.delete(photoID: 1), "deleting it twice is not a deletion")
    }

    func testDeleteAll() throws {
        for id in 1...5 {
            try store.store(photoID: Int64(id), source: .embedded, fingerprint: nil,
                            width: 512, height: 512, jpeg: jpeg(UInt8(id)))
        }
        XCTAssertEqual(try store.count, 5)
        try store.deleteAll()
        XCTAssertEqual(try store.count, 0)
        XCTAssertEqual(try store.totalBytes, 0)
    }

    /// The two databases are separate files, so no foreign key can cascade. The
    /// `previewStore` hook is what does it instead.
    func testDeletingAPhotoDeletesItsPreview() throws {
        let photoID = try makePhoto("one.dng")
        try store.store(photoID: photoID, source: .embedded, fingerprint: nil,
                        width: 512, height: 512, jpeg: jpeg(6))
        library.previewStore = store

        XCTAssertTrue(try library.deletePhoto(id: photoID))
        XCTAssertNil(try store.preview(for: photoID))
    }

    func testDeletingAPhotoLeavesOtherPreviewsAlone() throws {
        let doomed = try makePhoto("doomed.dng")
        let kept = try makePhoto("kept.dng")
        try store.store(photoID: doomed, source: .embedded, fingerprint: nil,
                        width: 512, height: 512, jpeg: jpeg(7))
        try store.store(photoID: kept, source: .embedded, fingerprint: nil,
                        width: 512, height: 512, jpeg: jpeg(8))
        library.previewStore = store

        XCTAssertTrue(try library.deletePhoto(id: doomed))
        XCTAssertEqual(try store.count, 1)
        XCTAssertNotNil(try store.preview(for: kept))
    }

    // MARK: - Currency

    func testAnEmbeddedPreviewIsCurrentOnlyWithoutADevelopment() {
        let row = StoredPreview(source: .embedded, fingerprint: nil,
                                width: 512, height: 512, jpeg: Data())
        XCTAssertTrue(row.isCurrent(developmentFingerprint: nil))
        XCTAssertFalse(row.isCurrent(developmentFingerprint: EditState().fingerprint))
    }

    func testARenderedPreviewIsCurrentOnlyForItsOwnEdit() {
        var edit = EditState()
        edit.tone.exposure = 0.5
        var other = EditState()
        other.tone.exposure = 0.6
        let row = StoredPreview(source: .rendered, fingerprint: edit.fingerprint,
                                width: 512, height: 512, jpeg: Data())

        XCTAssertTrue(row.isCurrent(developmentFingerprint: edit.fingerprint))
        XCTAssertFalse(row.isCurrent(developmentFingerprint: other.fingerprint))
        XCTAssertFalse(row.isCurrent(developmentFingerprint: nil),
                       "deleting the development sends the cell back to the embedded preview")
    }

    // MARK: - Persistence

    func testTheRowsSurviveReopening() throws {
        try store.store(photoID: 3, source: .rendered, fingerprint: EditState().fingerprint,
                        width: 512, height: 400, jpeg: jpeg(5, count: 33))
        try store.close()

        store = try PreviewStore(url: library.previewsURL)
        let row = try XCTUnwrap(try store.preview(for: 3))
        XCTAssertEqual(row.source, .rendered)
        XCTAssertEqual(row.width, 512)
        XCTAssertEqual(row.jpeg.count, 33)
    }
}
