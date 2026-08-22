import Foundation
import GrayroomLibrary

/// How a `<photo>` argument on the command line names a photo.
public enum PhotoRefError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case ambiguousPrefix(String, [String])
    case fileNotInLibrary(String)

    public var description: String {
        switch self {
        case .notFound(let token):
            return "no photo matches '\(token)' (expected an id, a hash prefix, or a file path)"
        case .ambiguousPrefix(let token, let matches):
            return "hash prefix '\(token)' matches \(matches.count) photos: "
                + matches.joined(separator: ", ")
        case .fileNotInLibrary(let path):
            return "\(path) is not in the library (run `grayroom import` first)"
        }
    }
}

/// Resolves a `<photo>` argument.
///
/// Three spellings, tried in this order:
///
/// 1. an integer that is a photo **id**;
/// 2. an existing **file path**, which is hashed and looked up;
/// 3. a **hash prefix**, which must match exactly one photo.
///
/// The order matters because the spellings overlap: `1234` is both a plausible
/// id and a plausible hash prefix, and ids are what `ls` prints, so they win.
public enum PhotoRef {
    public static func resolve(_ token: String, in library: Library) throws -> Photo {
        if let id = Int64(token), let photo = try library.photo(id: id) {
            return photo
        }

        let asPath = URL(fileURLWithPath: token)
        if FileManager.default.fileExists(atPath: asPath.path),
           !asPath.hasDirectoryPath {
            let hash = try FileHash.sha256(of: asPath)
            guard let photo = try library.photo(withHash: hash) else {
                throw PhotoRefError.fileNotInLibrary(asPath.standardizedFileURL.path)
            }
            return photo
        }

        let matches = try library.photos(withHashPrefix: token)
        switch matches.count {
        case 0: throw PhotoRefError.notFound(token)
        case 1: return matches[0]
        default:
            throw PhotoRefError.ambiguousPrefix(
                token, matches.map { Format.hashPrefix($0) })
        }
    }

    /// The photo's id, which every operation actually needs.
    public static func resolveID(_ token: String, in library: Library) throws -> Int64 {
        let photo = try resolve(token, in: library)
        guard let id = photo.id else { throw PhotoRefError.notFound(token) }
        return id
    }
}
