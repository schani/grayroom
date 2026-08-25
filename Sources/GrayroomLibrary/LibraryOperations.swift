import Foundation
import GRDB
import GrayroomCore

/// The three things a photo's *row* does not say, gathered per photo by
/// `Library.catalogSnapshot()`.
public struct PhotoSummary: Equatable, Sendable {
    /// Every path the library has for this photo, sorted — empty for a photo it
    /// remembers but has no file for. All of them, not just the first, because
    /// the Folders panel counts a photo under every directory it sits in.
    public var locations: [String]
    public var developmentCount: Int
    /// Tag names, alphabetically.
    public var tags: [String]
    /// `EditState.fingerprint` of development #1, and `nil` for a photo that has
    /// no development — which is what the grid compares its stored preview
    /// against, so it has to come along with the snapshot.
    public var developmentFingerprint: Data?

    /// The lexicographically first of the photo's recorded paths, or `nil` when
    /// it has none. Defined rather than "whichever row came back first", so the
    /// same library opens the same file from one launch to the next.
    public var firstLocation: String? { locations.first }

    public init(locations: [String] = [], developmentCount: Int = 0, tags: [String] = [],
                developmentFingerprint: Data? = nil) {
        self.locations = locations
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

    /// Filters compose (all of them are ANDed). Ordered by capture date by
    /// default, then id, so photos with no EXIF date sort first but stay
    /// stable; `sort` picks another key (see `PhotoSortKey`).
    public func photos(color: ColorLabel? = nil,
                       tag: String? = nil,
                       cameraID: Int64? = nil,
                       lensID: Int64? = nil,
                       sort: PhotoSortKey = .captureTime,
                       ascending: Bool = true) throws -> [Photo] {
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
        if let lensID {
            conditions.append("photos.lens_id = ?")
            arguments.append(lensID)
        }
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY " + sort.orderBy(ascending: ascending)
        return try dbPool.read { db in
            try Photo.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    /// Cascades: the photo's locations, developments and tag links go with it,
    /// and so does its preview when `previewStore` is wired up — that one is a
    /// different database file, so SQLite cannot do it for us.
    @discardableResult
    public func deletePhoto(id: Int64) throws -> Bool {
        let hash = try photo(id: id)?.hash
        let deleted = try dbPool.write { db in try Photo.deleteOne(db, key: id) }
        if deleted, let hash { try previewStore?.delete(hash: hash) }
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
            // Every path, grouped in Swift rather than with `group_concat`: a
            // POSIX path may contain any byte but `/` and NUL, so there is no
            // separator that is safe to join on and split back. One ordered
            // scan of a table with one row per file costs less than getting
            // that wrong, and `ORDER BY` is what makes `firstLocation` the
            // lexicographically first path rather than whichever row SQLite
            // happened to return.
            let locations = try Row.fetchAll(db, sql: """
                SELECT photo_id, path FROM locations ORDER BY photo_id, path
                """)
            for row in locations {
                let id: Int64 = row["photo_id"]
                summaries[id, default: PhotoSummary()].locations.append(row["path"])
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

    // MARK: - Lenses

    public func lens(id: Int64) throws -> Lens? {
        try dbPool.read { db in try Lens.fetchOne(db, key: id) }
    }

    public func allLenses() throws -> [Lens] {
        try dbPool.read { db in
            try Lens.order(Column("make"), Column("model")).fetchAll(db)
        }
    }

    /// Find-or-create by `(make, model)`, which is the table's unique key.
    ///
    /// Unlike a camera, a lens is allowed an empty make — a file that names the
    /// glass but not who ground it still names the glass. An empty *model* is
    /// not a lens at all, and is rejected rather than stored as a row nobody
    /// could tell from another.
    @discardableResult
    public func lens(make: String = "", model: String) throws -> Lens {
        try dbPool.write { db in try Library.findOrCreateLens(db, make: make, model: model) }
    }

    /// Trims both fields; throws `LibraryError.emptyLensModel` when nothing is
    /// left of the model.
    static func findOrCreateLens(_ db: Database, make: String, model: String) throws -> Lens {
        let make = make.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { throw LibraryError.emptyLensModel }
        if let existing = try Lens
            .filter(Column("make") == make && Column("model") == model)
            .fetchOne(db) {
            return existing
        }
        var lens = Lens(make: make, model: model)
        try lens.insert(db)
        return lens
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
