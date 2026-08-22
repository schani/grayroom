import Foundation
import GRDB
import GrayroomCore
import UniformTypeIdentifiers

/// What the importer needs to know about a file beyond its bytes.
public struct PhotoMetadata: Equatable, Sendable {
    public var width: Int?
    public var height: Int?
    public var capturedAt: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?

    public init(
        width: Int? = nil,
        height: Int? = nil,
        capturedAt: Date? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitude: Double? = nil
    ) {
        self.width = width
        self.height = height
        self.capturedAt = capturedAt
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

/// What became of the file's path.
public enum LocationOutcome: Equatable, Sendable {
    /// The path was not in the library and now is.
    case added
    /// The path was already recorded against this same photo.
    case unchanged
    /// The path was recorded against a *different* photo — the bytes there
    /// changed since it was last seen — and now points at this one.
    case repointed(fromPhotoID: Int64)
}

public struct ImportResult: Equatable, Sendable {
    public var photoID: Int64
    /// `false` when the same bytes were already in the library.
    public var isNewPhoto: Bool
    public var location: LocationOutcome
    /// The absolute, standardized path that was imported.
    public var path: String

    public init(photoID: Int64, isNewPhoto: Bool, location: LocationOutcome, path: String) {
        self.photoID = photoID
        self.isNewPhoto = isNewPhoto
        self.location = location
        self.path = path
    }
}

/// Hash → upsert photo → upsert location.
///
/// Identity is the SHA-256 of the whole file, so the same file at two paths is
/// one photo with two locations, and re-importing a path already in the library
/// changes nothing.
public final class Importer {
    /// Injectable so tests can import arbitrary bytes without a RAW decoder.
    public typealias MetadataProbe = (URL) throws -> PhotoMetadata

    public let library: Library
    private let probe: MetadataProbe

    public init(library: Library, probe: @escaping MetadataProbe = Importer.probeRAW) {
        self.library = library
        self.probe = probe
    }

    /// The real probe: CIRAWFilter + ImageIO, no GPU work.
    public static func probeRAW(_ url: URL) throws -> PhotoMetadata {
        let info = try RawDecoder.probe(url: url)
        return PhotoMetadata(
            width: Int(info.orientedSize.width.rounded()),
            height: Int(info.orientedSize.height.rounded()),
            capturedAt: info.capturedAt,
            cameraMake: info.cameraMake,
            cameraModel: info.cameraModel,
            latitude: info.latitude,
            longitude: info.longitude,
            altitude: info.altitude)
    }

    @discardableResult
    public func importFile(at url: URL) throws -> ImportResult {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        let hash = try FileHash.sha256(of: standardized)

        // Hashing already happened outside the transaction; only look at
        // metadata when the bytes are actually new to the library.
        if let existing = try library.photo(withHash: hash), let photoID = existing.id {
            let outcome = try library.dbPool.write { db in
                try Library.addLocation(db, photoID: photoID, path: path).outcome
            }
            return ImportResult(photoID: photoID, isNewPhoto: false, location: outcome,
                                path: path)
        }

        let metadata = try probe(standardized)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let byteSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0

        return try library.dbPool.write { db in
            // Another writer may have inserted these bytes since the read above.
            if let existing = try Photo.filter(Column("hash") == hash).fetchOne(db),
               let photoID = existing.id {
                let outcome = try Library.addLocation(db, photoID: photoID, path: path).outcome
                return ImportResult(photoID: photoID, isNewPhoto: false, location: outcome,
                                    path: path)
            }

            var cameraID: Int64?
            let make = metadata.cameraMake?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let model = metadata.cameraModel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !make.isEmpty, !model.isEmpty {
                cameraID = try Library.findOrCreateCamera(db, make: make, model: model).id
            }

            var photo = Photo(
                hash: hash,
                byteSize: byteSize,
                originalName: standardized.lastPathComponent,
                importedAt: Date(),
                capturedAt: metadata.capturedAt,
                cameraId: cameraID,
                width: metadata.width,
                height: metadata.height,
                latitude: metadata.latitude,
                longitude: metadata.longitude,
                altitude: metadata.altitude,
                color: .unlabeled)
            try photo.insert(db)
            let photoID = photo.id!
            let outcome = try Library.addLocation(db, photoID: photoID, path: path).outcome
            return ImportResult(photoID: photoID, isNewPhoto: true, location: outcome,
                                path: path)
        }
    }

    /// Imports every RAW file in a directory, skipping anything else.
    ///
    /// Files that fail to import (unreadable, undecodable) are skipped rather
    /// than aborting the run.
    @discardableResult
    public func importDirectory(at url: URL, recursive: Bool = true) throws -> [ImportResult] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw LibraryError.notADirectory(url) }

        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
            options: options)
        else { return [] }

        var results: [ImportResult] = []
        for case let file as URL in enumerator {
            guard Importer.isRAW(file) else { continue }
            if let result = try? importFile(at: file) { results.append(result) }
        }
        return results
    }

    /// `UTType.dng` needs macOS 15; the package deploys to 14.
    private static let dng = UTType("com.adobe.raw-image")

    /// Camera RAW by content type, with DNG called out because it is what this
    /// project actually shoots.
    public static func isRAW(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
        else { return false }
        if type.conforms(to: .rawImage) { return true }
        if let dng = Importer.dng, type.conforms(to: dng) { return true }
        return false
    }
}
