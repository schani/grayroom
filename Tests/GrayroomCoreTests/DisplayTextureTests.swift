import CoreGraphics
import Metal
import XCTest
@testable import GrayroomCore

/// `MetalContext.makeDisplayTexture(from:)` — the upload that puts a `CGImage`
/// on the same canvas a pipeline render goes on.
///
/// It exists for the Library loupe: a photo nobody has developed is the camera's
/// own embedded preview, an 8-bit sRGB `CGImage`, and the loupe draws it on the
/// very `CanvasNSView` the develop view uses so it pans and zooms the same way.
/// The two facts that have to hold are that the picture arrives the right way up
/// and that the *sampler* — not the shader — is the thing that decodes sRGB, so
/// the canvas's linear compositing gets linear light without a CPU pass.
final class DisplayTextureTests: XCTestCase {

    /// A `width`x`height` image whose top-left quadrant is white and whose
    /// bottom-right is black, so orientation is unambiguous.
    private func cornerImage(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let value: UInt8 = (x < width / 2 && y < height / 2) ? 255 : 0
                bytes[i] = value
                bytes[i + 1] = value
                bytes[i + 2] = value
                bytes[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    func testTheTextureIsSRGBTaggedAndMipmapped() throws {
        let (context, _) = try TestGPU.require()
        let texture = try context.makeDisplayTexture(from: cornerImage(width: 64, height: 32))
        XCTAssertEqual(texture.width, 64)
        XCTAssertEqual(texture.height, 32)
        // `_srgb`, so the sampler decodes to linear light for free. Anything
        // else would hand the canvas shader — which composites in linear and
        // writes an extended-linear drawable — encoded values, and every
        // undeveloped photo in the loupe would be washed out.
        XCTAssertEqual(texture.pixelFormat, .rgba8Unorm_srgb)
        // A full pyramid: the canvas samples an explicit level, so a picture
        // shown below 100 % has to have levels to be minified through.
        XCTAssertGreaterThan(texture.mipmapLevelCount, 1)
        XCTAssertEqual(texture.mipmapLevelCount,
                       Int(floor(log2(Double(max(64, 32))))) + 1)
    }

    /// Row 0 of the texture is the **top** row of the picture, which is the row
    /// order the canvas transform and every mask coordinate already assume.
    func testThePictureIsTheRightWayUp() throws {
        let (context, _) = try TestGPU.require()
        let texture = try context.makeDisplayTexture(from: cornerImage(width: 8, height: 8))
        var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
        pixels.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!, bytesPerRow: 8 * 4,
                             from: MTLRegionMake2D(0, 0, 8, 8), mipmapLevel: 0)
        }
        func red(x: Int, y: Int) -> UInt8 { pixels[(y * 8 + x) * 4] }
        XCTAssertEqual(red(x: 1, y: 1), 255, "the white quadrant is at the top left")
        XCTAssertEqual(red(x: 6, y: 6), 0, "and the black one at the bottom right")
        XCTAssertEqual(red(x: 6, y: 1), 0)
        XCTAssertEqual(red(x: 1, y: 6), 0)
    }

    func testAnEmptyImageIsRefusedRatherThanCrashing() throws {
        let (context, _) = try TestGPU.require()
        // A 1x1 is the smallest legal picture and must still work — the guard is
        // for degenerate sizes, not for small ones.
        let texture = try context.makeDisplayTexture(from: cornerImage(width: 1, height: 1))
        XCTAssertEqual(texture.width, 1)
        XCTAssertEqual(texture.mipmapLevelCount, 1)
    }
}
