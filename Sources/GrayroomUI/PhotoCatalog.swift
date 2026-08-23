import Foundation
import GrayroomLibrary
import Observation

/// One photo as the library grid needs it: its row, flattened together with the
/// four things the row does not carry (its first path, how many developments it
/// has, its tags, and the fingerprint of development #1).
///
/// A value type with no database handle in it, so the grid can hold ten
/// thousand of these and a cell can be diffed by `==`.
public struct CatalogPhoto: Identifiable, Equatable, Sendable {
    public var id: Int64
    /// SHA-256 of the file — the photo's external identity.
    public var hash: Data
    public var originalName: String
    public var capturedAt: Date?
    public var importedAt: Date
    public var width: Int?
    public var height: Int?
    public var cameraId: Int64?
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    public var byteSize: Int64
    public var color: ColorLabel
    /// `nil` when the library has no path for this photo at all.
    public var firstLocation: String?
    public var developmentCount: Int
    public var tags: [String]
    /// `EditState.fingerprint` of development #1, `nil` when the photo has no
    /// development. It is what decides whether the grid should be showing the
    /// camera's embedded preview or this app's render of that development — see
    /// `StoredPreview.isCurrent(developmentFingerprint:)` — so it is held in RAM
    /// with the rest of the row rather than looked up per cell.
    public var developmentFingerprint: Data?

    public init(id: Int64,
                hash: Data = Data(),
                originalName: String,
                capturedAt: Date? = nil,
                importedAt: Date = Date(),
                width: Int? = nil,
                height: Int? = nil,
                cameraId: Int64? = nil,
                latitude: Double? = nil,
                longitude: Double? = nil,
                altitude: Double? = nil,
                byteSize: Int64 = 0,
                color: ColorLabel = .unlabeled,
                firstLocation: String? = nil,
                developmentCount: Int = 0,
                tags: [String] = [],
                developmentFingerprint: Data? = nil) {
        self.id = id
        self.hash = hash
        self.originalName = originalName
        self.capturedAt = capturedAt
        self.importedAt = importedAt
        self.width = width
        self.height = height
        self.cameraId = cameraId
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.byteSize = byteSize
        self.color = color
        self.firstLocation = firstLocation
        self.developmentCount = developmentCount
        self.tags = tags
        self.developmentFingerprint = developmentFingerprint
    }

    /// A row plus its aggregates. `nil` for a photo that has not been inserted
    /// yet — the catalog only ever describes stored photos.
    public init?(photo: Photo, summary: PhotoSummary = PhotoSummary()) {
        guard let id = photo.id else { return nil }
        self.init(id: id,
                  hash: photo.hash,
                  originalName: photo.originalName,
                  capturedAt: photo.capturedAt,
                  importedAt: photo.importedAt,
                  width: photo.width,
                  height: photo.height,
                  cameraId: photo.cameraId,
                  latitude: photo.latitude,
                  longitude: photo.longitude,
                  altitude: photo.altitude,
                  byteSize: photo.byteSize,
                  color: photo.color,
                  firstLocation: summary.firstLocation,
                  developmentCount: summary.developmentCount,
                  tags: summary.tags,
                  developmentFingerprint: summary.developmentFingerprint)
    }

    /// The file to open, when there is one.
    public var url: URL? { firstLocation.map { URL(fileURLWithPath: $0) } }

    /// Lowercase hex — how the CLI addresses this photo.
    public var hashHexString: String { FileHash.hexString(hash) }
}

/// Every photo in the library, in RAM, in the order the grid draws them.
///
/// # Why the whole library is held in memory
///
/// A `CatalogPhoto` is on the order of 200 bytes plus its strings, so a
/// hundred-thousand-frame library is tens of megabytes — less than one decoded
/// RAW. In exchange the grid never queries while scrolling, arrow keys are
/// index arithmetic, and "what is selected" is a set of integers rather than a
/// set of database rows. The alternative (a windowed query per screenful) buys
/// nothing at this scale and makes every one of those operations async.
///
/// # Threading
///
/// Main-thread only by convention, like the other `@Observable` stores. The
/// database reads it does are of a local SQLite file and are synchronous; the
/// app calls `load(from:)` at launch and after an import, not while scrolling.
///
/// # Order
///
/// Capture date ascending, undated photos last, ties broken by row id — the
/// same rule the import grid sorts by, so a card looks the same before and
/// after it is imported. Undated frames go last rather than pretending to have
/// been shot at the epoch.
@Observable
public final class PhotoCatalog {
    public private(set) var photos: [CatalogPhoto] = []
    /// Rebuilt with `photos`; the grid asks "where is photo 4711" once per
    /// keystroke and once per cell, which is not a place for a linear scan.
    private var indexByID: [Int64: Int] = [:]

    public init() {}

    public init(photos: [CatalogPhoto]) {
        replace(photos)
    }

    public var count: Int { photos.count }
    public var isEmpty: Bool { photos.isEmpty }
    /// The grid's displayed order — what a shift-range and the arrow keys move
    /// along.
    public var ids: [Int64] { photos.map(\.id) }

    public func index(of id: Int64) -> Int? { indexByID[id] }

    public func photo(id: Int64) -> CatalogPhoto? {
        indexByID[id].map { photos[$0] }
    }

    // MARK: - Loading

    /// Reads the whole library: one snapshot, five statements, sorted here.
    public func load(from library: Library) throws {
        let snapshot = try library.catalogSnapshot()
        replace(snapshot.photos.compactMap { photo in
            guard let id = photo.id else { return nil }
            return CatalogPhoto(photo: photo, summary: snapshot.summaries[id] ?? PhotoSummary())
        })
    }

    public func replace(_ photos: [CatalogPhoto]) {
        self.photos = photos.sorted(by: PhotoCatalog.isOrderedBefore)
        reindex()
    }

    /// Capture date ascending, `nil` last, then row id.
    public static func isOrderedBefore(_ a: CatalogPhoto, _ b: CatalogPhoto) -> Bool {
        switch (a.capturedAt, b.capturedAt) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return false
        case (_?, nil): return true
        default: return a.id < b.id
        }
    }

    private func reindex() {
        indexByID = [:]
        indexByID.reserveCapacity(photos.count)
        for (offset, photo) in photos.enumerated() { indexByID[photo.id] = offset }
    }

    // MARK: - Mutation

    /// Insert or update, keeping the sort order.
    ///
    /// Used after an import and after a development is saved. A photo whose
    /// sort key has not moved is replaced in place, so the grid does not
    /// reshuffle under the user when a colour label changes.
    public func apply(_ photo: CatalogPhoto) {
        if let index = indexByID[photo.id] {
            let existing = photos[index]
            photos[index] = photo
            guard existing.capturedAt != photo.capturedAt else { return }
            photos.sort(by: PhotoCatalog.isOrderedBefore)
            reindex()
            return
        }
        let insertion = photos.firstIndex { !PhotoCatalog.isOrderedBefore($0, photo) }
            ?? photos.count
        photos.insert(photo, at: insertion)
        reindex()
    }

    public func remove(id: Int64) {
        guard let index = indexByID[id] else { return }
        photos.remove(at: index)
        reindex()
    }

    /// Writes the label to the database first, then to RAM — so a failed write
    /// leaves the grid showing what the library actually holds.
    public func setColor(_ color: ColorLabel, for ids: [Int64], in library: Library) throws {
        guard !ids.isEmpty else { return }
        try library.setColor(color, photoIDs: ids)
        for id in ids {
            guard let index = indexByID[id] else { continue }
            photos[index].color = color
        }
    }

    /// After a development is created or saved. The count only ever grows here;
    /// deleting a development goes through a reload.
    public func setDevelopmentCount(_ count: Int, for id: Int64) {
        guard let index = indexByID[id], photos[index].developmentCount != count else { return }
        photos[index].developmentCount = count
    }

    /// After development #1 is written. This is what invalidates the grid's
    /// picture of the photo: the cell is keyed by the fingerprint, so moving it
    /// is what makes the cell ask for a preview of the edit that was just saved
    /// instead of the one before it.
    public func setDevelopmentFingerprint(_ fingerprint: Data?, for id: Int64) {
        guard let index = indexByID[id],
              photos[index].developmentFingerprint != fingerprint else { return }
        photos[index].developmentFingerprint = fingerprint
    }
}
