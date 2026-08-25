import ArgumentParser
import Foundation
import GrayroomLibrary

/// How far apart two photos may be and still count as the same picture.
///
/// Shared by `similar` and `duplicates` so the two commands cannot disagree
/// about it; the default is `PhotoAnalyzer.defaultSimilarityThreshold`.
struct ThresholdOption: ParsableArguments {
    @Option(name: .customLong("threshold"),
            help: ArgumentHelp("Largest feature-print distance that still counts as similar.",
                               discussion: "0 is the same picture; unrelated photographs "
                                   + "measure around 1 and up.",
                               valueName: "d"))
    var threshold: Double = PhotoAnalyzer.defaultSimilarityThreshold

    init() {}

    func validate() throws {
        guard threshold >= 0 else { throw fail("--threshold cannot be negative") }
    }
}

struct Similar: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "similar",
        abstract: "List the photos that look like this one, nearest first.")

    @OptionGroup var libraryOptions: LibraryOptions
    @OptionGroup var thresholdOption: ThresholdOption

    @Argument(help: "A photo id, a hash prefix, or a path to the file.")
    var photo: String

    @Option(name: .customLong("limit"), help: "At most this many photos.")
    var limit: Int?

    func validate() throws {
        if let limit, limit < 1 { throw fail("--limit must be at least 1") }
    }

    func run() throws {
        let library = try libraryOptions.open()
        let id: Int64
        do {
            id = try PhotoRef.resolveID(photo, in: library)
        } catch let e as PhotoRefError {
            throw fail(e.description)
        }
        guard try library.analysis(photoID: id) != nil else {
            throw fail("photo \(id) has no feature print (run `grayroom analyze` first)")
        }

        let matches = try library.similarPhotos(to: id,
                                                threshold: thresholdOption.threshold,
                                                limit: limit)
        var out = ""
        for match in matches {
            guard let photo = try library.photo(id: match.id) else { continue }
            out += [
                String(format: "%.4f", match.distance),
                String(match.id),
                Format.hashPrefix(photo),
                photo.originalName,
                Format.orDash(try library.locations(for: match.id).first?.path),
            ].joined(separator: "  ") + "\n"
        }
        print(out, terminator: "")
        standardError("\(matches.count) photo(s) within \(thresholdOption.threshold)\n")
    }
}

struct Duplicates: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "duplicates",
        abstract: "List groups of near-identical photos.",
        discussion: """
        Photos are grouped by single linkage: two frames are in one group when \
        a chain of pairs closer than the threshold joins them, which is what a \
        burst looks like. A photo with no feature print is not considered — run \
        `grayroom analyze --missing` first.
        """)

    @OptionGroup var libraryOptions: LibraryOptions
    @OptionGroup var thresholdOption: ThresholdOption

    func run() throws {
        let library = try libraryOptions.open()
        let groups = try library.duplicateGroups(threshold: thresholdOption.threshold)

        var out = ""
        for (index, group) in groups.enumerated() {
            out += "group \(index + 1) (\(group.count) photos)\n"
            for id in group {
                guard let photo = try library.photo(id: id) else { continue }
                out += "  " + [
                    String(id),
                    Format.hashPrefix(photo),
                    photo.originalName,
                    Format.orDash(try library.locations(for: id).first?.path),
                ].joined(separator: "  ") + "\n"
            }
        }
        print(out, terminator: "")
        let photos = groups.reduce(0) { $0 + $1.count }
        standardError("\(groups.count) group(s), \(photos) photo(s) "
            + "within \(thresholdOption.threshold)\n")
    }
}
