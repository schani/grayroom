import ArgumentParser
import Foundation
import GrayroomCore
import GrayroomLibrary

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Render photos from the library into a folder.",
        discussion: """
        Each photo is rendered at full resolution through the development the \
        library shows for it — #1, or the neutral decode when it has none — and \
        written as <original stem>.<ext>. Nothing is overwritten: a name that is \
        taken gets -2, -3, … as in Lightroom.
        """)

    @OptionGroup var libraryOptions: LibraryOptions

    @Argument(help: "Photos, each a photo id, a hash prefix, or a path to the file.")
    var photos: [String]

    @Option(name: .customLong("to"), help: ArgumentHelp("Destination folder.",
                                                        valueName: "dir"))
    var to: String

    @Option(name: .customLong("format"), help: "png | png16 | jpeg | tiff16")
    var format: ExportFormat = .png

    @Option(name: .customLong("quality"), help: "JPEG quality, 0…1.")
    var quality: Double = 0.92

    func validate() throws {
        if photos.isEmpty { throw fail("export needs at least one photo") }
        if quality < 0 || quality > 1 { throw fail("--quality must be between 0 and 1") }
    }

    func run() throws {
        let library = try libraryOptions.open()
        let ids = try photos.map { try resolvePhoto($0, in: library) }
        let directory = URL(fileURLWithPath: to, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let jobs = try BatchExport.jobs(forPhotoIDs: ids, in: library)
        let result = BatchExport.run(jobs, to: directory, format: format, quality: quality,
                                     renderer: try Renderer())

        for url in result.written { print(url.path) }
        for failure in result.failures {
            standardError("failed \(failure.stem): \(failure.message)\n")
        }
        standardError("exported \(result.written.count) of \(jobs.count) "
            + "to \(directory.path)\n")
    }
}
