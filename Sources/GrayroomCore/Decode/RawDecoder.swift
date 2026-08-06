import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Metal

public enum DecodeError: Error, CustomStringConvertible {
    case fileNotFound(URL)
    case notRAW(URL)
    case emptyExtent
    case renderFailed

    public var description: String {
        switch self {
        case .fileNotFound(let u): return "file not found: \(u.path)"
        case .notRAW(let u): return "not a decodable RAW file: \(u.path)"
        case .emptyExtent: return "RAW decoded to an empty extent"
        case .renderFailed: return "Core Image failed to render the decoded RAW"
        }
    }
}

/// Metadata reported by `grayroom probe`.
public struct RawInfo {
    public var url: URL
    public var nativeSize: CGSize
    public var orientation: CGImagePropertyOrientation
    public var orientedSize: CGSize
    public var asShotTemperature: Double
    public var asShotTint: Double
    public var decoderVersion: String
    public var supportedDecoderVersions: [String]
    public var hasEmbeddedThumbnail: Bool
    public var hasPreviewImage: Bool
    public var lensCorrectionSupported: Bool
    public var cameraMake: String?
    public var cameraModel: String?
}

/// A decoded, linear scene-referred image.
public struct DecodedImage {
    public let texture: MTLTexture
    /// White balance actually used (as-shot unless the edit overrode it).
    public let temperature: Double
    public let tint: Double
    public let asShotTemperature: Double
    public let asShotTint: Double
    public let nativeSize: CGSize

    public var width: Int { texture.width }
    public var height: Int { texture.height }
}

/// CIRAWFilter -> linear `rgba16Float` `MTLTexture`.
///
/// Apple's "pleasing rendering" is neutralised (baseline exposure, shadow bias,
/// global/local tone curves and gamut mapping all off) so the pipeline gets a
/// genuinely linear scene-referred image. Lens correction stays on and noise
/// reduction keeps its per-camera defaults.
public final class RawDecoder {
    public let metal: MetalContext
    private let ciContext: CIContext
    /// Extended linear sRGB: linear transfer, Rec.709 primaries, values outside 0…1 allowed.
    public static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    public init(metal: MetalContext) {
        self.metal = metal
        self.ciContext = CIContext(
            mtlCommandQueue: metal.commandQueue,
            options: [
                .workingColorSpace: RawDecoder.workingColorSpace,
                .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
                .cacheIntermediates: false,
                .highQualityDownsample: true,
            ])
    }

    private static func makeFilter(url: URL) throws -> CIRAWFilter {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DecodeError.fileNotFound(url)
        }
        guard let filter = CIRAWFilter(imageURL: url) else { throw DecodeError.notRAW(url) }
        // CIRAWFilter happily hands back a filter for non-RAW input; a zero
        // native size is the reliable tell.
        guard filter.nativeSize.width > 0, filter.nativeSize.height > 0 else {
            throw DecodeError.notRAW(url)
        }
        return filter
    }

    /// Zeroes Apple's look so the output is linear scene-referred.
    ///
    /// Internal rather than private so `DecodeOutputTests` can assert the
    /// resulting settings directly: the preview/export agreement this buys is a
    /// property of *these parameters*, not of any one rendition.
    static func neutralize(_ f: CIRAWFilter) {
        f.baselineExposure = 0
        f.shadowBias = 0
        f.boostAmount = 0
        f.boostShadowAmount = 0
        f.localToneMapAmount = 0
        f.isGamutMappingEnabled = false
        f.exposure = 0
        f.extendedDynamicRangeAmount = 0
        // Capture sharpening OFF (wave 3, audit `decode-output` #3).
        //
        // Apple's per-camera default is `sharpnessAmount = 0.9` on these Leica
        // DNGs — measured: +83 % Laplacian-of-log-luminance RMS on a full-res
        // centre crop. But CIRAWFilter silently *disables* sharpening whenever
        // `scaleFactor < 1`, and the GUI previews at 2560 px while export runs
        // at full resolution. So the on-screen image had no capture sharpening
        // and the exported file had a strong, uncontrollable one, with clarity
        // running downstream of it amplifying halos that were never visible
        // while editing. Pinning it to a fixed non-zero value would not fix
        // that — it is a no-op below full res either way — so the only value
        // that makes preview and export agree is 0. A real
        // Amount/Radius/Detail/Masking stage is deferred (M5).
        f.sharpnessAmount = 0
        // Lens correction stays on; NR keeps its per-camera defaults (measured
        // scale-invariant, so it does not break preview/export agreement).
    }

    // MARK: - Probe

    public func probe(url: URL) throws -> RawInfo {
        let f = try RawDecoder.makeFilter(url: url)
        let native = f.nativeSize
        let orientation = f.orientation
        let swapped = orientation.rawValue >= 5
        let oriented = swapped ? CGSize(width: native.height, height: native.width) : native

        var make: String?
        var model: String?
        if let tiff = f.properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            make = tiff[kCGImagePropertyTIFFMake as String] as? String
            model = tiff[kCGImagePropertyTIFFModel as String] as? String
        }

        var hasThumb = false
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailFromImageAlways: false,
                kCGImageSourceThumbnailMaxPixelSize: 512,
            ]
            hasThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) != nil
        }

        return RawInfo(
            url: url,
            nativeSize: native,
            orientation: orientation,
            orientedSize: oriented,
            asShotTemperature: Double(f.neutralTemperature),
            asShotTint: Double(f.neutralTint),
            decoderVersion: f.decoderVersion.rawValue,
            supportedDecoderVersions: f.supportedDecoderVersions.map(\.rawValue),
            hasEmbeddedThumbnail: hasThumb,
            hasPreviewImage: f.previewImage != nil,
            lensCorrectionSupported: f.isLensCorrectionSupported,
            cameraMake: make,
            cameraModel: model)
    }

    // MARK: - Decode

    /// Decodes to a linear `rgba16Float` texture.
    ///
    /// - Parameter maxDimension: if set, the longer output edge is capped at
    ///   this many pixels. A coarse reduction is asked of the RAW decoder
    ///   (`scaleFactor`, which is both faster and better than post-scaling) and
    ///   any residual is trimmed with Lanczos.
    public func decode(url: URL,
                       edit: EditState = EditState(),
                       maxDimension: Int? = nil) throws -> DecodedImage {
        let f = try RawDecoder.makeFilter(url: url)
        RawDecoder.neutralize(f)

        let asShotTemp = Double(f.neutralTemperature)
        let asShotTint = Double(f.neutralTint)

        // White balance is applied at decode time in v1 (see PLAN.md).
        let temperature = edit.whiteBalance.temperature ?? asShotTemp
        let tint = edit.whiteBalance.tint ?? asShotTint
        if edit.whiteBalance.temperature != nil || edit.whiteBalance.tint != nil {
            f.neutralTemperature = Float(temperature)
            f.neutralTint = Float(tint)
        }

        let native = f.nativeSize
        let longestNative = max(native.width, native.height)
        if let maxDim = maxDimension, longestNative > 0, CGFloat(maxDim) < longestNative {
            f.scaleFactor = Float(max(0.01, min(1.0, CGFloat(maxDim) / longestNative)))
        }

        guard var image = f.outputImage else { throw DecodeError.renderFailed }
        guard !image.extent.isEmpty, !image.extent.isInfinite else { throw DecodeError.emptyExtent }

        // `outputImage` already has orientation applied.
        if let maxDim = maxDimension {
            let longest = max(image.extent.width, image.extent.height)
            if longest > CGFloat(maxDim) {
                let scale = CGFloat(maxDim) / longest
                let lanczos = CIFilter(name: "CILanczosScaleTransform")!
                lanczos.setValue(image, forKey: kCIInputImageKey)
                lanczos.setValue(NSNumber(value: Double(scale)), forKey: kCIInputScaleKey)
                lanczos.setValue(NSNumber(value: 1.0), forKey: kCIInputAspectRatioKey)
                if let scaled = lanczos.outputImage { image = scaled }
            }
        }

        // Move to the origin so texture coordinates line up.
        let extent = image.extent
        if extent.origin != .zero {
            image = image.transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                                            y: -extent.origin.y))
        }
        let width = Int(image.extent.width.rounded())
        let height = Int(image.extent.height.rounded())
        guard width > 0, height > 0 else { throw DecodeError.emptyExtent }

        // Core Image is bottom-left origin, MTLTexture row 0 is the top row, so
        // flip vertically to keep the texture in image order.
        image = image.transformed(
            by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height)))

        let texture = try metal.makeWorkingTexture(width: width, height: height)
        guard let cb = metal.commandQueue.makeCommandBuffer() else { throw DecodeError.renderFailed }
        ciContext.render(image,
                         to: texture,
                         commandBuffer: cb,
                         bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: RawDecoder.workingColorSpace)
        cb.commit()
        cb.waitUntilCompleted()
        if cb.error != nil { throw DecodeError.renderFailed }

        return DecodedImage(texture: texture,
                            temperature: temperature,
                            tint: tint,
                            asShotTemperature: asShotTemp,
                            asShotTint: asShotTint,
                            nativeSize: native)
    }
}
