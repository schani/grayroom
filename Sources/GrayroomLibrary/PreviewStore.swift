import Foundation
import GRDB
import GrayroomCore

/// Where a stored preview came from.
///
/// The two cases are not interchangeable: an embedded preview is the camera's
/// own JPEG and shows the picture *before* Grayroom touched it, while a rendered
/// one is this app's pipeline run over a development. Which one a photo should
/// have is decided by whether it has a development at all — see
/// `StoredPreview.isCurrent(developmentFingerprint:)`.
public enum PreviewSource: Int, Codable, Sendable {
    case embedded = 0
    case rendered = 1
}

/// One row of `previews.sqlite`.
public struct StoredPreview: Equatable, Sendable {
    public let source: PreviewSource
    /// The development's `EditState.fingerprint`, and `nil` for an embedded
    /// preview — which is not a rendition of any edit and so has nothing to
    /// compare against.
    public let fingerprint: Data?
    public let width: Int
    public let height: Int
    public let jpeg: Data
    public let updatedAt: Date

    public init(source: PreviewSource, fingerprint: Data?,
                width: Int, height: Int, jpeg: Data, updatedAt: Date = Date()) {
        self.source = source
        self.fingerprint = fingerprint
        self.width = width
        self.height = height
        self.jpeg = jpeg
        self.updatedAt = updatedAt
    }

    /// Whether this row still describes what the photo looks like.
    ///
    /// A photo with no development should show the camera's embedded preview; a
    /// photo with one should show *that* development rendered, which is what the
    /// fingerprint comparison establishes. Anything else is stale and has to be
    /// rebuilt.
    public func isCurrent(developmentFingerprint: Data?) -> Bool {
        guard let developmentFingerprint else { return source == .embedded }
        return source == .rendered && fingerprint == developmentFingerprint
    }
}

/// The grid's pictures: one JPEG per photo, in a SQLite file of their own next
/// to the library.
///
/// # Why a second database
///
/// These are derived data. They are regenerated from the file and the
/// development whenever they go stale, they are two orders of magnitude larger
/// than everything else the library holds, and they are written constantly while
/// a folder is being scrolled. Putting them in `library.sqlite` would mean every
/// backup, every copy and every `VACUUM` of the catalogue dragged a few hundred
/// megabytes of JPEG along with it, and would put preview writes in the same WAL
/// as the edits they are derived from. A separate pool with its own WAL keeps
/// the two apart: losing `previews.sqlite` costs nothing but time.
///
/// # Threading
///
/// Like `Library`: every entry point is synchronous and throwing, and the pool
/// itself is safe to use from several queues. `PreviewBuilder` calls it from its
/// own serial worker.
public final class PreviewStore {
    public let url: URL
    public let dbPool: DatabasePool

    public init(url: URL) throws {
        self.url = url
        var config = Configuration()
        config.foreignKeysEnabled = true
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        self.dbPool = try DatabasePool(path: url.path, configuration: config)
        try PreviewStore.migrator.migrate(dbPool)
    }

    public convenience init(path: String) throws {
        try self.init(url: URL(fileURLWithPath: path))
    }

    /// The store that belongs to this library — `previews.sqlite` beside it.
    public static func open(for library: Library) throws -> PreviewStore {
        try PreviewStore(url: library.previewsURL)
    }

    public func close() throws {
        try dbPool.close()
    }

    // MARK: - Migrations

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        // Everything here is derived from the file and the development, so a
        // file written by an older layout is not migrated: it is thrown away
        // and built again. That is the cache invalidating itself, not a
        // migration.
        migrator.eraseDatabaseOnSchemaChange = true
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE previews (
                    photo_hash BLOB PRIMARY KEY,
                    source INTEGER NOT NULL,
                    edit_fingerprint BLOB,
                    width INTEGER NOT NULL,
                    height INTEGER NOT NULL,
                    jpeg BLOB NOT NULL,
                    updated_at DATETIME NOT NULL
                );
                """)
        }
        return migrator
    }

    // MARK: - Reading

    public func preview(for hash: Data) throws -> StoredPreview? {
        try dbPool.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT source, edit_fingerprint, width, height, jpeg, updated_at \
                    FROM previews WHERE photo_hash = ?
                    """,
                arguments: [hash])
            else { return nil }
            let raw: Int = row["source"]
            return StoredPreview(source: PreviewSource(rawValue: raw) ?? .embedded,
                                 fingerprint: row["edit_fingerprint"],
                                 width: row["width"],
                                 height: row["height"],
                                 jpeg: row["jpeg"],
                                 updatedAt: row["updated_at"])
        }
    }

    /// How many photos have a preview.
    public var count: Int {
        get throws {
            try dbPool.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM previews") ?? 0
            }
        }
    }

    /// The JPEGs' total size — what the file costs, near enough.
    public var totalBytes: Int64 {
        get throws {
            try dbPool.read { db in
                try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(LENGTH(jpeg)), 0) FROM previews")
                    ?? 0
            }
        }
    }

    // MARK: - Writing

    /// Insert or replace the photo's preview. A photo has exactly one, because a
    /// stale one has no use: the whole point of the source and the fingerprint
    /// is to tell whether *the* preview is the right one.
    public func store(hash: Data,
                      source: PreviewSource,
                      fingerprint: Data?,
                      width: Int,
                      height: Int,
                      jpeg: Data,
                      updatedAt: Date = Date()) throws {
        // An embedded preview is not a rendition of an edit, so it must not
        // carry one's fingerprint — `isCurrent` reads a non-nil fingerprint as
        // "this is development so-and-so rendered".
        let storedFingerprint = source == .embedded ? nil : fingerprint
        try dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO previews \
                (photo_hash, source, edit_fingerprint, width, height, jpeg, updated_at) \
                VALUES (?, ?, ?, ?, ?, ?, ?) \
                ON CONFLICT(photo_hash) DO UPDATE SET \
                source = excluded.source, \
                edit_fingerprint = excluded.edit_fingerprint, \
                width = excluded.width, \
                height = excluded.height, \
                jpeg = excluded.jpeg, \
                updated_at = excluded.updated_at
                """,
                arguments: [hash, source.rawValue, storedFingerprint,
                            width, height, jpeg, updatedAt])
        }
    }

    @discardableResult
    public func delete(hash: Data) throws -> Bool {
        try dbPool.write { db in
            try db.execute(sql: "DELETE FROM previews WHERE photo_hash = ?", arguments: [hash])
            return db.changesCount > 0
        }
    }

    public func deleteAll() throws {
        try dbPool.write { db in try db.execute(sql: "DELETE FROM previews") }
    }
}
