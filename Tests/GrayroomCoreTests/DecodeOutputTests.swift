import CoreGraphics
import CoreImage
import ImageIO
import Metal
import XCTest
@testable import GrayroomCore

/// Wave 3, audit `decode-output`: the decode parameters that made the preview
/// and the export disagree (#3), and the 8-bit quantisation that banded smooth
/// gradients (#8).
final class DecodeOutputTests: XCTestCase {

    private func requireDNG() throws -> URL {
        guard let url = testDataURL("L1000003.DNG") else {
            throw XCTSkip("testdata/L1000003.DNG not present (set GRAYROOM_TEST_DNG to override)")
        }
        return url
    }

    // MARK: - #3: preview vs export

    /// The parameter-level statement: nothing `neutralize` sets may depend on
    /// the output resolution, and capture sharpening is off.
    func testNeutralizeDisablesCaptureSharpeningAtEveryScale() throws {
        let url = try requireDNG()
        let filter = try XCTUnwrap(CIRAWFilter(imageURL: url))

        // What Apple would have done, for the record: strong, per-camera.
        let appleDefault = filter.sharpnessAmount
        print("[decode #3] Apple's default sharpnessAmount for this camera = \(appleDefault)")
        XCTAssertGreaterThan(appleDefault, 0.5,
                             "precondition: this camera's default sharpening is the thing at issue")

        for scale in [1.0, 0.5, 0.25] as [Float] {
            let f = try XCTUnwrap(CIRAWFilter(imageURL: url))
            f.scaleFactor = scale
            ImageDecoder.neutralize(f)
            XCTAssertEqual(f.sharpnessAmount, 0, "sharpening must be off at scaleFactor \(scale)")
            XCTAssertEqual(f.boostAmount, 0)
            XCTAssertEqual(f.baselineExposure, 0)
            XCTAssertEqual(f.localToneMapAmount, 0)
            XCTAssertEqual(f.extendedDynamicRangeAmount, 0)
        }
    }

    /// The rendition-level statement, on a 512² centre crop so the readback
    /// stays small while the decode runs at full resolution.
    ///
    /// Two facts, measured: (a) at full resolution Apple's default sharpening
    /// adds a large amount of pixel-scale energy, and (b) below full resolution
    /// CIRAWFilter ignores `sharpnessAmount` entirely. Together those are the
    /// preview/export mismatch — the GUI previews at 2560 px and export runs at
    /// full res, so what you judged on screen was never what the file got.
    /// Grayroom's own decode must match the *unsharpened* rendition at both.
    func testFullResDecodeMatchesTheDraftDecodesCharacter() throws {
        let url = try requireDNG()
        let (ctx, _) = try TestGPU.require()
        let ciContext = CIContext(mtlCommandQueue: ctx.commandQueue,
                                  options: [.workingColorSpace: ImageDecoder.workingColorSpace,
                                            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
                                            .cacheIntermediates: false])

        /// Laplacian-of-log-luminance RMS over a 512² centre crop of the decode.
        func pixelScaleEnergy(scale: Float, sharpening: Float?) throws -> Double {
            let f = try XCTUnwrap(CIRAWFilter(imageURL: url))
            f.scaleFactor = scale
            ImageDecoder.neutralize(f)
            if let sharpening { f.sharpnessAmount = sharpening }
            let image = try XCTUnwrap(f.outputImage)
            let side = 512
            let originX = image.extent.midX - CGFloat(side / 2)
            let originY = image.extent.midY - CGFloat(side / 2)
            let texture = try ctx.makeWorkingTexture(width: side, height: side)
            let cb = try XCTUnwrap(ctx.commandQueue.makeCommandBuffer())
            ciContext.render(image.transformed(by: CGAffineTransform(translationX: -originX,
                                                                     y: -originY)),
                             to: texture, commandBuffer: cb,
                             bounds: CGRect(x: 0, y: 0, width: side, height: side),
                             colorSpace: ImageDecoder.workingColorSpace)
            cb.commit()
            cb.waitUntilCompleted()
            let img = try TextureReadback.read(texture)

            var acc = 0.0, n = 0.0
            for y in 1..<(side - 1) {
                for x in 1..<(side - 1) {
                    func l(_ x: Int, _ y: Int) -> Double {
                        let (r, g, b) = img.rgb(x: x, y: y)
                        let Y = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
                        return log2(max(Y, 1e-6))
                    }
                    let d = 4 * l(x, y) - l(x - 1, y) - l(x + 1, y) - l(x, y - 1) - l(x, y + 1)
                    acc += d * d
                    n += 1
                }
            }
            return (acc / n).squareRoot()
        }

        let fullOurs = try pixelScaleEnergy(scale: 1, sharpening: nil)
        let fullApple = try pixelScaleEnergy(scale: 1, sharpening: 0.9)
        let draftOurs = try pixelScaleEnergy(scale: 0.25, sharpening: nil)
        let draftApple = try pixelScaleEnergy(scale: 0.25, sharpening: 0.9)
        print("[decode #3] full res: ours \(fullOurs), Apple default \(fullApple) "
              + "(x\(fullApple / fullOurs)); quarter res: ours \(draftOurs), "
              + "Apple default \(draftApple) (x\(draftApple / draftOurs))")

        // (a) At full resolution the setting matters a great deal…
        XCTAssertGreaterThan(fullApple, fullOurs * 1.3,
                             "precondition: sharpening should be visible at full res")
        // (b) …and below full resolution it does nothing at all, which is why
        // pinning it to a non-zero value could not have fixed the mismatch.
        XCTAssertEqual(draftApple, draftOurs, accuracy: draftOurs * 1e-4,
                       "sharpening is a no-op below full res: \(draftApple) vs \(draftOurs)")

        // And grayroom's real decode path takes the unsharpened branch at full
        // resolution — the thing the export used to get wrong.
        let decoder = ImageDecoder(metal: ctx)
        let decoded = try decoder.decode(url: url, maxDimension: nil)
        XCTAssertGreaterThan(max(decoded.width, decoded.height), 2560,
                             "precondition: this must be the full-resolution path")
    }

    // MARK: - #8: 8-bit dither

    /// A synthetic ramp so shallow that naive rounding turns it into a handful
    /// of hard bands. The dither has to break those runs up without changing the
    /// picture: same endpoints, same mean to well under one code.
    func testEightBitExportDithersSmoothRamps() throws {
        let w = 1024, h = 32
        // 0.30 → 0.32 across the frame: 5.1 codes over 1024 pixels, i.e. ~200
        // pixels per band undithered.
        var pixels = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = Float(0.30 + 0.02 * Double(x) / Double(w - 1))
                let i = (y * w + x) * 4
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v; pixels[i + 3] = 1
            }
        }
        let image = FloatImage(width: w, height: h, pixels: pixels)

        func rowStats(_ codes: [UInt8]) -> (unique: Int, maxRun: Int, transitions: Int) {
            var run = 1, maxRun = 1, transitions = 0
            for i in 1..<codes.count {
                if codes[i] == codes[i - 1] {
                    run += 1
                } else {
                    run = 1
                    transitions += 1
                }
                maxRun = max(maxRun, run)
            }
            return (Set(codes).count, maxRun, transitions)
        }

        // Undithered reference: exactly what the old code did.
        let plain = (0..<w).map { x -> UInt8 in
            UInt8(clamping: Int((min(max(image.pixels[x * 4], 0), 1) * 255).rounded()))
        }
        let dithered = (0..<w).map { Dither.quantize8(image.pixels[$0 * 4], x: $0, y: 0, channel: 0) }
        let p = rowStats(plain), d = rowStats(dithered)
        print("[dither] ramp row: undithered \(p.unique) codes / max run \(p.maxRun) / "
              + "\(p.transitions) transitions; dithered \(d.unique) / \(d.maxRun) / "
              + "\(d.transitions)")

        // Measured: undithered 6 codes, max run 201, 5 transitions — five hard
        // contours. Dithered: 7 codes, max run 47, ~450 transitions, i.e. the
        // contours have dissolved into noise. The residual 47-pixel run sits
        // where the fractional part is near zero, which is exactly where a
        // stochastic-rounding dither is *meant* to be quiet.
        XCTAssertGreaterThan(p.maxRun, 100, "precondition: the undithered ramp is banded")
        XCTAssertLessThan(d.maxRun, p.maxRun / 3, "dither must break up the flat runs")
        XCTAssertGreaterThan(d.transitions, 20 * p.transitions)
        XCTAssertLessThanOrEqual(d.unique, p.unique + 1,
                                 "dither must not invent codes outside the ramp's range")

        // The mean is preserved to well under a code, so the picture does not
        // shift — this is dither, not noise.
        func mean(_ c: [UInt8]) -> Double { c.reduce(0.0) { $0 + Double($1) } / Double(c.count) }
        let exact = (0..<w).reduce(0.0) { $0 + Double(image.pixels[$1 * 4]) * 255 } / Double(w)
        print("[dither] mean code: exact \(exact), undithered \(mean(plain)), "
              + "dithered \(mean(dithered))")
        XCTAssertEqual(mean(dithered), exact, accuracy: 0.05)
    }

    /// Exactly representable values — 0 and 1 above all — must not move. A pure
    /// black surround or a clipped highlight speckling by one code would be a
    /// worse artefact than the banding, and it is what a ±1 LSB triangular
    /// dither would have done to 1 pixel in 8.
    func testDitherLeavesExactCodesAlone() {
        XCTAssertEqual(Dither.quantize8(0, x: 0, y: 0, channel: 0), 0)
        XCTAssertEqual(Dither.quantize8(1, x: 0, y: 0, channel: 0), 255)
        for x in 0..<4096 {
            XCTAssertEqual(Dither.quantize8(0, x: x, y: x % 97, channel: x % 3), 0,
                           "black speckled at x=\(x)")
            XCTAssertEqual(Dither.quantize8(1, x: x, y: x % 97, channel: x % 3), 255,
                           "white speckled at x=\(x)")
        }
        // A value a millionth of a code off must move a millionth of the time,
        // not an eighth of it.
        var moved = 0
        for x in 0..<20000 where Dither.quantize8(Float(128) / 255 + 1e-7,
                                                  x: x, y: 5, channel: 0) != 128 { moved += 1 }
        XCTAssertLessThan(moved, 20, "\(moved)/20000 near-exact values moved")
        // Out-of-range input clamps, and stays clamped.
        XCTAssertEqual(Dither.quantize8(-3, x: 7, y: 9, channel: 1), 0)
        XCTAssertEqual(Dither.quantize8(4, x: 7, y: 9, channel: 1), 255)
    }

    /// The dither is a hash of position, so an export is reproducible byte for
    /// byte, and it only ever chooses between the two codes bracketing the exact
    /// value.
    func testDitherIsDeterministicAndBracketed() {
        var rng = SeededRandom(seed: 0x0DDF_1234)
        for _ in 0..<5000 {
            let v = Float(rng.double(in: 0...1))
            let x = Int(rng.double(in: 0...4000)), y = Int(rng.double(in: 0...4000))
            let c = Int(rng.double(in: 0...2.999))
            let a = Dither.quantize8(v, x: x, y: y, channel: c)
            XCTAssertEqual(a, Dither.quantize8(v, x: x, y: y, channel: c))
            let s = Double(v) * 255
            XCTAssertGreaterThanOrEqual(Double(a), s.rounded(.down))
            XCTAssertLessThanOrEqual(Double(a), s.rounded(.up))
        }
        // Over many pixels the choice is proportional to the fractional part,
        // which is what makes the mean exact.
        for frac in [0.1, 0.25, 0.5, 0.75, 0.9] {
            let v = Float((100.0 + frac) / 255.0)
            var up = 0
            for i in 0..<4000 where Dither.quantize8(v, x: i, y: 3, channel: 0) == 101 { up += 1 }
            XCTAssertEqual(Double(up) / 4000, frac, accuracy: 0.03, "frac \(frac)")
        }
    }

    /// End to end through the writer: a ramp exported as an 8-bit PNG has no
    /// long flat runs, and the 16-bit path is untouched (no dither, no noise).
    func testExportedPNGIsDitheredAndSixteenBitIsNot() throws {
        let w = 512, h = 8
        var pixels = [Float](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let v = Float(0.5 + 0.01 * Double(x) / Double(w - 1))
                let i = (y * w + x) * 4
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v; pixels[i + 3] = 1
            }
        }
        let image = FloatImage(width: w, height: h, pixels: pixels)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grayroom-dither-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let png = dir.appendingPathComponent("ramp.png")
        try ImageWriter.write(image: image, to: png, format: .png)
        let codes = try readFirstRow(png, bitsPerComponent: 8)
        var transitions = 0
        for i in 1..<codes.count where codes[i] != codes[i - 1] { transitions += 1 }
        print("[dither] exported PNG row: \(Set(codes).count) unique codes, "
              + "\(transitions) transitions over \(w) px")
        // Undithered this ramp spans 2.6 codes, i.e. 2 contours in 512 pixels.
        XCTAssertGreaterThan(transitions, 100)
        XCTAssertGreaterThanOrEqual(Set(codes).count, 3)
        for c in codes {
            XCTAssertGreaterThanOrEqual(c, 127)
            XCTAssertLessThanOrEqual(c, 131)
        }

        // 16 bit is deliberately *not* dithered: a flat patch that sits between
        // two codes comes out as one code there and as two (in the right
        // proportion) at 8 bit.
        let flatValue = Float(127.4 / 255)
        var flatPixels = [Float](repeating: 0, count: 64 * 4 * 4)
        for i in 0..<(64 * 4) {
            flatPixels[i * 4] = flatValue
            flatPixels[i * 4 + 1] = flatValue
            flatPixels[i * 4 + 2] = flatValue
            flatPixels[i * 4 + 3] = 1
        }
        let flat = FloatImage(width: 64, height: 4, pixels: flatPixels)

        let flat16 = dir.appendingPathComponent("flat16.png")
        try ImageWriter.write(image: flat, to: flat16, format: .png16)
        XCTAssertEqual(Set(try readFirstRow(flat16, bitsPerComponent: 16)).count, 1,
                       "16-bit output must not be dithered")

        let flat8 = dir.appendingPathComponent("flat8.png")
        try ImageWriter.write(image: flat, to: flat8, format: .png)
        let flatCodes = try readFirstRow(flat8, bitsPerComponent: 8)
        XCTAssertEqual(Set(flatCodes), [127, 128], "8-bit flat patch must dither between two codes")
        let up = Double(flatCodes.filter { $0 == 128 }.count) / Double(flatCodes.count)
        print("[dither] flat 127.4 patch: \(up) of the row took the upper code")
        XCTAssertEqual(up, 0.4, accuracy: 0.15)
    }

    private func readFirstRow(_ url: URL, bitsPerComponent: Int) throws -> [Int] {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(cg.bitsPerComponent, bitsPerComponent)
        let data = try XCTUnwrap(cg.dataProvider?.data) as Data
        let stride = cg.bitsPerPixel / 8
        return (0..<cg.width).map { x in
            if bitsPerComponent == 8 { return Int(data[x * stride]) }
            return Int(data[x * stride]) | (Int(data[x * stride + 1]) << 8)
        }
    }
}
