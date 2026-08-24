import ArgumentParser
import CoreGraphics
import Foundation
import GRDB
import GrayroomCore
import GrayroomLibrary
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GrayroomCLI

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

    /// A real, ImageIO-written image in the sandbox. The CLI's `import`,
    /// `probe` and `render` all go through the *production* decoder, so their
    /// tests cannot feed them arbitrary bytes.
    ///
    /// The pixels are a deterministic gradient, so two files of different sizes
    /// never collide on content hash and the render tests have something with
    /// structure in it.
    @discardableResult
    func writeImage(_ name: String, width: Int = 32, height: Int = 24,
                    type: UTType = .jpeg, seed: Int = 0) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8((x * 255 / max(width - 1, 1) + seed) % 256)
                bytes[i + 1] = UInt8((y * 255 / max(height - 1, 1) + seed) % 256)
                bytes[i + 2] = UInt8(((x + y) * 127 / max(width + height - 2, 1) + seed) % 256)
                bytes[i + 3] = 255
            }
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

    /// The whole argv, with `--library` already pointed at this sandbox.
    ///
    /// Every test goes through this rather than `runGrayroom` directly: a
    /// command run without `--library` would resolve `$GRAYROOM_LIBRARY` or the
    /// real one under Application Support.
    @discardableResult
    func run(_ args: [String]) throws -> CommandOutput {
        try runGrayroom(args + ["--library", library.url.path])
    }

    /// The same, asserting that it fails with a message containing `message`.
    func assertFails(_ args: [String], contains message: String,
                     file: StaticString = #filePath, line: UInt = #line) {
        assertCommandFails(args + ["--library", library.url.path], contains: message,
                           file: file, line: line)
    }
}

// MARK: - Running a command line

/// What a command wrote.
struct CommandOutput {
    var stdout: String
    var stderr: String

    /// stdout split into non-empty lines — every list-shaped command prints one
    /// record per line.
    var lines: [String] {
        stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}

/// Parses and runs a full `grayroom` command line, capturing what it printed.
///
/// The commands write with `print` / `FileHandle.standardError`, so the capture
/// is done where they actually write: file descriptors 1 and 2 are pointed at
/// temporary files for the duration. Anything the command threw is rethrown
/// *after* the descriptors are back, so a failing test still reports properly.
@discardableResult
func runGrayroom(_ args: [String]) throws -> CommandOutput {
    var command = try Grayroom.parseAsRoot(args)

    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    let outURL = dir.appendingPathComponent("grayroom-stdout-\(UUID().uuidString)")
    let errURL = dir.appendingPathComponent("grayroom-stderr-\(UUID().uuidString)")
    defer {
        try? FileManager.default.removeItem(at: outURL)
        try? FileManager.default.removeItem(at: errURL)
    }
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)

    let outFD = open(outURL.path, O_WRONLY)
    let errFD = open(errURL.path, O_WRONLY)
    guard outFD >= 0, errFD >= 0 else {
        throw XCTSkip("could not open capture files")
    }
    fflush(stdout)
    fflush(stderr)
    let savedOut = dup(1)
    let savedErr = dup(2)
    dup2(outFD, 1)
    dup2(errFD, 2)

    var thrown: Error?
    do { try command.run() } catch { thrown = error }

    fflush(stdout)
    fflush(stderr)
    dup2(savedOut, 1)
    dup2(savedErr, 2)
    close(savedOut)
    close(savedErr)
    close(outFD)
    close(errFD)

    if let thrown { throw thrown }
    return CommandOutput(
        stdout: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
        stderr: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
}

/// Asserts that running `args` fails with a message containing `message`.
///
/// Every user-facing CLI failure is a `ValidationError`, which is what makes the
/// binary print a usage error rather than a Swift error dump, so the type is
/// asserted as well as the text.
func assertCommandFails(_ args: [String], contains message: String,
                        file: StaticString = #filePath, line: UInt = #line) {
    do {
        _ = try runGrayroom(args)
        XCTFail("expected a failure containing '\(message)'", file: file, line: line)
    } catch let error as ValidationError {
        XCTAssertTrue(error.message.contains(message),
                      "'\(error.message)' does not contain '\(message)'", file: file, line: line)
    } catch {
        XCTFail("expected a ValidationError, got \(error)", file: file, line: line)
    }
}

/// Skips the test when this machine has no usable GPU.
func requireRenderer(file: StaticString = #filePath, line: UInt = #line) throws {
    guard (try? Renderer()) != nil else {
        throw XCTSkip("no Metal device / shader compilation failed")
    }
}

/// A file from the gitignored `testdata/` directory, when there is one.
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

/// An `EditState` that is recognisably not the default.
func distinctiveEdit(exposure: Double) -> EditState {
    var edit = EditState()
    edit.tone.exposure = exposure
    edit.clarity = 21
    return edit
}
