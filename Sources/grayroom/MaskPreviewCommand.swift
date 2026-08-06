import ArgumentParser
import Foundation
import GrayroomCore

/// The headless way to look at what a sidecar's strokes actually paint.
struct MaskPreview: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mask-preview",
        abstract: "Render a sidecar's mask coverage as a grayscale PNG.",
        discussion: """
        Rasterises the mask strokes at the same resolution the render would use \
        and writes the coverage straight out: 0 = untouched, 255 = full coverage \
        (linear, no transfer function). With no --mask the union of every \
        enabled mask is shown.
        """)

    @Argument(help: "Path to the RAW file (its decoded size sets the preview resolution).")
    var input: String

    @Option(name: [.short, .customLong("output")], help: "Output PNG path.")
    var output: String

    @Option(name: .customLong("edit"), help: "Sidecar JSON holding the masks.")
    var editPath: String?

    @Option(name: .customLong("set"),
            help: ArgumentHelp("Override an edit value, e.g. masks[0].enabled=false.",
                               valueName: "key=value"))
    var settings: [String] = []

    @Option(name: .customLong("mask"), help: "Preview only this mask (0-based index).")
    var mask: Int?

    @Option(name: .customLong("max-dimension"), help: "Cap the longer output edge at N pixels.")
    var maxDimension: Int?

    func validate() throws {
        if let m = maxDimension, m < 16 { throw fail("--max-dimension must be at least 16") }
        if let i = mask, i < 0 { throw fail("--mask must be >= 0") }
    }

    func run() throws {
        let inputURL = URL(fileURLWithPath: input)
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw fail("input file not found: \(inputURL.path)")
        }
        let outputURL = URL(fileURLWithPath: output)
        let parent = outputURL.deletingLastPathComponent()
        if !parent.path.isEmpty, !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        var edit: EditState
        if let editPath {
            let url = URL(fileURLWithPath: editPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw fail("sidecar not found: \(url.path)")
            }
            do {
                edit = try EditState.load(from: url)
            } catch {
                throw fail("could not read sidecar \(url.path): \(error)")
            }
        } else {
            edit = EditState()
        }
        do {
            edit = try edit.applying(settings: settings)
        } catch let e as EditStateError {
            throw fail(e.description)
        }

        if let i = mask, i >= edit.masks.count {
            throw fail("--mask \(i) but the edit has \(edit.masks.count) mask(s)")
        }

        let renderer = try Renderer()
        let decoded = try renderer.decoder.decode(url: inputURL, edit: edit,
                                                  maxDimension: maxDimension)
        let w = decoded.width, h = decoded.height
        let coverage = try renderer.pipeline.maskCoverage(masks: edit.masks,
                                                          width: w, height: h,
                                                          maskIndex: mask)
        try ImageWriter.writeGray(coverage, width: w, height: h, to: outputURL)

        let covered = coverage.reduce(0.0) { $0 + Double($1) } / Double(max(w * h, 1))
        standardError("wrote \(outputURL.path) (\(w)x\(h), grayscale)\n")
        standardError(String(format: "masks: %d (%d enabled), mean coverage %.4f\n",
                             edit.masks.count,
                             edit.masks.filter(\.enabled).count,
                             covered))
    }
}
