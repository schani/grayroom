import ArgumentParser
import Foundation
import GrayroomCore
import GrayroomLibrary

extension ExportFormat: ExpressibleByArgument {}

struct Render: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "render",
        abstract: "Decode a RAW, apply an edit, and export an image.",
        discussion: """
        The edit comes from --edit if given, otherwise from the input file's \
        development in the library (#1 unless --development says otherwise), otherwise from \
        the defaults. --set overrides apply on top either way.
        """)

    @OptionGroup var libraryOptions: LibraryOptions
    @OptionGroup var editOptions: EditOptions

    @Argument(help: "Path to the image file.")
    var input: String

    @Option(name: [.short, .customLong("output")], help: "Output file path.")
    var output: String

    @Option(name: .customLong("max-dimension"), help: "Cap the longer output edge at N pixels.")
    var maxDimension: Int?

    @Flag(name: .customLong("histogram"), help: "Print a luminance histogram and clipping stats.")
    var histogram = false

    @Option(name: .customLong("format"), help: "png | png16 | jpeg | tiff16")
    var format: ExportFormat = .png

    @Option(name: .customLong("quality"), help: "JPEG quality, 0…1.")
    var quality: Double = 0.92

    @Flag(name: .customLong("save"),
          help: "Write the effective edit back to the photo's development, importing the file if needed.")
    var save = false

    @Option(name: .customLong("save-edit"), help: "Write the effective EditState to this path.")
    var saveEdit: String?

    func validate() throws {
        if let m = maxDimension, m < 16 { throw fail("--max-dimension must be at least 16") }
        if quality < 0 || quality > 1 { throw fail("--quality must be between 0 and 1") }
        try editOptions.validate()
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

        // `--save` needs a library; rendering does not, so a library that will
        // not open is only fatal when something asked to write to it.
        let library = save ? try libraryOptions.open() : libraryOptions.openIfAvailable()
        let resolved = try editOptions.resolve(input: inputURL, library: library)

        if let saveEdit {
            try resolved.edit.save(to: URL(fileURLWithPath: saveEdit))
        }

        let renderer = try Renderer()
        let result = try renderer.render(rawURL: inputURL,
                                         edit: resolved.edit,
                                         to: outputURL,
                                         format: format,
                                         quality: quality,
                                         maxDimension: maxDimension,
                                         computeHistogram: histogram)

        if save, let library {
            let stored = try EditSource.save(resolved, input: inputURL,
                                             developmentOrdinal: editOptions.developmentOrdinal,
                                             library: library)
            standardError("saved to photo \(stored.photoId) development #\(stored.ordinal)\n")
        }

        standardError("edit source: \(describe(resolved.origin))\n")
        standardError("wrote \(outputURL.path) (\(result.width)x\(result.height), \(format.rawValue))\n")
        standardError(String(format: "white balance: %.0f K / tint %.2f\n",
                             result.temperature, result.tint))
        if let h = result.histogram {
            standardError(h.asciiPlot(rows: 32))
            standardError(h.summary + "\n")
        }
    }

    private func describe(_ origin: EditOrigin) -> String {
        switch origin {
        case .file(let url): return url.path
        case .libraryDevelopment(let id, let ordinal): return "library development #\(ordinal) (id \(id))"
        case .defaults: return "defaults"
        }
    }
}
