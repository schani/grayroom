import ArgumentParser
import Foundation
import GrayroomCore
import GrayroomLibrary

struct Developments: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "developments",
        abstract: "Work with a photo's developments (one development = one EditState).",
        subcommands: [ListDevelopments.self, AddDevelopment.self, RemoveDevelopment.self,
                      ExportDevelopment.self, SetDevelopment.self],
        aliases: ["dev"])

    struct ListDevelopments: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ls",
            abstract: "List a photo's developments.")

        @OptionGroup var libraryOptions: LibraryOptions

        @Argument(help: "A photo id, a hash prefix, or a path to the file.")
        var photo: String

        func run() throws {
            let library = try libraryOptions.open()
            let photoID = try resolvePhoto(photo, in: library)
            let developments = try library.developments(for: photoID)
            var out = ""
            for entry in developments {
                out += [
                    entry.id.map(String.init) ?? "-",
                    "#\(entry.ordinal)",
                    Format.date(entry.createdAt),
                    Format.date(entry.updatedAt),
                ].joined(separator: "  ") + "\n"
            }
            print(out, terminator: "")
            standardError("\(developments.count) development(s)\n")
        }
    }

    struct AddDevelopment: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Append a development to a photo.")

        @OptionGroup var libraryOptions: LibraryOptions

        @Argument(help: "A photo id, a hash prefix, or a path to the file.")
        var photo: String

        @Option(name: .customLong("edit"), help: "JSON file to seed the development with.")
        var editPath: String?

        func run() throws {
            let library = try libraryOptions.open()
            let photoID = try resolvePhoto(photo, in: library)
            var edit = EditState()
            if let editPath {
                let url = URL(fileURLWithPath: editPath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw fail("edit file not found: \(url.path)")
                }
                do {
                    edit = try EditState.load(from: url)
                } catch {
                    throw fail("could not read \(url.path): \(error)")
                }
            }
            let created = try library.addDevelopment(photoID: photoID, edit: edit)
            print("photo \(photoID): development #\(created.ordinal) "
                + "(id \(created.id.map(String.init) ?? "-"))")
        }
    }

    struct RemoveDevelopment: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Delete a development.")

        @OptionGroup var libraryOptions: LibraryOptions

        @Argument(help: "The development id (from `developments ls`).")
        var developmentID: Int64

        func run() throws {
            let library = try libraryOptions.open()
            guard try library.deleteDevelopment(id: developmentID) else {
                throw fail("no development with id \(developmentID)")
            }
            print("deleted development \(developmentID)")
        }
    }

    struct ExportDevelopment: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Write a development's EditState to a JSON file.")

        @OptionGroup var libraryOptions: LibraryOptions

        @Argument(help: "The development id (from `developments ls`).")
        var developmentID: Int64

        @Argument(help: "Output JSON path.")
        var output: String

        func run() throws {
            let library = try libraryOptions.open()
            guard let entry = try library.development(id: developmentID) else {
                throw fail("no development with id \(developmentID)")
            }
            let url = URL(fileURLWithPath: output)
            let parent = url.deletingLastPathComponent()
            if !parent.path.isEmpty, !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try entry.edit.save(to: url)
            print("wrote \(url.path)")
        }
    }

    struct SetDevelopment: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Apply key=value overrides to a development's EditState.",
            discussion: """
            The same dotted key paths `render --set` takes, e.g. \
            tone.exposure=1.0 or masks[0].adjustments.clarity=-30.
            """)

        @OptionGroup var libraryOptions: LibraryOptions

        @Argument(help: "The development id (from `developments ls`).")
        var developmentID: Int64

        @Argument(help: ArgumentHelp("One or more key=value overrides.",
                                    valueName: "key=value"))
        var settings: [String]

        func validate() throws {
            if settings.isEmpty { throw fail("developments set needs at least one key=value") }
        }

        func run() throws {
            let library = try libraryOptions.open()
            guard let entry = try library.development(id: developmentID) else {
                throw fail("no development with id \(developmentID)")
            }
            let updated: EditState
            do {
                updated = try entry.edit.applying(settings: settings)
            } catch let e as EditStateError {
                throw fail(e.description)
            }
            _ = try library.updateDevelopment(id: developmentID, edit: updated)
            print("updated development \(developmentID)")
        }
    }
}
