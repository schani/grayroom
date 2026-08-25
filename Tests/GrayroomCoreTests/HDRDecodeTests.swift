import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import GrayroomCore

/// The macOS 26 decode properties: highlight recovery on the RAW path, and the
/// HDR statistics an already-rendered file carries.
final class HDRDecodeTests: XCTestCase {

    private func requireDNG() throws -> URL {
        guard let url = testDataURL("L1000003.DNG") else {
            throw XCTSkip("testdata/L1000003.DNG not present (set GRAYROOM_TEST_DNG to override)")
        }
        return url
    }

    // MARK: - Highlight recovery

    /// Wherever `CIRAWFilter` can reconstruct a clipped channel, the decode asks
    /// it to. There is no user option — Lightroom has none either — so the only
    /// statement to make is that the enabled flag tracks the supported one.
    func testHighlightRecoveryIsOnWhereverItIsSupported() throws {
        let url = try requireDNG()
        let filter = try XCTUnwrap(CIRAWFilter(imageURL: url))
        ImageDecoder.neutralize(filter)
        XCTAssertEqual(filter.isHighlightRecoveryEnabled, filter.isHighlightRecoverySupported)
        print("[hdr] highlight recovery supported = \(filter.isHighlightRecoverySupported)")
    }

    /// And `probe` says so, which is where the CLI reads it from.
    func testProbeReportsHighlightRecovery() throws {
        let info = try ImageDecoder.probe(url: try requireDNG())
        XCTAssertEqual(info.highlightRecoveryEnabled, info.highlightRecoverySupported)
        XCTAssertTrue(info.highlightRecoverySupported,
                      "this decoder supports recovery for this file")
    }

    /// A rendered file has no demosaic left to recover a channel in, and no
    /// sensor data to do it from.
    func testAStandardImageReportsNoHighlightRecovery() throws {
        let url = try writePNG(name: "hdr-sdr.png")
        let info = try ImageDecoder.probe(url: url)
        XCTAssertFalse(info.highlightRecoverySupported)
        XCTAssertFalse(info.highlightRecoveryEnabled)
    }

    // MARK: - HDR statistics

    /// An SDR file states a headroom of exactly SDR white and has no average
    /// light level to state.
    func testAnSDRFileReportsSDRHeadroom() throws {
        let info = try ImageDecoder.probe(url: try writePNG(name: "hdr-sdr-headroom.png"))
        XCTAssertEqual(info.contentHeadroom, 1.0, accuracy: 1e-6)
        XCTAssertEqual(info.contentAverageLightLevel, 0)
    }

    /// A PQ file carries real headroom, and `kCGComputeHDRStats` is what fills
    /// in the average light level beside it.
    func testAnHDRFileReportsItsHeadroomAndLightLevel() throws {
        let url = try writeHDRHEIC(name: "hdr-pq.heic")
        let info = try ImageDecoder.probe(url: url)
        XCTAssertGreaterThan(info.contentHeadroom, 1.0)
        XCTAssertGreaterThan(info.contentAverageLightLevel, 0)
        print(String(format: "[hdr] headroom %.3f, average light level %.4f",
                     info.contentHeadroom, info.contentAverageLightLevel))
    }

    /// A RAW is scene-referred: the headroom metadata describes an encoding
    /// against a display white, and a RAW has not been encoded against one.
    func testARAWReportsNoHDRStatistics() throws {
        let info = try ImageDecoder.probe(url: try requireDNG())
        XCTAssertEqual(info.contentHeadroom, 0)
        XCTAssertEqual(info.contentAverageLightLevel, 0)
    }

    // MARK: - Fixtures

    private var directory: URL {
        get throws {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("grayroom-hdr", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    private func writePNG(name: String) throws -> URL {
        let side = 16
        var bytes = [UInt8](repeating: 128, count: side * side * 4)
        for i in 0..<(side * side) { bytes[i * 4 + 3] = 255 }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: side * 4, space: space, bitmapInfo: info,
                            provider: CGDataProvider(data: Data(bytes) as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return try write(image, name: name, type: .png)
    }

    /// A float image tagged Rec. 2100 PQ, which is what makes the encoder write
    /// a file with headroom above SDR white.
    private func writeHDRHEIC(name: String) throws -> URL {
        let side = 64
        var floats = [Float](repeating: 0, count: side * side * 4)
        for i in 0..<(side * side) {
            let v: Float = i % 2 == 0 ? 0.9 : 0.4
            floats[i * 4] = v
            floats[i * 4 + 1] = v
            floats[i * 4 + 2] = v
            floats[i * 4 + 3] = 1
        }
        guard let space = CGColorSpace(name: CGColorSpace.itur_2100_PQ) else {
            throw XCTSkip("no Rec. 2100 PQ colour space here")
        }
        let info = CGBitmapInfo(rawValue: CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipLast.rawValue)
        let data = floats.withUnsafeBytes { Data($0) }
        let image = CGImage(width: side, height: side, bitsPerComponent: 32, bitsPerPixel: 128,
                            bytesPerRow: side * 16, space: space, bitmapInfo: info,
                            provider: CGDataProvider(data: data as CFData)!,
                            decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return try write(image, name: name, type: .heic)
    }

    private func write(_ image: CGImage, name: String, type: UTType) throws -> URL {
        let url = try directory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil)
        else { throw XCTSkip("ImageIO cannot write \(type.identifier) here") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("ImageIO could not write \(name)")
        }
        return url
    }
}
