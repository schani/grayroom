import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import GrayroomCore

/// Writes small, exactly-known images with ImageIO so the decode can be checked
/// against arithmetic rather than against another decoder.
enum SyntheticImage {
    static let directory: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grayroom-synthetic-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// One row of 8-bit sRGB patches, one column each, written as `type`.
    ///
    /// The patch values are *encoded* sRGB code values, which is the whole
    /// point: the decoder has to linearize them.
    @discardableResult
    static func write(patches: [UInt8], to name: String, type: UTType,
                      capturedAt: String? = nil, height: Int = 4) throws -> URL {
        let width = patches.count
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = patches[x]
                bytes[i + 1] = patches[x]
                bytes[i + 2] = patches[x]
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
        return try write(image, to: name, type: type, capturedAt: capturedAt)
    }

    /// A 16-bit-per-channel image, for the TIFF round-trip.
    @discardableResult
    static func write16Bit(values: [UInt16], to name: String, type: UTType,
                           height: Int = 2) throws -> URL {
        let width = values.count
        var samples = [UInt16](repeating: 0xFFFF, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                samples[i] = values[x]
                samples[i + 1] = values[x]
                samples[i + 2] = values[x]
                samples[i + 3] = 0xFFFF
            }
        }
        let data = samples.withUnsafeBytes { Data($0) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
            .union(.byteOrder16Little)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                            bytesPerRow: width * 8, space: space, bitmapInfo: info,
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        return try write(image, to: name, type: type, capturedAt: nil)
    }

    private static func write(_ image: CGImage, to name: String, type: UTType,
                              capturedAt: String?) throws -> URL {
        let url = directory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil)
        else { throw XCTSkip("ImageIO cannot write \(type.identifier) here") }
        var properties: [CFString: Any] = [:]
        if let capturedAt {
            properties[kCGImagePropertyExifDictionary] = [
                kCGImagePropertyExifDateTimeOriginal as String: capturedAt,
                kCGImagePropertyExifOffsetTimeOriginal as String: "+00:00",
            ]
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFMake as String: "Grayroom",
                kCGImagePropertyTIFFModel as String: "Synthetic",
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("ImageIO could not finalize \(type.identifier)")
        }
        return url
    }

    /// The sRGB electro-optical transfer function — the arithmetic the decode
    /// is being checked against.
    static func linearize(_ code: UInt8) -> Double {
        let c = Double(code) / 255
        return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
}

final class StandardImageTests: XCTestCase {
    /// Reads a decoded texture back as floats, one row.
    private func readRow(_ texture: MTLTexture, y: Int = 0) -> [(Double, Double, Double)] {
        let width = texture.width
        var halfs = [Float16](repeating: 0, count: width * 4)
        halfs.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!,
                             bytesPerRow: width * 4 * MemoryLayout<Float16>.size,
                             from: MTLRegionMake2D(0, y, width, 1), mipmapLevel: 0)
        }
        return (0..<width).map {
            (Double(halfs[$0 * 4]), Double(halfs[$0 * 4 + 1]), Double(halfs[$0 * 4 + 2]))
        }
    }

    // MARK: - Format predicate

    func testSupportedFormats() throws {
        func url(_ name: String) -> URL { URL(fileURLWithPath: "/photos/\(name)") }
        for name in ["a.jpg", "a.jpeg", "a.tif", "a.tiff", "a.png", "a.heic", "a.heif",
                     "a.DNG", "a.NEF", "a.RAF", "a.IIQ", "a.3FR"] {
            XCTAssertTrue(ImageFormat.isSupported(url(name)), name)
        }
        for name in ["a.txt", "a.xmp", "a.json", "a.gif", "a.pdf", "a.svg", "a.mov", "a.zip"] {
            XCTAssertFalse(ImageFormat.isSupported(url(name)), name)
        }
    }

    func testRAWAndStandardAreDistinguished() {
        func url(_ name: String) -> URL { URL(fileURLWithPath: "/photos/\(name)") }
        for name in ["a.DNG", "a.NEF", "a.RAF", "a.IIQ", "a.3FR", "a.CR2", "a.ARW"] {
            XCTAssertTrue(ImageFormat.isRAW(url(name)), name)
        }
        for name in ["a.jpg", "a.tiff", "a.png", "a.heic"] {
            XCTAssertFalse(ImageFormat.isRAW(url(name)), name)
        }
    }

    // MARK: - Linearization

    /// The measurement the whole non-RAW path stands on: an sRGB code value has
    /// to arrive in the working space *linearized*, not passed through.
    func testJPEGPatchesDecodeToLinearValues() throws {
        let (ctx, _) = try TestGPU.require()
        let codes: [UInt8] = [0, 64, 128, 192, 255]
        let url = try SyntheticImage.write(patches: codes, to: "patches.jpg", type: .jpeg)
        let decoded = try ImageDecoder(metal: ctx).decode(url: url)
        XCTAssertEqual(decoded.width, codes.count)

        let row = readRow(decoded.texture)
        for (index, code) in codes.enumerated() {
            let expected = SyntheticImage.linearize(code)
            let (r, g, b) = row[index]
            // JPEG is lossy and the texture is half-float, so this is a
            // tolerance on the transfer function, not on the codec.
            XCTAssertEqual(r, expected, accuracy: 0.01, "code \(code) red")
            XCTAssertEqual(g, expected, accuracy: 0.01, "code \(code) green")
            XCTAssertEqual(b, expected, accuracy: 0.01, "code \(code) blue")
        }
        print("[standard decode] sRGB code 128 -> linear \(row[2].0) "
            + "(reference \(SyntheticImage.linearize(128)))")
    }

    func testMidGreyBlackAndWhiteLandWhereTheyShould() throws {
        let (ctx, _) = try TestGPU.require()
        let url = try SyntheticImage.write(patches: [0, 128, 255], to: "endpoints.png",
                                           type: .png)
        let row = readRow(try ImageDecoder(metal: ctx).decode(url: url).texture)
        // PNG is lossless, so these are tight. 128/255 through the sRGB EOTF
        // is 0.21586, not the 0.2140 a plain 2.2 gamma would give — the
        // reference is the real transfer function, computed, not a constant.
        XCTAssertEqual(row[0].0, 0, accuracy: 0.001)
        XCTAssertEqual(row[1].0, SyntheticImage.linearize(128), accuracy: 0.001)
        XCTAssertEqual(row[2].0, 1.0, accuracy: 0.002)
    }

    func testSixteenBitTIFFRoundTrips() throws {
        let (ctx, _) = try TestGPU.require()
        // 0, 25 %, 50 %, 100 % of full scale as sRGB-encoded 16-bit values.
        let values: [UInt16] = [0, 16384, 32768, 65535]
        let url = try SyntheticImage.write16Bit(values: values, to: "sixteen.tiff", type: .tiff)
        let row = readRow(try ImageDecoder(metal: ctx).decode(url: url).texture)
        for (index, value) in values.enumerated() {
            let encoded = Double(value) / 65535
            let expected = encoded <= 0.04045
                ? encoded / 12.92
                : pow((encoded + 0.055) / 1.055, 2.4)
            XCTAssertEqual(row[index].0, expected, accuracy: 0.003, "value \(value)")
        }
    }

    // MARK: - Probe

    func testProbeOfAJPEGReportsNotRAWWithSizeAndDate() throws {
        let url = try SyntheticImage.write(patches: [128, 200], to: "probed.jpg", type: .jpeg,
                                           capturedAt: "2019:07:04 12:34:56", height: 6)
        let info = try ImageDecoder.probe(url: url)
        XCTAssertFalse(info.isRAW)
        XCTAssertEqual(info.nativeSize, CGSize(width: 2, height: 6))
        XCTAssertEqual(info.orientedSize, CGSize(width: 2, height: 6))
        XCTAssertEqual(info.asShotTemperature, 6500)
        XCTAssertEqual(info.asShotTint, 0)
        XCTAssertFalse(info.lensCorrectionSupported)
        XCTAssertFalse(info.hasPreviewImage)
        XCTAssertTrue(info.supportedDecoderVersions.isEmpty)
        XCTAssertEqual(info.cameraMake, "Grayroom")
        XCTAssertEqual(info.cameraModel, "Synthetic")

        var components = DateComponents()
        components.year = 2019; components.month = 7; components.day = 4
        components.hour = 12; components.minute = 34; components.second = 56
        components.timeZone = TimeZone(secondsFromGMT: 0)
        let expected = Calendar(identifier: .gregorian).date(from: components)!
        XCTAssertEqual(try XCTUnwrap(info.capturedAt).timeIntervalSince1970,
                       expected.timeIntervalSince1970, accuracy: 1)
    }

    func testProbeOfARealRAWStillReportsRAW() throws {
        guard let url = testDataURL("L1000003.DNG") else {
            throw XCTSkip("testdata/L1000003.DNG not present (set GRAYROOM_TEST_DNG to override)")
        }
        let info = try ImageDecoder.probe(url: url)
        XCTAssertTrue(info.isRAW)
        XCTAssertFalse(info.supportedDecoderVersions.isEmpty)
        XCTAssertFalse(info.decoderVersion.isEmpty)
        // A real camera's as-shot white balance is not the D65 stand-in the
        // standard path reports.
        XCTAssertNotEqual(info.asShotTemperature, ImageDecoder.standardNeutralTemperature)
    }

    func testProbeOfAMissingFileThrows() {
        let url = URL(fileURLWithPath: "/nowhere/nothing.jpg")
        XCTAssertThrowsError(try ImageDecoder.probe(url: url))
    }

    func testProbeOfGarbageThrows() throws {
        let url = SyntheticImage.directory.appendingPathComponent("garbage.jpg")
        try Data("not an image".utf8).write(to: url)
        XCTAssertThrowsError(try ImageDecoder.probe(url: url))
    }

    // MARK: - White balance

    /// The non-RAW temp/tint shift has to move the image in the same direction
    /// the RAW slider does: a higher Kelvin warms it.
    func testTemperatureWarmsAndCoolsInTheRAWDirection() throws {
        let (ctx, _) = try TestGPU.require()
        let url = try SyntheticImage.write(patches: [128], to: "neutral.png", type: .png)
        let decoder = ImageDecoder(metal: ctx)

        func balance(_ temperature: Double?, _ tint: Double? = nil) -> (Double, Double, Double) {
            var edit = EditState()
            edit.whiteBalance = EditState.WhiteBalance(temperature: temperature, tint: tint)
            return readRow(try! decoder.decode(url: url, edit: edit).texture)[0]
        }

        let neutral = balance(nil)
        XCTAssertEqual(neutral.0, neutral.2, accuracy: 0.001, "untouched stays neutral")

        // Explicitly asking for the reference is still a no-op on colour.
        let reference = balance(6500, 0)
        XCTAssertEqual(reference.0, reference.2, accuracy: 0.01)

        let warm = balance(9000)
        XCTAssertGreaterThan(warm.0, warm.2, "9000 K should be warmer than neutral")
        let cool = balance(4000)
        XCTAssertLessThan(cool.0, cool.2, "4000 K should be cooler than neutral")
        XCTAssertGreaterThan(warm.0 / warm.2, cool.0 / cool.2)
        print(String(format: "[standard WB] 4000 K R/B %.3f, 6500 K R/B %.3f, 9000 K R/B %.3f",
                     cool.0 / cool.2, reference.0 / max(reference.2, 1e-6), warm.0 / warm.2))

        // Tint: positive is magenta, negative is green — the RAW convention.
        let magenta = balance(6500, 80)
        XCTAssertGreaterThan((magenta.0 + magenta.2) / 2, magenta.1)
        let green = balance(6500, -60)
        XCTAssertLessThan((green.0 + green.2) / 2, green.1)
    }

    /// White balance is applied at decode time on this path too, so the decode
    /// cache key has to keep separating on it.
    func testWhiteBalanceChangesTheDecodedPixels() throws {
        let (ctx, _) = try TestGPU.require()
        let url = try SyntheticImage.write(patches: [128], to: "cachekey.png", type: .png)
        let decoder = ImageDecoder(metal: ctx)
        var edit = EditState()
        edit.whiteBalance = EditState.WhiteBalance(temperature: 9000, tint: nil)
        let plain = readRow(try decoder.decode(url: url).texture)[0]
        let warmed = readRow(try decoder.decode(url: url, edit: edit).texture)[0]
        XCTAssertNotEqual(plain.0, warmed.0, accuracy: 0.0)
        XCTAssertEqual(RenderInvalidationProbe.decodeInvalidates(edit), true)
    }

    // MARK: - Reduction and orientation

    func testNativeDimensionsSurviveOrientationAndReduction() throws {
        let (context, _) = try TestGPU.require()
        let decoder = ImageDecoder(metal: context)
        let original = try SyntheticImage.write(patches: Array(repeating: 128, count: 12),
                                                 to: "native-source.png", type: .png, height: 8)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(original as CFURL, nil))
        for orientation in 1...8 {
            let url = SyntheticImage.directory.appendingPathComponent("native-\(orientation).tiff")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
                url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
            CGImageDestinationAddImageFromSource(destination, source, 0,
                                                [kCGImagePropertyOrientation: orientation] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            for edge in [nil, 6] as [Int?] {
                var edit = EditState()
                edit.whiteBalance.temperature = 9000
                let decoded = try decoder.decode(url: url, edit: edit, maxDimension: edge)
                XCTAssertEqual(decoded.nativeSize, CGSize(width: 12, height: 8), "orientation \(orientation)")
                let width = edge == nil ? 12 : 6
                let height = edge == nil ? 8 : 4
                XCTAssertEqual(decoded.width, orientation < 5 ? width : height)
                XCTAssertEqual(decoded.height, orientation < 5 ? height : width)
            }
        }
    }

    func testMaxDimensionReducesAStandardImage() throws {
        let (ctx, _) = try TestGPU.require()
        let url = try SyntheticImage.write(patches: [UInt8](repeating: 128, count: 64),
                                           to: "wide.png", type: .png, height: 32)
        let decoded = try ImageDecoder(metal: ctx).decode(url: url, maxDimension: 16)
        XCTAssertEqual(max(decoded.width, decoded.height), 16)
        XCTAssertEqual(decoded.nativeSize, CGSize(width: 64, height: 32))
    }

    func testHEICDecodesWhenTheSystemCanWriteIt() throws {
        let (ctx, _) = try TestGPU.require()
        guard let heic = UTType("public.heic") else { throw XCTSkip("no HEIC UTType") }
        let url = try SyntheticImage.write(patches: [0, 128, 255], to: "patches.heic", type: heic)
        let info = try ImageDecoder.probe(url: url)
        XCTAssertFalse(info.isRAW)
        XCTAssertEqual(info.nativeSize.width, 3)
        let row = readRow(try ImageDecoder(metal: ctx).decode(url: url).texture)
        XCTAssertEqual(row[1].0, SyntheticImage.linearize(128), accuracy: 0.02)
        // The import grid's thumbnail path has to work for it too.
        XCTAssertNotNil(EmbeddedPreview.thumbnail(url: url, maxPixelSize: 64))
    }

    func testEmbeddedPreviewWorksForStandardFormats() throws {
        for (name, type) in [("thumb.jpg", UTType.jpeg), ("thumb.png", .png),
                             ("thumb.tiff", .tiff)] {
            let url = try SyntheticImage.write(patches: [UInt8](repeating: 128, count: 40),
                                               to: name, type: type, height: 20)
            let thumbnail = try XCTUnwrap(EmbeddedPreview.thumbnail(url: url, maxPixelSize: 16),
                                          name)
            XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 16, name)
        }
    }
}

/// `RenderInvalidation` lives in `GrayroomUI`, which `GrayroomCoreTests` cannot
/// import; this restates the one fact this file needs about it.
private enum RenderInvalidationProbe {
    static func decodeInvalidates(_ edit: EditState) -> Bool {
        edit.whiteBalance != EditState().whiteBalance
    }
}
