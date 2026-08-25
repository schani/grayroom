import CoreGraphics
import Foundation
import XCTest
@testable import GrayroomLibrary

/// The two Vision columns: what they hold, that they survive the database, and
/// the arithmetic that turns them into "these are the same picture".
final class PhotoAnalysisTests: XCTestCase {
    private var temp: TempLibrary!
    private var library: Library { temp.library }

    override func setUpWithError() throws {
        temp = try TempLibrary()
    }

    override func tearDown() {
        temp.tearDown()
        temp = nil
    }

    // MARK: - Vision

    /// A feature print stored and read back is the *same* feature print: the
    /// distance from a print to its round trip is exactly zero, which is what
    /// makes a stored print comparable to one computed a year later.
    func testFeaturePrintRoundTripsThroughItsStoredForm() throws {
        let analysis = try analyze(gradientImage(width: 128, height: 96, seed: 0))
        XCTAssertFalse(analysis.featurePrint.isEmpty)
        XCTAssertEqual(try PhotoAnalyzer.distance(analysis.featurePrint, analysis.featurePrint),
                       0, accuracy: 1e-9)

        let again = try analyze(gradientImage(width: 128, height: 96, seed: 0))
        XCTAssertEqual(try PhotoAnalyzer.distance(analysis.featurePrint, again.featurePrint),
                       0, accuracy: 1e-6, "the same pixels give the same print")
    }

    func testAestheticScoreIsInRange() throws {
        let analysis = try analyze(gradientImage(width: 128, height: 96, seed: 7))
        XCTAssertGreaterThanOrEqual(analysis.aestheticScore, -1)
        XCTAssertLessThanOrEqual(analysis.aestheticScore, 1)
    }

    /// Two different pictures are further apart than a picture is from itself.
    func testDifferentPicturesAreFurtherApartThanIdenticalOnes() throws {
        let a = try analyze(gradientImage(width: 128, height: 96, seed: 0))
        let b = try analyze(noiseImage(width: 128, height: 96))
        XCTAssertGreaterThan(try PhotoAnalyzer.distance(a.featurePrint, b.featurePrint), 0)
    }

    // MARK: - The database

    func testAnalysisIsStoredAndReadBack() throws {
        let id = try stubPhoto("a.dng")
        XCTAssertNil(try library.analysis(photoID: id))
        XCTAssertEqual(try library.photoIDsMissingAnalysis(), [id])

        let analysis = PhotoAnalysis(aestheticScore: 0.25, featurePrint: Data([1, 2, 3]))
        try library.setAnalysis(photoID: id, analysis)

        XCTAssertEqual(try library.analysis(photoID: id), analysis)
        XCTAssertEqual(try library.photo(id: id)?.aestheticScore, 0.25)
        XCTAssertEqual(try library.photoIDsMissingAnalysis(), [])
    }

    func testClearingAnAnalysisPutsThePhotoBackInTheMissingList() throws {
        let id = try stubPhoto("a.dng")
        try library.setAnalysis(photoID: id,
                                PhotoAnalysis(aestheticScore: 0.5, featurePrint: Data([9])))
        try library.setAnalysis(photoID: id, nil)
        XCTAssertNil(try library.analysis(photoID: id))
        XCTAssertEqual(try library.photoIDsMissingAnalysis(), [id])
    }

    func testSettingAnAnalysisOnAMissingPhotoThrows() throws {
        XCTAssertThrowsError(try library.setAnalysis(
            photoID: 4711, PhotoAnalysis(aestheticScore: 0, featurePrint: Data())))
    }

    /// The feature print is deliberately not on the `Photo` record — it is
    /// kilobytes a row and the catalogue reads every row.
    func testTheCatalogSnapshotDoesNotCarryFeaturePrints() throws {
        let id = try stubPhoto("a.dng")
        try library.setAnalysis(photoID: id,
                                PhotoAnalysis(aestheticScore: -0.5,
                                              featurePrint: Data(repeating: 7, count: 4096)))
        let snapshot = try library.catalogSnapshot()
        XCTAssertEqual(snapshot.photos.first?.aestheticScore, -0.5)
        XCTAssertEqual(try library.featurePrintIndex().featurePrint(of: id)?.count, 4096,
                       "the print is still there — it is just not in the snapshot")
    }

    // MARK: - The importer

    func testImportComputesTheAnalysis() throws {
        let url = try temp.writeFile("a.dng", Data("a".utf8))
        let analysis = PhotoAnalysis(aestheticScore: 0.75, featurePrint: Data([4, 5, 6]))
        let importer = Importer(library: library, probe: stubProbe(), analyze: { _ in analysis })

        let id = try importer.importFile(at: url).photoID

        XCTAssertEqual(try library.analysis(photoID: id), analysis)
        XCTAssertEqual(try library.photo(id: id)?.aestheticScore, 0.75)
    }

    /// A file Vision cannot be run on is still imported; it simply has no score.
    func testImportWithoutAnAnalysisStillMakesThePhoto() throws {
        let url = try temp.writeFile("a.dng", Data("a".utf8))
        let importer = Importer(library: library, probe: stubProbe(), analyze: { _ in nil })

        let id = try importer.importFile(at: url).photoID

        XCTAssertNil(try library.analysis(photoID: id))
        XCTAssertEqual(try library.photoIDsMissingAnalysis(), [id])
    }

    /// Real files, real Vision, through the production importer.
    func testImportOfARealImageScoresIt() throws {
        let url = try temp.writeJPEG("real.jpg", width: 160, height: 120)
        let importer = Importer(library: library, probe: stubProbe())

        let id = try importer.importFile(at: url).photoID

        let analysis = try XCTUnwrap(try library.analysis(photoID: id))
        XCTAssertFalse(analysis.featurePrint.isEmpty)
        XCTAssertEqual(try PhotoAnalyzer.distance(analysis.featurePrint, analysis.featurePrint),
                       0, accuracy: 1e-9)
    }

    // MARK: - Nearest neighbours

    /// Threshold, order and limit, with prints whose distances are known
    /// exactly: two photos that share a print are zero apart, a third is not.
    func testNearestRespectsThresholdAndLimit() throws {
        let one = try analyze(gradientImage(width: 128, height: 96, seed: 0)).featurePrint
        let other = try analyze(noiseImage(width: 128, height: 96)).featurePrint
        let index = FeaturePrintIndex([(1, one), (2, one), (3, one), (4, other)])

        let all = try index.nearest(to: 1, threshold: 0)
        XCTAssertEqual(all.map(\.id), [2, 3], "the twins, and not the photo itself")
        XCTAssertEqual(try index.nearest(to: 1, threshold: 0, limit: 1).map(\.id), [2])
        XCTAssertTrue(try index.nearest(to: 4, threshold: 0).isEmpty)
    }

    func testNearestOnAPhotoWithNoPrintThrows() {
        let index = FeaturePrintIndex([])
        XCTAssertThrowsError(try index.nearest(to: 1, threshold: 1))
    }

    func testDuplicateGroupsFindsTheTwinsAndLeavesTheRest() throws {
        let one = try analyze(gradientImage(width: 128, height: 96, seed: 0)).featurePrint
        let other = try analyze(noiseImage(width: 128, height: 96)).featurePrint
        let index = FeaturePrintIndex([(1, one), (2, other), (3, one)])

        XCTAssertEqual(try index.duplicateGroups(threshold: 0), [[1, 3]])
    }

    // MARK: - Single linkage

    /// A and C are one group when both are near B, even though they are far
    /// apart themselves — which is what a burst of frames looks like.
    func testSingleLinkageChainsThroughTheMiddleFrame() throws {
        let distances: [Set<Int64>: Double] = [
            [1, 2]: 0.4, [2, 3]: 0.4, [1, 3]: 0.9,
            [1, 4]: 2.0, [2, 4]: 2.0, [3, 4]: 2.0,
        ]
        let groups = try FeaturePrintIndex.singleLinkageGroups([1, 2, 3, 4], threshold: 0.5) {
            distances[[$0, $1]] ?? .infinity
        }
        XCTAssertEqual(groups, [[1, 2, 3]])
    }

    func testSingleLinkageDropsLonePhotosAndOrdersGroups() throws {
        let distances: [Set<Int64>: Double] = [[3, 4]: 0.1, [1, 2]: 0.1]
        let groups = try FeaturePrintIndex.singleLinkageGroups([4, 3, 2, 1], threshold: 0.5) {
            distances[[$0, $1]] ?? 9
        }
        XCTAssertEqual(groups, [[1, 2], [3, 4]], "sorted inside, and by lowest id between")
    }

    func testSingleLinkageOfNothingIsNothing() throws {
        XCTAssertEqual(try FeaturePrintIndex.singleLinkageGroups([], threshold: 1) { _, _ in 0 },
                       [])
    }

    // MARK: - Sorting

    func testPhotosCanBeSortedByNameAndByScore() throws {
        let b = try stubPhoto("b.dng")
        let a = try stubPhoto("a.dng")
        let c = try stubPhoto("c.dng")
        try library.setAnalysis(photoID: a,
                                PhotoAnalysis(aestheticScore: -0.5, featurePrint: Data([1])))
        try library.setAnalysis(photoID: b,
                                PhotoAnalysis(aestheticScore: 0.9, featurePrint: Data([2])))

        XCTAssertEqual(try library.photos(sort: .fileName).map(\.id), [a, b, c])
        XCTAssertEqual(try library.photos(sort: .fileName, ascending: false).map(\.id), [c, b, a])
        XCTAssertEqual(try library.photos(sort: .aestheticScore).map(\.id), [a, b, c],
                       "worst first, and the unscored photo last either way")
        XCTAssertEqual(try library.photos(sort: .aestheticScore, ascending: false).map(\.id),
                       [b, a, c])
    }

    // MARK: - Helpers

    private func analyze(_ image: CGImage) throws -> PhotoAnalysis {
        try PhotoAnalyzer.analyze(image: image)
    }

    @discardableResult
    private func stubPhoto(_ name: String) throws -> Int64 {
        let url = try temp.writeFile(name, Data(name.utf8))
        return try Importer(library: library, probe: stubProbe(), analyze: { _ in nil })
            .importFile(at: url).photoID
    }

    private func gradientImage(width: Int, height: Int, seed: Int) -> CGImage {
        image(width: width, height: height) { x, y in
            (UInt8((x * 255 / max(width - 1, 1) + seed) % 256),
             UInt8((y * 255 / max(height - 1, 1) + seed) % 256),
             UInt8(((x + y) * 127 / max(width + height - 2, 1) + seed) % 256))
        }
    }

    private func noiseImage(width: Int, height: Int) -> CGImage {
        image(width: width, height: height) { x, y in
            let v = UInt8((x &* 71 &+ y &* 173) % 256)
            return (v, UInt8(255 - Int(v)), UInt8((Int(v) &* 3) % 256))
        }
    }

    private func image(width: Int, height: Int,
                       pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r
                bytes[i + 1] = g
                bytes[i + 2] = b
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }
}
