import Foundation
import Metal

/// Fixed-order global pipeline for M1 + M2, with M3 local adjustments.
///
///   input (linear, WB applied at decode)
///     -> masks      (rasterise strokes -> per-pixel parameter maps) [no masks: skipped]
///     -> tone       (exposure + 5 tone controls + local deltas, ratio-preserving)
///     -> clarity    (fast local Laplacian on log2 luminance, per-pixel amount) [skipped at 0]
///     -> mix        (B&W mixer, or the colour style, by treatment)
///                                                  [colour + neutral: skipped]
///     -> toning     (split tone, luminance-neutral) [skipped when identity]
///     -> output     (file: linear -> sRGB, clamped 0…1;
///                    display: linear, clamped 0…W)
///     -> histogram tap (on the linear texture the output stage reads)
///
/// Each stage is a type in `Stages/`; `passes(for:)` lists the ones an edit
/// actually needs, and `render` runs that list.
///
/// Everything ahead of `mix` is colour-agnostic — it scales all three channels
/// alike, preserving their ratios — and `mix` is the slot `EditState.treatment`
/// fills: the B&W mixer, or the colour style.
///
/// With zero active masks nothing about the encoding changes: the tone kernel's
/// `hasLocal` flag is 0 and the clarity stage gets its 1x1 global amount
/// texture, so the result is bit-for-bit the pre-M3 one.
public final class Pipeline {
    /// What the pipeline renders, as a number. Bump it whenever the same edit
    /// starts producing different pixels — a stage's arithmetic, or a decoder
    /// option like highlight recovery. It is mixed into
    /// `EditState.fingerprint`, so bumping it is what makes every stored
    /// preview stale (see `EditStateIO`).
    ///
    /// 2: highlight recovery on wherever `CIRAWFilter` supports it.
    public static let rendererVersion = 2

    public let context: MetalContext

    private let histogramPipeline: MTLComputePipelineState
    private let toneStage: ToneStage
    private let clarityStage: ClarityStage
    private let bwMixStage: BWMixStage
    private let styleStage: StyleStage
    private let toningStage: ToningStage
    private let outputStage: OutputStage
    let maskStage: MaskStage

    /// Rasterisation depends only on the strokes and the resolution, never on
    /// the sliders, so moving a slider reuses the maps.
    ///
    /// Two entries, least-recently-used first: the interactive loop alternates a
    /// draft render with a full-resolution refine of the *same* strokes, and a
    /// single entry keyed by resolution would re-rasterise every stamp on every
    /// frame of a slider drag.
    private struct MaskCacheEntry {
        var masks: [Mask]
        var width: Int
        var height: Int
        var maps: MaskStage.Maps
    }
    private var maskCache: [MaskCacheEntry] = []
    private static let maskCacheCapacity = 2

    /// Test hook: the resolutions currently held by the mask cache, least
    /// recently used first.
    var maskCacheResolutions: [(width: Int, height: Int)] {
        maskCache.map { ($0.width, $0.height) }
    }

    /// Drops the rasterised maps. At full resolution an entry is a 24 MP
    /// `rgba16Float` plus an `r16Float` — ~240 MB — and two of them outlive any
    /// reason to keep them the moment a different image is opened.
    public func clearMaskCache() {
        maskCache.removeAll()
    }

    public init(context: MetalContext) throws {
        self.context = context
        histogramPipeline = try context.computePipeline("histogramKernel")
        toneStage = try ToneStage(context: context)
        clarityStage = try ClarityStage(context: context)
        bwMixStage = try BWMixStage(context: context)
        styleStage = try StyleStage(context: context)
        toningStage = try ToningStage(context: context)
        outputStage = try OutputStage(context: context)
        maskStage = try MaskStage(context: context)
    }

    /// Stage boundaries, in pipeline order; `mix` is the slot the B&W mixer or
    /// the colour style occupies. Useful for golden tests that need to inspect
    /// an intermediate (still linear) result.
    public enum Stage: Int, CaseIterable, Sendable {
        case tone, clarity, mix, toning, output
    }

    /// What the `output` stage produces.
    public enum OutputMode: Sendable {
        /// What a file gets: sRGB-encoded, clamped to `[0, 1]`. Independent of
        /// `EditState.hdr` — export is always SDR.
        case file
        /// What the canvas gets: **linear**, clamped to `[0, W]`, unencoded and
        /// undithered, for an extended-linear-sRGB float16 drawable. `W` is
        /// `EditState.displayWhite`.
        case display
    }

    /// One image pass: reads `source`, writes `destination`, same size,
    /// rgba16Float.
    struct Pass {
        let stage: Stage
        let encode: (_ cb: MTLCommandBuffer,
                     _ source: MTLTexture,
                     _ destination: MTLTexture) throws -> Void
    }

    /// The adjustment passes this edit needs, in pipeline order. A stage that
    /// would be the identity is left out, so the default edit is tone and mix
    /// only. `output` is not here: it is fixed, and its mode comes from the
    /// render call rather than the edit.
    func passes(for edit: EditState, maps: MaskStage.Maps?,
                width: Int, height: Int) -> [Pass] {
        let masks = edit.activeMasks
        var passes: [Pass] = []

        // Local deltas are applied analytically on top of the global LUT's
        // output; see Tone.metal and ToneCurve.applyToneDelta. The shoulder
        // aims at the edit's ceiling whatever the output mode is — `hdr` is part
        // of the rendition, so a file export of an HDR edit is that rendition
        // clipped, not a different picture.
        let hasLocalTone = maps != nil && masks.contains { $0.adjustments.affectsTone }
        let toneParams = hasLocalTone ? maps!.paramsA : nil
        passes.append(Pass(stage: .tone) { cb, src, dst in
            try self.toneStage.encode(cb, source: src, destination: dst, tone: edit.tone,
                                      params: toneParams, displayWhite: edit.displayWhite)
        })

        if edit.clarityActive {
            let globalClarity = min(max(edit.clarity, 0), 100)
            let localClarity = maps != nil && masks.contains { $0.adjustments.clarity != 0 }
            if localClarity {
                // One pyramid for the whole frame, always at the full-scale
                // lift; the amount map scales it per pixel. A region whose
                // deltas push the effective clarity below 0 gets amount 0.
                let peak = MaskRasterizer.clarityRange(global: globalClarity, masks: masks).hi
                if peak > 0 {
                    let paramsB = maps!.paramsB
                    passes.append(Pass(stage: .clarity) { cb, src, dst in
                        let amount = try self.maskStage.encodeClarityAmount(
                            cb, paramsB: paramsB, globalClarity: globalClarity,
                            width: width, height: height)
                        try self.clarityStage.encode(cb, source: src, destination: dst,
                                                     clarity: peak, amountTexture: amount)
                    })
                }
            } else {
                passes.append(Pass(stage: .clarity) { cb, src, dst in
                    try self.clarityStage.encode(cb, source: src, destination: dst,
                                                 clarity: globalClarity)
                })
            }
        }

        // The mixer slot, where the colour-agnostic part of the pipeline ends.
        // The neutral style is the pipeline's own rendition, so it runs nothing.
        switch edit.treatment {
        case .blackAndWhite:
            passes.append(Pass(stage: .mix) { cb, src, dst in
                try self.bwMixStage.encode(cb, source: src, destination: dst, mix: edit.bwMix)
            })
        case .color:
            if edit.style != .neutral {
                let parameters = ColorStyleParameters.parameters(for: edit.style)
                passes.append(Pass(stage: .mix) { cb, src, dst in
                    try self.styleStage.encode(cb, source: src, destination: dst,
                                               parameters: parameters)
                })
            }
        }

        if !edit.toning.isIdentity {
            passes.append(Pass(stage: .toning) { cb, src, dst in
                try self.toningStage.encode(cb, source: src, destination: dst,
                                            toning: edit.toning)
            })
        }

        return passes
    }

    public struct Result {
        /// The rendered texture: output-referred (sRGB-encoded) for
        /// `OutputMode.file`, display-linear for `.display`, or the linear
        /// intermediate when `upTo` stopped short of `.output`.
        public let texture: MTLTexture
        public let histogram: Histogram?
    }

    /// Runs the pipeline. `input` must be linear scene-referred rgba16Float.
    ///
    /// - Parameter output: `.file` (the default) is byte-for-byte the export
    ///   path; `.display` writes display-linear values for the canvas.
    /// - Parameter generateDisplayMipmaps: allocate the working textures with a
    ///   mip pyramid and fill the output's before the command buffer completes.
    ///   Only the app's canvas wants this; file output paths leave it off and
    ///   are unaffected, pixel for pixel.
    public func render(input: MTLTexture,
                       edit: EditState,
                       upTo lastStage: Stage = .output,
                       output outputMode: OutputMode = .file,
                       computeHistogram: Bool = false,
                       generateDisplayMipmaps: Bool = false) throws -> Result {
        let w = input.width, h = input.height
        // The output clamp, and the number the histogram normalises against.
        // A file always ends at SDR white.
        let outputCeiling = outputMode == .display ? edit.displayWhite : 1.0

        // Both working textures carry the pyramid: which of the two ends up
        // holding the result depends on how many stages ran, and a mipmapped
        // pair costs less than a mipmapped copy of a flat one.
        var src = input
        var dst = try context.makeWorkingTexture(width: w, height: h,
                                                 mipmapped: generateDisplayMipmaps)
        let spare = try context.makeWorkingTexture(width: w, height: h,
                                                   mipmapped: generateDisplayMipmaps)
        var pool = [spare]

        guard let commandBuffer = context.commandQueue.makeCommandBuffer() else {
            throw MetalError.encoderFailed
        }

        func advance() {
            // Never recycle the caller's input texture.
            if src !== input { pool.append(src) }
            src = dst
            dst = pool.removeFirst()
        }

        var latest = input
        func runs(_ stage: Stage) -> Bool { lastStage.rawValue >= stage.rawValue }

        // --- masks ----------------------------------------------------------
        let maps = try maskMaps(commandBuffer, masks: edit.activeMasks, width: w, height: h)

        // --- adjustments ---------------------------------------------------
        let plan = passes(for: edit, maps: maps, width: w, height: h)
        for pass in plan where runs(pass.stage) {
            try pass.encode(commandBuffer, src, dst)
            latest = dst
            advance()
        }

        // --- output transform -----------------------------------------------
        // The histogram taps the texture the output stage *reads*, so it is
        // captured here, before the ping-pong moves on. Nothing writes to it
        // again: `advance()` puts it back in the pool, but the pool is not
        // touched after the last stage.
        let preOutput = src
        if runs(.output) {
            try outputStage.encode(commandBuffer, source: src, destination: dst,
                                   mode: outputMode, ceiling: outputCeiling)
            latest = dst
            advance()
        }
        let output = latest

        // --- histogram tap ----------------------------------------------------
        var histogramBuffer: MTLBuffer?
        if computeHistogram, runs(.output) {
            let counterCount = 258
            guard let buf = context.device.makeBuffer(
                length: counterCount * MemoryLayout<UInt32>.stride,
                options: .storageModeShared) else { throw MetalError.textureAllocationFailed }
            memset(buf.contents(), 0, buf.length)
            var white = Float(outputCeiling)
            try context.encodePass(commandBuffer, histogramPipeline, width: w, height: h) { e in
                e.setTexture(preOutput, index: 0)
                e.setBuffer(buf, offset: 0, index: 0)
                e.setBytes(&white, length: MemoryLayout<Float>.stride, index: 1)
            }
            histogramBuffer = buf
        }

        // --- display mip pyramid ------------------------------------------------
        if generateDisplayMipmaps, output !== input, output.mipmapLevelCount > 1 {
            guard let blit = commandBuffer.makeBlitCommandEncoder() else {
                throw MetalError.encoderFailed
            }
            blit.generateMipmaps(for: output)
            blit.endEncoding()
        }

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let err = commandBuffer.error { throw err }

        var histogram: Histogram?
        if let buf = histogramBuffer {
            let p = buf.contents().bindMemory(to: UInt32.self, capacity: 258)
            let bins = Array(UnsafeBufferPointer(start: p, count: 256))
            histogram = Histogram(bins: bins,
                                  pixelCount: w * h,
                                  shadowClippedPixels: Int(p[256]),
                                  highlightClippedPixels: Int(p[257]))
        }
        return Result(texture: output, histogram: histogram)
    }

    // MARK: - Masks

    /// The parameter maps for `masks`, from the cache when the strokes and the
    /// resolution are unchanged. Cached maps were produced by an already
    /// completed command buffer, so they need no extra synchronisation.
    private func maskMaps(_ cb: MTLCommandBuffer,
                          masks: [Mask],
                          width: Int, height: Int) throws -> MaskStage.Maps? {
        guard !masks.isEmpty else { return nil }
        if let i = maskCache.firstIndex(where: {
            $0.width == width && $0.height == height && $0.masks == masks
        }) {
            let entry = maskCache.remove(at: i)
            maskCache.append(entry)                      // most recently used last
            return entry.maps
        }
        let maps = try maskStage.encodeMaps(cb, masks: masks, width: width, height: height)
        maskCache.append(MaskCacheEntry(masks: masks, width: width, height: height, maps: maps))
        if maskCache.count > Pipeline.maskCacheCapacity { maskCache.removeFirst() }
        return maps
    }

    /// Rasterised mask coverage at `width x height`, read back to the CPU.
    /// `maskIndex` selects one mask; `nil` unions every enabled mask. This is
    /// what `grayroom mask-preview` renders.
    public func maskCoverage(masks: [Mask],
                             width: Int, height: Int,
                             maskIndex: Int? = nil) throws -> [Float] {
        let texture = try maskCoverageTexture(masks: masks, width: width, height: height,
                                              maskIndex: maskIndex)
        return try TextureReadback.readScalar(texture)
    }

    /// The same coverage, left on the GPU as an `r16Float` texture. The GUI
    /// composites this as a translucent overlay on the canvas, so reading it
    /// back to the CPU first would be pure waste.
    ///
    /// `maskIndex` selects one mask *whether or not it is enabled* (the overlay
    /// shows what you are painting); `nil` unions every enabled mask.
    public func maskCoverageTexture(masks: [Mask],
                                    width: Int, height: Int,
                                    maskIndex: Int? = nil) throws -> MTLTexture {
        let selected: [Mask]
        if let i = maskIndex {
            selected = (i >= 0 && i < masks.count) ? [masks[i]] : []
        } else {
            selected = masks.filter { $0.enabled }
        }
        guard let cb = context.commandQueue.makeCommandBuffer() else { throw MetalError.encoderFailed }
        let texture = try maskStage.encodeUnionCoverage(cb, masks: selected,
                                                        width: width, height: height)
        cb.commit()
        cb.waitUntilCompleted()
        if let err = cb.error { throw err }
        return texture
    }

    /// Test hook: the tone stage alone, with an explicit per-pixel parameter map.
    func renderToneOnly(input: MTLTexture,
                        tone: EditState.Tone,
                        params: MTLTexture?) throws -> MTLTexture {
        guard let cb = context.commandQueue.makeCommandBuffer() else { throw MetalError.encoderFailed }
        let dst = try context.makeWorkingTexture(width: input.width, height: input.height)
        try toneStage.encode(cb, source: input, destination: dst, tone: tone, params: params)
        cb.commit()
        cb.waitUntilCompleted()
        if let err = cb.error { throw err }
        return dst
    }

    /// Test hook: the style stage alone, from hand-built parameters rather than
    /// one of the presets.
    func renderStyleOnly(input: MTLTexture,
                         parameters: ColorStyleParameters) throws -> MTLTexture {
        guard let cb = context.commandQueue.makeCommandBuffer() else { throw MetalError.encoderFailed }
        let dst = try context.makeWorkingTexture(width: input.width, height: input.height)
        try styleStage.encode(cb, source: input, destination: dst, parameters: parameters)
        cb.commit()
        cb.waitUntilCompleted()
        if let err = cb.error { throw err }
        return dst
    }
}
