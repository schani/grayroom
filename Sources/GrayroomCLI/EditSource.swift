import ArgumentParser
import Foundation
import GrayroomCore
import GrayroomLibrary

/// Where the effective `EditState` came from.
public enum EditOrigin: Equatable {
    /// `--edit file.json`.
    case file(URL)
    /// A development in the library.
    case libraryDevelopment(id: Int64, ordinal: Int)
    /// Nothing said otherwise, so a default `EditState`.
    case defaults
}

public struct ResolvedEdit: Equatable {
    /// The edit to render, with `--set` overrides already applied.
    public var edit: EditState
    public var origin: EditOrigin
    /// The library photo the input file is, when the library knows it. `--save`
    /// needs it; rendering does not.
    public var photoID: Int64?
}

public enum EditSourceError: Error, CustomStringConvertible, Equatable {
    case fileNotFound(String)
    case unreadable(String, String)
    case noSuchDevelopment(Int, Int64)

    public var description: String {
        switch self {
        case .fileNotFound(let path): return "edit file not found: \(path)"
        case .unreadable(let path, let reason): return "could not read \(path): \(reason)"
        case .noSuchDevelopment(let ordinal, let photoID):
            return "photo \(photoID) has no development #\(ordinal)"
        }
    }
}

/// The edit a `render` (or `mask-preview`) actually uses.
///
/// Precedence, highest first:
///
/// 1. `--edit file.json`;
/// 2. the input file's first remaining development, unless `--development` says otherwise;
/// 3. a default `EditState`.
///
/// `--set` overrides are applied on top of whichever won.
public enum EditSource {
    public static func resolve(input: URL,
                               editPath: String?,
                               developmentOrdinal: Int?,
                               settings: [String],
                               library: Library?) throws -> ResolvedEdit {
        // The photo id is wanted whichever branch wins: `--save` writes back to
        // it even when the edit came from a file.
        var photoID: Int64?
        if let library, FileManager.default.fileExists(atPath: input.path) {
            let hash = try FileHash.sha256(of: input)
            photoID = try library.photo(withHash: hash)?.id
        }

        var edit = EditState()
        var origin = EditOrigin.defaults

        if let editPath {
            let url = URL(fileURLWithPath: editPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw EditSourceError.fileNotFound(url.path)
            }
            do {
                edit = try EditState.load(from: url)
            } catch {
                throw EditSourceError.unreadable(url.path, "\(error)")
            }
            origin = .file(url)
        } else if let library, let photoID {
            if let match = try development(for: photoID, ordinal: developmentOrdinal, in: library),
               let id = match.id {
                edit = match.edit
                origin = .libraryDevelopment(id: id, ordinal: match.ordinal)
            } else if let developmentOrdinal {
                // An explicit --development that does not exist is a mistake, not a
                // reason to silently render the defaults.
                throw EditSourceError.noSuchDevelopment(developmentOrdinal, photoID)
            }
        }

        edit = try edit.applying(settings: settings)
        return ResolvedEdit(edit: edit, origin: origin, photoID: photoID)
    }

    /// `render --save`: write the effective edit back to the library.
    ///
    /// Writes to the source development, the explicit ordinal, or the first
    /// remaining development. Files new to the library are imported first.
    @discardableResult
    public static func save(_ resolved: ResolvedEdit,
                            input: URL,
                            developmentOrdinal: Int?,
                            library: Library,
                            importer: Importer? = nil) throws -> Development {
        var photoID = resolved.photoID
        if photoID == nil {
            let importer = importer ?? Importer(library: library)
            photoID = try importer.importFile(at: input).photoID
        }
        guard let photoID else { throw EditSourceError.fileNotFound(input.path) }

        if case .libraryDevelopment(let id, _) = resolved.origin {
            return try library.updateDevelopment(id: id, edit: resolved.edit)
        }
        if let existing = try development(for: photoID, ordinal: developmentOrdinal, in: library),
           let id = existing.id {
            return try library.updateDevelopment(id: id, edit: resolved.edit)
        }
        return try library.addDevelopment(photoID: photoID, edit: resolved.edit)
    }

    private static func development(for photoID: Int64, ordinal: Int?,
                                    in library: Library) throws -> Development? {
        let developments = try library.developments(for: photoID)
        guard let ordinal else { return developments.first }
        return developments.first { $0.ordinal == ordinal }
    }
}

/// The `--edit` / `--development` / `--set` trio, shared by `render` and
/// `mask-preview`.
struct EditOptions: ParsableArguments {
    @Option(name: .customLong("edit"), help: "JSON file to load as the base edit.")
    var editPath: String?

    @Option(name: .customLong("development"),
            help: ArgumentHelp("Use this development of the input photo instead of development #1.",
                               valueName: "ordinal"))
    var developmentOrdinal: Int?

    @Option(name: .customLong("set"),
            help: ArgumentHelp("Override an edit value, e.g. tone.exposure=1.0 or bwMix.enabled=false.",
                               discussion: "Values are clamped to their documented ranges, "
                                   + "not rejected: clarity is 0…100 (positive only), so "
                                   + "clarity=-50 loads as 0. Per-mask clarity deltas "
                                   + "(masks[N].adjustments.clarity) keep the full -100…100 range.",
                               valueName: "key=value"))
    var settings: [String] = []

    init() {}

    func validate() throws {
        if let developmentOrdinal, developmentOrdinal < 1 { throw fail("--development must be at least 1") }
    }

    /// Wraps the resolver's errors as `ValidationError`s so the CLI prints them
    /// as usage failures rather than as a stack of Swift error descriptions.
    func resolve(input: URL, library: Library?) throws -> ResolvedEdit {
        do {
            return try EditSource.resolve(input: input,
                                          editPath: editPath,
                                          developmentOrdinal: developmentOrdinal,
                                          settings: settings,
                                          library: library)
        } catch let e as EditSourceError {
            throw fail(e.description)
        } catch let e as EditStateError {
            throw fail(e.description)
        }
    }
}
