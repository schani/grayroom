import Foundation
import XCTest
@testable import GrayroomLibrary

/// A throwaway library in `NSTemporaryDirectory()`, torn down with the test.
final class TempLibrary {
    let directory: URL
    let library: Library

    init() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grayroom-library-tests-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        library = try Library(url: directory.appendingPathComponent("library.sqlite"))
    }

    /// Writes `contents` into the sandbox and returns its URL.
    @discardableResult
    func writeFile(_ name: String, _ contents: Data) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url)
        return url
    }

    func tearDown() {
        try? library.close()
        // WAL and SHM files go with the directory.
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A stub probe so importer tests can use arbitrary bytes instead of a RAW file.
func stubProbe(_ metadata: PhotoMetadata = PhotoMetadata()) -> Importer.MetadataProbe {
    { _ in metadata }
}

func testDataURL(_ name: String) -> URL? {
    if let env = ProcessInfo.processInfo.environment["GRAYROOM_TEST_DNG"] {
        let u = URL(fileURLWithPath: env)
        if FileManager.default.fileExists(atPath: u.path) { return u }
    }
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<6 {
        let candidate = dir.appendingPathComponent("testdata").appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}
