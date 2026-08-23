import Foundation
import GRDB
import GrayroomCore

/// The three things a photo's *row* does not say, gathered per photo by
/// `Library.catalogSnapshot()`.
public struct PhotoSummary: Equatable, Sendable {
    /// The lexicographically first of the photo's recorded paths, or `nil` when
    /// it has none — a photo the library remembers but has no file for.
    public var firstLocation: String?
    public var developmentCount: Int
    /// Tag names, alphabetically.
    public var tags: [String]
    /// `EditState.fingerprint` of development #1, and `nil` for a photo that has
    /// no development — which is what the grid compares its stored preview
    /// against, so it has to come along with the snapshot.
    public var developmentFingerprint: Data?

    public init(firstLocation: String? = nil, developmentCount: Int = 0, tags: [String] = [],
                developmentFingerprint: Data? = nil) {
        self.firstLocation = firstLocation
        self.developmentCount = developmentCount
        self.tags = tags
        self.developmentFingerprint = developmentFingerprint
    }
}

/// Every operation is synchronous and throwing: the library is a local SQLite
/// file, and the callers (CLI, app model) already have their own concurrency.
extension Library {

    // MARK: - Photos

    public func photo(withHash hash: Data) throws -> Photo? {
        try dbPool.read { db in
            try Photo.filter(Column("hash") == hash).fetchOne(db)
        }
    }

    public func photo(withHashHexString hex: String) throws -> Photo? {
        guard let data = FileHash.data(fromHexString: hex) else { return nil }
        return try photo(withHash: data)
    }

    /// Every photo whose hash starts with `hex` (case-insensitive). The CLI
    /// addresses photos by short hash prefixes, and needs to know when one is
    /// ambiguous, so this returns all matches rather than the first.
    public func photos(withHashPrefix hex: String) throws -> [Photo] {
        let prefix = hex.uppercased()
        guard !prefix.isEmpty, prefix.allSatisfy(\.isHexDigit) else { return [] }
        return try dbPool.read { db in
            try Photo.fetchAll(db,
                               sql: "SELECT * FROM photos WHERE hex(hash) LIKE ? ORDER BY id",
                               arguments: [prefix + "%"])
        }
    }

    public func photo(id: Int64) throws -> Photo? {
        try dbPool.read { db in try Photo.fetchOne(db, key: id) }
    }

    /// Filters compose (all of them are ANDed). Ordered by capture date, then
    /// id, so photos with no EXIF date sort first but stay stable.
    public func photos(color: ColorLabel? = nil,
                       tag: String? = nil,
                       cameraID: Int64? = nil) throws -> [Photo] {
        var sql = "SELECT photos.* FROM photos"
        var arguments: [DatabaseValueConvertible] = []
        if tag != nil {
            sql += """
                 JOIN photo_tags ON photo_tags.photo_id = photos.id \
                JOIN tags ON tags.id = photo_tags.tag_id
                """
        }
        var conditions: [String] = []
        if let tag {
            conditions.append("tags.name = ?")
            arguments.append(tag.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let color {
            conditions.append("photos.color = ?")
            arguments.append(color.rawValue)
        }
        if let cameraID {
            conditions.append("photos.camera_id = ?")
            arguments.append(cameraID)
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY photos.captured_at, photos.id"
        return try dbPool.read { db in
            try Photo.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    /// Cascades: the photo's locations, developments and tag links go with it,
    /// and so does its preview when `previewStore` is wired up — that one is a
    /// different database file, so SQLite cannot do it for us.
    @discardableResult
    public func deletePhoto(id: Int64) throws -> Bool {
        let deleted = try dbPool.write { db in try Photo.deleteOne(db, key: id) }
        if deleted { try previewStore?.delete(photoID: id) }
        return deleted
    }

    public func setColor(photoID: Int64, _ color: ColorLabel) throws {
        try dbPool.write { db in
            try db.execute(sql: "UPDATE photos SET color = ? WHERE id = ?",
                           arguments: [color.rawValue, photoID])
            guard db.changesCount > 0 else { throw LibraryError.noSuchPhoto(photoID) }
        }
    }

    /// One label onto a whole selection, in a single transaction.
    ///
    /// The grid labels twenty frames with one keystroke, and twenty separate
    /// write transactions would be twenty fsyncs for what is one user action —
    /// and would leave the library half-labelled if one of them threw.
    public func setColor(_ color: ColorLabel, photoIDs: [Int64]) throws {
        guard !photoIDs.isEmpty else { return }
        try dbPool.write { db in
            for photoID in photoIDs {
                try db.execute(sql: "UPDATE photos SET color = ? WHERE id = ?",
                               arguments: [color.rawValue, photoID])
                guard db.changesCount > 0 else { throw LibraryError.noSuchPhoto(photoID) }
            }
        }
    }

    // MARK: - Catalog snapshot

    /// Everything the grid needs about every photo, read as one consistent
    /// snapshot.
    ///
    /// Five statements, no `N+1`: the photos themselves plus four aggregates
    /// keyed by photo id. A grid of ten thousand frames that asked the database
    /// for each photo's first path, development count and tags separately would
    /// issue thirty thousand queries to draw one screen; this issues five and
    /// joins them in RAM, which is what `PhotoCatalog` then holds.
    ///
    /// They run inside one `read`, so the aggregates cannot describe a
    /// different moment than the photo rows do.
    public func catalogSnapshot() throws -> (photos: [Photo], summaries: [Int64: PhotoSummary]) {
        try dbPool.read { db in
            let photos = try Photo.fetchAll(db, sql: "SELECT * FROM photos ORDER BY id")
            var summaries: [Int64: PhotoSummary] = [:]
            summaries.reserveCapacity(photos.count)
            for photo in photos {
                if let id = photo.id { summaries[id] = PhotoSummary() }
            }
            // MIN(path): "the photo's first location" has to be a defined one,
            // not whichever row SQLite happens to return, or the same library
            // would open a different file from one launch to the next.
            let locations = try Row.fetchAll(db, sql: """
                SELECT photo_id, MIN(path) AS path FROM locations GROUP BY photo_id
                """)
            for row in locations {
                let id: Int64 = row["photo_id"]
                summaries[id, default: PhotoSummary()].firstLocation = row["path"]
            }
            let developments = try Row.fetchAll(db, sql: """
                SELECT photo_id, COUNT(*) AS n FROM developments GROUP BY photo_id
                """)
            for row in developments {
                let id: Int64 = row["photo_id"]
                summaries[id, default: PhotoSummary()].developmentCount = row["n"]
            }
            // Development #1's fingerprint, hashed straight off the stored text.
            // `#1` is the photo's lowest ordinal — the same one `developments(for:)`
            // hands back first — and the JSON is hashed rather than decoded
            // because decoding a hundred thousand `EditState`s to draw a grid
            // would be the slowest thing the app does.
            let firstEdits = try Row.fetchAll(db, sql: """
                SELECT d.photo_id AS photo_id, d.edit_json AS edit_json FROM developments d \
                JOIN (SELECT photo_id, MIN(ordinal) AS ordinal FROM developments \
                GROUP BY photo_id) m \
                ON m.photo_id = d.photo_id AND m.ordinal = d.ordinal
                """)
            for row in firstEdits {
                let id: Int64 = row["photo_id"]
                let json: String = row["edit_json"]
                summaries[id, default: PhotoSummary()].developmentFingerprint =
                    EditState.fingerprint(ofEditJSON: Data(json.utf8))
            }
            // Not GROUP BY / group_concat: a tag name may contain the separator,
            // and the join is one scan of a table that is small by construction.
            let tags = try Row.fetchAll(db, sql: """
                SELECT photo_tags.photo_id AS photo_id, tags.name AS name \
                FROM photo_tags JOIN tags ON tags.id = photo_tags.tag_id \
                ORDER BY tags.name
                """)
            for row in tags {
                let id: Int64 = row["photo_id"]
                summaries[id, default: PhotoSummary()].tags.append(row["name"])
            }
            return (photos, summaries)
        }
    }

    // MARK: - Cameras

    public func camera(id: Int64) throws -> Camera? {
        try dbPool.read { db in try Camera.fetchOne(db, key: id) }
    }

    public func allCameras() throws -> [Camera] {
        try dbPool.read { db in
            try Camera.order(Column("make"), Column("model")).fetchAll(db)
        }
    }

    /// Find-or-create by `(make, model)`, which is the table's unique key.
    @discardableResult
    public func camera(make: String, model: String) throws -> Camera {
        try dbPool.write { db in try Library.findOrCreateCamera(db, make: make, model: model) }
    }

    static func findOrCreateCamera(_ db: Database, make: String, model: String) throws -> Camera {
        if let existing = try Camera
            .filter(Column("make") == make && Column("model") == model)
            .fetchOne(db) {
            return existing
        }
        var camera = Camera(make: make, model: model)
        try camera.insert(db)
        return camera
    }

    // MARK: - Locations

    public func locations(for photoID: Int64) throws -> [Location] {
        try dbPool.read { db in
            try Location.filter(Column("photo_id") == photoID)
                .order(Column("path"))
                .fetchAll(db)
        }
    }

    public func location(atPath path: String) throws -> Location? {
        try dbPool.read { db in try Location.filter(Column("path") == path).fetchOne(db) }
    }

    /// The path is stored absolute and standardized. Adding a path a photo
    /// already has is a no-op that returns the existing row.
    @discardableResult
    public func addLocation(photoID: Int64, path: String) throws -> Location {
        try dbPool.write { db in
            try Library.addLocation(db, photoID: photoID, path: path).location
        }
    }

    static func addLocation(_ db: Database, photoID: Int64, path: String)
        throws -> (location: Location, outcome: LocationOutcome) {
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        if var existing = try Location.filter(Column("path") == standardized).fetchOne(db) {
            let previous = existing.photoId
            guard previous != photoID else { return (existing, .unchanged) }
            // The bytes at this path changed since it was recorded. Import is
            // the one moment we actually know that, so the row is repointed
            // rather than left describing a file that no longer exists there.
            existing.photoId = photoID
            try existing.update(db)
            return (existing, .repointed(fromPhotoID: previous))
        }
        var location = Location(photoId: photoID, path: standardized)
        try location.insert(db)
        return (location, .added)
    }

    @discardableResult
    public func removeLocation(id: Int64) throws -> Bool {
        try dbPool.write { db in try Location.deleteOne(db, key: id) }
    }

    // MARK: - Developments

    public func developments(for photoID: Int64) throws -> [Development] {
        try dbPool.read { db in
            try Development.filter(Column("photo_id") == photoID)
                .order(Column("ordinal"))
                .fetchAll(db)
        }
    }

    public func development(id: Int64) throws -> Development? {
        try dbPool.read { db in try Development.fetchOne(db, key: id) }
    }

    /// Appends a development. Ordinals are 1-based and dense per photo, so the first
    /// development of a photo is development #1.
    @discardableResult
    public func addDevelopment(photoID: Int64, edit: EditState) throws -> Development {
        try dbPool.write { db in
            guard try Photo.exists(db, key: photoID) else {
                throw LibraryError.noSuchPhoto(photoID)
            }
            let next = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(ordinal), 0) + 1 FROM developments WHERE photo_id = ?",
                arguments: [photoID]) ?? 1
            let now = Date()
            var record = Development(photoId: photoID, ordinal: next, edit: edit,
                               createdAt: now, updatedAt: now)
            try record.insert(db)
            return record
        }
    }

    @discardableResult
    public func updateDevelopment(id: Int64, edit: EditState) throws -> Development {
        try dbPool.write { db in
            guard var record = try Development.fetchOne(db, key: id) else {
                throw LibraryError.noSuchDevelopment(id)
            }
            record.edit = edit
            record.updatedAt = Date()
            try record.update(db)
            return record
        }
    }

    @discardableResult
    public func deleteDevelopment(id: Int64) throws -> Bool {
        try dbPool.write { db in try Development.deleteOne(db, key: id) }
    }

    // MARK: - Tags

    public func allTags() throws -> [Tag] {
        try dbPool.read { db in try Tag.order(Column("name")).fetchAll(db) }
    }

    public func tags(for photoID: Int64) throws -> [Tag] {
        try dbPool.read { db in
            try Tag.fetchAll(db, sql: """
                SELECT tags.* FROM tags \
                JOIN photo_tags ON photo_tags.tag_id = tags.id \
                WHERE photo_tags.photo_id = ? \
                ORDER BY tags.name
                """, arguments: [photoID])
        }
    }

    /// Find-or-create, case-insensitively (`tags.name` is `COLLATE NOCASE`):
    /// tagging a photo "Portrait" when "portrait" exists reuses that tag, and
    /// tagging twice is idempotent. The first spelling seen wins.
    @discardableResult
    public func addTag(photoID: Int64, name: String) throws -> Tag {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LibraryError.emptyTagName }
        return try dbPool.write { db in
            guard try Photo.exists(db, key: photoID) else {
                throw LibraryError.noSuchPhoto(photoID)
            }
            let tag: Tag
            if let existing = try Tag.filter(Column("name") == trimmed).fetchOne(db) {
                tag = existing
            } else {
                var fresh = Tag(name: trimmed)
                try fresh.insert(db)
                tag = fresh
            }
            try db.execute(
                sql: "INSERT OR IGNORE INTO photo_tags (photo_id, tag_id) VALUES (?, ?)",
                arguments: [photoID, tag.id])
            return tag
        }
    }

    /// Unlinks the tag from the photo. The tag itself stays in the library even
    /// when nothing carries it any more.
    @discardableResult
    public func removeTag(photoID: Int64, name: String) throws -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try dbPool.write { db in
            try db.execute(sql: """
                DELETE FROM photo_tags \
                WHERE photo_id = ? \
                AND tag_id IN (SELECT id FROM tags WHERE name = ?)
                """, arguments: [photoID, trimmed])
            return db.changesCount > 0
        }
    }
}
