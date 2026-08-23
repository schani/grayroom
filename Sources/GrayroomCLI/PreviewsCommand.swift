import ArgumentParser
import Foundation
import GrayroomLibrary

/// The grid's preview store, from the terminal.
///
/// Two subcommands, both for looking at (or getting rid of) derived data: the
/// previews are rebuilt on demand by the app, so `clear` costs nothing but the
/// time to build them again.
struct Previews: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "previews",
        abstract: "Inspect or clear the library's preview store (previews.sqlite).",
        subcommands: [PreviewStats.self, PreviewClear.self])

    struct PreviewStats: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stats",
            abstract: "How many previews are stored, and how much they weigh.")

        @OptionGroup var libraryOptions: LibraryOptions

        func run() throws {
            let library = try libraryOptions.open()
            let store = try PreviewStore.open(for: library)
            let count = try store.count
            let bytes = try store.totalBytes
            print("\(store.url.path)")
            print("\(count) preview(s), \(Previews.describe(bytes))")
        }
    }

    struct PreviewClear: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear",
            abstract: "Delete every stored preview. They are rebuilt on demand.")

        @OptionGroup var libraryOptions: LibraryOptions

        func run() throws {
            let library = try libraryOptions.open()
            let store = try PreviewStore.open(for: library)
            let count = try store.count
            try store.deleteAll()
            print("deleted \(count) preview(s) from \(store.url.path)")
        }
    }

    static func describe(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0
            ? "\(bytes) B"
            : String(format: "%.1f %@ (%lld B)", value, units[index], bytes)
    }
}
