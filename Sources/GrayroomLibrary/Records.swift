import Foundation
import GRDB
import GrayroomCore

/// Swift camelCase ↔ SQLite snake_case, applied uniformly to every record.
///
/// Note the property spellings: the decoding strategy turns `camera_id` into
/// `cameraId`, not `cameraID`, so the records spell foreign keys `…Id`. The
/// library's *API* still uses the Swift-idiomatic `photoID:` labels.
public protocol LibraryRecord: Codable, FetchableRecord, MutablePersistableRecord {}

extension LibraryRecord {
    public static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy {
        .convertFromSnakeCase
    }
    public static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy {
        .convertToSnakeCase
    }
}

// MARK: - Camera

public struct Camera: LibraryRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "cameras"

    public var id: Int64?
    public var make: String
    public var model: String

    public init(id: Int64? = nil, make: String, model: String) {
        self.id = id
        self.make = make
        self.model = model
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Lens

/// The glass in front of the camera, kept the same way the body is: one row per
/// distinct `(make, model)`, found-or-created at import.
///
/// `make` is allowed to be empty, and often is — plenty of cameras write
/// `LensModel` with no `LensMake` beside it (adapted and manual glass in
/// particular), and dropping those would lose the only thing the file says
/// about the lens. `model` is what identifies a lens, so a row is never made
/// without one.
public struct Lens: LibraryRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "lenses"

    public var id: Int64?
    public var make: String
    public var model: String

    public init(id: Int64? = nil, make: String = "", model: String) {
        self.id = id
        self.make = make
        self.model = model
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Photo

public struct Photo: LibraryRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "photos"

    public var id: Int64?
    /// SHA-256 of the whole file — the photo's external identity.
    public var hash: Data
    public var byteSize: Int64
    public var originalName: String
    public var importedAt: Date
    public var capturedAt: Date?
    public var cameraId: Int64?
    public var lensId: Int64?
    public var width: Int?
    public var height: Int?
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    public var color: ColorLabel
    /// Vision's `overallScore`, −1…1, and `nil` until the photo is analysed.
    ///
    /// Its companion column, `feature_print`, is deliberately *not* here: it is
    /// kilobytes per row, and this record is what `catalogSnapshot` decodes for
    /// every photo in the library. Feature prints are read only by the queries
    /// that compare them.
    public var aestheticScore: Double?

    public init(
        id: Int64? = nil,
        hash: Data,
        byteSize: Int64,
        originalName: String,
        importedAt: Date = Date(),
        capturedAt: Date? = nil,
        cameraId: Int64? = nil,
        lensId: Int64? = nil,
        width: Int? = nil,
        height: Int? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitude: Double? = nil,
        color: ColorLabel = .unlabeled,
        aestheticScore: Double? = nil
    ) {
        self.id = id
        self.hash = hash
        self.byteSize = byteSize
        self.originalName = originalName
        self.importedAt = importedAt
        self.capturedAt = capturedAt
        self.cameraId = cameraId
        self.lensId = lensId
        self.width = width
        self.height = height
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.color = color
        self.aestheticScore = aestheticScore
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var hashHexString: String { FileHash.hexString(hash) }
}

// MARK: - Location

public struct Location: LibraryRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "locations"

    public var id: Int64?
    public var photoId: Int64
    /// Absolute and standardized (`URL.standardizedFileURL.path`).
    public var path: String

    public init(id: Int64? = nil, photoId: Int64, path: String) {
        self.id = id
        self.photoId = photoId
        self.path = path
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var url: URL { URL(fileURLWithPath: path) }
}

// MARK: - Development

/// One rendition of a photo: a single `EditState`, stored as JSON.
///
/// The JSON is produced by `EditState.jsonData()` / read back by
/// `EditState.decode(from:)` — the same tolerant codec the rest of the app
/// uses, so there is exactly one on-disk representation of an edit.
public struct Development: LibraryRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "developments"

    public var id: Int64?
    public var photoId: Int64
    public var ordinal: Int
    public var edit: EditState
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        photoId: Int64,
        ordinal: Int,
        edit: EditState,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.photoId = photoId
        self.ordinal = ordinal
        self.edit = edit
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    private enum CodingKeys: String, CodingKey {
        case id, photoId, ordinal, editJson, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(Int64.self, forKey: .id)
        photoId = try c.decode(Int64.self, forKey: .photoId)
        ordinal = try c.decode(Int.self, forKey: .ordinal)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        let json = try c.decode(String.self, forKey: .editJson)
        edit = try EditState.decode(from: Data(json.utf8))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Omitted when nil so SQLite assigns the autoincremented rowid.
        try c.encodeIfPresent(id, forKey: .id)
        try c.encode(photoId, forKey: .photoId)
        try c.encode(ordinal, forKey: .ordinal)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        let data = try edit.jsonData()
        try c.encode(String(decoding: data, as: UTF8.self), forKey: .editJson)
    }
}

// MARK: - Tag

public struct Tag: LibraryRecord, Identifiable, Equatable, Sendable {
    public static let databaseTableName = "tags"

    public var id: Int64?
    public var name: String

    public init(id: Int64? = nil, name: String) {
        self.id = id
        self.name = name
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - PhotoTag

public struct PhotoTag: LibraryRecord, Equatable, Sendable {
    public static let databaseTableName = "photo_tags"

    public var photoId: Int64
    public var tagId: Int64

    public init(photoId: Int64, tagId: Int64) {
        self.photoId = photoId
        self.tagId = tagId
    }
}
