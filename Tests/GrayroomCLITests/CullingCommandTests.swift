import CoreGraphics
import Foundation
import GrayroomLibrary
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GrayroomCLI

/// `analyze`, `similar` and `duplicates`, plus the score `ls` and `show` print.
///
/// The photos are real images written by ImageIO, because these commands run
/// real Vision over them. The near-duplicate pair is the same pixels written
/// twice, as a JPEG and as a PNG: different bytes, so two photos, and the same
/// picture, so a distance near zero.
final class CullingCommandTests: XCTestCase {
    private var temp: TempLibrary!
    private var library: Library { temp.library }

    override func setUpWithError() throws {
        try XCTSkipUnless(PhotoAnalyzer.isAvailable, "Vision needs macOS 15")
        temp = try TempLibrary()
    }

    override func tearDown() {
        temp?.tearDown()
        temp = nil
    }

    /// Two pictures Vision can tell apart: a smooth diagonal ramp and a fine
    /// checkerboard. Seeds of one pattern are *not* enough — a gradient at two
    /// offsets is the same picture as far as a feature print is concerned.
    private enum Pattern {
        case ramp
        case checker

        func pixel(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> (UInt8, UInt8, UInt8) {
            switch self {
            case .ramp:
                let v = UInt8((x + y) * 255 / max(width + height - 2, 1))
                return (v, UInt8(255 - Int(v)), 128)
            case .checker:
                let on = ((x / 8) + (y / 8)) % 2 == 0
                return on ? (255, 255, 255) : (0, 0, 32)
            }
        }
    }

    /// A photo imported with no analysis, so `analyze` has something to do.
    @discardableResult
    private func unanalysedPhoto(_ name: String, type: UTType = .jpeg,
                                 pattern: Pattern = .ramp) throws -> Int64 {
        let url = try write(name, type: type, pattern: pattern)
        let importer = Importer(library: library, probe: { _ in PhotoMetadata() },
                                analyze: { _ in nil })
        return try importer.importFile(at: url).photoID
    }

    private func write(_ name: String, type: UTType, pattern: Pattern) throws -> URL {
        let (width, height) = (160, 120)
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pattern.pixel(x, y, width, height)
                let i = (y * width + x) * 4
                bytes[i] = r
                bytes[i + 1] = g
                bytes[i + 2] = b
            }
        }
        let url = temp.directory.appendingPathComponent(name)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGBitmapInfo(
                                rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// The same picture in two containers, and one that looks like neither.
    private func analysedTrio() throws -> (jpeg: Int64, png: Int64, other: Int64) {
        let jpeg = try unanalysedPhoto("twin.jpg")
        let png = try unanalysedPhoto("twin.png", type: .png)
        let other = try unanalysedPhoto("other.jpg", pattern: .checker)
        try temp.run(["analyze"])
        return (jpeg, png, other)
    }

    // MARK: - analyze

    func testAnalyzeScoresEveryPhotoAndFingerprintsIt() throws {
        let id = try unanalysedPhoto("a.jpg")
        XCTAssertEqual(try library.photoIDsMissingAnalysis(), [id])

        let output = try temp.run(["analyze"])

        let analysis = try XCTUnwrap(try library.analysis(photoID: id))
        XCTAssertFalse(analysis.featurePrint.isEmpty)
        XCTAssertGreaterThanOrEqual(analysis.aestheticScore, -1)
        XCTAssertLessThanOrEqual(analysis.aestheticScore, 1)
        XCTAssertEqual(try library.photoIDsMissingAnalysis(), [])
        XCTAssertTrue(output.lines[0].hasPrefix("1/1  \(id)  "), output.lines[0])
        XCTAssertTrue(output.stderr.contains("analysed 1 photo(s)"), output.stderr)
    }

    func testAnalyzeMissingLeavesAnalysedPhotosAlone() throws {
        let done = try unanalysedPhoto("done.jpg")
        try library.setAnalysis(photoID: done,
                                PhotoAnalysis(aestheticScore: 0.5, featurePrint: Data([1, 2])))
        let todo = try unanalysedPhoto("todo.jpg", pattern: .checker)

        let output = try temp.run(["analyze", "--missing"])

        XCTAssertEqual(try library.analysis(photoID: done)?.featurePrint, Data([1, 2]),
                       "the hand-written analysis was not recomputed")
        XCTAssertNotNil(try library.analysis(photoID: todo))
        XCTAssertEqual(output.lines.count, 1, output.stdout)
    }

    func testAnalyzeTakesNamedPhotos() throws {
        let one = try unanalysedPhoto("one.jpg")
        try unanalysedPhoto("two.jpg", pattern: .checker)

        try temp.run(["analyze", String(one)])

        XCTAssertNotNil(try library.analysis(photoID: one))
        XCTAssertEqual(try library.photoIDsMissingAnalysis().count, 1)
    }

    func testAnalyzeReportsAPhotoWithNoFile() throws {
        let id = try unanalysedPhoto("gone.jpg")
        for location in try library.locations(for: id) {
            try library.removeLocation(id: XCTUnwrap(location.id))
        }

        let output = try temp.run(["analyze"])

        XCTAssertTrue(output.stderr.contains("skipped (no file)"), output.stderr)
        XCTAssertTrue(output.stderr.contains("analysed 0 photo(s), 1 skipped"), output.stderr)
    }

    // MARK: - similar

    func testSimilarFindsTheTwinAndNotTheStranger() throws {
        let trio = try analysedTrio()

        let output = try temp.run(["similar", String(trio.jpeg)])

        XCTAssertEqual(output.lines.count, 1, output.stdout)
        let fields = output.lines[0].components(separatedBy: "  ")
        XCTAssertEqual(fields[1], String(trio.png))
        XCTAssertLessThan(try XCTUnwrap(Double(fields[0])),
                          PhotoAnalyzer.defaultSimilarityThreshold)
        XCTAssertFalse(output.stdout.contains("other.jpg"), output.stdout)
        XCTAssertTrue(output.stderr.contains("1 photo(s) within"), output.stderr)
    }

    func testSimilarObeysTheThresholdAndTheLimit() throws {
        let trio = try analysedTrio()

        XCTAssertTrue(try temp.run(["similar", String(trio.jpeg), "--threshold", "0"])
            .lines.isEmpty, "nothing is bit-identical to anything else")
        XCTAssertEqual(try temp.run(["similar", String(trio.jpeg), "--threshold", "9",
                                     "--limit", "1"]).lines.count, 1)
        XCTAssertEqual(try temp.run(["similar", String(trio.jpeg), "--threshold", "9"])
            .lines.count, 2, "a wide enough net catches the stranger too")
    }

    func testSimilarNeedsAFeaturePrint() throws {
        let id = try unanalysedPhoto("a.jpg")
        temp.assertFails(["similar", String(id)], contains: "has no feature print")
    }

    /// Thrown from `validate()`, so it comes back wrapped as a parse failure
    /// rather than as the `ValidationError` a `run()` failure gives.
    func testSimilarRejectsANegativeThreshold() throws {
        let id = try unanalysedPhoto("a.jpg")
        XCTAssertThrowsError(try temp.run(["similar", String(id), "--threshold=-1"])) { error in
            XCTAssertTrue("\(error)".contains("cannot be negative"), "\(error)")
        }
    }

    // MARK: - duplicates

    func testDuplicatesGroupsTheTwinsAndLeavesTheStrangerOut() throws {
        let trio = try analysedTrio()

        let output = try temp.run(["duplicates"])

        XCTAssertTrue(output.lines[0].hasPrefix("group 1 (2 photos)"), output.lines[0])
        XCTAssertTrue(output.stdout.contains("twin.jpg"), output.stdout)
        XCTAssertTrue(output.stdout.contains("twin.png"), output.stdout)
        XCTAssertFalse(output.stdout.contains("other.jpg"), output.stdout)
        XCTAssertTrue(output.stderr.contains("1 group(s), 2 photo(s)"), output.stderr)
        _ = trio
    }

    func testDuplicatesFindsNothingWhenNothingIsClose() throws {
        try unanalysedPhoto("a.jpg")
        try unanalysedPhoto("b.jpg", pattern: .checker)
        try temp.run(["analyze"])

        let output = try temp.run(["duplicates", "--threshold", "0.05"])

        XCTAssertTrue(output.lines.isEmpty, output.stdout)
        XCTAssertTrue(output.stderr.contains("0 group(s)"), output.stderr)
    }

    // MARK: - ls and show

    func testListPrintsTheScoreAndSortsByIt() throws {
        let low = try unanalysedPhoto("low.jpg")
        let high = try unanalysedPhoto("high.jpg", pattern: .checker)
        try library.setAnalysis(photoID: low,
                                PhotoAnalysis(aestheticScore: -0.25, featurePrint: Data([1])))
        try library.setAnalysis(photoID: high,
                                PhotoAnalysis(aestheticScore: 0.75, featurePrint: Data([2])))
        let unscored = try unanalysedPhoto("unscored.jpg", type: .png, pattern: .checker)

        let scored = try temp.run(["ls", "--sort", "score"])
        XCTAssertEqual(scored.lines.map { $0.components(separatedBy: "  ")[0] },
                       [String(high), String(low), String(unscored)],
                       "best first, unscored last")
        XCTAssertEqual(scored.lines[0].components(separatedBy: "  ")[3], "+0.75")
        XCTAssertEqual(scored.lines[2].components(separatedBy: "  ")[3], "-")

        let named = try temp.run(["ls", "--sort", "name"])
        XCTAssertEqual(named.lines.map { $0.components(separatedBy: "  ")[0] },
                       [String(high), String(low), String(unscored)])
    }

    func testShowPrintsTheScore() throws {
        let id = try unanalysedPhoto("a.jpg")
        try library.setAnalysis(photoID: id,
                                PhotoAnalysis(aestheticScore: -0.5, featurePrint: Data([1])))

        let output = try temp.run(["show", String(id)])

        XCTAssertTrue(output.stdout.contains("score:         -0.50"), output.stdout)
    }

    func testShowPrintsADashWithoutAScore() throws {
        let id = try unanalysedPhoto("a.jpg")
        let output = try temp.run(["show", String(id)])
        XCTAssertTrue(output.stdout.contains("score:         -\n"), output.stdout)
    }
}
