import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Which files this app will open, and which of the two decode paths each one
/// takes.
///
/// The split is not cosmetic. A camera RAW goes through `CIRAWFilter`, which
/// demosaics sensor data and exposes a real white balance in Kelvin; everything
/// else is already a rendered RGB image and goes through `CIImage` plus a
/// relative temperature/tint shift. `ImageDecoder` dispatches on `isRAW`, and
/// the library's scanner filters on `isSupported`, so both questions live here
/// rather than being asked twice with two slightly different answers.
public enum ImageFormat {
    /// `UTType.dng` needs macOS 15; the package deploys to 14.
    private static let dng = UTType("com.adobe.raw-image")

    /// Image types this app deliberately does not open.
    ///
    /// GIF and SVG are not photographs — one is an animation container whose
    /// first frame is rarely the point, the other is vector art with no pixels
    /// of its own. PDF does not conform to `.image` at all and is listed only so
    /// the exclusion reads as a complete statement of intent.
    private static let excluded: [UTType] = {
        var types: [UTType] = [.gif, .pdf]
        if let svg = UTType("public.svg-image") { types.append(svg) }
        return types
    }()

    /// The formats named explicitly in the product decision, so the predicate
    /// does not depend entirely on what this OS build's ImageIO happens to list.
    private static let alwaysSupported: [UTType] = {
        var types: [UTType] = [.jpeg, .tiff, .png]
        for identifier in ["public.heic", "public.heif", "public.heics"] {
            if let type = UTType(identifier) { types.append(type) }
        }
        return types
    }()

    /// Everything `CGImageSource` can read on this system, resolved once.
    private static let imageIOTypes: [UTType] = {
        (CGImageSourceCopyTypeIdentifiers() as? [String] ?? []).compactMap(UTType.init)
    }()

    /// The file's type, from the filesystem when it knows and the extension
    /// otherwise.
    public static func contentType(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
    }

    /// Camera RAW, with DNG called out because it is what this project actually
    /// shoots.
    public static func isRAW(_ url: URL) -> Bool {
        guard let type = contentType(of: url) else { return false }
        return isRAW(type)
    }

    public static func isRAW(_ type: UTType) -> Bool {
        if type.conforms(to: .rawImage) { return true }
        if let dng, type.conforms(to: dng) { return true }
        return false
    }

    /// Anything this app will decode: camera RAW, or a still image ImageIO can
    /// open that is not on the exclusion list.
    public static func isSupported(_ url: URL) -> Bool {
        guard let type = contentType(of: url) else { return false }
        if isRAW(type) { return true }
        guard type.conforms(to: .image) else { return false }
        if excluded.contains(where: { type.conforms(to: $0) }) { return false }
        if alwaysSupported.contains(where: { type.conforms(to: $0) }) { return true }
        return imageIOTypes.contains { type.conforms(to: $0) }
    }
}
