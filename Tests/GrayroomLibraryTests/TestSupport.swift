import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
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

    /// A real, ImageIO-written image in the sandbox — the importer's default
    /// probe actually decodes these, so they cannot be made of arbitrary bytes
    /// the way the RAW-stub tests' files are.
    @discardableResult
    func writeJPEG(_ name: String, width: Int, height: Int,
                   type: UTType = .jpeg) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            // A gradient, so the encoder has something to chew on and two files
            // of different sizes never collide on content hash.
            let value = UInt8((i * 251) % 256)
            bytes[i * 4] = value
            bytes[i * 4 + 1] = value
            bytes[i * 4 + 2] = value
            bytes[i * 4 + 3] = 255
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: space, bitmapInfo: info,
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil)
        else { throw XCTSkip("ImageIO cannot write \(type.identifier)") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("ImageIO could not finalize \(type.identifier)")
        }
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
