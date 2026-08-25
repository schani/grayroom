import Foundation
import GRDB
import GrayroomCore
import XCTest
@testable import GrayroomLibrary

final class LibraryTests: XCTestCase {
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
    private func makePhoto(_ name: String, capturedAt: Date? = nil) throws -> Int64 {
        let url = try temp.writeFile(name, Data(name.utf8))
        let importer = Importer(library: library,
                                probe: stubProbe(PhotoMetadata(capturedAt: capturedAt)))
        return try importer.importFile(at: url).photoID
    }

    /// A recognisable edit: a non-default tone plus one brush mask.
    private func sampleEdit() -> EditState {
        var edit = EditState()
        edit.tone = EditState.Tone(exposure: 0.75, contrast: -12, highlights: 30,
                                   shadows: -20, whites: 5, blacks: -7)
        edit.clarity = 42
        edit.masks = [
            Mask(id: UUID(uuidString: "6A1E0B0C-0000-4000-8000-000000000001")!,
                 name: "Sky",
                 enabled: true,
                 adjustments: MaskAdjustments(exposure: -1.25, contrast: 10,
                                              highlights: -40, shadows: 0, clarity: 15),
                 strokes: [
                    Stroke(brush: BrushParams(size: 0.2, feather: 60, flow: 40, density: 80),
                           erase: false,
                           polyline: [(0.1, 0.1), (0.4, 0.2), (0.7, 0.15)]),
                    Stroke(brush: BrushParams(),
                           erase: true,
                           polyline: [(0.5, 0.5)]),
                 ]),
        ]
        return edit
    }

    // MARK: - Schema

    func testSchemaIsCreatedWithForeignKeysOn() throws {
        try library.dbPool.read { db in
            for table in ["cameras", "lenses", "photos", "locations", "developments", "tags",
                          "photo_tags"] {
                XCTAssertTrue(try db.tableExists(table), table)
            }
            XCTAssertEqual(try Bool.fetchOne(db, sql: "PRAGMA foreign_keys"), true)
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA journal_mode"), "wal")
        }
    }

    func testV1LibraryGainsTheCullingColumns() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grayroom-v1-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("library.sqlite").path
        try Library.migrator.migrate(try DatabasePool(path: path), upTo: "v1")
        let library = try Library(path: path)
        try library.dbPool.read { db in
            let columns = try db.columns(in: "photos").map(\.name)
            XCTAssertTrue(columns.contains("aesthetic_score"))
            XCTAssertTrue(columns.contains("feature_print"))
        }
    }

    func testInvalidEditJSONIsRejected() throws {
        let photoID = try makePhoto("a.raw")
        try library.dbPool.write { db in
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO developments (photo_id, ordinal, edit_json, created_at, updated_at)
                VALUES (?, 1, 'not json', '2024-01-01', '2024-01-01')
                """, arguments: [photoID]))
        }
    }

    func testReopeningAnExistingDatabaseKeepsItsContents() throws {
        let photoID = try makePhoto("a.raw")
        try library.close()
        let reopened = try Library(url: temp.directory.appendingPathComponent("library.sqlite"))
        XCTAssertNotNil(try reopened.photo(id: photoID))
        try reopened.close()
    }

    // MARK: - Developments

    func testDevelopmentRoundTripsAnEditState() throws {
        let photoID = try makePhoto("a.raw")
        let edit = sampleEdit()
        let stored = try library.addDevelopment(photoID: photoID, edit: edit)
        XCTAssertEqual(stored.ordinal, 1)
        XCTAssertEqual(stored.edit, edit)

        let fetched = try XCTUnwrap(library.developments(for: photoID).first)
        XCTAssertEqual(fetched.edit, edit)
        XCTAssertEqual(fetched.edit.masks.first?.strokes.count, 2)
        XCTAssertEqual(fetched.edit.masks.first?.strokes[1].erase, true)
    }

    func testDevelopmentsAreOrderedByOrdinalAndOrdinalsAreUnique() throws {
        let photoID = try makePhoto("a.raw")
        var second = EditState()
        second.tone.exposure = 1
        var third = EditState()
        third.clarity = 10

        let a = try library.addDevelopment(photoID: photoID, edit: EditState())
        let b = try library.addDevelopment(photoID: photoID, edit: second)
        let c = try library.addDevelopment(photoID: photoID, edit: third)
        XCTAssertEqual([a.ordinal, b.ordinal, c.ordinal], [1, 2, 3])
        XCTAssertEqual(try library.developments(for: photoID).map(\.ordinal), [1, 2, 3])

        // A duplicate ordinal is refused by the schema.
        try library.dbPool.write { db in
            XCTAssertThrowsError(try db.execute(sql: """
                INSERT INTO developments (photo_id, ordinal, edit_json, created_at, updated_at)
                VALUES (?, 1, '{}', '2024-01-01', '2024-01-01')
                """, arguments: [photoID]))
        }

        // Ordinals of two photos are independent.
        let otherID = try makePhoto("b.raw")
        XCTAssertEqual(try library.addDevelopment(photoID: otherID, edit: EditState()).ordinal, 1)
    }

    func testUpdateDevelopmentBumpsUpdatedAt() throws {
        let photoID = try makePhoto("a.raw")
        let original = try library.addDevelopment(photoID: photoID, edit: EditState())
        let id = try XCTUnwrap(original.id)

        var edited = EditState()
        edited.tone.exposure = -2

        let updated = try library.updateDevelopment(id: id, edit: edited)
        XCTAssertEqual(updated.edit, edited)
        XCTAssertEqual(updated.ordinal, original.ordinal)
        XCTAssertEqual(updated.createdAt.timeIntervalSince1970,
                       original.createdAt.timeIntervalSince1970, accuracy: 0.002)
        XCTAssertGreaterThanOrEqual(updated.updatedAt, original.updatedAt)
        XCTAssertEqual(try XCTUnwrap(library.development(id: id)).edit, edited)
    }

    func testDeleteDevelopment() throws {
        let photoID = try makePhoto("a.raw")
        let development = try library.addDevelopment(photoID: photoID, edit: EditState())
        XCTAssertTrue(try library.deleteDevelopment(id: try XCTUnwrap(development.id)))
        XCTAssertEqual(try library.developments(for: photoID).count, 0)
    }

    func testAddDevelopmentToAMissingPhotoThrows() {
        XCTAssertThrowsError(try library.addDevelopment(photoID: 999, edit: EditState()))
    }

    // MARK: - Tags

    func testTaggingIsCaseInsensitiveAndIdempotent() throws {
        let photoID = try makePhoto("a.raw")
        let first = try library.addTag(photoID: photoID, name: "Portrait")
        let second = try library.addTag(photoID: photoID, name: "portrait")
        let third = try library.addTag(photoID: photoID, name: "  PORTRAIT  ")

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.id, third.id)
        XCTAssertEqual(try library.allTags().count, 1)
        // The first spelling seen is the one kept.
        XCTAssertEqual(try library.tags(for: photoID).map(\.name), ["Portrait"])
    }

    func testRemoveTagIsCaseInsensitiveAndKeepsTheTag() throws {
        let photoID = try makePhoto("a.raw")
        try library.addTag(photoID: photoID, name: "Street")
        XCTAssertTrue(try library.removeTag(photoID: photoID, name: "STREET"))
        XCTAssertEqual(try library.tags(for: photoID).count, 0)
        XCTAssertEqual(try library.allTags().map(\.name), ["Street"])
        XCTAssertFalse(try library.removeTag(photoID: photoID, name: "Street"))
    }

    func testEmptyTagNameThrows() throws {
        let photoID = try makePhoto("a.raw")
        XCTAssertThrowsError(try library.addTag(photoID: photoID, name: "   "))
    }

    // MARK: - Color and queries

    func testColorSetAndFilter() throws {
        let red = try makePhoto("red.raw")
        let blue = try makePhoto("blue.raw")
        let plain = try makePhoto("plain.raw")

        try library.setColor(photoID: red, .red)
        try library.setColor(photoID: blue, .blue)

        XCTAssertEqual(try XCTUnwrap(library.photo(id: red)).color, .red)
        XCTAssertEqual(try XCTUnwrap(library.photo(id: plain)).color, .unlabeled)
        XCTAssertEqual(try library.photos(color: .red).map(\.id), [red])
        XCTAssertEqual(try library.photos(color: .unlabeled).map(\.id), [plain])
        XCTAssertEqual(try library.photos().count, 3)

        // Colors are single-valued: setting again replaces.
        try library.setColor(photoID: red, .green)
        XCTAssertEqual(try library.photos(color: .red).count, 0)
        XCTAssertEqual(try library.photos(color: .green).map(\.id), [red])
    }

    func testSetColorOnAMissingPhotoThrows() {
        XCTAssertThrowsError(try library.setColor(photoID: 999, .red))
    }

    func testQueryFiltersCompose() throws {
        let metadata = PhotoMetadata(cameraMake: "Leica Camera AG", cameraModel: "LEICA M11")
        let importer = Importer(library: library, probe: stubProbe(metadata))
        let a = try importer.importFile(at: try temp.writeFile("a.raw", Data("a".utf8))).photoID
        let b = try importer.importFile(at: try temp.writeFile("b.raw", Data("b".utf8))).photoID

        let cameraID = try XCTUnwrap(XCTUnwrap(library.photo(id: a)).cameraId)
        try library.setColor(photoID: a, .yellow)
        try library.addTag(photoID: a, name: "keeper")
        try library.addTag(photoID: b, name: "keeper")

        XCTAssertEqual(try library.photos(tag: "KEEPER").map(\.id), [a, b])
        XCTAssertEqual(try library.photos(color: .yellow, tag: "keeper").map(\.id), [a])
        XCTAssertEqual(try library.photos(cameraID: cameraID).map(\.id), [a, b])
        XCTAssertEqual(
            try library.photos(color: .yellow, tag: "keeper", cameraID: cameraID).map(\.id), [a])
        XCTAssertEqual(try library.photos(color: .red, tag: "keeper").count, 0)
    }

    func testPhotosAreOrderedByCaptureDateThenID() throws {
        let late = try makePhoto("late.raw", capturedAt: Date(timeIntervalSince1970: 2_000_000))
        let early = try makePhoto("early.raw", capturedAt: Date(timeIntervalSince1970: 1_000_000))
        let undated = try makePhoto("undated.raw")
        // NULL capture dates sort first in SQLite, then the dated ones in order.
        XCTAssertEqual(try library.photos().map(\.id), [undated, early, late])
    }

    // MARK: - Locations

    func testAddAndRemoveLocation() throws {
        let photoID = try makePhoto("a.raw")
        let extra = temp.directory.appendingPathComponent("elsewhere/a.raw").path
        let added = try library.addLocation(photoID: photoID, path: extra)
        XCTAssertEqual(try library.locations(for: photoID).count, 2)

        // Re-adding the same path changes nothing.
        let again = try library.addLocation(photoID: photoID, path: extra)
        XCTAssertEqual(again.id, added.id)
        XCTAssertEqual(try library.locations(for: photoID).count, 2)

        XCTAssertTrue(try library.removeLocation(id: try XCTUnwrap(added.id)))
        XCTAssertEqual(try library.locations(for: photoID).count, 1)
    }

    // MARK: - Cascade

    func testDeletePhotoCascades() throws {
        let photoID = try makePhoto("a.raw")
        let survivor = try makePhoto("b.raw")
        try library.addLocation(photoID: photoID,
                                path: temp.directory.appendingPathComponent("copy.raw").path)
        try library.addDevelopment(photoID: photoID, edit: sampleEdit())
        try library.addDevelopment(photoID: photoID, edit: EditState())
        try library.addTag(photoID: photoID, name: "doomed")
        try library.addTag(photoID: survivor, name: "doomed")

        XCTAssertTrue(try library.deletePhoto(id: photoID))

        XCTAssertNil(try library.photo(id: photoID))
        XCTAssertEqual(try library.locations(for: photoID).count, 0)
        XCTAssertEqual(try library.developments(for: photoID).count, 0)
        XCTAssertEqual(try library.tags(for: photoID).count, 0)

        try library.dbPool.read { db in
            XCTAssertEqual(try Location.fetchCount(db), 1)
            XCTAssertEqual(try Development.fetchCount(db), 0)
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photo_tags"), 1)
        }
        // The tag row itself survives, and so does the other photo.
        XCTAssertEqual(try library.allTags().map(\.name), ["doomed"])
        XCTAssertEqual(try library.tags(for: survivor).map(\.name), ["doomed"])
    }

    func testDeletingALensLeavesItsPhotos() throws {
        let metadata = PhotoMetadata(lensMake: "Leica Camera AG",
                                     lensModel: "Summilux-M 1:1.4/35 ASPH.")
        let importer = Importer(library: library, probe: stubProbe(metadata))
        let photoID = try importer.importFile(at: try temp.writeFile("a.raw",
                                                                    Data("a".utf8))).photoID
        let lensID = try XCTUnwrap(XCTUnwrap(library.photo(id: photoID)).lensId)
        try library.dbPool.write { db in
            _ = try Lens.deleteOne(db, key: lensID)
        }
        let photo = try XCTUnwrap(library.photo(id: photoID))
        XCTAssertNil(photo.lensId)
    }

    func testDeletingACameraLeavesItsPhotos() throws {
        let metadata = PhotoMetadata(cameraMake: "Leica Camera AG", cameraModel: "LEICA M11")
        let importer = Importer(library: library, probe: stubProbe(metadata))
        let photoID = try importer.importFile(at: try temp.writeFile("a.raw",
                                                                    Data("a".utf8))).photoID
        let cameraID = try XCTUnwrap(XCTUnwrap(library.photo(id: photoID)).cameraId)
        try library.dbPool.write { db in
            _ = try Camera.deleteOne(db, key: cameraID)
        }
        let photo = try XCTUnwrap(library.photo(id: photoID))
        XCTAssertNil(photo.cameraId)
    }

    // MARK: - Catalog snapshot

    func testTheSnapshotCarriesDevelopmentOnesFingerprint() throws {
        let plain = try makePhoto("plain.raw")
        let developed = try makePhoto("developed.raw")
        let edit = sampleEdit()
        try library.addDevelopment(photoID: developed, edit: edit)

        let summaries = try library.catalogSnapshot().summaries
        XCTAssertNil(summaries[plain]?.developmentFingerprint,
                     "a photo with no development has nothing to compare a preview against")
        XCTAssertEqual(summaries[developed]?.developmentFingerprint, edit.fingerprint,
                       "hashing the stored edit_json has to agree with hashing the EditState")
    }

    func testTheSnapshotsFingerprintMovesWhenTheDevelopmentDoes() throws {
        let photoID = try makePhoto("a.raw")
        let created = try library.addDevelopment(photoID: photoID, edit: EditState())
        let before = try library.catalogSnapshot().summaries[photoID]?.developmentFingerprint

        var edit = EditState()
        edit.tone.exposure = 2
        try library.updateDevelopment(id: XCTUnwrap(created.id), edit: edit)

        let after = try library.catalogSnapshot().summaries[photoID]?.developmentFingerprint
        XCTAssertNotEqual(after, before)
        XCTAssertEqual(after, edit.fingerprint)
    }

    /// "Development #1" is the photo's lowest ordinal, which is what
    /// `developments(for:)` hands back first — the two have to name the same
    /// development or the grid would compare against an edit nothing renders.
    func testTheSnapshotUsesTheLowestOrdinal() throws {
        let photoID = try makePhoto("a.raw")
        var second = EditState()
        second.clarity = 55
        try library.addDevelopment(photoID: photoID, edit: EditState())
        try library.addDevelopment(photoID: photoID, edit: second)

        let summaries = try library.catalogSnapshot().summaries
        XCTAssertEqual(summaries[photoID]?.developmentCount, 2)
        XCTAssertEqual(summaries[photoID]?.developmentFingerprint, EditState().fingerprint)
        XCTAssertEqual(summaries[photoID]?.developmentFingerprint,
                       try XCTUnwrap(library.developments(for: photoID).first).edit.fingerprint)
    }

    // MARK: - Color label

    func testColorLabelRawValues() {
        XCTAssertEqual(ColorLabel.allCases.map(\.rawValue), [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(ColorLabel.allCases,
                       [.unlabeled, .red, .yellow, .green, .blue, .purple])
    }

    // MARK: - Lenses

    func testLensRoundTripAndFindOrCreate() throws {
        let first = try library.lens(make: "Leica Camera AG", model: "Summilux-M 1:1.4/35 ASPH.")
        let id = try XCTUnwrap(first.id)
        let read = try XCTUnwrap(library.lens(id: id))
        XCTAssertEqual(read, first)
        XCTAssertEqual(read.make, "Leica Camera AG")
        XCTAssertEqual(read.model, "Summilux-M 1:1.4/35 ASPH.")

        // Find-or-create: the same pair is the same row.
        let again = try library.lens(make: "Leica Camera AG", model: "Summilux-M 1:1.4/35 ASPH.")
        XCTAssertEqual(again.id, first.id)
        XCTAssertEqual(try library.allLenses().count, 1)

        // Either field differing makes a different lens.
        let otherModel = try library.lens(make: "Leica Camera AG", model: "R-Adapter M")
        let otherMake = try library.lens(make: "NIKON", model: "R-Adapter M")
        XCTAssertNotEqual(otherModel.id, first.id)
        XCTAssertNotEqual(otherMake.id, otherModel.id)
        // Ordered by make, then model.
        XCTAssertEqual(try library.allLenses().map { "\($0.make)/\($0.model)" },
                       ["Leica Camera AG/R-Adapter M",
                        "Leica Camera AG/Summilux-M 1:1.4/35 ASPH.",
                        "NIKON/R-Adapter M"])
        XCTAssertNil(try library.lens(id: 9_999))
    }

    /// Adapted and manual glass names the model and nothing else, and that is a
    /// lens worth keeping — unlike a camera, which needs both halves.
    func testALensWithNoMakeIsStillALens() throws {
        let lens = try library.lens(model: "Summicron 50")
        XCTAssertEqual(lens.make, "")
        XCTAssertEqual(try library.lens(id: try XCTUnwrap(lens.id))?.make, "")
        // And it is the same row the second time.
        XCTAssertEqual(try library.lens(make: "", model: "Summicron 50").id, lens.id)
        // A blank make is the empty make, not a third lens.
        XCTAssertEqual(try library.lens(make: "   ", model: "Summicron 50").id, lens.id)
        XCTAssertEqual(try library.allLenses().count, 1)
    }

    func testAnEmptyLensModelIsRejected() throws {
        for model in ["", "   ", "\n"] {
            XCTAssertThrowsError(try library.lens(make: "Leica", model: model)) { error in
                guard case LibraryError.emptyLensModel = error else {
                    return XCTFail("wrong error \(error)")
                }
            }
        }
        XCTAssertEqual(try library.allLenses().count, 0)
    }

    /// The surrounding whitespace a camera writes into EXIF is not part of the
    /// lens's identity: " XCD 38V " and "XCD 38V" are one row.
    func testLensFieldsAreTrimmed() throws {
        let padded = try library.lens(make: "  Hasselblad ", model: "  XCD 38V\n")
        XCTAssertEqual(padded.make, "Hasselblad")
        XCTAssertEqual(padded.model, "XCD 38V")
        XCTAssertEqual(try library.lens(make: "Hasselblad", model: "XCD 38V").id, padded.id)
        XCTAssertEqual(try library.allLenses().count, 1)
    }

    func testQueryFiltersByLens() throws {
        let summilux = PhotoMetadata(cameraMake: "Leica Camera AG", cameraModel: "LEICA M11",
                                     lensMake: "Leica Camera AG", lensModel: "Summilux-M")
        let noctilux = PhotoMetadata(cameraMake: "Leica Camera AG", cameraModel: "LEICA M11",
                                     lensMake: "Leica Camera AG", lensModel: "Noctilux-M")
        let a = try Importer(library: library, probe: stubProbe(summilux))
            .importFile(at: try temp.writeFile("a.raw", Data("a".utf8))).photoID
        let b = try Importer(library: library, probe: stubProbe(summilux))
            .importFile(at: try temp.writeFile("b.raw", Data("b".utf8))).photoID
        let c = try Importer(library: library, probe: stubProbe(noctilux))
            .importFile(at: try temp.writeFile("c.raw", Data("c".utf8))).photoID

        let summiluxID = try XCTUnwrap(XCTUnwrap(library.photo(id: a)).lensId)
        let noctiluxID = try XCTUnwrap(XCTUnwrap(library.photo(id: c)).lensId)
        let cameraID = try XCTUnwrap(XCTUnwrap(library.photo(id: a)).cameraId)
        XCTAssertNotEqual(summiluxID, noctiluxID)

        XCTAssertEqual(try library.photos(lensID: summiluxID).map(\.id), [a, b])
        XCTAssertEqual(try library.photos(lensID: noctiluxID).map(\.id), [c])
        // Composes with the other filters, camera included.
        try library.setColor(photoID: b, .green)
        XCTAssertEqual(try library.photos(color: .green, lensID: summiluxID).map(\.id), [b])
        XCTAssertEqual(try library.photos(cameraID: cameraID, lensID: noctiluxID).map(\.id), [c])
        XCTAssertEqual(try library.photos(color: .red, lensID: summiluxID).count, 0)
    }

    func testTheSnapshotCarriesTheLens() throws {
        let metadata = PhotoMetadata(lensMake: "FUJIFILM", lensModel: "GF63mmF2.8 R WR")
        let withLens = try Importer(library: library, probe: stubProbe(metadata))
            .importFile(at: try temp.writeFile("a.raw", Data("a".utf8))).photoID
        let without = try makePhoto("b.raw")
        let lensID = try XCTUnwrap(XCTUnwrap(library.photo(id: withLens)).lensId)

        let snapshot = try library.catalogSnapshot()
        let byID = Dictionary(uniqueKeysWithValues: snapshot.photos.map { ($0.id!, $0) })
        XCTAssertEqual(byID[withLens]?.lensId, lensID)
        XCTAssertNil(byID[without]?.lensId)
    }
}
