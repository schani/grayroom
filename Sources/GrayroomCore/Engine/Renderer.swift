import CoreGraphics
import Foundation
import Metal

/// Convenience façade: decode -> pipeline -> file. Used by the CLI and the
/// end-to-end tests so both exercise the same path.
public final class Renderer {
    public let metal: MetalContext
    public let decoder: ImageDecoder
    public let pipeline: Pipeline
    public let downsampler: Downsampler

    /// A renderer over an existing context.
    ///
    /// Paired with `MetalContext(sharing:)` this is how a second renderer gets
    /// the *device* of the first — so its textures can be drawn by a canvas set
    /// up against that one — without inheriting its command queue or its
    /// resolution-keyed caches.
    public init(metal: MetalContext) throws {
        self.metal = metal
        decoder = ImageDecoder(metal: metal)
        pipeline = try Pipeline(context: metal)
        downsampler = try Downsampler(context: metal)
    }

    public convenience init() throws {
        try self.init(metal: MetalContext())
    }

    public struct Output {
        public let width: Int
        public let height: Int
        public let histogram: Histogram?
        public let temperature: Double
        public let tint: Double
    }

    @discardableResult
    public func render(rawURL: URL,
                       edit: EditState,
                       to outputURL: URL,
                       format: ExportFormat,
                       quality: Double = 0.92,
                       maxDimension: Int? = nil,
                       computeHistogram: Bool = false) throws -> Output {
        let decoded = try decoder.decode(url: rawURL, edit: edit, maxDimension: maxDimension)
        let result = try pipeline.render(input: decoded.texture,
                                         edit: edit,
                                         computeHistogram: computeHistogram)
        try ImageWriter.write(texture: result.texture,
                              to: outputURL,
                              format: format,
                              quality: quality)
        return Output(width: result.texture.width,
                      height: result.texture.height,
                      histogram: result.histogram,
                      temperature: decoded.temperature,
                      tint: decoded.tint)
    }

    /// The same decode → pipeline path as `render(rawURL:…)`, small, and handed
    /// back as an sRGB `CGImage` instead of a file.
    ///
    /// This is what the library grid's rendered previews are made of, so it goes
    /// through the *real* pipeline rather than anything cheaper: a preview whose
    /// tone curve or B&W mix differed from the develop view's would be a picture
    /// of a photo that does not exist. The cost is the decode — capped by
    /// `maxDimension`, though a RAW still demosaics at full size before it can
    /// be reduced.
    ///
    /// Output mode is `.file`: the grid is an SDR surface, so a preview of an
    /// HDR edit is that rendition clipped at SDR white, exactly like an export.
    public func renderPreview(url: URL, edit: EditState, maxDimension: Int) throws -> CGImage {
        let decoded = try decoder.decode(url: url, edit: edit, maxDimension: maxDimension)
        let result = try pipeline.render(input: decoded.texture, edit: edit)
        return try ImageWriter.makeCGImage(TextureReadback.read(result.texture),
                                           bitsPerComponent: 8)
    }
}
