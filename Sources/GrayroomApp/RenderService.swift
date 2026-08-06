import Foundation
import GrayroomCore
import Metal

/// All GPU work, off the main thread.
///
/// One serial queue owns the interactive `Renderer` (decode + pipeline). That is
/// a requirement, not a style choice: `Pipeline` keeps a mask rasterisation
/// cache and `MetalContext` a pipeline-state cache, neither of which is
/// thread-safe, and serialising also means a slider drag can never have two
/// renders of the same image in flight.
///
/// Export gets its **own** `Renderer` on its own queue, so a 60 MP full-res
/// export does not freeze the preview loop (and does not evict the preview's
/// mask cache, which is keyed by resolution).
final class RenderService {
    /// Long edge of the interactive preview decode. 2560 is ~3 MP at 3:2, which
    /// renders the whole pipeline in a few ms on Apple Silicon.
    static let previewMaxDimension = 2560

    private let queue = DispatchQueue(label: "com.grayroom.render", qos: .userInitiated)
    private let exportQueue = DispatchQueue(label: "com.grayroom.export", qos: .utility)
    private let renderer: Renderer
    private var exportRenderer: Renderer?

    var metal: MetalContext { renderer.metal }

    init() throws {
        renderer = try Renderer()
    }

    // MARK: - Probe / decode

    func probe(url: URL, completion: @escaping (Result<RawInfo, Error>) -> Void) {
        run(queue) { try self.renderer.decoder.probe(url: url) } completion: { completion($0) }
    }

    func decode(url: URL, edit: EditState, maxDimension: Int?,
                completion: @escaping (Result<DecodedImage, Error>) -> Void) {
        run(queue) {
            try self.renderer.decoder.decode(url: url, edit: edit, maxDimension: maxDimension)
        } completion: { completion($0) }
    }

    // MARK: - Preview render

    struct PreviewResult {
        let texture: MTLTexture
        let histogram: Histogram?
        /// Selected mask's coverage, when the overlay is on.
        let coverage: MTLTexture?
        /// Wall-clock cost of the pipeline run, in milliseconds.
        let milliseconds: Double
    }

    /// Runs the pipeline on an already-decoded linear texture.
    ///
    /// - Parameter coverageMaskIndex: when non-nil the selected mask's coverage
    ///   is rasterised too, for the canvas overlay.
    func renderPreview(input: MTLTexture,
                       edit: EditState,
                       coverageMaskIndex: Int?,
                       completion: @escaping (Result<PreviewResult, Error>) -> Void) {
        run(queue) { () -> PreviewResult in
            let t0 = CFAbsoluteTimeGetCurrent()
            let result = try self.renderer.pipeline.render(input: input, edit: edit,
                                                           computeHistogram: true)
            var coverage: MTLTexture?
            if let i = coverageMaskIndex {
                coverage = try self.renderer.pipeline.maskCoverageTexture(
                    masks: edit.masks, width: input.width, height: input.height, maskIndex: i)
            }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            return PreviewResult(texture: result.texture, histogram: result.histogram,
                                 coverage: coverage, milliseconds: ms)
        } completion: { completion($0) }
    }

    /// The "before" image: the same decode through an all-defaults edit, i.e.
    /// decode + output transform and nothing else. Computed once per decode.
    func renderDefaults(input: MTLTexture,
                        completion: @escaping (Result<MTLTexture, Error>) -> Void) {
        run(queue) {
            try self.renderer.pipeline.render(input: input, edit: EditState()).texture
        } completion: { completion($0) }
    }

    // MARK: - Targeted adjustment sampling

    /// Average linear RGB of a small neighbourhood, sampled from the pipeline
    /// **before** the B&W mix — which is exactly the colour `bwMixKernel` sees.
    ///
    /// (Tone and clarity are both ratio-preserving, so in practice this hue
    /// equals the decoded hue; going through the real stage boundary keeps it
    /// true even if that ever stops being the case.)
    func sampleLinearRGB(input: MTLTexture,
                         edit: EditState,
                         normalized p: CGPoint,
                         radius: Int = 2,
                         completion: @escaping (Result<(Double, Double, Double), Error>) -> Void) {
        run(queue) { () -> (Double, Double, Double) in
            let stage = try self.renderer.pipeline.render(input: input, edit: edit, upTo: .clarity)
            let w = stage.texture.width, h = stage.texture.height
            let cx = Int((Double(p.x) * Double(w)).rounded(.down))
            let cy = Int((Double(p.y) * Double(h)).rounded(.down))
            let side = radius * 2 + 1
            let region = try TextureReadback.readRegion(stage.texture,
                                                        x: cx - radius, y: cy - radius,
                                                        width: side, height: side)
            var r = 0.0, g = 0.0, b = 0.0
            let n = Double(region.width * region.height)
            for i in stride(from: 0, to: region.pixels.count, by: 4) {
                r += Double(region.pixels[i])
                g += Double(region.pixels[i + 1])
                b += Double(region.pixels[i + 2])
            }
            return (r / n, g / n, b / n)
        } completion: { completion($0) }
    }

    // MARK: - Export

    /// Full pipeline at full resolution from a fresh full-res decode.
    func export(url: URL, edit: EditState, to outputURL: URL,
                format: ExportFormat, quality: Double,
                completion: @escaping (Result<Renderer.Output, Error>) -> Void) {
        run(exportQueue) { () -> Renderer.Output in
            let r: Renderer
            if let existing = self.exportRenderer {
                r = existing
            } else {
                r = try Renderer()
                self.exportRenderer = r
            }
            return try r.render(rawURL: url, edit: edit, to: outputURL,
                                format: format, quality: quality,
                                maxDimension: nil, computeHistogram: false)
        } completion: { completion($0) }
    }

    // MARK: - Plumbing

    private func run<T>(_ q: DispatchQueue,
                        _ work: @escaping () throws -> T,
                        completion: @escaping (Result<T, Error>) -> Void) {
        q.async {
            let result: Result<T, Error>
            do { result = .success(try work()) } catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
