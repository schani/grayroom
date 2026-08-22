import Foundation
import GRDB

/// Lightroom-style single-valued colour label (PLAN.md, "M6 — Library").
///
/// The zero case is `unlabeled` rather than `none` so that a bare `.none` in a
/// call like `photos(color:)` can never be read as `Optional.none`.
public enum ColorLabel: Int, Codable, CaseIterable, Sendable {
    case unlabeled = 0
    case red = 1
    case yellow = 2
    case green = 3
    case blue = 4
    case purple = 5
}

extension ColorLabel: DatabaseValueConvertible {}

extension ColorLabel {
    public var name: String {
        switch self {
        case .unlabeled: return "unlabeled"
        case .red: return "red"
        case .yellow: return "yellow"
        case .green: return "green"
        case .blue: return "blue"
        case .purple: return "purple"
        }
    }

    public init?(name: String) {
        let wanted = name.lowercased()
        guard let match = ColorLabel.allCases.first(where: { $0.name == wanted }) else {
            return nil
        }
        self = match
    }

    public static var allNames: [String] { allCases.map(\.name) }
}

public enum LibraryError: Error, CustomStringConvertible {
    case noSuchPhoto(Int64)
    case noSuchDevelopment(Int64)
    case notADirectory(URL)
    case emptyTagName

    public var description: String {
        switch self {
        case .noSuchPhoto(let id): return "no photo with id \(id)"
        case .noSuchDevelopment(let id): return "no development with id \(id)"
        case .notADirectory(let u): return "not a directory: \(u.path)"
        case .emptyTagName: return "a tag name cannot be empty"
        }
    }
}

/// The one SQLite database that holds every edit and every piece of
/// organization.
///
/// Every entry point takes an explicit path so tests and the CLI can work on
/// throwaway databases; `defaultURL()` is only the fallback the app uses.
public final class Library {
    public let url: URL
    public let dbPool: DatabasePool

    public init(path: String) throws {
        self.url = URL(fileURLWithPath: path)
        var config = Configuration()
        // Explicit, though both are GRDB defaults: the schema leans on ON
        // DELETE CASCADE, and a DatabasePool is WAL by definition.
        config.foreignKeysEnabled = true
        try FileManager.default.createDirectory(
            at: self.url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        self.dbPool = try DatabasePool(path: path, configuration: config)
        try Library.migrator.migrate(dbPool)
    }

    public convenience init(url: URL) throws {
        try self.init(path: url.path)
    }

    /// `~/Library/Application Support/Grayroom/library.sqlite`; the containing
    /// directory is created if it is missing.
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        let dir = support.appendingPathComponent("Grayroom", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.sqlite")
    }

    public static func openDefault() throws -> Library {
        try Library(url: try Library.defaultURL())
    }

    public func close() throws {
        try dbPool.close()
    }

    // MARK: - Migrations

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE cameras (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    make TEXT NOT NULL,
                    model TEXT NOT NULL,
                    UNIQUE (make, model)
                );

                CREATE TABLE photos (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    hash BLOB NOT NULL UNIQUE,
                    byte_size INTEGER NOT NULL,
                    original_name TEXT NOT NULL,
                    imported_at DATETIME NOT NULL,
                    captured_at DATETIME,
                    camera_id INTEGER REFERENCES cameras(id) ON DELETE SET NULL,
                    width INTEGER,
                    height INTEGER,
                    latitude DOUBLE,
                    longitude DOUBLE,
                    altitude DOUBLE,
                    color INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE locations (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                    path TEXT NOT NULL UNIQUE
                );

                CREATE TABLE developments (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                    ordinal INTEGER NOT NULL,
                    edit_json TEXT NOT NULL CHECK (json_valid(edit_json)),
                    created_at DATETIME NOT NULL,
                    updated_at DATETIME NOT NULL,
                    UNIQUE (photo_id, ordinal)
                );

                CREATE TABLE tags (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL COLLATE NOCASE UNIQUE
                );

                CREATE TABLE photo_tags (
                    photo_id INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
                    tag_id INTEGER NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
                    PRIMARY KEY (photo_id, tag_id)
                );

                CREATE INDEX index_locations_on_photo_id ON locations(photo_id);
                CREATE INDEX index_developments_on_photo_id ON developments(photo_id);
                CREATE INDEX index_photos_on_camera_id ON photos(camera_id);
                CREATE INDEX index_photos_on_color ON photos(color);
                CREATE INDEX index_photos_on_captured_at ON photos(captured_at);
                CREATE INDEX index_photo_tags_on_tag_id ON photo_tags(tag_id);
                """)
        }
        return migrator
    }
}
