import CoreGraphics
import Foundation
import XCTest
@testable import GrayroomCore

final class EmbeddedPreviewTests: XCTestCase {
    private func requireDNG() throws -> URL {
        guard let url = testDataURL("L1000003.DNG") else {
            throw XCTSkip("testdata/L1000003.DNG not present (set GRAYROOM_TEST_DNG to override)")
        }
        return url
    }

    func testThumbnailFitsTheRequestedBox() throws {
        let url = try requireDNG()
        let image = try XCTUnwrap(EmbeddedPreview.thumbnail(url: url, maxPixelSize: 256))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 256)
        XCTAssertGreaterThan(min(image.width, image.height), 0)
    }

    func testThumbnailHonoursTheRequestedSize() throws {
        let url = try requireDNG()
        let small = try XCTUnwrap(EmbeddedPreview.thumbnail(url: url, maxPixelSize: 96))
        let large = try XCTUnwrap(EmbeddedPreview.thumbnail(url: url, maxPixelSize: 512))
        XCTAssertLessThanOrEqual(max(small.width, small.height), 96)
        XCTAssertLessThanOrEqual(max(large.width, large.height), 512)
        XCTAssertGreaterThan(max(large.width, large.height), max(small.width, small.height))
    }

    /// `kCGImageSourceCreateThumbnailWithTransform` is what keeps a portrait
    /// frame from arriving on its side, so the thumbnail's aspect ratio has to
    /// match the *oriented* size the decoder reports, not the sensor's.
    func testThumbnailIsOrientedLikeTheDecodedImage() throws {
        let url = try requireDNG()
        let image = try XCTUnwrap(EmbeddedPreview.thumbnail(url: url, maxPixelSize: 256))
        let info = try ImageDecoder.probe(url: url)
        let thumbRatio = Double(image.width) / Double(image.height)
        let orientedRatio = info.orientedSize.width / info.orientedSize.height
        XCTAssertEqual(thumbRatio, orientedRatio, accuracy: 0.05)
    }

    func testCaptureDateMatchesTheFullProbe() throws {
        let url = try requireDNG()
        let cheap = try XCTUnwrap(ImageDecoder.captureDate(url: url))
        let full = try XCTUnwrap(ImageDecoder.probe(url: url).capturedAt)
        XCTAssertEqual(cheap.timeIntervalSince1970, full.timeIntervalSince1970, accuracy: 1)
    }

    func testMissingFileReturnsNil() {
        let url = URL(fileURLWithPath: "/nowhere/nothing.DNG")
        XCTAssertNil(EmbeddedPreview.thumbnail(url: url, maxPixelSize: 256))
        XCTAssertNil(ImageDecoder.captureDate(url: url))
    }

    /// Non-image bytes: ImageIO opens the source but has nothing to make a
    /// thumbnail from, and the `FromImageAlways` retry must not crash on that.
    func testGarbageBytesReturnNil() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grayroom-preview-\(UUID().uuidString).dng")
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(EmbeddedPreview.thumbnail(url: url, maxPixelSize: 256))
    }
}
