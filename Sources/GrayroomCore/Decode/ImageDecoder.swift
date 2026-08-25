import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Metal

public enum DecodeError: Error, CustomStringConvertible {
    case fileNotFound(URL)
    case undecodable(URL)
    case emptyExtent
    case renderFailed

    public var description: String {
        switch self {
        case .fileNotFound(let u): return "file not found: \(u.path)"
        case .undecodable(let u): return "not a decodable image: \(u.path)"
        case .emptyExtent: return "the image decoded to an empty extent"
        case .renderFailed: return "Core Image failed to render the decoded image"
        }
    }
}

/// Metadata reported by `grayroom probe`.
public struct ImageInfo {
    public var url: URL
    /// Whether this file went down the `CIRAWFilter` path.
    ///
    /// Several fields below only mean something for a RAW: a rendered JPEG has
    /// no decoder version to choose, no lens profile to apply and no separate
    /// preview image, and its "as shot" white balance is by definition neutral.
    public var isRAW: Bool
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
    /// Whether the decoder can reconstruct a clipped highlight channel for this
    /// file, and whether the decode this app runs has it on — it always does
    /// where it is supported, so the two only differ on a system or a file
    /// without it.
    public var highlightRecoverySupported: Bool
    public var highlightRecoveryEnabled: Bool
    /// How much linear headroom above SDR white the file's encoding carries
    /// (1.0 for an SDR file), and the frame's average light level relative to
    /// reference white. `0` means "not known": a RAW is scene-referred and has
    /// neither, and an SDR file has no light level to state.
    public var contentHeadroom: Double
    public var contentAverageLightLevel: Double
    public var cameraMake: String?
    public var cameraModel: String?
    /// EXIF `LensMake` / `LensModel`. Plenty of files carry a model with no
    /// make beside it (adapted and manual glass), so the two are independent.
    public var lensMake: String?
    public var lensModel: String?
    /// EXIF `DateTimeOriginal`, resolved against `OffsetTimeOriginal` when the
    /// file carries one and against the local time zone otherwise.
    public var capturedAt: Date?
    /// EXIF GPS position, with the N/S, E/W and above/below-sea-level
    /// references already applied.
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
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
public final class ImageDecoder {
    public let metal: MetalContext
    private let ciContext: CIContext
    /// Extended linear sRGB: linear transfer, Rec.709 primaries, values outside 0…1 allowed.
    public static let workingColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    public init(metal: MetalContext) {
        self.metal = metal
        self.ciContext = CIContext(
            mtlCommandQueue: metal.commandQueue,
            options: [
                .workingColorSpace: ImageDecoder.workingColorSpace,
                .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
                .cacheIntermediates: false,
                .highQualityDownsample: true,
            ])
    }

    /// The RAW filter for this file, or `nil` when it is not a RAW and should
    /// take the standard-image path.
    ///
    /// The type check comes first, but it is not trusted on its own: a file with
    /// a RAW extension that `CIRAWFilter` cannot actually open falls through to
    /// `CIImage` rather than failing outright. `CIRAWFilter` also happily hands
    /// back a filter for non-RAW input, and a zero native size is the reliable
    /// tell for that.
    static func rawFilter(url: URL) throws -> CIRAWFilter? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DecodeError.fileNotFound(url)
        }
        guard ImageFormat.isRAW(url), let filter = CIRAWFilter(imageURL: url),
              filter.nativeSize.width > 0, filter.nativeSize.height > 0
        else { return nil }
        return filter
    }

    /// The white balance a rendered image is defined to have been "shot" at.
    ///
    /// D65, the sRGB/Rec.709 white point — which is what an already-rendered
    /// JPEG or PNG is encoded against. Reporting it as the as-shot value makes
    /// the UI's "As Shot" reset land on no correction at all, which is the only
    /// sensible neutral for a file that has already been white-balanced once.
    public static let standardNeutralTemperature: Double = 6500
    public static let standardNeutralTint: Double = 0

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
        enableHighlightRecovery(f)
    }

    /// Highlight recovery ON wherever the decoder offers it.
    ///
    /// It reconstructs a channel that clipped while the other two did not, which
    /// is a *demosaic* job — the sensor data needed for it is gone by the time
    /// the pipeline sees a texture. Lightroom has no switch for it either. Not
    /// part of Apple's "pleasing rendering": it recovers detail rather than
    /// imposing a look, so `neutralize` turns it on instead of off.
    static func enableHighlightRecovery(_ f: CIRAWFilter) {
        guard f.isHighlightRecoverySupported else { return }
        f.isHighlightRecoveryEnabled = true
    }

    /// What `decode` will do with this file's clipped highlights, read back off
    /// a filter the same call was made on rather than assumed.
    static func highlightRecovery(_ f: CIRAWFilter) -> (supported: Bool, enabled: Bool) {
        enableHighlightRecovery(f)
        return (f.isHighlightRecoverySupported, f.isHighlightRecoveryEnabled)
    }

    /// The file's HDR statistics: linear headroom above SDR white, and average
    /// light level relative to reference white. `(0, 0)` means neither is known.
    ///
    /// The headroom comes from metadata (`CIImage` reads it off the encoding
    /// without decoding a pixel), and it is also the gate on the light level:
    /// that one needs an HDR decode with `kCGComputeHDRStats`, and probing is on
    /// the import path, where a full-resolution decode of every file would be
    /// the slowest thing the importer does. So an SDR file pays nothing, and an
    /// HDR one pays a 512 px decode — the same number the full frame gives, to
    /// eight digits, because it is a mean.
    static func hdrStats(url: URL) -> (headroom: Double, averageLightLevel: Double) {
        guard let headroom = CIImage(contentsOf: url).map({ Double($0.contentHeadroom) })
        else { return (0, 0) }
        guard headroom > 1, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return (headroom, 0)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
            kCGImageSourceDecodeRequestOptions: [kCGComputeHDRStats: true] as CFDictionary,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return (headroom, 0) }
        return (headroom, Double(image.contentAverageLightLevel))
    }

    // MARK: - Probe

    public func probe(url: URL) throws -> ImageInfo {
        try ImageDecoder.probe(url: url)
    }

    /// Metadata only — no GPU work, so the library importer can read a file's
    /// dimensions, capture date, camera and GPS without a `MetalContext`.
    public static func probe(url: URL) throws -> ImageInfo {
        guard let f = try ImageDecoder.rawFilter(url: url) else {
            return try probeStandard(url: url)
        }
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
        var fileProperties: [String: Any] = [:]
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailFromImageAlways: false,
                kCGImageSourceThumbnailMaxPixelSize: 512,
            ]
            hasThumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) != nil
            fileProperties =
                (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any]) ?? [:]
        }

        // CIRAWFilter's own property dictionary is the primary source; the
        // image source's is the fallback for files where it omits EXIF/GPS.
        let exif = ImageDecoder.section(kCGImagePropertyExifDictionary,
                                        primary: f.properties, fallback: fileProperties)
        let gps = ImageDecoder.section(kCGImagePropertyGPSDictionary,
                                       primary: f.properties, fallback: fileProperties)
        let capturedAt = ImageDecoder.captureDate(exif: exif)
        let (lat, lon, alt) = ImageDecoder.gpsPosition(gps: gps)
        let lens = ImageDecoder.lens(exif: exif)
        let recovery = ImageDecoder.highlightRecovery(f)

        return ImageInfo(
            url: url,
            isRAW: true,
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
            highlightRecoverySupported: recovery.supported,
            highlightRecoveryEnabled: recovery.enabled,
            // Scene-referred sensor data: the headroom metadata describes an
            // encoding, and a RAW has not been encoded against a white yet.
            contentHeadroom: 0,
            contentAverageLightLevel: 0,
            cameraMake: make,
            cameraModel: model,
            lensMake: lens.make,
            lensModel: lens.model,
            capturedAt: capturedAt,
            latitude: lat,
            longitude: lon,
            altitude: alt)
    }

    /// The same metadata for an already-rendered image, entirely out of
    /// ImageIO. Everything RAW-specific reports the honest "not applicable"
    /// value rather than a plausible-looking fiction.
    private static func probeStandard(url: URL) throws -> ImageInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
              as? [String: Any]
        else { throw DecodeError.undecodable(url) }

        let pixelWidth = (properties[kCGImagePropertyPixelWidth as String] as? NSNumber)?
            .doubleValue
        let pixelHeight = (properties[kCGImagePropertyPixelHeight as String] as? NSNumber)?
            .doubleValue
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else {
            throw DecodeError.undecodable(url)
        }
        // Un-oriented, to match what `CIRAWFilter.nativeSize` reports.
        let native = CGSize(width: pixelWidth, height: pixelHeight)
        let rawOrientation = (properties[kCGImagePropertyOrientation as String] as? NSNumber)?
            .uint32Value
        let orientation = rawOrientation
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        let swapped = orientation.rawValue >= 5
        let oriented = swapped ? CGSize(width: pixelHeight, height: pixelWidth) : native

        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any]
        let (lat, lon, alt) = ImageDecoder.gpsPosition(gps: gps)
        let lens = ImageDecoder.lens(exif: exif)

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceThumbnailMaxPixelSize: 512,
        ]
        let hasThumb = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary) != nil
        let hdr = ImageDecoder.hdrStats(url: url)

        return ImageInfo(
            url: url,
            isRAW: false,
            nativeSize: native,
            orientation: orientation,
            orientedSize: oriented,
            asShotTemperature: ImageDecoder.standardNeutralTemperature,
            asShotTint: ImageDecoder.standardNeutralTint,
            // No decoder version to pick and no lens profile to apply: the file
            // is already a rendering, and this app does not pretend it can undo
            // one.
            decoderVersion: "ImageIO",
            supportedDecoderVersions: [],
            hasEmbeddedThumbnail: hasThumb,
            // The image *is* the preview; there is no second, smaller rendition
            // the way a RAW carries one.
            hasPreviewImage: false,
            lensCorrectionSupported: false,
            // Both RAW-only: there is no demosaic left to recover a channel in.
            highlightRecoverySupported: false,
            highlightRecoveryEnabled: false,
            contentHeadroom: hdr.headroom,
            contentAverageLightLevel: hdr.averageLightLevel,
            cameraMake: tiff?[kCGImagePropertyTIFFMake as String] as? String,
            cameraModel: tiff?[kCGImagePropertyTIFFModel as String] as? String,
            lensMake: lens.make,
            lensModel: lens.model,
            capturedAt: ImageDecoder.captureDate(exif: exif),
            latitude: lat,
            longitude: lon,
            altitude: alt)
    }

    // MARK: - EXIF / GPS

    /// One of a property dictionary's sub-dictionaries, taken from `primary`
    /// and from `fallback` only when `primary` has none.
    ///
    /// `CIRAWFilter.properties` is the primary source for a RAW, and it does
    /// omit whole sections for some files — where ImageIO's own dictionary for
    /// the same file still has them. Falling back per *section* rather than per
    /// key keeps the two dictionaries from being interleaved: a file is
    /// described by one of them, whichever one describes it.
    static func section(_ key: CFString, primary: [AnyHashable: Any],
                        fallback: [AnyHashable: Any]) -> [String: Any]? {
        (primary[key as String] as? [String: Any])
            ?? (fallback[key as String] as? [String: Any])
    }

    /// EXIF `LensMake` / `LensModel`, blank-trimmed, with empty strings
    /// reported as "not there" rather than as a lens with no name.
    static func lens(exif: [String: Any]?) -> (make: String?, model: String?) {
        func string(_ key: CFString) -> String? {
            guard let raw = exif?[key as String] as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return (string(kCGImagePropertyExifLensMake), string(kCGImagePropertyExifLensModel))
    }

    /// The file's capture date read straight from ImageIO's property
    /// dictionary — no `CIRAWFilter`, so this costs a header read rather than a
    /// decoder set-up, which is what the import grid needs for a few thousand
    /// files.
    public static func captureDate(url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
              as? [String: Any]
        else { return nil }
        return captureDate(exif: properties[kCGImagePropertyExifDictionary as String]
            as? [String: Any])
    }

    /// EXIF `DateTimeOriginal` (`"yyyy:MM:dd HH:mm:ss"`, no zone) plus
    /// `OffsetTimeOriginal` (`"+02:00"`) when present; local time otherwise.
    static func captureDate(exif: [String: Any]?) -> Date? {
        guard let exif,
              let stamp = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String
        else { return nil }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let offset = exif[kCGImagePropertyExifOffsetTimeOriginal as String] as? String,
           let seconds = ImageDecoder.utcOffsetSeconds(offset) {
            fmt.timeZone = TimeZone(secondsFromGMT: seconds)
        } else {
            fmt.timeZone = TimeZone.current
        }
        return fmt.date(from: stamp)
    }

    /// `"+02:00"` / `"-05:30"` / `"Z"` → seconds from GMT.
    static func utcOffsetSeconds(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s == "Z" || s == "z" { return 0 }
        guard let sign = s.first, sign == "+" || sign == "-" else { return nil }
        let parts = s.dropFirst().split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        let magnitude = h * 3600 + m * 60
        return sign == "-" ? -magnitude : magnitude
    }

    static func gpsPosition(gps: [String: Any]?) -> (Double?, Double?, Double?) {
        guard let gps else { return (nil, nil, nil) }
        var lat = (gps[kCGImagePropertyGPSLatitude as String] as? NSNumber)?.doubleValue
        var lon = (gps[kCGImagePropertyGPSLongitude as String] as? NSNumber)?.doubleValue
        if let ref = gps[kCGImagePropertyGPSLatitudeRef as String] as? String,
           ref.uppercased() == "S" {
            lat = lat.map { -$0 }
        }
        if let ref = gps[kCGImagePropertyGPSLongitudeRef as String] as? String,
           ref.uppercased() == "W" {
            lon = lon.map { -$0 }
        }
        var alt = (gps[kCGImagePropertyGPSAltitude as String] as? NSNumber)?.doubleValue
        // Altitude ref 1 means "below sea level".
        if let ref = (gps[kCGImagePropertyGPSAltitudeRef as String] as? NSNumber)?.intValue,
           ref == 1 {
            alt = alt.map { -$0 }
        }
        return (lat, lon, alt)
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
        guard let f = try ImageDecoder.rawFilter(url: url) else {
            return try decodeStandard(url: url, edit: edit, maxDimension: maxDimension)
        }
        ImageDecoder.neutralize(f)

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

        guard let image = f.outputImage else { throw DecodeError.renderFailed }
        // `outputImage` already has orientation applied.
        let texture = try render(image, maxDimension: maxDimension)

        return DecodedImage(texture: texture,
                            temperature: temperature,
                            tint: tint,
                            asShotTemperature: asShotTemp,
                            asShotTint: asShotTint,
                            nativeSize: native)
    }

    /// The already-rendered path: JPEG, TIFF, PNG, HEIC.
    ///
    /// These files carry no sensor data and no as-shot white balance — they have
    /// already been demosaiced, white-balanced and encoded once. So there is
    /// nothing to neutralise and nothing to undo; the honest job is to get the
    /// pixels into the working space *linearly* and leave them alone.
    ///
    /// `CIImage(contentsOf:options:)` honours the embedded ICC profile by
    /// default, and rendering through `ciContext` — whose working space is
    /// extended linear sRGB — is what undoes the file's transfer function. An
    /// sRGB code value of 128 therefore lands at its linear equivalent, not at
    /// 0.5. No auto-enhance, no tone mapping: Core Image applies neither unless
    /// asked, and this does not ask.
    ///
    /// White balance is a *relative* shift here, not an absolute one. A RAW has
    /// a real illuminant to name; a JPEG's white is already D65 by construction,
    /// so temp/tint move the image away from that reference rather than picking
    /// a new interpretation of the sensor data.
    private func decodeStandard(url: URL, edit: EditState,
                                maxDimension: Int?) throws -> DecodedImage {
        guard var image = CIImage(contentsOf: url,
                                  options: [.applyOrientationProperty: true])
        else { throw DecodeError.undecodable(url) }
        guard !image.extent.isEmpty, !image.extent.isInfinite else {
            throw DecodeError.emptyExtent
        }
        // Un-oriented, to match the RAW path's `nativeSize`.
        let oriented = image.extent.size
        let info = try? ImageDecoder.probe(url: url)
        let native = info?.nativeSize ?? oriented

        let asShotTemp = ImageDecoder.standardNeutralTemperature
        let asShotTint = ImageDecoder.standardNeutralTint
        let temperature = edit.whiteBalance.temperature ?? asShotTemp
        let tint = edit.whiteBalance.tint ?? asShotTint
        if edit.whiteBalance.temperature != nil || edit.whiteBalance.tint != nil {
            image = ImageDecoder.applyTemperatureAndTint(image, temperature: temperature,
                                                         tint: tint)
        }

        let texture = try render(image, maxDimension: maxDimension)
        return DecodedImage(texture: texture,
                            temperature: temperature,
                            tint: tint,
                            asShotTemperature: asShotTemp,
                            asShotTint: asShotTint,
                            nativeSize: native)
    }

    /// Temp/tint for an already-rendered image, in the same direction as the
    /// RAW slider.
    ///
    /// The argument order is the part worth stating, because the obvious
    /// assignment is backwards. `CITemperatureAndTint` adapts *from* `neutral`
    /// *to* `targetNeutral`, so putting the slider value in `targetNeutral`
    /// makes a higher Kelvin cool the image — the opposite of `CIRAWFilter`,
    /// where raising `neutralTemperature` warms it (measured on a test DNG:
    /// R/B 0.18 at 3624 K, 0.84 at 6040 K, 1.55 at 9665 K). A slider that
    /// reverses meaning depending on the file's format would be a bug, so the
    /// slider value goes in `neutral` and the D65 reference in `targetNeutral`.
    /// Measured that way on a neutral grey patch, this path tracks the RAW one
    /// on both axes: R/B 0.35 at 4000 K and 1.49 at 9000 K, and (R+B)/2G 0.68
    /// at tint −60 and 1.59 at tint +80, against 0.70 and 1.61 from
    /// `CIRAWFilter`.
    static func applyTemperatureAndTint(_ image: CIImage, temperature: Double,
                                        tint: Double) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: temperature, y: tint)
        filter.targetNeutral = CIVector(x: ImageDecoder.standardNeutralTemperature,
                                        y: ImageDecoder.standardNeutralTint)
        return filter.outputImage ?? image
    }

    /// Lanczos down to `maxDimension` on the longer edge, or the image itself
    /// when it is already at or below it.
    static func reduced(_ image: CIImage, maxDimension: Int?) -> CIImage {
        guard let maxDim = maxDimension else { return image }
        let longest = max(image.extent.width, image.extent.height)
        guard longest > CGFloat(maxDim) else { return image }
        let lanczos = CIFilter(name: "CILanczosScaleTransform")!
        lanczos.setValue(image, forKey: kCIInputImageKey)
        lanczos.setValue(NSNumber(value: Double(CGFloat(maxDim) / longest)),
                         forKey: kCIInputScaleKey)
        lanczos.setValue(NSNumber(value: 1.0), forKey: kCIInputAspectRatioKey)
        return lanczos.outputImage ?? image
    }

    /// The camera's own rendering of a file, as an sRGB `CGImage`.
    ///
    /// Apple's "pleasing rendering" left **on**, which is the whole point:
    /// this is what a photo nobody has developed looks like — the same picture
    /// the camera embedded a JPEG of, only with as many pixels as the sensor
    /// has. `decode` neutralises all of it because the pipeline needs linear
    /// scene-referred data; nothing here goes through the pipeline.
    ///
    /// The loupe magnifies to this once an embedded preview has run out of
    /// pixels, which is the only reason it exists: at Fit the embedded JPEG is
    /// the same picture for a thousandth of the cost.
    public func cameraImage(url: URL, maxDimension: Int? = nil) throws -> CGImage {
        var image: CIImage
        if let f = try ImageDecoder.rawFilter(url: url) {
            ImageDecoder.enableHighlightRecovery(f)
            let longestNative = max(f.nativeSize.width, f.nativeSize.height)
            if let maxDim = maxDimension, longestNative > 0, CGFloat(maxDim) < longestNative {
                f.scaleFactor = Float(max(0.01, min(1.0, CGFloat(maxDim) / longestNative)))
            }
            guard let output = f.outputImage else { throw DecodeError.renderFailed }
            image = output
        } else {
            guard let standard = CIImage(contentsOf: url,
                                         options: [.applyOrientationProperty: true])
            else { throw DecodeError.undecodable(url) }
            image = standard
        }
        guard !image.extent.isEmpty, !image.extent.isInfinite else {
            throw DecodeError.emptyExtent
        }
        image = ImageDecoder.reduced(image, maxDimension: maxDimension)
        // `deferred: false` matters: the default hands back a `CGImage` that
        // renders when its pixels are first read, which for the loupe would be
        // on the main thread inside `makeDisplayTexture` — a hundred-megapixel
        // demosaic in the middle of a frame. Pay it here, on the queue that
        // asked for it.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let cgImage = ciContext.createCGImage(image, from: image.extent,
                                                    format: .RGBA8, colorSpace: space,
                                                    deferred: false)
        else { throw DecodeError.renderFailed }
        return cgImage
    }

    /// Optional reduction, then origin/flip normalisation, then the render into
    /// a working texture. Shared by both decode paths so preview and export
    /// cannot drift apart between formats.
    private func render(_ input: CIImage, maxDimension: Int?) throws -> MTLTexture {
        var image = input
        guard !image.extent.isEmpty, !image.extent.isInfinite else {
            throw DecodeError.emptyExtent
        }
        image = ImageDecoder.reduced(image, maxDimension: maxDimension)

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
        guard let cb = metal.commandQueue.makeCommandBuffer() else {
            throw DecodeError.renderFailed
        }
        ciContext.render(image,
                         to: texture,
                         commandBuffer: cb,
                         bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: ImageDecoder.workingColorSpace)
        cb.commit()
        cb.waitUntilCompleted()
        if cb.error != nil { throw DecodeError.renderFailed }
        return texture
    }
}
