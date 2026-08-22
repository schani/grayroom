import ArgumentParser
import Foundation
import GrayroomLibrary

struct Tag: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tag",
        abstract: "Add or remove a tag on a photo.",
        subcommands: [Add.self, Remove.self])

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Tag a photo. Tags are case-insensitive and idempotent.")

        @OptionGroup var libraryOptions: LibraryOptions

        @Argument(help: "A photo id, a hash prefix, or a path to the file.")
        var photo: String

        @Argument(help: "The tag name.")
        var name: String

        func run() throws {
            let library = try libraryOptions.open()
            let id = try resolvePhoto(photo, in: library)
            let tag = try library.addTag(photoID: id, name: name)
            print("photo \(id): tagged '\(tag.name)'")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "rm",
            abstract: "Untag a photo. The tag itself stays in the library.")

        @OptionGroup var libraryOptions: LibraryOptions

        @Argument(help: "A photo id, a hash prefix, or a path to the file.")
        var photo: String

        @Argument(help: "The tag name.")
        var name: String

        func run() throws {
            let library = try libraryOptions.open()
            let id = try resolvePhoto(photo, in: library)
            if try library.removeTag(photoID: id, name: name) {
                print("photo \(id): removed '\(name)'")
            } else {
                print("photo \(id): was not tagged '\(name)'")
            }
        }
    }
}

struct Color: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "color",
        abstract: "Set a photo's colour label.")

    @OptionGroup var libraryOptions: LibraryOptions

    @Argument(help: "A photo id, a hash prefix, or a path to the file.")
    var photo: String

    @Argument(help: "One of: \(ColorLabel.allNames.joined(separator: ", ")).")
    var label: ColorLabel

    func run() throws {
        let library = try libraryOptions.open()
        let id = try resolvePhoto(photo, in: library)
        try library.setColor(photoID: id, label)
        print("photo \(id): \(label.name)")
    }
}

/// `PhotoRef` with its errors turned into usage failures.
func resolvePhoto(_ token: String, in library: Library) throws -> Int64 {
    do {
        return try PhotoRef.resolveID(token, in: library)
    } catch let e as PhotoRefError {
        throw fail(e.description)
    }
}
