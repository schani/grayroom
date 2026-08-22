import ArgumentParser
import Foundation
import GrayroomLibrary

struct Show: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Print everything the library knows about one photo.")

    @OptionGroup var libraryOptions: LibraryOptions

    @Argument(help: "A photo id, a hash prefix, or a path to the file.")
    var photo: String

    func run() throws {
        let library = try libraryOptions.open()
        let record: Photo
        do {
            record = try PhotoRef.resolve(photo, in: library)
        } catch let e as PhotoRefError {
            throw fail(e.description)
        }
        guard let id = record.id else { throw fail("photo has no id") }

        var out = ""
        out += "id:            \(id)\n"
        out += "hash:          \(record.hashHexString)\n"
        out += "name:          \(record.originalName)\n"
        out += "bytes:         \(record.byteSize)\n"
        out += "captured:      \(Format.date(record.capturedAt))\n"
        out += "imported:      \(Format.date(record.importedAt))\n"
        if let camera = try record.cameraId.flatMap({ try library.camera(id: $0) }) {
            out += "camera:        \(Format.camera(camera)) (id \(camera.id.map(String.init) ?? "-"))\n"
        } else {
            out += "camera:        -\n"
        }
        if let w = record.width, let h = record.height {
            out += "size:          \(w) x \(h)\n"
        } else {
            out += "size:          -\n"
        }
        if let lat = record.latitude, let lon = record.longitude {
            out += String(format: "gps:           %.6f, %.6f", lat, lon)
            if let alt = record.altitude { out += String(format: " (%.1f m)", alt) }
            out += "\n"
        } else {
            out += "gps:           -\n"
        }
        out += "color:         \(record.color.name)\n"

        let tags = try library.tags(for: id).map(\.name)
        out += "tags:          \(Format.orDash(tags.joined(separator: ", ")))\n"

        let locations = try library.locations(for: id)
        out += locations.isEmpty ? "locations:     -\n" : "locations:\n"
        for location in locations {
            out += "  \(location.id.map(String.init) ?? "-")  \(location.path)\n"
        }

        let developments = try library.developments(for: id)
        out += developments.isEmpty ? "developments:  -\n" : "developments:\n"
        for entry in developments {
            out += "  id \(entry.id.map(String.init) ?? "-")  #\(entry.ordinal)  "
                + "updated \(Format.date(entry.updatedAt))\n"
        }
        print(out, terminator: "")
    }
}
