import Foundation
import Metal

/// Fixed-order global pipeline for M1 + M2, with M3 local adjustments.
///
///   input (linear, WB applied at decode)
///     -> masks      (rasterise strokes -> per-pixel parameter maps) [no masks: skipped]
///     -> tone       (exposure + 5 tone controls + local deltas, ratio-preserving)
///     -> clarity    (fast local Laplacian on log2 luminance, per-pixel amount) [skipped at 0]
///     -> bwMix      (8 hue bands -> gray)          [skipped when disabled]
///     -> toning     (split tone, luminance-neutral) [skipped when identity]
///     -> output     (linear -> sRGB)
///     -> histogram tap
///
/// With zero active masks nothing about the encoding changes: the tone kernel's
/// `hasLocal` flag is 0 and the clarity stage gets its 1x1 global amount
/// texture, so the result is bit-for-bit the pre-M3 one.
public final class Pipeline {
    public let context: MetalContext

    private let tonePipeline: MTLComputePipelineState
    private let bwMixPipeline: MTLComputePipelineState
    private let toningPipeline: MTLComputePipelineState
    private let outputPipeline: MTLComputePipelineState
    private let histogramPipeline: MTLComputePipelineState
    private let clarityStage: ClarityStage
    let maskStage: MaskStage

    /// Rasterisation depends only on the strokes and the resolution, never on
    /// the sliders, so moving a slider reuses the maps. One entry is enough for
    /// the CLI and for the M4 GUI's single-image editing loop.
    private var maskCache: (masks: [Mask], width: Int, height: Int, maps: MaskStage.Maps)?

    public init(context: MetalContext) throws {
        self.context = context
        tonePipeline = try context.computePipeline("toneKernel")
        bwMixPipeline = try context.computePipeline("bwMixKernel")
        toningPipeline = try context.computePipeline("toningKernel")
        outputPipeline = try context.computePipeline("outputKernel")
        histogramPipeline = try context.computePipeline("histogramKernel")
        clarityStage = try ClarityStage(context: context)
        maskStage = try MaskStage(context: context)
    }

    /// Stage boundaries, in pipeline order. Useful for golden tests that need to
    /// inspect an intermediate (still linear) result.
    public enum Stage: Int, CaseIterable, Sendable {
        case tone, clarity, bwMix, toning, output
    }

    public struct Result {
        /// Output-referred (sRGB-encoded) rgba16Float texture, or the linear
        /// intermediate when `upTo` stopped short of `.output`.
        public let texture: MTLTexture
        public let histogram: Histogram?
    }

    /// Runs the pipeline. `input` must be linear scene-referred rgba16Float.
    public func render(input: MTLTexture,
                       edit: EditState,
                       upTo lastStage: Stage = .output,
                       computeHistogram: Bool = false) throws -> Result {
        let w = input.width, h = input.height

        var src = input
        var dst = try context.makeWorkingTexture(width: w, height: h)
        let spare = try context.makeWorkingTexture(width: w, height: h)
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
        let masks = edit.activeMasks
        let maps = try maskMaps(commandBuffer, masks: masks, width: w, height: h)

        // --- tone -----------------------------------------------------------
        // Local deltas are applied analytically on top of the global LUT's
        // output; see Tone.metal and ToneCurve.applyToneDelta.
        let hasLocalTone = maps != nil && masks.contains { $0.adjustments.affectsTone }
        try encodeTone(commandBuffer, src: src, dst: dst, tone: edit.tone,
                       params: hasLocalTone ? maps!.paramsA : nil)
        latest = dst
        advance()

        // --- clarity ---------------------------------------------------------
        // Skipped entirely when nothing asks for it, so the default edit is
        // bit-for-bit unchanged.
        let localClarity = maps != nil && masks.contains { $0.adjustments.clarity != 0 }
        if runs(.clarity), edit.clarity != 0 || localClarity {
            if localClarity {
                // One variant for the whole frame — full-scale for the dominant
                // *sign*; the amount map scales it per pixel and zeroes any
                // pixel whose clarity has the opposite sign (see
                // MaskRasterizer.clarityVariant).
                let variant = MaskRasterizer.clarityVariant(global: edit.clarity, masks: masks)
                if variant.clarity != 0 {
                    let amount = try maskStage.encodeClarityAmount(
                        commandBuffer,
                        paramsB: maps!.paramsB,
                        globalClarity: edit.clarity,
                        dominantSign: variant.sign,
                        width: w, height: h)
                    try clarityStage.encode(commandBuffer, source: src, destination: dst,
                                            clarity: variant.clarity, amountTexture: amount)
                    latest = dst
                    advance()
                }
            } else {
                try clarityStage.encode(commandBuffer, source: src, destination: dst,
                                        clarity: edit.clarity)
                latest = dst
                advance()
            }
        }

        // --- B&W mix --------------------------------------------------------
        if runs(.bwMix), edit.bwMix.enabled {
            var sliders = edit.bwMix.sliders.map { Float($0) }
            var bwU = BWMixUniforms(maxEV: Float(BWMixBands.maxEV),
                                    satExponent: Float(BWMixBands.saturationExponent),
                                    satKnee: Float(BWMixBands.saturationKnee))
            try encode(commandBuffer, bwMixPipeline, w, h) { e in
                e.setTexture(src, index: 0)
                e.setTexture(dst, index: 1)
                e.setBytes(&sliders, length: MemoryLayout<Float>.stride * 8, index: 0)
                e.setBytes(&bwU, length: MemoryLayout<BWMixUniforms>.stride, index: 1)
            }
            latest = dst
            advance()
        }

        // --- toning ---------------------------------------------------------
        if runs(.toning), !edit.toning.isIdentity {
            let t = edit.toning
            var toningU = ToningUniforms(
                shadowHue: Float(t.shadowHue),
                shadowSat: Float(min(max(t.shadowSaturation, 0), 100) / 100),
                highlightHue: Float(t.highlightHue),
                highlightSat: Float(min(max(t.highlightSaturation, 0), 100) / 100),
                balance: Float(min(max(t.balance, -100), 100) / 100),
                strength: StageConstants.toningStrength,
                crossoverHalfWidth: StageConstants.toningCrossoverHalfWidth,
                lumaPreserve: StageConstants.toningLumaPreserve)
            try encode(commandBuffer, toningPipeline, w, h) { e in
                e.setTexture(src, index: 0)
                e.setTexture(dst, index: 1)
                e.setBytes(&toningU, length: MemoryLayout<ToningUniforms>.stride, index: 0)
            }
            latest = dst
            advance()
        }

        // --- output transform -----------------------------------------------
        if runs(.output) {
            try encode(commandBuffer, outputPipeline, w, h) { e in
                e.setTexture(src, index: 0)
                e.setTexture(dst, index: 1)
            }
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
            try encode(commandBuffer, histogramPipeline, w, h) { e in
                e.setTexture(output, index: 0)
                e.setBuffer(buf, offset: 0, index: 0)
            }
            histogramBuffer = buf
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
        if let c = maskCache, c.width == width, c.height == height, c.masks == masks {
            return c.maps
        }
        let maps = try maskStage.encodeMaps(cb, masks: masks, width: width, height: height)
        maskCache = (masks, width, height, maps)
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

    // MARK: - Tone

    private func encodeTone(_ cb: MTLCommandBuffer,
                            src: MTLTexture,
                            dst: MTLTexture,
                            tone: EditState.Tone,
                            params: MTLTexture?) throws {
        let lut = ToneCurve.makeLUT(for: tone)
        let lutTexture = try context.makeLUTTexture(lut.values)
        // A texture is always bound (a 1x1 dummy when there are no masks) so the
        // kernel never reads an unbound argument; `hasLocal` gates the code path.
        let paramsTexture = try params ?? context.makeWorkingTexture(width: 1, height: 1)
        var toneU = ToneUniforms(minEV: lut.minEV, maxEV: lut.maxEV,
                                 gainBelow: lut.gainBelow, gainAbove: lut.gainAbove,
                                 lutSize: UInt32(lut.size),
                                 hasLocal: params == nil ? 0 : 1)
        try encode(cb, tonePipeline, dst.width, dst.height) { e in
            e.setTexture(src, index: 0)
            e.setTexture(dst, index: 1)
            e.setTexture(lutTexture, index: 2)
            e.setTexture(paramsTexture, index: 3)
            e.setBytes(&toneU, length: MemoryLayout<ToneUniforms>.stride, index: 0)
        }
    }

    /// Test hook: the tone stage alone, with an explicit per-pixel parameter map.
    func renderToneOnly(input: MTLTexture,
                        tone: EditState.Tone,
                        params: MTLTexture?) throws -> MTLTexture {
        guard let cb = context.commandQueue.makeCommandBuffer() else { throw MetalError.encoderFailed }
        let dst = try context.makeWorkingTexture(width: input.width, height: input.height)
        try encodeTone(cb, src: input, dst: dst, tone: tone, params: params)
        cb.commit()
        cb.waitUntilCompleted()
        if let err = cb.error { throw err }
        return dst
    }

    private func encode(_ cb: MTLCommandBuffer,
                        _ state: MTLComputePipelineState,
                        _ w: Int, _ h: Int,
                        _ body: (MTLComputeCommandEncoder) -> Void) throws {
        guard let e = cb.makeComputeCommandEncoder() else { throw MetalError.encoderFailed }
        e.setComputePipelineState(state)
        body(e)
        context.dispatch(e, state, width: w, height: h)
        e.endEncoding()
    }
}
