import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GrayroomCore

/// The EXIF/GPS reading that turns a file into a library row. It is pure
/// dictionary arithmetic, so it is tested against the dictionaries directly
/// rather than against files that happen to carry the right tags.
final class DecodeMetadataTests: XCTestCase {

    private func gps(_ pairs: [CFString: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in pairs { out[k as String] = v }
        return out
    }

    // MARK: - GPS

    /// EXIF stores the magnitude and the hemisphere separately. Dropping the
    /// reference would put every southern/western frame on the wrong side of
    /// the planet.
    func testSouthAndWestAreNegated() {
        let north = ImageDecoder.gpsPosition(gps: gps([
            kCGImagePropertyGPSLatitude: 48.2 as NSNumber,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 16.37 as NSNumber,
            kCGImagePropertyGPSLongitudeRef: "E",
        ]))
        XCTAssertEqual(north.0!, 48.2, accuracy: 1e-9)
        XCTAssertEqual(north.1!, 16.37, accuracy: 1e-9)

        let south = ImageDecoder.gpsPosition(gps: gps([
            kCGImagePropertyGPSLatitude: 33.87 as NSNumber,
            kCGImagePropertyGPSLatitudeRef: "s",
            kCGImagePropertyGPSLongitude: 70.66 as NSNumber,
            kCGImagePropertyGPSLongitudeRef: "w",
        ]))
        XCTAssertEqual(south.0!, -33.87, accuracy: 1e-9, "the reference is case-insensitive")
        XCTAssertEqual(south.1!, -70.66, accuracy: 1e-9)
    }

    /// Altitude reference 1 means "below sea level".
    func testAltitudeReferenceOneIsBelowSeaLevel() {
        let above = ImageDecoder.gpsPosition(gps: gps([
            kCGImagePropertyGPSAltitude: 512.5 as NSNumber,
            kCGImagePropertyGPSAltitudeRef: 0 as NSNumber,
        ]))
        XCTAssertEqual(above.2!, 512.5, accuracy: 1e-9)

        let below = ImageDecoder.gpsPosition(gps: gps([
            kCGImagePropertyGPSAltitude: 3.25 as NSNumber,
            kCGImagePropertyGPSAltitudeRef: 1 as NSNumber,
        ]))
        XCTAssertEqual(below.2!, -3.25, accuracy: 1e-9)

        // No reference at all: taken as given rather than dropped.
        let bare = ImageDecoder.gpsPosition(gps: gps([
            kCGImagePropertyGPSAltitude: 7.0 as NSNumber,
        ]))
        XCTAssertEqual(bare.2!, 7.0, accuracy: 1e-9)
    }

    func testNoGPSDictionaryIsAllNil() {
        let (lat, lon, alt) = ImageDecoder.gpsPosition(gps: nil)
        XCTAssertNil(lat)
        XCTAssertNil(lon)
        XCTAssertNil(alt)
    }

    /// A dictionary with a reference but no coordinate stays nil rather than
    /// becoming a negative zero.
    func testAReferenceWithoutACoordinateStaysNil() {
        let (lat, lon, _) = ImageDecoder.gpsPosition(gps: gps([
            kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitudeRef: "W",
        ]))
        XCTAssertNil(lat)
        XCTAssertNil(lon)
    }

    // MARK: - Capture date

    func testUTCOffsetParsing() {
        XCTAssertEqual(ImageDecoder.utcOffsetSeconds("+02:00"), 7200)
        XCTAssertEqual(ImageDecoder.utcOffsetSeconds("-05:30"), -19800)
        XCTAssertEqual(ImageDecoder.utcOffsetSeconds("+00:00"), 0)
        XCTAssertEqual(ImageDecoder.utcOffsetSeconds("Z"), 0)
        XCTAssertEqual(ImageDecoder.utcOffsetSeconds("z"), 0)
        XCTAssertEqual(ImageDecoder.utcOffsetSeconds("  +01:00  "), 3600)

        for bad in ["02:00", "+0200", "+2", "", "+aa:bb", "+02:00:00"] {
            XCTAssertNil(ImageDecoder.utcOffsetSeconds(bad), bad)
        }
    }

    /// The offset is what makes the same wall-clock stamp a different instant.
    func testTheOffsetTagDecidesTheInstant() throws {
        let stamp = "2024:07:04 12:00:00"
        func date(offset: String?) -> Date? {
            var exif: [String: Any] = [
                kCGImagePropertyExifDateTimeOriginal as String: stamp,
            ]
            if let offset {
                exif[kCGImagePropertyExifOffsetTimeOriginal as String] = offset
            }
            return ImageDecoder.captureDate(exif: exif)
        }

        let utc = try XCTUnwrap(date(offset: "+00:00"))
        let east = try XCTUnwrap(date(offset: "+02:00"))
        XCTAssertEqual(east.timeIntervalSince(utc), -7200, accuracy: 0.5,
                       "noon at +02:00 is two hours earlier in UTC than noon at UTC")

        // No offset tag: the local zone, whatever it is here.
        let local = try XCTUnwrap(date(offset: nil))
        let expected = TimeInterval(-TimeZone.current.secondsFromGMT(for: utc))
        XCTAssertEqual(local.timeIntervalSince(utc), expected, accuracy: 1.0)

        // An unparseable offset falls back to local rather than failing.
        XCTAssertEqual(try XCTUnwrap(date(offset: "nonsense")), local)
    }

    func testNoDateTimeOriginalIsNoDate() {
        XCTAssertNil(ImageDecoder.captureDate(exif: nil))
        XCTAssertNil(ImageDecoder.captureDate(exif: [:]))
        XCTAssertNil(ImageDecoder.captureDate(exif: [
            kCGImagePropertyExifDateTimeOriginal as String: "not a date",
        ]))
    }

    func testCaptureDateOfAFileWithoutOneIsNil() throws {
        let url = try SyntheticImage.write(patches: [0, 128, 255], to: "nodate.png", type: .png)
        XCTAssertNil(ImageDecoder.captureDate(url: url))
        XCTAssertNil(ImageDecoder.captureDate(url: URL(fileURLWithPath: "/nope/missing.jpg")))
    }

    // MARK: - Format predicate

    /// The predicate is not just the hand-written list: a still format this OS
    /// build's ImageIO can read is openable even though the product decision
    /// never named it. That fallback is what keeps the import scanner from
    /// silently skipping a file the decoder would have opened.
    func testAFormatOnlyImageIOKnowsIsStillSupported() {
        func url(_ name: String) -> URL { URL(fileURLWithPath: "/photos/\(name)") }
        // BMP is readable by every ImageIO build and is on neither the
        // explicitly-supported list nor the exclusion list.
        XCTAssertTrue(ImageFormat.isSupported(url("a.bmp")))
        XCTAssertFalse(ImageFormat.isRAW(url("a.bmp")))
    }

    /// An extension the system has never heard of resolves to a *dynamic* type
    /// rather than to nothing, so the predicate has to reject it on "does not
    /// conform to `.image`" rather than on "has no type".
    func testAnUnknownExtensionIsNotSupported() throws {
        let url = URL(fileURLWithPath: "/photos/a.qqzz")
        let type = try XCTUnwrap(ImageFormat.contentType(of: url))
        XCTAssertTrue(type.isDynamic)
        XCTAssertFalse(type.conforms(to: .image))
        XCTAssertFalse(ImageFormat.isSupported(url))
        XCTAssertFalse(ImageFormat.isRAW(url))
    }
}
