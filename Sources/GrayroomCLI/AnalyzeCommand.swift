import ArgumentParser
import Foundation
import GrayroomLibrary

struct Analyze: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Score photos and fingerprint them for the similarity commands.",
        discussion: """
        Runs Vision over each photo's embedded preview — never a full RAW \
        decode — and stores its aesthetics score and image feature print. \
        Import does this already; this is for photos that arrived before it \
        did, or whose analysis was cleared. One line per photo as it is done.
        """)

    @OptionGroup var libraryOptions: LibraryOptions

    @Flag(name: .customLong("missing"),
          help: "Only photos with no analysis yet, instead of all of them.")
    var missingOnly = false

    @Argument(help: "Photos to analyse. Defaults to the whole library.")
    var photos: [String] = []

    func run() throws {
        let library = try libraryOptions.open()

        var ids: [Int64]
        if !photos.isEmpty {
            do {
                ids = try photos.map { try PhotoRef.resolveID($0, in: library) }
            } catch let e as PhotoRefError {
                throw fail(e.description)
            }
            if missingOnly {
                let missing = Set(try library.photoIDsMissingAnalysis())
                ids = ids.filter { missing.contains($0) }
            }
        } else {
            ids = missingOnly
                ? try library.photoIDsMissingAnalysis()
                : try library.photos().compactMap(\.id)
        }

        var analysed = 0, skipped = 0
        for (index, id) in ids.enumerated() {
            guard let photo = try library.photo(id: id) else { continue }
            guard let url = try library.locations(for: id).first?.url else {
                standardError("skipped (no file): \(photo.originalName)\n")
                skipped += 1
                continue
            }
            do {
                let analysis = try PhotoAnalyzer.analyze(url: url)
                try library.setAnalysis(photoID: id, analysis)
                analysed += 1
                print("\(index + 1)/\(ids.count)  \(id)  "
                    + "\(Format.score(analysis.aestheticScore))  \(photo.originalName)")
            } catch {
                standardError("skipped (\(error)): \(photo.originalName)\n")
                skipped += 1
            }
        }

        var summary = "analysed \(analysed) photo(s)"
        if skipped > 0 { summary += ", \(skipped) skipped" }
        standardError(summary + "\n")
    }
}
