import ArgumentParser
import Foundation
import GrayroomLibrary

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List photos in the library.",
        discussion: """
        One line per photo: id, hash prefix, capture date, camera, colour, tags, \
        development count, first location. Filters compose.
        """)

    @OptionGroup var libraryOptions: LibraryOptions

    @Option(name: .customLong("color"), help: "Only photos with this colour label.")
    var color: ColorLabel?

    @Option(name: .customLong("tag"), help: "Only photos carrying this tag.")
    var tag: String?

    @Option(name: .customLong("camera"), help: "Only photos from this camera id.")
    var camera: Int64?

    @Option(name: .customLong("lens"), help: "Only photos taken through this lens id.")
    var lens: Int64?

    func run() throws {
        let library = try libraryOptions.open()
        let photos = try library.photos(color: color, tag: tag, cameraID: camera, lensID: lens)

        var cameras: [Int64: Camera] = [:]
        var out = ""
        for photo in photos {
            guard let id = photo.id else { continue }
            if let cameraID = photo.cameraId, cameras[cameraID] == nil {
                cameras[cameraID] = try library.camera(id: cameraID)
            }
            let tags = try library.tags(for: id).map(\.name).joined(separator: ",")
            let developmentCount = try library.developments(for: id).count
            let location = try library.locations(for: id).first?.path
            out += [
                String(id),
                Format.hashPrefix(photo),
                Format.date(photo.capturedAt),
                Format.camera(photo.cameraId.flatMap { cameras[$0] }),
                photo.color.name,
                Format.orDash(tags),
                String(developmentCount),
                Format.orDash(location),
            ].joined(separator: "  ") + "\n"
        }
        print(out, terminator: "")
        standardError("\(photos.count) photo(s)\n")
    }
}
