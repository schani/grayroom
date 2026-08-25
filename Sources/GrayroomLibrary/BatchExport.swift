import Foundation
import GrayroomCore

/// One photo to write out: the file to render, the edit to render it through,
/// and the stem the output file is named after.
public struct ExportJob: Equatable, Sendable {
    /// The original. `nil` when the library has no file for the photo, which is
    /// a failure the batch reports rather than a job it drops.
    public var source: URL?
    public var edit: EditState
    /// The original's name without its extension — what the output is called.
    public var stem: String

    public init(source: URL?, edit: EditState, stem: String) {
        self.source = source
        self.edit = edit
        self.stem = stem
    }

    /// The photo open in Develop: whatever edit is on screen, named after the
    /// file it came from.
    public init(source: URL, edit: EditState) {
        self.init(source: source, edit: edit,
                  stem: ExportNaming.stem(ofFileName: source.lastPathComponent))
    }
}

public struct BatchExportResult: Equatable, Sendable {
    public struct Failure: Equatable, Sendable {
        public var stem: String
        public var message: String
    }

    public var written: [URL] = []
    public var failures: [Failure] = []
    /// Whether the run stopped early because the task was cancelled.
    public var isCancelled = false

    public init() {}
}

public enum BatchExportError: Error, CustomStringConvertible, Equatable {
    case noFile(String)

    public var description: String {
        switch self {
        case .noFile(let stem): return "\(stem): the library has no file for it"
        }
    }
}

/// What an exported file is called.
public enum ExportNaming {
    public static func stem(ofFileName name: String) -> String {
        URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    }

    /// `stem.ext`, and `stem-2.ext`, `stem-3.ext`… when that is taken —
    /// Lightroom's rule. Nothing is ever overwritten.
    ///
    /// `isTaken` is asked rather than the file system so that the names one
    /// batch has already claimed count as taken too: two photos with the same
    /// original name must not write over each other.
    public static func fileName(stem: String, extension ext: String,
                                isTaken: (String) -> Bool) -> String {
        let first = "\(stem).\(ext)"
        guard isTaken(first) else { return first }
        var n = 2
        while isTaken("\(stem)-\(n).\(ext)") { n += 1 }
        return "\(stem)-\(n).\(ext)"
    }
}

/// Exporting several photos into one folder, with no UI in it.
///
/// The rule for *which* edit a photo is exported through is the one the Library
/// grid draws it by: development #1 — the photo's lowest ordinal — or, for a
/// photo with no development, the neutral decode. So what lands in the folder is
/// what the grid was showing.
public enum BatchExport {
    /// The jobs for a set of photos, in the order given.
    public static func jobs(forPhotoIDs ids: [Int64], in library: Library) throws -> [ExportJob] {
        try ids.compactMap { id in
            guard let photo = try library.photo(id: id) else { return nil }
            // First by path, as `CatalogPhoto.firstLocation` is, so the grid and
            // the export open the same file.
            let path = try library.locations(for: id).map(\.path).sorted().first
            return ExportJob(source: path.map { URL(fileURLWithPath: $0) },
                             edit: try library.developments(for: id).first?.edit ?? EditState(),
                             stem: ExportNaming.stem(ofFileName: photo.originalName))
        }
    }

    /// Renders every job into `directory` at full resolution.
    ///
    /// Synchronous, and cancelled between files: `isCancelled` is polled before
    /// each render, which is the only granularity a single render offers.
    /// `progress` is called after each one with how many are done and the name
    /// that was written.
    public static func run(_ jobs: [ExportJob],
                           to directory: URL,
                           format: ExportFormat,
                           quality: Double,
                           renderer: Renderer,
                           isCancelled: () -> Bool = { false },
                           progress: (Int, String) -> Void = { _, _ in }) -> BatchExportResult {
        var result = BatchExportResult()
        var taken: Set<String> = []
        for (index, job) in jobs.enumerated() {
            if isCancelled() {
                result.isCancelled = true
                break
            }
            let name = ExportNaming.fileName(stem: job.stem, extension: format.fileExtension) {
                taken.contains($0)
                    || FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent($0).path)
            }
            let url = directory.appendingPathComponent(name)
            do {
                guard let source = job.source else { throw BatchExportError.noFile(job.stem) }
                try renderer.render(rawURL: source, edit: job.edit, to: url,
                                    format: format, quality: quality,
                                    maxDimension: nil, computeHistogram: false)
                taken.insert(name)
                result.written.append(url)
            } catch {
                // Not taken: nothing was written, so the name is still free for
                // whatever comes next.
                result.failures.append(.init(stem: job.stem, message: "\(error)"))
            }
            progress(index + 1, name)
        }
        return result
    }
}
