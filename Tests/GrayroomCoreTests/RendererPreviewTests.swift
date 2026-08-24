import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import GrayroomCore

/// `Renderer.renderPreview` — what the library grid's cells are made of.
///
/// The contract that matters is that it is the *same* rendition as an export,
/// not something cheaper that happens to look similar: a grid showing a photo
/// that does not exist would be worse than a grid showing nothing.
final class RendererPreviewTests: XCTestCase {
    private var renderer: Renderer!
    private var directory: URL!
    private var input: URL!

    override func setUpWithError() throws {
        guard let r = try? Renderer() else {
            throw XCTSkip("no Metal device / shader compilation failed")
        }
        renderer = r
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grayroom-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        input = try writeGradient("in.png", width: 64, height: 40)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        renderer = nil
        directory = nil
        input = nil
    }

    private func writeGradient(_ name: String, width: Int, height: Int) throws -> URL {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8(x * 255 / max(width - 1, 1))
                bytes[i + 1] = UInt8(y * 255 / max(height - 1, 1))
                bytes[i + 2] = UInt8((x &+ y) % 256)
            }
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: width * 4, space: space,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        let url = directory.appendingPathComponent(name)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    /// The interleaved RGB codes of a CGImage.
    private func codes(_ image: CGImage) throws -> [UInt8] {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }

    private func codes(ofFile url: URL) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try codes(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    func testPreviewIsAnSRGBEightBitImageCappedAtTheRequestedEdge() throws {
        let image = try renderer.renderPreview(url: input, edit: EditState(), maxDimension: 32)
        XCTAssertEqual([image.width, image.height], [32, 20], "aspect ratio kept")
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.bitsPerPixel, 24)
        XCTAssertEqual(image.colorSpace?.name as String?, CGColorSpace.sRGB as String)
    }

    /// The whole point: a grid cell is the export, not an approximation of it.
    func testAPreviewIsPixelForPixelWhatAnExportOfTheSameEditWouldBe() throws {
        var edit = EditState()
        edit.tone.exposure = 0.6
        edit.tone.contrast = 25
        edit.bwMix.blue = -40
        edit.toning = EditState.Toning(shadowHue: 40, shadowSaturation: 20,
                                       highlightHue: 210, highlightSaturation: 15)

        let exported = directory.appendingPathComponent("export.png")
        try renderer.render(rawURL: input, edit: edit, to: exported,
                            format: .png, maxDimension: 32)

        let preview = try renderer.renderPreview(url: input, edit: edit, maxDimension: 32)
        XCTAssertEqual(try codes(preview), try codes(ofFile: exported))
    }

    /// The edit reaches the preview: +2 EV is a brighter cell.
    func testThePreviewReflectsTheEdit() throws {
        var brighter = EditState()
        brighter.tone.exposure = 2

        func mean(_ image: CGImage) throws -> Double {
            let bytes = try codes(image)
            var acc = 0.0
            for i in stride(from: 0, to: bytes.count, by: 4) { acc += Double(bytes[i]) }
            return acc / Double(bytes.count / 4)
        }

        let base = try mean(renderer.renderPreview(url: input, edit: EditState(), maxDimension: 32))
        let lifted = try mean(renderer.renderPreview(url: input, edit: brighter, maxDimension: 32))
        XCTAssertGreaterThan(lifted, base + 20)
    }

    /// The grid is an SDR surface, so an HDR edit's preview is that rendition
    /// clipped at SDR white — exactly like an export, and *not* the SDR edit.
    func testAnHDREditPreviewsAsTheSDRClippedRendition() throws {
        var sdr = EditState()
        sdr.tone.exposure = 1.5
        var hdr = sdr
        hdr.hdr = true

        let exported = directory.appendingPathComponent("hdr-export.png")
        try renderer.render(rawURL: input, edit: hdr, to: exported, format: .png, maxDimension: 32)

        let preview = try renderer.renderPreview(url: input, edit: hdr, maxDimension: 32)
        XCTAssertEqual(try codes(preview), try codes(ofFile: exported))

        let sdrPreview = try renderer.renderPreview(url: input, edit: sdr, maxDimension: 32)
        XCTAssertNotEqual(try codes(preview), try codes(sdrPreview),
                          "the HDR shoulder still changes the rendition below the clip")
    }

    func testPreviewOfAMissingFileThrows() {
        XCTAssertThrowsError(try renderer.renderPreview(
            url: URL(fileURLWithPath: "/nope/missing.png"),
            edit: EditState(), maxDimension: 32))
    }
}

/// White balance on the RAW path, which is the *reference* direction the
/// standard-image path is calibrated against (see `ImageDecoder`).
final class RawWhiteBalanceTests: XCTestCase {

    private func requireDNG() throws -> URL {
        guard let url = testDataURL("L1000003.DNG") else {
            throw XCTSkip("testdata/L1000003.DNG not present (set GRAYROOM_TEST_DNG to override)")
        }
        return url
    }

    private func meanRGB(_ image: FloatImage) -> (Double, Double, Double) {
        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: image.pixels.count, by: 4) {
            r += Double(image.pixels[i])
            g += Double(image.pixels[i + 1])
            b += Double(image.pixels[i + 2])
        }
        let n = Double(image.width * image.height)
        return (r / n, g / n, b / n)
    }

    /// A higher Kelvin warms the image — more red relative to blue. This is the
    /// direction `ImageDecoder.applyTemperatureAndTint` had to be argued into
    /// matching for standard images, so the RAW side needs its own guard.
    func testAHigherKelvinWarmsTheDecodedRAW() throws {
        let url = try requireDNG()
        let (ctx, _) = try TestGPU.require()
        let decoder = ImageDecoder(metal: ctx)

        func ratio(temperature: Double) throws -> Double {
            var edit = EditState()
            edit.whiteBalance = EditState.WhiteBalance(temperature: temperature, tint: 0)
            let decoded = try decoder.decode(url: url, edit: edit, maxDimension: 192)
            XCTAssertEqual(decoded.temperature, temperature)
            XCTAssertEqual(decoded.tint, 0)
            let (r, _, b) = meanRGB(try TextureReadback.read(decoded.texture))
            return r / b
        }

        let cool = try ratio(temperature: 4000)
        let warm = try ratio(temperature: 9000)
        print("[raw WB] 4000 K R/B \(cool), 9000 K R/B \(warm)")
        XCTAssertLessThan(cool, warm)
        XCTAssertGreaterThan(warm / cool, 2)
    }

    /// With no white balance in the edit the as-shot values are used *and*
    /// reported, which is what "As Shot" means on a RAW.
    func testAnEditWithNoWhiteBalanceUsesAsShot() throws {
        let url = try requireDNG()
        let (ctx, _) = try TestGPU.require()
        let decoder = ImageDecoder(metal: ctx)

        let decoded = try decoder.decode(url: url, edit: EditState(), maxDimension: 128)
        let probed = try ImageDecoder.probe(url: url)
        XCTAssertEqual(decoded.temperature, probed.asShotTemperature, accuracy: 1e-6)
        XCTAssertEqual(decoded.tint, probed.asShotTint, accuracy: 1e-6)
        XCTAssertEqual(decoded.asShotTemperature, probed.asShotTemperature, accuracy: 1e-6)
        XCTAssertEqual(decoded.nativeSize, probed.nativeSize)
    }

    /// Only one of the two axes given still counts as an override: the other
    /// falls back to as-shot rather than to zero.
    func testATintOnlyOverrideKeepsTheAsShotTemperature() throws {
        let url = try requireDNG()
        let (ctx, _) = try TestGPU.require()
        let decoder = ImageDecoder(metal: ctx)

        var edit = EditState()
        edit.whiteBalance = EditState.WhiteBalance(temperature: nil, tint: 40)
        let decoded = try decoder.decode(url: url, edit: edit, maxDimension: 128)
        XCTAssertEqual(decoded.temperature, decoded.asShotTemperature, accuracy: 1e-6)
        XCTAssertEqual(decoded.tint, 40)
    }

    func testDecodeOfAMissingFileThrowsFileNotFound() {
        let (ctx, _) = try! TestGPU.require()
        let decoder = ImageDecoder(metal: ctx)
        XCTAssertThrowsError(try decoder.decode(url: URL(fileURLWithPath: "/nope/x.dng"))) { error in
            guard case DecodeError.fileNotFound = error else {
                return XCTFail("wrong error \(error)")
            }
        }
    }
}
