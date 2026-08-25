import ArgumentParser
import Foundation
import GrayroomLibrary
import XCTest
@testable import GrayroomCLI

/// The command surface itself: that the subcommands exist under the names the
/// docs promise, and that their options parse into the values the run methods
/// expect.
final class CommandParsingTests: XCTestCase {

    private func parse<T: ParsableCommand>(_ type: T.Type, _ args: [String]) throws -> T {
        let command = try Grayroom.parseAsRoot(args)
        return try XCTUnwrap(command as? T, "parsed \(Swift.type(of: command)) instead")
    }

    func testSubcommandNames() {
        let names = Grayroom.configuration.subcommands.map { $0.configuration.commandName ?? "" }
        XCTAssertEqual(Set(names),
                       ["probe", "render", "mask-preview", "import", "ls", "show",
                        "tag", "color", "developments", "previews",
                        "analyze", "similar", "duplicates"])
    }

    func testImportParsing() throws {
        let command = try parse(Import.self, ["import", "a.dng", "shoot/", "--no-recursive"])
        XCTAssertEqual(command.paths, ["a.dng", "shoot/"])
        XCTAssertTrue(command.noRecursive)
        XCTAssertFalse(try parse(Import.self, ["import", "a.dng"]).noRecursive)
    }

    func testImportNeedsAPath() {
        XCTAssertThrowsError(try Grayroom.parseAsRoot(["import"]))
    }

    func testListFilters() throws {
        let command = try parse(List.self,
                                ["ls", "--color", "red", "--tag", "keeper", "--camera", "3"])
        XCTAssertEqual(command.color, .red)
        XCTAssertEqual(command.tag, "keeper")
        XCTAssertEqual(command.camera, 3)

        let bare = try parse(List.self, ["ls"])
        XCTAssertNil(bare.color)
        XCTAssertNil(bare.tag)
        XCTAssertNil(bare.camera)
    }

    func testColorLabelsParseByName() throws {
        for label in ColorLabel.allCases {
            let command = try parse(Color.self, ["color", "7", label.name])
            XCTAssertEqual(command.label, label)
            XCTAssertEqual(command.photo, "7")
        }
        XCTAssertThrowsError(try Grayroom.parseAsRoot(["color", "7", "chartreuse"]))
        XCTAssertThrowsError(try Grayroom.parseAsRoot(["ls", "--color", "chartreuse"]))
    }

    func testTagSubcommands() throws {
        let add = try parse(Tag.Add.self, ["tag", "add", "abc123", "street"])
        XCTAssertEqual(add.photo, "abc123")
        XCTAssertEqual(add.name, "street")

        let remove = try parse(Tag.Remove.self, ["tag", "rm", "12", "street"])
        XCTAssertEqual(remove.photo, "12")
        XCTAssertEqual(remove.name, "street")
    }

    func testDevelopmentsSubcommands() throws {
        let list = try parse(Developments.ListDevelopments.self, ["developments", "ls", "4"])
        XCTAssertEqual(list.photo, "4")

        let add = try parse(Developments.AddDevelopment.self,
                            ["developments", "add", "4", "--edit", "e.json"])
        XCTAssertEqual(add.editPath, "e.json")
        let bareAdd = try parse(Developments.AddDevelopment.self, ["developments", "add", "4"])
        XCTAssertNil(bareAdd.editPath)

        let remove = try parse(Developments.RemoveDevelopment.self, ["developments", "rm", "9"])
        XCTAssertEqual(remove.developmentID, 9)

        let export = try parse(Developments.ExportDevelopment.self,
                               ["developments", "export", "9", "out.json"])
        XCTAssertEqual(export.developmentID, 9)
        XCTAssertEqual(export.output, "out.json")

        let set = try parse(Developments.SetDevelopment.self,
                            ["developments", "set", "9", "tone.exposure=1", "clarity=20"])
        XCTAssertEqual(set.settings, ["tone.exposure=1", "clarity=20"])
    }

    /// `dev` is the alias the command is actually typed with.
    func testDevelopmentsAlias() throws {
        let list = try parse(Developments.ListDevelopments.self, ["dev", "ls", "4"])
        XCTAssertEqual(list.photo, "4")
        let set = try parse(Developments.SetDevelopment.self, ["dev", "set", "9", "clarity=20"])
        XCTAssertEqual(set.developmentID, 9)
    }

    func testPreviewsSubcommands() throws {
        let stats = try parse(Previews.PreviewStats.self,
                              ["previews", "stats", "--library", "/tmp/l.sqlite"])
        XCTAssertEqual(stats.libraryOptions.libraryPath, "/tmp/l.sqlite")
        let clear = try parse(Previews.PreviewClear.self, ["previews", "clear"])
        XCTAssertNil(clear.libraryOptions.libraryPath)
    }

    func testPreviewSizeFormatting() {
        XCTAssertEqual(Previews.describe(0), "0 B")
        XCTAssertEqual(Previews.describe(512), "512 B")
        XCTAssertEqual(Previews.describe(2048), "2.0 KB (2048 B)")
        XCTAssertEqual(Previews.describe(3 * 1024 * 1024), "3.0 MB (3145728 B)")
    }

    func testRenderOptions() throws {
        let command = try parse(Render.self, [
            "render", "in.dng", "-o", "out.png",
            "--development", "2", "--set", "tone.exposure=1", "--save",
            "--library", "/tmp/l.sqlite",
        ])
        XCTAssertEqual(command.input, "in.dng")
        XCTAssertEqual(command.output, "out.png")
        XCTAssertEqual(command.editOptions.developmentOrdinal, 2)
        XCTAssertEqual(command.editOptions.settings, ["tone.exposure=1"])
        XCTAssertTrue(command.save)
        XCTAssertEqual(command.libraryOptions.libraryPath, "/tmp/l.sqlite")

        let bare = try parse(Render.self, ["render", "in.dng", "-o", "out.png"])
        XCTAssertFalse(bare.save)
        XCTAssertNil(bare.editOptions.developmentOrdinal)
        XCTAssertNil(bare.editOptions.editPath)
    }

    func testMaskPreviewTakesTheSameEditOptions() throws {
        let command = try parse(MaskPreview.self,
                                ["mask-preview", "in.dng", "-o", "m.png", "--development", "3"])
        XCTAssertEqual(command.editOptions.developmentOrdinal, 3)
    }

    func testDevelopmentOrdinalMustBeAtLeastOne() {
        XCTAssertThrowsError(try Grayroom.parseAsRoot(
            ["render", "in.dng", "-o", "out.png", "--development", "0"]))
    }

    // MARK: - Library location

    func testLibraryPathPrecedence() throws {
        let previous = ProcessInfo.processInfo.environment["GRAYROOM_LIBRARY"]
        defer {
            if let previous { setenv("GRAYROOM_LIBRARY", previous, 1) }
            else { unsetenv("GRAYROOM_LIBRARY") }
        }

        setenv("GRAYROOM_LIBRARY", "/tmp/from-env.sqlite", 1)

        // --library wins over the environment.
        var options = LibraryOptions()
        options.libraryPath = "/tmp/explicit.sqlite"
        XCTAssertEqual(try options.resolvedURL().path, "/tmp/explicit.sqlite")

        // The environment wins over the default.
        options.libraryPath = nil
        XCTAssertEqual(try options.resolvedURL().path, "/tmp/from-env.sqlite")

        // With neither, the default under Application Support.
        unsetenv("GRAYROOM_LIBRARY")
        XCTAssertEqual(try options.resolvedURL(), try Library.defaultURL())
        XCTAssertEqual(try Library.defaultURL().lastPathComponent, "library.sqlite")
    }
}
