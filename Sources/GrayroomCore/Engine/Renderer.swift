import Foundation
import Metal

/// Convenience façade: decode -> pipeline -> file. Used by the CLI and the
/// end-to-end tests so both exercise the same path.
public final class Renderer {
    public let metal: MetalContext
    public let decoder: RawDecoder
    public let pipeline: Pipeline
    public let downsampler: Downsampler

    public init() throws {
        metal = try MetalContext()
        decoder = RawDecoder(metal: metal)
        pipeline = try Pipeline(context: metal)
        downsampler = try Downsampler(context: metal)
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
}
