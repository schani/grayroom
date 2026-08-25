import Foundation
import GrayroomCore
import GrayroomLibrary
import XCTest
@testable import GrayroomCLI

/// The catalogue-reading and catalogue-writing commands — `ls`, `show`, `tag`,
/// `color`, `developments`, `previews` — run end to end.
///
/// None of them touches a decoder, so the photos here are stub-imported bytes.
final class CatalogCommandTests: XCTestCase {
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
    private func stubPhoto(_ name: String, bytes: String? = nil) throws -> Int64 {
        let url = try temp.writeFile(name, Data((bytes ?? name).utf8))
        return try temp.importFile(url)
    }

    // MARK: - ls

    func testListPrintsOneLinePerPhotoWithItsFields() throws {
        let id = try stubPhoto("a.dng")
        try library.setColor(photoID: id, .green)
        try library.addTag(photoID: id, name: "street")
        try library.addTag(photoID: id, name: "keeper")
        try library.addDevelopment(photoID: id, edit: EditState())

        let output = try temp.run(["ls"])

        XCTAssertEqual(output.lines.count, 1)
        let fields = output.lines[0].components(separatedBy: "  ")
        XCTAssertEqual(fields[0], String(id))
        let photo = try XCTUnwrap(library.photo(id: id))
        XCTAssertEqual(fields[1], String(photo.hashHexString.prefix(12)))
        XCTAssertEqual(fields[2], "-", "no capture date")
        XCTAssertEqual(fields[3], "-", "no camera")
        XCTAssertEqual(fields[4], "green")
        XCTAssertEqual(fields[5], "keeper,street")
        XCTAssertEqual(fields[6], "1", "development count")
        XCTAssertTrue(fields[7].hasSuffix("a.dng"), fields[7])
        XCTAssertTrue(output.stderr.contains("1 photo(s)"), output.stderr)
    }

    func testListIsOrderedByCaptureDateThenID() throws {
        let undated = try stubPhoto("undated.dng")
        let late = try stubPhoto("late.dng")
        let early = try stubPhoto("early.dng")
        try library.dbPool.write { db in
            try db.execute(sql: "UPDATE photos SET captured_at = ? WHERE id = ?",
                           arguments: [Date(timeIntervalSince1970: 2_000), late])
            try db.execute(sql: "UPDATE photos SET captured_at = ? WHERE id = ?",
                           arguments: [Date(timeIntervalSince1970: 1_000), early])
        }

        let ids = try temp.run(["ls"]).lines.map { $0.components(separatedBy: "  ")[0] }
        XCTAssertEqual(ids, [String(undated), String(early), String(late)])
    }

    func testListFiltersComposeAndAreANDed() throws {
        let redKeeper = try stubPhoto("1.dng")
        let redOther = try stubPhoto("2.dng")
        let blueKeeper = try stubPhoto("3.dng")
        try library.setColor(photoID: redKeeper, .red)
        try library.setColor(photoID: redOther, .red)
        try library.setColor(photoID: blueKeeper, .blue)
        try library.addTag(photoID: redKeeper, name: "keeper")
        try library.addTag(photoID: blueKeeper, name: "keeper")

        func ids(_ args: [String]) throws -> [String] {
            try temp.run(args).lines.map { $0.components(separatedBy: "  ")[0] }
        }

        XCTAssertEqual(try ids(["ls"]).count, 3)
        XCTAssertEqual(try ids(["ls", "--color", "red"]).sorted(),
                       [redKeeper, redOther].map(String.init).sorted())
        XCTAssertEqual(try ids(["ls", "--tag", "keeper"]).sorted(),
                       [redKeeper, blueKeeper].map(String.init).sorted())
        XCTAssertEqual(try ids(["ls", "--color", "red", "--tag", "keeper"]),
                       [String(redKeeper)])
        XCTAssertEqual(try ids(["ls", "--color", "purple"]), [])
    }

    func testListFiltersByCamera() throws {
        let leica = try library.camera(make: "Leica", model: "M11")
        let other = try library.camera(make: "Nikon", model: "Z8")
        let a = try stubPhoto("a.dng")
        try library.dbPool.write { db in
            try db.execute(sql: "UPDATE photos SET camera_id = ? WHERE id = ?",
                           arguments: [leica.id, a])
        }
        try stubPhoto("b.dng")

        let matched = try temp.run(["ls", "--camera", String(try XCTUnwrap(leica.id))])
        XCTAssertEqual(matched.lines.count, 1)
        XCTAssertTrue(matched.lines[0].contains("Leica M11"), matched.lines[0])

        let none = try temp.run(["ls", "--camera", String(try XCTUnwrap(other.id))])
        XCTAssertEqual(none.lines.count, 0)
        XCTAssertTrue(none.stderr.contains("0 photo(s)"), none.stderr)
    }

    func testListFiltersByLens() throws {
        let summilux = try library.lens(make: "Leica Camera AG", model: "Summilux-M")
        let adapted = try library.lens(model: "R-Adapter M")
        let a = try stubPhoto("a.dng")
        try stubPhoto("b.dng")
        try library.dbPool.write { db in
            try db.execute(sql: "UPDATE photos SET lens_id = ? WHERE id = ?",
                           arguments: [summilux.id, a])
        }

        let matched = try temp.run(["ls", "--lens", String(try XCTUnwrap(summilux.id))])
        XCTAssertEqual(matched.lines.count, 1)
        XCTAssertTrue(matched.lines[0].hasPrefix(String(a)), matched.lines[0])

        let none = try temp.run(["ls", "--lens", String(try XCTUnwrap(adapted.id))])
        XCTAssertEqual(none.lines.count, 0)
        XCTAssertTrue(none.stderr.contains("0 photo(s)"), none.stderr)
    }

    /// `--camera` and `--lens` are separate dimensions and compose.
    func testListFiltersByCameraAndLensTogether() throws {
        let camera = try library.camera(make: "Leica Camera AG", model: "LEICA M11")
        let lens = try library.lens(make: "Leica Camera AG", model: "Summilux-M")
        let both = try stubPhoto("both.dng")
        let cameraOnly = try stubPhoto("camera-only.dng")
        try library.dbPool.write { db in
            try db.execute(sql: "UPDATE photos SET camera_id = ?, lens_id = ? WHERE id = ?",
                           arguments: [camera.id, lens.id, both])
            try db.execute(sql: "UPDATE photos SET camera_id = ? WHERE id = ?",
                           arguments: [camera.id, cameraOnly])
        }

        let byCamera = try temp.run(["ls", "--camera", String(try XCTUnwrap(camera.id))])
        XCTAssertEqual(byCamera.lines.count, 2)
        let byBoth = try temp.run(["ls",
                                   "--camera", String(try XCTUnwrap(camera.id)),
                                   "--lens", String(try XCTUnwrap(lens.id))])
        XCTAssertEqual(byBoth.lines.count, 1)
        XCTAssertTrue(byBoth.lines[0].hasPrefix(String(both)), byBoth.lines[0])
    }

    func testAnEmptyLibraryListsNothing() throws {
        let output = try temp.run(["ls"])
        XCTAssertEqual(output.stdout, "")
        XCTAssertTrue(output.stderr.contains("0 photo(s)"), output.stderr)
    }

    func testAnUnknownColourNameIsRejectedAtParseTime() {
        XCTAssertThrowsError(try Grayroom.parseAsRoot(["ls", "--color", "chartreuse"]))
    }

    // MARK: - show

    func testShowPrintsEverythingTheLibraryKnows() throws {
        let id = try stubPhoto("a.dng")
        let camera = try library.camera(make: "Leica", model: "M11")
        try library.dbPool.write { db in
            try db.execute(sql: """
                UPDATE photos SET camera_id = ?, width = 40, height = 30, \
                latitude = -33.5, longitude = -70.25, altitude = 512.0 WHERE id = ?
                """, arguments: [camera.id, id])
        }
        try library.setColor(photoID: id, .yellow)
        try library.addTag(photoID: id, name: "street")
        try library.addDevelopment(photoID: id, edit: EditState())

        let out = try temp.run(["show", String(id)]).stdout
        let photo = try XCTUnwrap(library.photo(id: id))

        XCTAssertTrue(out.contains("id:            \(id)"), out)
        XCTAssertTrue(out.contains("hash:          \(photo.hashHexString)"), out)
        XCTAssertTrue(out.contains("name:          a.dng"), out)
        XCTAssertTrue(out.contains("bytes:         \(photo.byteSize)"), out)
        XCTAssertTrue(out.contains("camera:        Leica M11"), out)
        XCTAssertTrue(out.contains("size:          40 x 30"), out)
        XCTAssertTrue(out.contains("gps:           -33.500000, -70.250000 (512.0 m)"), out)
        XCTAssertTrue(out.contains("color:         yellow"), out)
        XCTAssertTrue(out.contains("tags:          street"), out)
        XCTAssertTrue(out.contains("#1"), out)
    }

    /// The absent values print as dashes rather than as `nil` or an empty gap.
    func testShowPrintsDashesForWhatIsMissing() throws {
        let id = try stubPhoto("a.dng")
        let out = try temp.run(["show", String(id)]).stdout
        XCTAssertTrue(out.contains("captured:      -"), out)
        XCTAssertTrue(out.contains("camera:        -"), out)
        XCTAssertTrue(out.contains("lens:          -"), out)
        XCTAssertTrue(out.contains("size:          -"), out)
        XCTAssertTrue(out.contains("gps:           -"), out)
        XCTAssertTrue(out.contains("tags:          -"), out)
        XCTAssertTrue(out.contains("developments:  -"), out)
        XCTAssertFalse(out.contains("locations:     -"), "it does have a location")
    }

    func testShowPrintsTheLensWithItsID() throws {
        let id = try stubPhoto("a.dng")
        let lens = try library.lens(make: "Leica Camera AG", model: "Summilux-M 1:1.4/35 ASPH.")
        try library.dbPool.write { db in
            try db.execute(sql: "UPDATE photos SET lens_id = ? WHERE id = ?",
                           arguments: [lens.id, id])
        }
        let out = try temp.run(["show", String(id)]).stdout
        XCTAssertTrue(
            out.contains("lens:          Leica Camera AG Summilux-M 1:1.4/35 ASPH. "
                         + "(id \(try XCTUnwrap(lens.id)))"), out)
    }

    /// A lens with no make prints as its model alone, with no leading gap.
    func testShowPrintsALensWithNoMake() throws {
        let id = try stubPhoto("a.dng")
        let lens = try library.lens(model: "R-Adapter M")
        try library.dbPool.write { db in
            try db.execute(sql: "UPDATE photos SET lens_id = ? WHERE id = ?",
                           arguments: [lens.id, id])
        }
        let out = try temp.run(["show", String(id)]).stdout
        XCTAssertTrue(out.contains("lens:          R-Adapter M (id"), out)
    }

    func testShowResolvesAHashPrefixAndAFilePath() throws {
        let url = try temp.writeFile("a.dng", Data("a".utf8))
        let id = try temp.importFile(url)
        let photo = try XCTUnwrap(library.photo(id: id))

        for token in [String(id), String(photo.hashHexString.prefix(8)), url.path] {
            let out = try temp.run(["show", token]).stdout
            XCTAssertTrue(out.contains("hash:          \(photo.hashHexString)"),
                          "token \(token): \(out)")
        }
    }

    func testShowOfAnAmbiguousHashPrefixNamesTheMatches() throws {
        let tail = String(repeating: "0", count: 59)
        try temp.insertPhoto(hashHex: "abcd1" + tail)
        try temp.insertPhoto(hashHex: "abcd2" + tail)

        temp.assertFails(["show", "abcd"],
                           contains: "matches 2 photos")
        // One digit more and it resolves.
        XCTAssertNoThrow(try temp.run(["show", "abcd1"]))
    }

    func testShowOfAnUnknownPhotoFails() throws {
        try stubPhoto("a.dng")
        temp.assertFails(["show", "ff00ff"],
                           contains: "no photo matches 'ff00ff'")
    }

    func testShowOfAFileThatIsNotInTheLibraryFails() throws {
        let stranger = try temp.writeFile("stranger.dng", Data("stranger".utf8))
        temp.assertFails(["show", stranger.path],
                           contains: "is not in the library")
    }

    // MARK: - tag / color

    func testTagAddAndRemove() throws {
        let id = try stubPhoto("a.dng")

        let added = try temp.run(["tag", "add", String(id), "  Street  "])
        XCTAssertEqual(try library.tags(for: id).map(\.name), ["Street"],
                       "the name is trimmed, and the first spelling is kept")
        XCTAssertTrue(added.stdout.contains("photo \(id): tagged 'Street'"), added.stdout)

        // Case-insensitive and idempotent: the second add reuses the tag row.
        try temp.run(["tag", "add", String(id), "street"])
        XCTAssertEqual(try library.tags(for: id).count, 1)
        XCTAssertEqual(try library.allTags().count, 1)

        let removed = try temp.run(["tag", "rm", String(id), "STREET"])
        XCTAssertTrue(try library.tags(for: id).isEmpty)
        XCTAssertTrue(removed.stdout.contains("removed 'STREET'"), removed.stdout)
        // The tag row itself survives.
        XCTAssertEqual(try library.allTags().map(\.name), ["Street"])
    }

    func testRemovingATagThePhotoDoesNotCarrySaysSo() throws {
        let id = try stubPhoto("a.dng")
        let output = try temp.run(["tag", "rm", String(id), "nope"])
        XCTAssertTrue(output.stdout.contains("was not tagged 'nope'"), output.stdout)
    }

    func testTaggingAnUnknownPhotoFails() throws {
        temp.assertFails(["tag", "add", "999", "street"],
                           contains: "no photo matches '999'")
    }

    func testColorSetsTheLabelAndEveryNameParses() throws {
        let id = try stubPhoto("a.dng")
        for label in ColorLabel.allCases {
            let output = try temp.run(["color", String(id), label.name])
            XCTAssertEqual(try library.photo(id: id)?.color, label)
            XCTAssertTrue(output.stdout.contains("photo \(id): \(label.name)"), output.stdout)
        }
    }

    func testAnUnknownColourNameIsRejected() {
        XCTAssertThrowsError(try Grayroom.parseAsRoot(["color", "1", "chartreuse"]))
    }

    // MARK: - developments

    func testDevelopmentsAddListExportAndRemove() throws {
        let id = try stubPhoto("a.dng")

        let added = try temp.run(["developments", "add", String(id)])
        XCTAssertTrue(added.stdout.contains("development #1"), added.stdout)
        let first = try XCTUnwrap(library.developments(for: id).first)
        XCTAssertEqual(first.edit, EditState())

        // A seeded second development, and the ordinals stay dense and 1-based.
        let editFile = temp.directory.appendingPathComponent("seed.json")
        try distinctiveEdit(exposure: 1.75).save(to: editFile)
        let seeded = try temp.run(["dev", "add", String(id), "--edit", editFile.path])
        XCTAssertTrue(seeded.stdout.contains("development #2"), seeded.stdout)
        XCTAssertEqual(try library.developments(for: id).map(\.ordinal), [1, 2])
        XCTAssertEqual(try library.developments(for: id)[1].edit.tone.exposure, 1.75)

        let listed = try temp.run(["developments", "ls", String(id)])
        XCTAssertEqual(listed.lines.count, 2)
        XCTAssertTrue(listed.lines[0].contains("#1"), listed.lines[0])
        XCTAssertTrue(listed.lines[1].contains("#2"), listed.lines[1])
        XCTAssertTrue(listed.stderr.contains("2 development(s)"), listed.stderr)

        // Export writes the same edit back out, through directories it creates.
        let secondID = try XCTUnwrap(library.developments(for: id)[1].id)
        let exported = temp.directory.appendingPathComponent("out/deep/edit.json")
        try temp.run(["developments", "export", String(secondID), exported.path])
        XCTAssertEqual(try EditState.load(from: exported).tone.exposure, 1.75)

        let removed = try temp.run(["developments", "rm", String(secondID)])
        XCTAssertTrue(removed.stdout.contains("deleted development \(secondID)"), removed.stdout)
        XCTAssertEqual(try library.developments(for: id).map(\.ordinal), [1])
    }

    func testDevelopmentsSetAppliesOverridesAndKeepsTheRest() throws {
        let id = try stubPhoto("a.dng")
        let stored = try library.addDevelopment(photoID: id, edit: distinctiveEdit(exposure: 1.5))
        let developmentID = try XCTUnwrap(stored.id)

        let output = try temp.run(["dev", "set", String(developmentID),
                                   "tone.exposure=-0.5", "bwMix.enabled=false"])

        let updated = try XCTUnwrap(library.development(id: developmentID)).edit
        XCTAssertEqual(updated.tone.exposure, -0.5)
        XCTAssertFalse(updated.bwMix.enabled)
        XCTAssertEqual(updated.clarity, 21, "untouched fields survive")
        XCTAssertTrue(output.stdout.contains("updated development \(developmentID)"), output.stdout)
    }

    func testDevelopmentsSetRejectsAnUnknownKey() throws {
        let id = try stubPhoto("a.dng")
        let stored = try library.addDevelopment(photoID: id, edit: EditState())
        let developmentID = try XCTUnwrap(stored.id)

        temp.assertFails(["dev", "set", String(developmentID), "tone.nope=1"],
                           contains: "unknown edit key 'tone.nope'")
        XCTAssertEqual(try XCTUnwrap(library.development(id: developmentID)).edit, EditState(),
                       "a rejected --set must leave the stored edit alone")
    }

    func testDevelopmentsSetNeedsAtLeastOneOverride() {
        XCTAssertThrowsError(try Grayroom.parseAsRoot(["dev", "set", "1"]))
    }

    func testDevelopmentCommandsOnAMissingDevelopmentFail() throws {
        let out = temp.directory.appendingPathComponent("nope.json").path
        temp.assertFails(["developments", "rm", "404"],
                           contains: "no development with id 404")
        temp.assertFails(["developments", "export", "404", out],
                           contains: "no development with id 404")
        temp.assertFails(["dev", "set", "404", "clarity=10"],
                           contains: "no development with id 404")
    }

    func testDevelopmentsAddWithAMissingOrUnreadableEditFileFails() throws {
        let id = try stubPhoto("a.dng")
        temp.assertFails(["developments", "add", String(id), "--edit", "/nope/edit.json"],
                           contains: "edit file not found")

        let garbage = try temp.writeFile("bad.json", Data("{ not json".utf8))
        temp.assertFails(["developments", "add", String(id), "--edit", garbage.path],
                           contains: "could not read")
        XCTAssertTrue(try library.developments(for: id).isEmpty)
    }

    func testDevelopmentsListOfAPhotoWithNoneIsEmpty() throws {
        let id = try stubPhoto("a.dng")
        let output = try temp.run(["developments", "ls", String(id)])
        XCTAssertEqual(output.stdout, "")
        XCTAssertTrue(output.stderr.contains("0 development(s)"), output.stderr)
    }

    // MARK: - previews

    func testPreviewsStatsAndClear() throws {
        let id = try stubPhoto("a.dng")
        let hash = try XCTUnwrap(try library.photo(id: id)).hash
        let store = try PreviewStore.open(for: library)
        let jpeg = Data(repeating: 0xAB, count: 2048)
        try store.store(hash: hash, source: .embedded, fingerprint: nil,
                        width: 512, height: 341, jpeg: jpeg)
        try store.close()

        let stats = try temp.run(["previews", "stats"])
        XCTAssertTrue(stats.stdout.contains(library.previewsURL.path), stats.stdout)
        XCTAssertTrue(stats.stdout.contains("1 preview(s), 2.0 KB (2048 B)"), stats.stdout)

        let cleared = try temp.run(["previews", "clear"])
        XCTAssertTrue(cleared.stdout.contains("deleted 1 preview(s)"), cleared.stdout)

        let after = try temp.run(["previews", "stats"])
        XCTAssertTrue(after.stdout.contains("0 preview(s), 0 B"), after.stdout)
    }

    /// The store is created beside the library on first use, so `stats` works
    /// before anything has ever been previewed.
    func testPreviewsStatsOnALibraryWithNoStoreYet() throws {
        let output = try temp.run(["previews", "stats"])
        XCTAssertTrue(output.stdout.contains("0 preview(s)"), output.stdout)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.previewsURL.path))
    }
}
