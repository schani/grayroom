import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import GrayroomCore

/// The two ends of the export path that nothing else covers: the grayscale
/// data writer `mask-preview` uses, and the readback the whole CPU side of the
/// pipeline is built on.
final class ExportPathTests: XCTestCase {

    private lazy var directory: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grayroom-export-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// The single-channel codes of a written PNG, plus the shape of the file.
    private func readGray(_ url: URL, width: Int, height: Int) throws
        -> (codes: [UInt8], bitsPerPixel: Int, bitsPerComponent: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.png.identifier)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, width)
        XCTAssertEqual(image.height, height)
        var bytes = [UInt8](repeating: 0, count: width * height)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, image.bitsPerPixel, image.bitsPerComponent)
    }

    // MARK: - writeGray

    /// `writeGray` writes **data**, not a picture: `round(255 · v)` with no
    /// transfer function, so 0.5 is code 128 and not the sRGB-encoded 188 that
    /// the picture writer would produce.
    func testWriteGrayIsLinearWithNoTransferFunction() throws {
        let values: [Float] = [0, 0.25, 0.5, 0.75, 1]
        let url = directory.appendingPathComponent("gray.png")
        try ImageWriter.writeGray(values, width: values.count, height: 1, to: url)

        let (codes, bitsPerPixel, bitsPerComponent) = try readGray(url, width: 5, height: 1)
        XCTAssertEqual(codes, [0, 64, 128, 191, 255])
        XCTAssertEqual(bitsPerPixel, 8, "one channel, not three")
        XCTAssertEqual(bitsPerComponent, 8)

        // What the *picture* writer would have made of the same 0.5.
        let asPicture = try ImageWriter.makeCGImage(
            FloatImage(width: 1, height: 1, pixels: [0.5, 0.5, 0.5, 1]), bitsPerComponent: 8)
        XCTAssertEqual(asPicture.bitsPerPixel, 24)
        XCTAssertNotEqual(codes[2], 188, "coverage must not be sRGB-encoded")
    }

    func testWriteGrayClampsOutOfRangeValues() throws {
        let url = directory.appendingPathComponent("clamped.png")
        try ImageWriter.writeGray([-3, -0.001, 1.001, 17], width: 4, height: 1, to: url)
        XCTAssertEqual(try readGray(url, width: 4, height: 1).codes, [0, 0, 255, 255])
    }

    /// Row-major from the top, matching the mask convention.
    func testWriteGrayKeepsRowOrder() throws {
        let url = directory.appendingPathComponent("rows.png")
        try ImageWriter.writeGray([1, 0, 0, 0], width: 2, height: 2, to: url)
        XCTAssertEqual(try readGray(url, width: 2, height: 2).codes, [255, 0, 0, 0])
    }

    func testWriteGrayFailsOnAnUnwritablePath() {
        XCTAssertThrowsError(try ImageWriter.writeGray(
            [0.5], width: 1, height: 1,
            to: URL(fileURLWithPath: "/nonexistent-directory-for-tests/x.png")))
    }

    // MARK: - makeCGImage

    /// Values outside 0…1 are clamped at both depths, so an unclamped
    /// intermediate can never wrap around into a dark pixel.
    func testMakeCGImageClampsAtBothDepths() throws {
        let pixels: [Float] = [-2, 0.5, 3, 1,
                               1.5, -0.25, 0, 1]
        let image = FloatImage(width: 2, height: 1, pixels: pixels)

        for bits in [8, 16] {
            let cg = try ImageWriter.makeCGImage(image, bitsPerComponent: bits)
            XCTAssertEqual(cg.bitsPerComponent, bits)
            XCTAssertEqual(cg.bitsPerPixel, bits * 3, "no alpha channel")
            XCTAssertEqual(cg.colorSpace?.name as String?, CGColorSpace.sRGB as String)

            let data = try XCTUnwrap(cg.dataProvider?.data as Data?)
            if bits == 8 {
                XCTAssertEqual(data[0], 0, "-2 clamps to black")
                XCTAssertEqual(data[2], 255, "3 clamps to white")
                XCTAssertEqual(data[3], 255, "1.5 clamps to white")
                XCTAssertEqual(data[4], 0, "-0.25 clamps to black")
            } else {
                let words: [UInt16] = data.withUnsafeBytes { Array($0.bindMemory(to: UInt16.self)) }
                XCTAssertEqual(words[0], 0)
                XCTAssertEqual(words[1], UInt16((0.5 * 65535).rounded()))
                XCTAssertEqual(words[2], 65535)
            }
        }
    }

    // MARK: - TextureReadback

    func testReadbackRejectsTheWrongPixelFormat() throws {
        let (ctx, _) = try TestGPU.require()
        let scalar = try ctx.makeScalarTexture(width: 4, height: 4)
        XCTAssertThrowsError(try TextureReadback.read(scalar)) { error in
            guard case ReadbackError.unsupportedPixelFormat = error else {
                return XCTFail("wrong error \(error)")
            }
        }
        XCTAssertThrowsError(try TextureReadback.readRegion(scalar, x: 0, y: 0,
                                                            width: 2, height: 2)) { error in
            guard case ReadbackError.unsupportedPixelFormat = error else {
                return XCTFail("wrong error \(error)")
            }
        }

        let rgba = try ctx.makeWorkingTexture(width: 4, height: 4)
        XCTAssertThrowsError(try TextureReadback.readScalar(rgba)) { error in
            guard case ReadbackError.unsupportedPixelFormat = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }

    /// `readScalar` handles both single-channel formats the pipeline uses:
    /// `r16Float` masks and the `r32Float` clarity pyramids.
    func testReadScalarHandlesBothSingleChannelFormats() throws {
        let (ctx, _) = try TestGPU.require()
        let values: [Float] = [0, 0.25, 0.5, 1]

        let half = try ctx.makeAmountTexture(width: 4, height: 1)
        values.map { Float16($0) }.withUnsafeBytes {
            half.replace(region: MTLRegionMake2D(0, 0, 4, 1), mipmapLevel: 0,
                         withBytes: $0.baseAddress!, bytesPerRow: 4 * MemoryLayout<Float16>.size)
        }
        XCTAssertEqual(try TextureReadback.readScalar(half), values)

        let full = try ctx.makeScalarTexture(width: 4, height: 1)
        values.withUnsafeBytes {
            full.replace(region: MTLRegionMake2D(0, 0, 4, 1), mipmapLevel: 0,
                         withBytes: $0.baseAddress!, bytesPerRow: 4 * MemoryLayout<Float>.size)
        }
        XCTAssertEqual(try TextureReadback.readScalar(full), values)
    }

    /// A region wholly outside the texture is clipped back onto it rather than
    /// reading out of bounds: the targeted-adjustment tool asks for a 3x3 box
    /// around a cursor that may be on the very last pixel.
    func testReadRegionClipsToTheTexture() throws {
        let (ctx, _) = try TestGPU.require()
        let texture = try ctx.makeTexture(width: 4, height: 4) { x, y in
            (Float(x) / 4, Float(y) / 4, 0)
        }
        let corner = try TextureReadback.readRegion(texture, x: 3, y: 3, width: 3, height: 3)
        XCTAssertEqual([corner.width, corner.height], [1, 1])
        XCTAssertEqual(corner.rgb(x: 0, y: 0).0, 3.0 / 4, accuracy: 1e-3)

        let past = try TextureReadback.readRegion(texture, x: 99, y: -5, width: 2, height: 2)
        XCTAssertEqual([past.width, past.height], [1, 2])
    }

    /// `FloatImage.meanLuminance` is Rec.709 weighted and safe on an empty image.
    func testMeanLuminanceIsRec709AndSafeWhenEmpty() {
        let green = FloatImage(width: 1, height: 1, pixels: [0, 1, 0, 1])
        XCTAssertEqual(green.meanLuminance, 0.7152, accuracy: 1e-6)
        XCTAssertEqual(FloatImage(width: 0, height: 0, pixels: []).meanLuminance, 0)
    }
}
