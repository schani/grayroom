import ArgumentParser
import Foundation
import GrayroomLibrary

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Add RAW files to the library.",
        discussion: """
        Files are identified by the SHA-256 of their bytes, so the same file at \
        two paths is one photo with two locations and re-importing costs nothing. \
        Directories are walked for camera RAW files.
        """)

    @OptionGroup var libraryOptions: LibraryOptions

    @Argument(help: "RAW files or directories to import.")
    var paths: [String]

    @Flag(name: .customLong("no-recursive"), help: "Do not descend into subdirectories.")
    var noRecursive = false

    func validate() throws {
        if paths.isEmpty { throw fail("import needs at least one path") }
    }

    func run() throws {
        let library = try libraryOptions.open()
        let importer = Importer(library: library)

        var added = 0, existing = 0, repointed = 0, newPhotos = 0, failed = 0
        var out = ""

        func report(_ result: ImportResult) throws {
            let verb: String
            switch result.location {
            case .added: verb = "added"; added += 1
            case .unchanged: verb = "exists"; existing += 1
            case .repointed: verb = "repointed"; repointed += 1
            }
            if result.isNewPhoto { newPhotos += 1 }
            let photo = try library.photo(id: result.photoID)
            let hash = photo.map { Format.hashPrefix($0) } ?? "-"
            out += "\(verb.padding(toLength: 9, withPad: " ", startingAt: 0))  "
                + "\(hash)  \(result.path)\n"
        }

        for path in paths {
            let url = URL(fileURLWithPath: path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                standardError("skipped (not found): \(path)\n")
                failed += 1
                continue
            }
            if isDirectory.boolValue {
                for result in try importer.importDirectory(at: url, recursive: !noRecursive) {
                    try report(result)
                }
            } else {
                do {
                    try report(try importer.importFile(at: url))
                } catch {
                    standardError("skipped (\(error)): \(path)\n")
                    failed += 1
                }
            }
        }

        print(out, terminator: "")
        var summary = "\(added + existing + repointed) file(s): \(added) added, "
            + "\(existing) exists, \(repointed) repointed; \(newPhotos) new photo(s)"
        if failed > 0 { summary += ", \(failed) skipped" }
        print(summary)
    }
}
