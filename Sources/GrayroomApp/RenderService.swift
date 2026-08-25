import CoreGraphics
import Foundation
import GrayroomCore
import GrayroomLibrary
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
    private let queue = DispatchQueue(label: "com.grayroom.render", qos: .userInitiated)
    private let exportQueue = DispatchQueue(label: "com.grayroom.export", qos: .utility)
    private let previewQueue = DispatchQueue(label: "com.grayroom.gridpreview", qos: .utility)
    private let loupeQueue = DispatchQueue(label: "com.grayroom.loupe", qos: .userInitiated)
    private let renderer: Renderer
    private var exportRenderer: Renderer?
    private var gridPreviewRenderer: Renderer?
    private var loupeRenderer: Renderer?

    var metal: MetalContext { renderer.metal }

    init() throws {
        renderer = try Renderer()
    }

    // MARK: - Probe / decode

    func probe(url: URL, completion: @escaping (Result<ImageInfo, Error>) -> Void) {
        run(queue) { try self.renderer.decoder.probe(url: url) } completion: { completion($0) }
    }

    /// A decode plus the reduced copy the draft pass renders from. `draft` is
    /// `nil` when the frame is already at or below `draftLongEdge`.
    struct DecodeResult {
        let image: DecodedImage
        let draft: MTLTexture?
    }

    /// Decodes and, in the same hop, builds the draft input. Reducing costs a
    /// couple of ms and is worth paying once per decode rather than once per
    /// frame of a slider drag.
    func decode(url: URL, edit: EditState, maxDimension: Int?, draftLongEdge: Int,
                completion: @escaping (Result<DecodeResult, Error>) -> Void) {
        run(queue) { () -> DecodeResult in
            let image = try self.renderer.decoder.decode(url: url, edit: edit,
                                                         maxDimension: maxDimension)
            let draft = try self.renderer.downsampler.downsampled(image.texture,
                                                                  longEdge: draftLongEdge)
            return DecodeResult(image: image, draft: draft)
        } completion: { completion($0) }
    }

    /// Drops the rasterised mask maps, which at full resolution are the largest
    /// thing the renderer holds between edits. Opening a different image is the
    /// one moment they are certainly dead.
    func clearMaskCache() {
        queue.async { self.renderer.pipeline.clearMaskCache() }
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
    ///   is rasterised too, for the canvas overlay — at `input`'s resolution, so
    ///   that the overlay and the image it is drawn over always describe the
    ///   same frame whether this is a draft or a refine.
    /// - Parameter computeHistogram: off for a draft pass, whose numbers nobody
    ///   would have time to read.
    func renderPreview(input: MTLTexture,
                       edit: EditState,
                       coverageMaskIndex: Int?,
                       computeHistogram: Bool,
                       completion: @escaping (Result<PreviewResult, Error>) -> Void) {
        run(queue) { () -> PreviewResult in
            let t0 = CFAbsoluteTimeGetCurrent()
            let result = try self.renderer.pipeline.render(input: input, edit: edit,
                                                           output: .display,
                                                           computeHistogram: computeHistogram,
                                                           generateDisplayMipmaps: true)
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
    ///
    /// All-defaults includes `hdr = false`, so "before" is always the SDR
    /// rendition — holding `\` on an HDR edit shows what the picture was, which
    /// is the comparison the key is for.
    func renderDefaults(input: MTLTexture,
                        completion: @escaping (Result<MTLTexture, Error>) -> Void) {
        run(queue) {
            try self.renderer.pipeline.render(input: input, edit: EditState(),
                                              output: .display,
                                              generateDisplayMipmaps: true).texture
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
            try self.rendererForExport().render(rawURL: url, edit: edit, to: outputURL,
                                                format: format, quality: quality,
                                                maxDimension: nil, computeHistogram: false)
        } completion: { completion($0) }
    }

    /// Several photos into one folder, on the same queue and the same renderer
    /// as a single export. `isCancelled` is polled on the worker — `TaskCenter`
    /// answers it from any thread — and `progress` lands on the main queue.
    func exportBatch(_ jobs: [ExportJob], to directory: URL,
                     format: ExportFormat, quality: Double,
                     isCancelled: @escaping () -> Bool,
                     progress: @escaping (Int, String) -> Void,
                     completion: @escaping (Result<BatchExportResult, Error>) -> Void) {
        run(exportQueue) { () -> BatchExportResult in
            BatchExport.run(jobs, to: directory, format: format, quality: quality,
                            renderer: try self.rendererForExport(),
                            isCancelled: isCancelled,
                            progress: { done, name in
                                DispatchQueue.main.async { progress(done, name) }
                            })
        } completion: { completion($0) }
    }

    /// Only ever touched on `exportQueue`.
    private func rendererForExport() throws -> Renderer {
        if let existing = exportRenderer { return existing }
        let r = try Renderer()
        exportRenderer = r
        return r
    }

    // MARK: - Grid previews

    /// A small render of one photo for the library grid, off on its own.
    ///
    /// Third `Renderer`, third queue, for the same reason export has its own: a
    /// grid preview is a full decode of a file that is *not* the one being
    /// edited, and running it on the interactive queue would put a
    /// hundred-megapixel demosaic in front of the next slider frame and evict
    /// the preview's mask cache besides. `PreviewBuilder` runs one of these at a
    /// time and holds them back while the user is editing; this end only has to
    /// keep them off the interactive queue.
    func renderGridPreview(url: URL, edit: EditState, maxDimension: Int,
                           completion: @escaping (Result<CGImage, Error>) -> Void) {
        run(previewQueue) { () -> CGImage in
            let r: Renderer
            if let existing = self.gridPreviewRenderer {
                r = existing
            } else {
                r = try Renderer()
                self.gridPreviewRenderer = r
            }
            return try r.renderPreview(url: url, edit: edit, maxDimension: maxDimension)
        } completion: { completion($0) }
    }

    // MARK: - The library loupe

    /// The loupe's picture of one photo: a decode capped at `maxDimension`
    /// (`nil` for the file's own pixels) through the real pipeline, handed back
    /// as a **display texture** rather than a `CGImage` so it keeps the
    /// headroom an 8-bit image would throw away.
    ///
    /// Its own `Renderer` on its own queue, for the reason export has one: this
    /// is a whole decode of a file the develop view is not editing, and the
    /// mask cache it fills is keyed by a resolution the interactive loop never
    /// asks for. Its context shares the interactive one's *device* — so the
    /// texture is one the canvas can draw — and nothing else.
    func renderLoupe(url: URL, edit: EditState, maxDimension: Int?,
                     completion: @escaping (Result<MTLTexture, Error>) -> Void) {
        run(loupeQueue) { () -> MTLTexture in
            let renderer = try self.loupe()
            let decoded = try renderer.decoder.decode(url: url, edit: edit,
                                                      maxDimension: maxDimension)
            return try renderer.pipeline.render(input: decoded.texture, edit: edit,
                                                output: .display,
                                                computeHistogram: false,
                                                generateDisplayMipmaps: true).texture
        } completion: { completion($0) }
    }

    /// The camera's own rendering of a file, for a photo with no development
    /// whose embedded preview has run out of pixels.
    ///
    /// Handed back as a texture rather than a `CGImage` because the copy into
    /// one is not free either: at a hundred megapixels it is 400 MB and a
    /// mipmap chain, which is not something to do on the main thread.
    func decodeCameraTexture(url: URL, maxDimension: Int?,
                             completion: @escaping (Result<MTLTexture, Error>) -> Void) {
        run(loupeQueue) { () -> MTLTexture in
            let renderer = try self.loupe()
            let image = try renderer.decoder.cameraImage(url: url, maxDimension: maxDimension)
            return try renderer.metal.makeDisplayTexture(from: image)
        } completion: { completion($0) }
    }

    /// Drops the rasterised masks the loupe's renderer holds. At a hundred
    /// megapixels they are the largest thing it keeps between photos, and
    /// stepping to another photo is the moment they are certainly dead.
    func clearLoupeMaskCache() {
        loupeQueue.async { self.loupeRenderer?.pipeline.clearMaskCache() }
    }

    private func loupe() throws -> Renderer {
        if let existing = loupeRenderer { return existing }
        let renderer = try Renderer(metal: MetalContext(sharing: self.renderer.metal))
        loupeRenderer = renderer
        return renderer
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
