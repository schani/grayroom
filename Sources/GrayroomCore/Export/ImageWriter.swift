import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

public enum ExportFormat: String, CaseIterable, Sendable {
    case png            // 8-bit
    case png16          // 16-bit
    case jpeg           // 8-bit
    case tiff16         // 16-bit

    public var bitsPerComponent: Int {
        switch self {
        case .png, .jpeg: return 8
        case .png16, .tiff16: return 16
        }
    }

    var utType: UTType {
        switch self {
        case .png, .png16: return .png
        case .jpeg: return .jpeg
        case .tiff16: return .tiff
        }
    }

    public var fileExtension: String {
        switch self {
        case .png, .png16: return "png"
        case .jpeg: return "jpg"
        case .tiff16: return "tif"
        }
    }
}

public enum ExportError: Error, CustomStringConvertible {
    case cgImageCreationFailed
    case destinationCreationFailed(URL)
    case writeFailed(URL)

    public var description: String {
        switch self {
        case .cgImageCreationFailed: return "could not build a CGImage from the output texture"
        case .destinationCreationFailed(let u): return "could not create an image destination at \(u.path)"
        case .writeFailed(let u): return "could not write \(u.path)"
        }
    }
}

/// ImageIO writers. Input is the output-referred (sRGB-encoded, 0…1) texture;
/// files are tagged sRGB and written without an alpha channel.
public enum ImageWriter {
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    public static func write(texture: MTLTexture,
                             to url: URL,
                             format: ExportFormat,
                             quality: Double = 0.92) throws {
        let image = try TextureReadback.read(texture)
        try write(image: image, to: url, format: format, quality: quality)
    }

    public static func write(image: FloatImage,
                             to url: URL,
                             format: ExportFormat,
                             quality: Double = 0.92) throws {
        let cg = try makeCGImage(image, bitsPerComponent: format.bitsPerComponent)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, format.utType.identifier as CFString, 1, nil)
        else { throw ExportError.destinationCreationFailed(url) }

        var props: [CFString: Any] = [:]
        if format == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0), 1)
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.writeFailed(url) }
    }

    /// Builds an interleaved RGB (no alpha) CGImage. 8-bit uses one byte per
    /// component; 16-bit uses host-endian UInt16.
    public static func makeCGImage(_ image: FloatImage, bitsPerComponent: Int) throws -> CGImage {
        let w = image.width, h = image.height
        let componentsPerPixel = 3
        let data: CFData
        let bytesPerRow: Int
        var bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)

        if bitsPerComponent == 8 {
            bytesPerRow = w * componentsPerPixel
            var bytes = [UInt8](repeating: 0, count: bytesPerRow * h)
            for p in 0..<(w * h) {
                for c in 0..<3 {
                    let v = image.pixels[p * 4 + c]
                    bytes[p * 3 + c] = UInt8(clamping: Int((min(max(v, 0), 1) * 255).rounded()))
                }
            }
            data = Data(bytes) as CFData
        } else {
            bytesPerRow = w * componentsPerPixel * 2
            var words = [UInt16](repeating: 0, count: w * h * componentsPerPixel)
            for p in 0..<(w * h) {
                for c in 0..<3 {
                    let v = image.pixels[p * 4 + c]
                    words[p * 3 + c] = UInt16(clamping: Int((min(max(v, 0), 1) * 65535).rounded()))
                }
            }
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue
                                      | CGBitmapInfo.byteOrder16Little.rawValue)
            data = words.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        }

        guard let provider = CGDataProvider(data: data),
              let cg = CGImage(width: w,
                               height: h,
                               bitsPerComponent: bitsPerComponent,
                               bitsPerPixel: bitsPerComponent * componentsPerPixel,
                               bytesPerRow: bytesPerRow,
                               space: sRGB,
                               bitmapInfo: bitmapInfo,
                               provider: provider,
                               decode: nil,
                               shouldInterpolate: false,
                               intent: .defaultIntent)
        else { throw ExportError.cgImageCreationFailed }
        return cg
    }
}
