import Foundation
import GrayroomCore
import GrayroomLibrary
import XCTest
@testable import GrayroomCLI

/// The `render` / `mask-preview` edit-source precedence, exercised without a
/// GPU: the resolver only hashes the input file and reads the library, so any
/// bytes will do as a stand-in for a RAW.
final class EditSourceTests: XCTestCase {
    private var temp: TempLibrary!
    private var library: Library { temp.library }
    private var input: URL!

    override func setUpWithError() throws {
        temp = try TempLibrary()
        input = try temp.writeFile("IMG.dng", Data("raw bytes".utf8))
    }

    override func tearDown() {
        temp.tearDown()
        temp = nil
        input = nil
    }

    private func resolve(editPath: String? = nil,
                         developmentOrdinal: Int? = nil,
                         settings: [String] = [],
                         library: Library?) throws -> ResolvedEdit {
        try EditSource.resolve(input: input,
                               editPath: editPath,
                               developmentOrdinal: developmentOrdinal,
                               settings: settings,
                               library: library)
    }

    private func writeEditFile(_ edit: EditState, named name: String = "edit.json") throws -> URL {
        let url = temp.directory.appendingPathComponent(name)
        try edit.save(to: url)
        return url
    }

    // MARK: - Precedence

    func testDefaultsWhenThereIsNoLibrary() throws {
        let resolved = try resolve(library: nil)
        XCTAssertEqual(resolved.edit, EditState())
        XCTAssertEqual(resolved.origin, .defaults)
        XCTAssertNil(resolved.photoID)
    }

    func testDefaultsWhenTheFileIsNotInTheLibrary() throws {
        let resolved = try resolve(library: library)
        XCTAssertEqual(resolved.edit, EditState())
        XCTAssertEqual(resolved.origin, .defaults)
        XCTAssertNil(resolved.photoID)
    }

    func testDefaultsWhenThePhotoHasNoDevelopments() throws {
        let photoID = try temp.importFile(input)
        let resolved = try resolve(library: library)
        XCTAssertEqual(resolved.edit, EditState())
        XCTAssertEqual(resolved.origin, .defaults)
        XCTAssertEqual(resolved.photoID, photoID)
    }

    func testDevelopmentOneIsUsedWhenTheFileIsInTheLibrary() throws {
        let photoID = try temp.importFile(input)
        let stored = try library.addDevelopment(photoID: photoID, edit: distinctiveEdit(exposure: 1.5))

        let resolved = try resolve(library: library)
        XCTAssertEqual(resolved.edit, stored.edit)
        XCTAssertEqual(resolved.origin, .libraryDevelopment(id: try XCTUnwrap(stored.id), ordinal: 1))
        XCTAssertEqual(resolved.photoID, photoID)
    }

    func testEditFileBeatsTheLibraryDevelopment() throws {
        let photoID = try temp.importFile(input)
        try library.addDevelopment(photoID: photoID, edit: distinctiveEdit(exposure: 1.5))
        let fromFile = distinctiveEdit(exposure: -2)
        let url = try writeEditFile(fromFile)

        let resolved = try resolve(editPath: url.path, library: library)
        XCTAssertEqual(resolved.edit, fromFile)
        XCTAssertEqual(resolved.origin, .file(url))
        // The photo is still identified, because --save needs it.
        XCTAssertEqual(resolved.photoID, photoID)
    }

    func testExplicitDevelopmentOrdinal() throws {
        let photoID = try temp.importFile(input)
        try library.addDevelopment(photoID: photoID, edit: distinctiveEdit(exposure: 1))
        let second = try library.addDevelopment(photoID: photoID, edit: distinctiveEdit(exposure: 2))

        let resolved = try resolve(developmentOrdinal: 2, library: library)
        XCTAssertEqual(resolved.edit, second.edit)
        XCTAssertEqual(resolved.origin, .libraryDevelopment(id: try XCTUnwrap(second.id), ordinal: 2))
    }

    /// An explicit `--development` that does not exist is a mistake, not a reason to
    /// quietly render the defaults.
    func testExplicitDevelopmentOrdinalThatDoesNotExistThrows() throws {
        let photoID = try temp.importFile(input)
        try library.addDevelopment(photoID: photoID, edit: distinctiveEdit(exposure: 1))

        XCTAssertThrowsError(try resolve(developmentOrdinal: 7, library: library)) { error in
            guard case EditSourceError.noSuchDevelopment(let ordinal, let id) = error else {
                return XCTFail("wrong error \(error)")
            }
            XCTAssertEqual(ordinal, 7)
            XCTAssertEqual(id, photoID)
        }
    }

    func testMissingEditFileThrows() {
        XCTAssertThrowsError(try resolve(editPath: "/nope/edit.json", library: library)) { error in
            guard case EditSourceError.fileNotFound = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    // MARK: - --set on top

    func testSetOverridesApplyOnTopOfEverySource() throws {
        let photoID = try temp.importFile(input)
        try library.addDevelopment(photoID: photoID, edit: distinctiveEdit(exposure: 1.5))
        let url = try writeEditFile(distinctiveEdit(exposure: -2))

        // On top of the library development: the untouched fields survive.
        let overDevelopment = try resolve(settings: ["tone.exposure=0.25"], library: library)
        XCTAssertEqual(overDevelopment.edit.tone.exposure, 0.25)
        XCTAssertEqual(overDevelopment.edit.clarity, 21)

        // On top of the file.
        let overFile = try resolve(editPath: url.path,
                                   settings: ["tone.exposure=0.25"],
                                   library: library)
        XCTAssertEqual(overFile.edit.tone.exposure, 0.25)
        XCTAssertEqual(overFile.edit.clarity, 21)

        // On top of the defaults.
        let overDefaults = try resolve(settings: ["tone.exposure=0.25"], library: nil)
        XCTAssertEqual(overDefaults.edit.tone.exposure, 0.25)
        XCTAssertEqual(overDefaults.edit.clarity, 0)
    }

    func testABadSettingThrows() {
        XCTAssertThrowsError(try resolve(settings: ["tone.nope=1"], library: library)) { error in
            guard error is EditStateError else { return XCTFail("wrong error \(error)") }
        }
    }

    // MARK: - --save

    func testSaveUpdatesTheDevelopmentTheEditCameFrom() throws {
        let photoID = try temp.importFile(input)
        let original = try library.addDevelopment(photoID: photoID, edit: distinctiveEdit(exposure: 1.5))

        let resolved = try resolve(settings: ["tone.exposure=0.25"], library: library)
        let saved = try EditSource.save(resolved, input: input,
                                        developmentOrdinal: nil, library: library)

        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(try library.developments(for: photoID).count, 1)
        XCTAssertEqual(try XCTUnwrap(library.development(id: try XCTUnwrap(saved.id))).edit.tone.exposure,
                       0.25)
    }

    func testSaveCreatesDevelopmentOneWhenThePhotoHasNone() throws {
        let photoID = try temp.importFile(input)
        let resolved = try resolve(settings: ["tone.exposure=0.25"], library: library)
        let saved = try EditSource.save(resolved, input: input,
                                        developmentOrdinal: nil, library: library)

        XCTAssertEqual(saved.ordinal, 1)
        XCTAssertEqual(saved.photoId, photoID)
        XCTAssertEqual(try library.developments(for: photoID).map(\.ordinal), [1])
    }

    /// An edit that came from a file is written to development #1, not appended.
    func testSaveOfAFileEditOverwritesDevelopmentOne() throws {
        let photoID = try temp.importFile(input)
        let existing = try library.addDevelopment(photoID: photoID, edit: distinctiveEdit(exposure: 1.5))
        let url = try writeEditFile(distinctiveEdit(exposure: -2))

        let resolved = try resolve(editPath: url.path, library: library)
        let saved = try EditSource.save(resolved, input: input,
                                        developmentOrdinal: nil, library: library)

        XCTAssertEqual(saved.id, existing.id)
        XCTAssertEqual(saved.edit.tone.exposure, -2)
        XCTAssertEqual(try library.developments(for: photoID).count, 1)
    }

    func testSaveImportsAFileTheLibraryHasNeverSeen() throws {
        XCTAssertEqual(try library.photos().count, 0)

        let resolved = try resolve(settings: ["tone.exposure=0.25"], library: library)
        XCTAssertNil(resolved.photoID)

        let saved = try EditSource.save(resolved, input: input, developmentOrdinal: nil,
                                        library: library, importer: temp.stubImporter())

        XCTAssertEqual(try library.photos().count, 1)
        XCTAssertEqual(saved.ordinal, 1)
        XCTAssertEqual(saved.edit.tone.exposure, 0.25)
        let photo = try XCTUnwrap(library.photos().first)
        XCTAssertEqual(saved.photoId, photo.id)
    }

    func testSaveHonoursAnExplicitDevelopmentOrdinal() throws {
        let photoID = try temp.importFile(input)
        try library.addDevelopment(photoID: photoID, edit: distinctiveEdit(exposure: 1))

        // --development 2 does not exist yet, so this appends rather than overwrites.
        let resolved = try resolve(editPath: try writeEditFile(distinctiveEdit(exposure: 9)).path,
                                   developmentOrdinal: 2,
                                   library: library)
        let saved = try EditSource.save(resolved, input: input,
                                        developmentOrdinal: 2, library: library)

        XCTAssertEqual(saved.ordinal, 2)
        XCTAssertEqual(try library.developments(for: photoID).map(\.ordinal), [1, 2])
        XCTAssertEqual(try library.developments(for: photoID)[0].edit.tone.exposure, 1)
    }
}
