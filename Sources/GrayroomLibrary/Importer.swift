import Foundation
import GRDB
import GrayroomCore

/// What the importer needs to know about a file beyond its bytes.
public struct PhotoMetadata: Equatable, Sendable {
    public var width: Int?
    public var height: Int?
    public var capturedAt: Date?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensMake: String?
    public var lensModel: String?
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?

    public init(
        width: Int? = nil,
        height: Int? = nil,
        capturedAt: Date? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensMake: String? = nil,
        lensModel: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitude: Double? = nil
    ) {
        self.width = width
        self.height = height
        self.capturedAt = capturedAt
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensMake = lensMake
        self.lensModel = lensModel
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

/// Finding the importable images under a directory, without touching the
/// library.
///
/// Split out of `Importer` because the import window has to show the user what
/// it found *before* anything is imported — scanning is a question about the
/// filesystem, importing is a change to the library, and only the second one
/// needs a `Library`.
public enum ImportScanner {
    /// Every importable image under `directory`, sorted by path.
    ///
    /// - Throws: `LibraryError.notADirectory` when `directory` is not one.
    public static func scan(directory: URL, recursive: Bool) throws -> [URL] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { throw LibraryError.notADirectory(directory) }

        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentTypeKey],
            options: options)
        else { return [] }

        var urls: [URL] = []
        for case let file as URL in enumerator where Importer.isSupportedImage(file) {
            urls.append(file.standardizedFileURL)
        }
        return urls.sorted { $0.path < $1.path }
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
    /// The culling aids, computed at import. `nil` for a file Vision could not
    /// be run on — one unscored frame is not a reason to refuse the import.
    public typealias Analyzer = (URL) -> PhotoAnalysis?

    public let library: Library
    private let probe: MetadataProbe
    private let analyzer: Analyzer

    public init(library: Library, probe: @escaping MetadataProbe = Importer.probeRAW,
                analyze: @escaping Analyzer = Importer.analyzePreview) {
        self.library = library
        self.probe = probe
        self.analyzer = analyze
    }

    /// The real probe: CIRAWFilter (RAW) or ImageIO (everything else), no GPU
    /// work.
    public static func probeRAW(_ url: URL) throws -> PhotoMetadata {
        let info = try ImageDecoder.probe(url: url)
        return PhotoMetadata(
            width: Int(info.orientedSize.width.rounded()),
            height: Int(info.orientedSize.height.rounded()),
            capturedAt: info.capturedAt,
            cameraMake: info.cameraMake,
            cameraModel: info.cameraModel,
            lensMake: info.lensMake,
            lensModel: info.lensModel,
            latitude: info.latitude,
            longitude: info.longitude,
            altitude: info.altitude)
    }

    /// - Parameter precomputedHash: the file's SHA-256, hex, when the caller
    ///   already has it. The import window's scan hashes every file to decide
    ///   what is new, and hashing 200 frames a second time would double the
    ///   slowest part of the whole operation. The caller is asserting the bytes
    ///   have not changed since it looked.
    @discardableResult
    public func importFile(at url: URL, precomputedHash: String? = nil) throws -> ImportResult {
        let standardized = url.standardizedFileURL
        let path = standardized.path
        let hash = try precomputedHash.flatMap(FileHash.data(fromHexString:))
            ?? FileHash.sha256(of: standardized)

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
        // Outside the transaction: a 512 px decode plus one Vision pass,
        // measured at about 47 ms a frame, and a write transaction is not the
        // place to spend that.
        let analysis = analyzer(standardized)
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

            // A lens needs only its model: the make is often missing on
            // adapted and manual glass, and the model alone is still the one
            // thing the file says about what the picture was taken through.
            var lensID: Int64?
            let lensMake = metadata.lensMake?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let lensModel = metadata.lensModel?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !lensModel.isEmpty {
                lensID = try Library.findOrCreateLens(db, make: lensMake, model: lensModel).id
            }

            var photo = Photo(
                hash: hash,
                byteSize: byteSize,
                originalName: standardized.lastPathComponent,
                importedAt: Date(),
                capturedAt: metadata.capturedAt,
                cameraId: cameraID,
                lensId: lensID,
                width: metadata.width,
                height: metadata.height,
                latitude: metadata.latitude,
                longitude: metadata.longitude,
                altitude: metadata.altitude,
                color: .unlabeled,
                aestheticScore: analysis?.aestheticScore)
            try photo.insert(db)
            let photoID = photo.id!
            if let featurePrint = analysis?.featurePrint {
                try db.execute(sql: "UPDATE photos SET feature_print = ? WHERE id = ?",
                               arguments: [featurePrint, photoID])
            }
            let outcome = try Library.addLocation(db, photoID: photoID, path: path).outcome
            return ImportResult(photoID: photoID, isNewPhoto: true, location: outcome,
                                path: path)
        }
    }

    /// Imports a list of files one at a time.
    ///
    /// A file that fails is reported through `progress` and skipped — one
    /// unreadable frame does not abandon the other 199. `precomputedHashes` is
    /// keyed by standardized URL and lets a caller that has already hashed the
    /// files skip doing it twice. `progress` is called
    /// once per file with `(filesFinished, total, outcome)`, on whatever thread
    /// this runs on; `isCancelled` is consulted before each file, so a
    /// cancelled run stops between files rather than mid-write.
    @discardableResult
    public func importFiles(_ urls: [URL],
                            precomputedHashes: [URL: String] = [:],
                            progress: ((Int, Int, Result<ImportResult, Error>) -> Void)? = nil,
                            isCancelled: () -> Bool = { false }) -> [ImportResult] {
        var results: [ImportResult] = []
        let total = urls.count
        for (index, url) in urls.enumerated() {
            if isCancelled() { break }
            let outcome = Result {
                try importFile(at: url,
                               precomputedHash: precomputedHashes[url.standardizedFileURL])
            }
            if case .success(let result) = outcome { results.append(result) }
            progress?(index + 1, total, outcome)
        }
        return results
    }

    /// Imports every importable image in a directory, skipping anything else.
    ///
    /// Files that fail to import (unreadable, undecodable) are skipped rather
    /// than aborting the run.
    @discardableResult
    public func importDirectory(at url: URL, recursive: Bool = true) throws -> [ImportResult] {
        importFiles(try ImportScanner.scan(directory: url, recursive: recursive))
    }

    /// The default analyzer: Vision over the file's embedded preview, never a
    /// full RAW decode.
    public static func analyzePreview(_ url: URL) -> PhotoAnalysis? {
        try? PhotoAnalyzer.analyze(url: url)
    }

    /// Everything the decoder will open: camera RAW plus the standard still
    /// formats (JPEG, TIFF, PNG, HEIC). The predicate itself lives in
    /// `GrayroomCore` next to the decoder that dispatches on it, so the scanner
    /// and the decoder cannot disagree about what is openable.
    public static func isSupportedImage(_ url: URL) -> Bool {
        ImageFormat.isSupported(url)
    }
}
