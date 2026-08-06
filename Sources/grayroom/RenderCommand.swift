import ArgumentParser
import Foundation
import GrayroomCore

extension ExportFormat: ExpressibleByArgument {}

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render",
        abstract: "Decode a RAW, apply an edit, and export an image.")

    @Argument(help: "Path to the RAW file.")
    var input: String

    @Option(name: [.short, .customLong("output")], help: "Output file path.")
    var output: String

    @Option(name: .customLong("edit"), help: "Sidecar JSON to load as the base edit.")
    var editPath: String?

    @Option(name: .customLong("set"),
            help: ArgumentHelp("Override an edit value, e.g. tone.exposure=1.0 or bwMix.enabled=false.",
                               valueName: "key=value"))
    var settings: [String] = []

    @Option(name: .customLong("max-dimension"), help: "Cap the longer output edge at N pixels.")
    var maxDimension: Int?

    @Flag(name: .customLong("histogram"), help: "Print a luminance histogram and clipping stats.")
    var histogram = false

    @Option(name: .customLong("format"), help: "png | png16 | jpeg | tiff16")
    var format: ExportFormat = .png

    @Option(name: .customLong("quality"), help: "JPEG quality, 0…1.")
    var quality: Double = 0.92

    @Option(name: .customLong("save-edit"), help: "Write the effective EditState to this path.")
    var saveEdit: String?

    func validate() throws {
        if let m = maxDimension, m < 16 { throw fail("--max-dimension must be at least 16") }
        if quality < 0 || quality > 1 { throw fail("--quality must be between 0 and 1") }
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

        if let saveEdit {
            try edit.save(to: URL(fileURLWithPath: saveEdit))
        }

        let renderer = try Renderer()
        let result = try renderer.render(rawURL: inputURL,
                                         edit: edit,
                                         to: outputURL,
                                         format: format,
                                         quality: quality,
                                         maxDimension: maxDimension,
                                         computeHistogram: histogram)

        standardError("wrote \(outputURL.path) (\(result.width)x\(result.height), \(format.rawValue))\n")
        standardError(String(format: "white balance: %.0f K / tint %.2f\n",
                             result.temperature, result.tint))
        if let h = result.histogram {
            standardError(h.asciiPlot(rows: 32))
            standardError(h.summary + "\n")
        }
    }
}
