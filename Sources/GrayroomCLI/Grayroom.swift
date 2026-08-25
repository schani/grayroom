import ArgumentParser
import Foundation
import GrayroomLibrary

public struct Grayroom: ParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "grayroom",
        abstract: "Headless B&W RAW developer.",
        version: "0.4.0 (M6)",
        subcommands: [Probe.self, Render.self, Export.self, MaskPreview.self,
                      Import.self, List.self, Show.self,
                      Tag.self, Color.self, Developments.self, Previews.self],
        defaultSubcommand: nil)

    public init() {}
}

func fail(_ message: String) -> ValidationError {
    ValidationError(message)
}

func standardError(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

// MARK: - Library location

/// Where the library lives, for every command that touches it.
///
/// Precedence: `--library`, then `$GRAYROOM_LIBRARY`, then the default under
/// Application Support.
struct LibraryOptions: ParsableArguments {
    @Option(name: .customLong("library"),
            help: ArgumentHelp("Path to the library database.",
                               discussion: "Defaults to $GRAYROOM_LIBRARY, or "
                                   + "~/Library/Application Support/Grayroom/library.sqlite.",
                               valueName: "path"))
    var libraryPath: String?

    init() {}

    func resolvedURL() throws -> URL {
        if let libraryPath, !libraryPath.isEmpty {
            return URL(fileURLWithPath: libraryPath)
        }
        let env = ProcessInfo.processInfo.environment["GRAYROOM_LIBRARY"]
        if let env, !env.isEmpty { return URL(fileURLWithPath: env) }
        return try Library.defaultURL()
    }

    func open() throws -> Library {
        let url = try resolvedURL()
        do {
            return try Library(url: url)
        } catch {
            throw fail("could not open library \(url.path): \(error)")
        }
    }

    /// `nil` instead of an error, for commands that work with or without a
    /// library (`render` on a file nobody has imported).
    ///
    /// A library that does not exist yet is not created here: rendering a file
    /// is not a reason to start a catalogue.
    func openIfAvailable() -> Library? {
        guard let url = try? resolvedURL(),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return try? Library(url: url)
    }
}

// MARK: - Argument types

extension ColorLabel: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(name: argument)
    }

    public static var allValueStrings: [String] { allNames }
}

extension PhotoSortKey: ExpressibleByArgument {
    public init?(argument: String) {
        self.init(rawValue: argument.lowercased())
    }

    public static var allValueStrings: [String] { allCases.map(\.rawValue) }
}

// MARK: - Formatting

enum Format {
    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ date: Date?) -> String {
        guard let date else { return "-" }
        return isoFormatter.string(from: date)
    }

    static func hashPrefix(_ photo: Photo, length: Int = 12) -> String {
        String(photo.hashHexString.prefix(length))
    }

    static func orDash(_ s: String?) -> String {
        guard let s, !s.isEmpty else { return "-" }
        return s
    }

    static func camera(_ camera: Camera?) -> String {
        guard let camera else { return "-" }
        return "\(camera.make) \(camera.model)".trimmingCharacters(in: .whitespaces)
    }

    /// The same shape as `camera`, and a lens with no make prints as its model
    /// alone rather than with a leading space.
    static func lens(_ lens: Lens?) -> String {
        guard let lens else { return "-" }
        return "\(lens.make) \(lens.model)".trimmingCharacters(in: .whitespaces)
    }
}
