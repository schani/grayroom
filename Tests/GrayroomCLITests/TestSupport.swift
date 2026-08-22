import Foundation
import GRDB
import GrayroomCore
import GrayroomLibrary
import XCTest

/// A throwaway library plus a sandbox to put files in.
final class TempLibrary {
    let directory: URL
    let library: Library

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grayroom-cli-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        library = try Library(url: directory.appendingPathComponent("library.sqlite"))
    }

    @discardableResult
    func writeFile(_ name: String, _ contents: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url)
        return url
    }

    /// Imports arbitrary bytes without going anywhere near a RAW decoder.
    @discardableResult
    func importFile(_ url: URL) throws -> Int64 {
        try stubImporter().importFile(at: url).photoID
    }

    func stubImporter() -> Importer {
        Importer(library: library, probe: { _ in PhotoMetadata() })
    }

    /// A photo with a hand-picked hash, for the prefix-matching tests: real
    /// SHA-256 digests of test data never collide on a prefix, so ambiguity has
    /// to be constructed.
    @discardableResult
    func insertPhoto(hashHex: String, name: String = "crafted.dng") throws -> Int64 {
        let hash = FileHash.data(fromHexString: hashHex)!
        return try library.dbPool.write { db in
            var photo = Photo(hash: hash, byteSize: 1, originalName: name)
            try photo.insert(db)
            return photo.id!
        }
    }

    func tearDown() {
        try? library.close()
        try? FileManager.default.removeItem(at: directory)
    }
}

/// An `EditState` that is recognisably not the default.
func distinctiveEdit(exposure: Double) -> EditState {
    var edit = EditState()
    edit.tone.exposure = exposure
    edit.clarity = 21
    return edit
}
