import Foundation
import Metal

public enum ReadbackError: Error, CustomStringConvertible {
    case unsupportedPixelFormat(MTLPixelFormat)
    case privateStorage

    public var description: String {
        switch self {
        case .unsupportedPixelFormat(let f): return "unsupported texture pixel format \(f.rawValue)"
        case .privateStorage: return "cannot read back a private-storage texture"
        }
    }
}

/// A CPU copy of an `rgba16Float` texture as tightly packed Float RGBA.
public struct FloatImage {
    public let width: Int
    public let height: Int
    /// `width * height * 4` values, row-major, top row first.
    public let pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    @inline(__always)
    public func rgb(x: Int, y: Int) -> (Float, Float, Float) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }

    /// Rec.709 luminance of the whole image.
    public var meanLuminance: Double {
        guard width * height > 0 else { return 0 }
        var acc = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            acc += 0.2126 * Double(pixels[i]) + 0.7152 * Double(pixels[i + 1]) + 0.0722 * Double(pixels[i + 2])
        }
        return acc / Double(width * height)
    }
}

public enum TextureReadback {
    /// Reads an `rgba16Float` texture into floats, honouring the row stride
    /// Metal hands back (`bytesPerRow` is chosen by us here, so it is tight, but
    /// the unpacking code does not assume it).
    public static func read(_ texture: MTLTexture) throws -> FloatImage {
        guard texture.pixelFormat == .rgba16Float else {
            throw ReadbackError.unsupportedPixelFormat(texture.pixelFormat)
        }
        guard texture.storageMode != .private else { throw ReadbackError.privateStorage }

        let w = texture.width, h = texture.height
        let componentsPerRow = w * 4
        let bytesPerRow = componentsPerRow * MemoryLayout<Float16>.size
        var halfs = [Float16](repeating: 0, count: componentsPerRow * h)
        halfs.withUnsafeMutableBytes { raw in
            texture.getBytes(raw.baseAddress!,
                             bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, w, h),
                             mipmapLevel: 0)
        }
        var floats = [Float](repeating: 0, count: componentsPerRow * h)
        for i in 0..<floats.count { floats[i] = Float(halfs[i]) }
        return FloatImage(width: w, height: h, pixels: floats)
    }

    /// Reads a single-channel texture (`r16Float` mask coverage / parameter
    /// maps, `r32Float` clarity pyramids) into `width * height` floats,
    /// row-major, top row first.
    public static func readScalar(_ texture: MTLTexture) throws -> [Float] {
        guard texture.storageMode != .private else { throw ReadbackError.privateStorage }
        let w = texture.width, h = texture.height
        switch texture.pixelFormat {
        case .r16Float:
            var halfs = [Float16](repeating: 0, count: w * h)
            halfs.withUnsafeMutableBytes { raw in
                texture.getBytes(raw.baseAddress!,
                                 bytesPerRow: w * MemoryLayout<Float16>.size,
                                 from: MTLRegionMake2D(0, 0, w, h),
                                 mipmapLevel: 0)
            }
            return halfs.map { Float($0) }
        case .r32Float:
            var floats = [Float](repeating: 0, count: w * h)
            floats.withUnsafeMutableBytes { raw in
                texture.getBytes(raw.baseAddress!,
                                 bytesPerRow: w * MemoryLayout<Float>.size,
                                 from: MTLRegionMake2D(0, 0, w, h),
                                 mipmapLevel: 0)
            }
            return floats
        default:
            throw ReadbackError.unsupportedPixelFormat(texture.pixelFormat)
        }
    }
}
