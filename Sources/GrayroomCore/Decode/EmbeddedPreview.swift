import CoreGraphics
import Foundation
import ImageIO

/// The cheap thumbnail path: ImageIO's embedded JPEG preview, never the RAW
/// decoder.
///
/// The import grid shows a few thousand files at once, so a thumbnail has to
/// cost roughly a JPEG decode of a small image. `CIRAWFilter` — which is what
/// `ImageDecoder` uses — demosaics the sensor data before it can hand back a
/// single pixel, which is three orders of magnitude more work and needs a
/// `MetalContext` besides. Every RAW format this app opens carries an embedded
/// preview, so the fast path is the normal one; the `FromImageAlways` retry
/// exists only for the file that does not.
public enum EmbeddedPreview {
    /// The file's embedded preview, scaled so its longer edge is at most
    /// `maxPixelSize`, with the EXIF orientation already applied.
    ///
    /// Returns `nil` when ImageIO cannot read the file at all.
    public static func thumbnail(url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            // Without this the thumbnail comes back in sensor orientation and
            // every portrait frame in the grid lies on its side.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return image
        }
        // No embedded preview: pay for a full decode of this one file rather
        // than showing a blank cell.
        options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
