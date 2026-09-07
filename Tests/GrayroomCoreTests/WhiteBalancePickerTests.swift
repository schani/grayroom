import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import XCTest
@testable import GrayroomCore

/// The eyedropper: clicking a neutral area has to make that area render neutral,
/// on a RAW and on an already-rendered file, whatever the file's orientation.
final class WhiteBalancePickerTests: XCTestCase {

    // MARK: - Robertson

    /// D65 sits *above* the Planckian locus — 6504 K at tint +10, which is what
    /// Lightroom shows for a daylight-balanced shot, and why the picker states
    /// its tint relative to this point rather than to the locus.
    func testD65IsSixAndAHalfThousandKelvin() {
        let d65 = CorrelatedColorTemperature.temperatureAndTint(x: 0.3127, y: 0.3290)
        XCTAssertEqual(d65.temperature, 6504, accuracy: 10)
        XCTAssertEqual(d65.tint, 10, accuracy: 1)
    }

    /// A point *on* the Planckian locus reports the locus temperature and no
    /// tint of its own.
    func testAPlanckianPointReportsItsOwnTemperature() {
        let p = CorrelatedColorTemperature.temperatureAndTint(x: 0.4369, y: 0.4041)
        XCTAssertEqual(p.temperature, 3000, accuracy: 40)
        XCTAssertEqual(p.tint, 0, accuracy: 3)
    }

    /// Above the locus is green, below it is magenta — opposite signs, which is
    /// the whole content of the tint axis.
    func testTintChangesSignAcrossTheLocus() {
        let above = CorrelatedColorTemperature.temperatureAndTint(x: 0.4369, y: 0.4241)
        let below = CorrelatedColorTemperature.temperatureAndTint(x: 0.4369, y: 0.3841)
        XCTAssertGreaterThan(above.tint * below.tint * -1, 0,
                             "above \(above.tint), below \(below.tint)")
    }

    // MARK: - RAW

    func testPickingOnAnOrientationOneRAW() throws {
        try assertPickIsNeutral(file: "DSC02345.ARW", at: CGPoint(x: 0.6, y: 0.4),
                                tolerance: 0.03)
    }

    /// Orientation 6 — this is what pins the coordinate mapping: a picker that
    /// ignored the rotation would sample the wrong corner.
    func testPickingOnAnOrientationSixRAW() throws {
        try assertPickIsNeutral(file: "L1000003.DNG", at: CGPoint(x: 0.3, y: 0.7),
                                tolerance: 0.03)
    }

    // MARK: - Rendered images

    func testPickingOnAPNGWithAKnownCast() throws {
        let (ctx, _) = try TestGPU.require()
        let decoder = ImageDecoder(metal: ctx)
        let url = try writeCast(name: "wb-cast.png", linear: (0.225, 0.18, 0.144))
        let point = CGPoint(x: 0.5, y: 0.5)

        let pick = try WhiteBalancePicker.pick(url: url, edit: EditState(),
                                               normalized: point, decoder: decoder)
        XCTAssertFalse(pick.isClipped)
        XCTAssertEqual(pick.sample.x / pick.sample.y, 1.25, accuracy: 0.02, "the cast was written")

        var edit = EditState()
        edit.whiteBalance = pick.whiteBalance
        let after = try WhiteBalancePicker.mean(url: url, edit: edit, at: point, decoder: decoder)
        report("PNG cast", pick: pick, after: after)
        XCTAssertEqual(after.x / after.y, 1, accuracy: 0.02)
        XCTAssertEqual(after.z / after.y, 1, accuracy: 0.02)
    }

    // MARK: - Clipping

    func testAClippedSampleIsRefusedAndADarkOneIsNot() throws {
        let (ctx, _) = try TestGPU.require()
        let decoder = ImageDecoder(metal: ctx)
        let point = CGPoint(x: 0.5, y: 0.5)

        let blown = try writeCast(name: "wb-blown.png", linear: (1, 1, 1))
        let clipped = try WhiteBalancePicker.pick(url: blown, edit: EditState(),
                                                  normalized: point, decoder: decoder)
        XCTAssertGreaterThanOrEqual(clipped.sample.max(), WhiteBalancePicker.clipLevel)
        XCTAssertTrue(clipped.isClipped)

        let grey = try writeCast(name: "wb-grey.png", linear: (0.4, 0.4, 0.4))
        let fine = try WhiteBalancePicker.pick(url: grey, edit: EditState(),
                                               normalized: point, decoder: decoder)
        XCTAssertFalse(fine.isClipped)
    }

    // MARK: - Helpers

    private func assertPickIsNeutral(file: String, at point: CGPoint, tolerance: Double,
                                     line: UInt = #line) throws {
        guard let url = testDataURL(file) else {
            throw XCTSkip("testdata/\(file) not present")
        }
        let (ctx, _) = try TestGPU.require()
        let decoder = ImageDecoder(metal: ctx)
        let pick = try WhiteBalancePicker.pick(url: url, edit: EditState(),
                                               normalized: point, decoder: decoder)
        XCTAssertNotNil(pick.whiteBalance.temperature, file: #filePath, line: line)
        XCTAssertNotNil(pick.whiteBalance.tint, file: #filePath, line: line)

        var edit = EditState()
        edit.whiteBalance = pick.whiteBalance
        let after = try WhiteBalancePicker.mean(url: url, edit: edit, at: point, decoder: decoder)
        report(file, pick: pick, after: after)
        XCTAssertEqual(after.x / after.y, 1, accuracy: tolerance, file: #filePath, line: line)
        XCTAssertEqual(after.z / after.y, 1, accuracy: tolerance, file: #filePath, line: line)
    }

    private func report(_ what: String, pick: WhiteBalancePick, after: SIMD3<Double>) {
        print(String(format: "[wb pick] %@: %.0f K tint %+.1f, before r/g %.3f b/g %.3f, "
                     + "after r/g %.4f b/g %.4f",
                     what, pick.whiteBalance.temperature ?? 0, pick.whiteBalance.tint ?? 0,
                     pick.sample.x / pick.sample.y, pick.sample.z / pick.sample.y,
                     after.x / after.y, after.z / after.y))
    }

    /// A 64×64 PNG of one linear colour, written as sRGB code values — so the
    /// decoder has to linearize it back to what was asked for.
    private func writeCast(name: String, linear: (Double, Double, Double)) throws -> URL {
        func encode(_ c: Double) -> UInt8 {
            let x = min(max(c, 0), 1)
            let s = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            return UInt8(min(max((s * 255).rounded(), 0), 255))
        }
        let side = 64
        var bytes = [UInt8](repeating: 255, count: side * side * 4)
        for i in 0..<(side * side) {
            bytes[i * 4] = encode(linear.0)
            bytes[i * 4 + 1] = encode(linear.1)
            bytes[i * 4 + 2] = encode(linear.2)
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: side * 4, space: space, bitmapInfo: info,
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        let url = SyntheticImage.directory.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw XCTSkip("ImageIO cannot write PNG here") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("ImageIO could not finalize the PNG")
        }
        return url
    }
}
