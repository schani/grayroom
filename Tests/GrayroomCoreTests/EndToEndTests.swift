import CoreGraphics
import ImageIO
import XCTest
@testable import GrayroomCore

final class EndToEndTests: XCTestCase {

    private func requireDNG() throws -> URL {
        guard let url = testDataURL("L1000003.DNG") else {
            throw XCTSkip("testdata/L1000003.DNG not present (set GRAYROOM_TEST_DNG to override)")
        }
        return url
    }

    func testProbeRealDNG() throws {
        let url = try requireDNG()
        let (ctx, _) = try TestGPU.require()
        let info = try ImageDecoder(metal: ctx).probe(url: url)
        XCTAssertGreaterThan(info.nativeSize.width, 1000)
        XCTAssertGreaterThan(info.nativeSize.height, 1000)
        XCTAssertGreaterThan(info.asShotTemperature, 1500)
        XCTAssertLessThan(info.asShotTemperature, 50000)
        XCTAssertFalse(info.supportedDecoderVersions.isEmpty)
        XCTAssertFalse(info.decoderVersion.isEmpty)
    }

    func testNonRAWInputIsRejected() throws {
        let (ctx, _) = try TestGPU.require()
        let decoder = ImageDecoder(metal: ctx)
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("not-a-raw-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertThrowsError(try decoder.probe(url: file))
        XCTAssertThrowsError(try decoder.decode(url: file))
        XCTAssertThrowsError(try decoder.probe(url: file.appendingPathExtension("missing"))) { err in
            guard case DecodeError.fileNotFound = err else { return XCTFail("wrong error \(err)") }
        }
    }

    func testDecodeIsLinearAndScaled() throws {
        let url = try requireDNG()
        let (ctx, _) = try TestGPU.require()
        let decoded = try ImageDecoder(metal: ctx).decode(url: url, maxDimension: 512)
        XCTAssertLessThanOrEqual(max(decoded.width, decoded.height), 512)
        XCTAssertGreaterThan(min(decoded.width, decoded.height), 100)

        let img = try TextureReadback.read(decoded.texture)
        let mean = img.meanLuminance
        XCTAssertGreaterThan(mean, 0.0005, "decoded image is black")
        // Scene-referred linear: mean well below the sRGB-encoded mean of the
        // same picture (a linear image looks dark before the output transform).
        XCTAssertLessThan(mean, 0.9)
        XCTAssertTrue(img.pixels.allSatisfy { $0.isFinite })
    }

    func testEndToEndRenderPNG() throws {
        let url = try requireDNG()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grayroom-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("out.png")

        var edit = EditState()
        edit.tone = .init(exposure: 0.3, contrast: 25, highlights: -40, shadows: 20)
        edit.bwMix = .init(red: -30, blue: -60)
        edit.toning = .init(shadowHue: 215, shadowSaturation: 12,
                            highlightHue: 45, highlightSaturation: 10, balance: 10)

        let renderer = try Renderer()
        let result = try renderer.render(rawURL: url,
                                         edit: edit,
                                         to: out,
                                         format: .png,
                                         maxDimension: 1024,
                                         computeHistogram: true)

        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(max(result.width, result.height), 1024)

        let src = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(cg.width, result.width)
        XCTAssertEqual(cg.height, result.height)

        let h = try XCTUnwrap(result.histogram)
        XCTAssertEqual(h.pixelCount, result.width * result.height)
        XCTAssertGreaterThan(h.meanLuminance, 0.05)
        XCTAssertLessThan(h.meanLuminance, 0.95)
        XCTAssertLessThan(h.highlightClippedFraction, 0.5)
        XCTAssertLessThan(h.shadowClippedFraction, 0.5)
    }

    func testEndToEndFormats() throws {
        let url = try requireDNG()
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grayroom-fmt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let renderer = try Renderer()
        for format in ExportFormat.allCases {
            let out = dir.appendingPathComponent("out-\(format.rawValue).\(format.fileExtension)")
            let r = try renderer.render(rawURL: url, edit: EditState(), to: out,
                                        format: format, quality: 0.8, maxDimension: 256)
            let attrs = try FileManager.default.attributesOfItem(atPath: out.path)
            XCTAssertGreaterThan(attrs[.size] as? Int ?? 0, 512, "\(format.rawValue) too small")

            let src = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
            XCTAssertEqual(cg.width, r.width, "\(format.rawValue)")
            XCTAssertEqual(cg.height, r.height, "\(format.rawValue)")
            if format.bitsPerComponent == 16 {
                XCTAssertEqual(cg.bitsPerComponent, 16, "\(format.rawValue)")
            }
        }
    }

    func testDecodeOrientationMatchesCoreGraphics() throws {
        // The Metal texture must be in image order (row 0 = top), matching what
        // Core Graphics produces from the same CIImage.
        let url = try requireDNG()
        let (ctx, _) = try TestGPU.require()
        let decoded = try ImageDecoder(metal: ctx).decode(url: url, maxDimension: 256)
        let img = try TextureReadback.read(decoded.texture)

        guard let filter = CIRAWFilter(imageURL: url) else { throw XCTSkip("no RAW filter") }
        filter.baselineExposure = 0
        filter.shadowBias = 0
        filter.boostAmount = 0
        filter.boostShadowAmount = 0
        filter.localToneMapAmount = 0
        filter.isGamutMappingEnabled = false
        filter.scaleFactor = Float(256.0 / max(filter.nativeSize.width, filter.nativeSize.height))
        let ciImage = try XCTUnwrap(filter.outputImage)
        let ciContext = CIContext(options: [.workingColorSpace: ImageDecoder.workingColorSpace])
        let cg = try XCTUnwrap(ciContext.createCGImage(
            ciImage, from: ciImage.extent,
            format: .RGBAh, colorSpace: ImageDecoder.workingColorSpace))

        XCTAssertEqual(cg.width, img.width)
        XCTAssertEqual(cg.height, img.height)

        // Compare the mean luminance of the top and bottom eighth of both.
        var cgHalfs = [Float16](repeating: 0, count: cg.width * cg.height * 4)
        let cs = ImageDecoder.workingColorSpace
        let bmInfo = CGBitmapInfo.floatComponents.rawValue
            | CGBitmapInfo.byteOrder16Little.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        cgHalfs.withUnsafeMutableBytes { raw in
            if let bmp = CGContext(data: raw.baseAddress,
                                   width: cg.width, height: cg.height,
                                   bitsPerComponent: 16, bytesPerRow: cg.width * 8,
                                   space: cs, bitmapInfo: bmInfo) {
                bmp.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
        }

        func bandMean(_ get: (Int, Int) -> Double, _ w: Int, _ h: Int, top: Bool) -> Double {
            let rows = max(1, h / 8)
            let range = top ? 0..<rows : (h - rows)..<h
            var acc = 0.0
            for y in range { for x in 0..<w { acc += get(x, y) } }
            return acc / Double(rows * w)
        }

        let texTop = bandMean({ x, y in
            let (r, g, b) = img.rgb(x: x, y: y)
            return 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        }, img.width, img.height, top: true)
        let texBottom = bandMean({ x, y in
            let (r, g, b) = img.rgb(x: x, y: y)
            return 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        }, img.width, img.height, top: false)

        let cgTop = bandMean({ x, y in
            let i = (y * cg.width + x) * 4
            return 0.2126 * Double(cgHalfs[i]) + 0.7152 * Double(cgHalfs[i + 1])
                + 0.0722 * Double(cgHalfs[i + 2])
        }, cg.width, cg.height, top: true)
        let cgBottom = bandMean({ x, y in
            let i = (y * cg.width + x) * 4
            return 0.2126 * Double(cgHalfs[i]) + 0.7152 * Double(cgHalfs[i + 1])
                + 0.0722 * Double(cgHalfs[i + 2])
        }, cg.width, cg.height, top: false)

        // The image must not be upside down: the top band of the texture has to
        // match the top band of the Core Graphics render, not the bottom one.
        let toTop = abs(texTop - cgTop)
        let toBottom = abs(texTop - cgBottom)
        XCTAssertLessThan(toTop, max(toBottom, 1e-6),
                          "texture appears vertically flipped (top=\(texTop) cgTop=\(cgTop) cgBottom=\(cgBottom) texBottom=\(texBottom))")
    }
}
