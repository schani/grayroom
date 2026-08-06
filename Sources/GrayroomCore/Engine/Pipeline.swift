import Foundation
import Metal

/// Fixed-order global pipeline for M1.
///
///   input (linear, WB applied at decode)
///     -> tone       (exposure + 5 tone controls, ratio-preserving)
///     -> bwMix      (8 hue bands -> gray)          [skipped when disabled]
///     -> toning     (split tone, luminance-neutral) [skipped when identity]
///     -> output     (linear -> sRGB)
///     -> histogram tap
///
/// Clarity (M2) and masks (M3) slot in between tone and bwMix.
public final class Pipeline {
    public let context: MetalContext

    private let tonePipeline: MTLComputePipelineState
    private let bwMixPipeline: MTLComputePipelineState
    private let toningPipeline: MTLComputePipelineState
    private let outputPipeline: MTLComputePipelineState
    private let histogramPipeline: MTLComputePipelineState

    public init(context: MetalContext) throws {
        self.context = context
        tonePipeline = try context.computePipeline("toneKernel")
        bwMixPipeline = try context.computePipeline("bwMixKernel")
        toningPipeline = try context.computePipeline("toningKernel")
        outputPipeline = try context.computePipeline("outputKernel")
        histogramPipeline = try context.computePipeline("histogramKernel")
    }

    /// Stage boundaries, in pipeline order. Useful for golden tests that need to
    /// inspect an intermediate (still linear) result.
    public enum Stage: Int, CaseIterable, Sendable {
        case tone, bwMix, toning, output
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

        // --- tone -----------------------------------------------------------
        let lut = ToneCurve.makeLUT(for: edit.tone)
        let lutTexture = try context.makeLUTTexture(lut.values)
        var toneU = ToneUniforms(minEV: lut.minEV, maxEV: lut.maxEV,
                                 gainBelow: lut.gainBelow, gainAbove: lut.gainAbove,
                                 lutSize: UInt32(lut.size))
        try encode(commandBuffer, tonePipeline, w, h) { e in
            e.setTexture(src, index: 0)
            e.setTexture(dst, index: 1)
            e.setTexture(lutTexture, index: 2)
            e.setBytes(&toneU, length: MemoryLayout<ToneUniforms>.stride, index: 0)
        }
        latest = dst
        advance()

        // --- B&W mix --------------------------------------------------------
        if runs(.bwMix), edit.bwMix.enabled {
            var sliders = edit.bwMix.sliders.map { Float($0) }
            var bwU = BWMixUniforms(gainPerUnit: StageConstants.bwGainPerUnit)
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
                strength: StageConstants.toningStrength)
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
