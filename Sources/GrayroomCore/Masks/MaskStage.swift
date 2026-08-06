import Foundation
import Metal

/// GPU side of the mask system: stroke rasterisation and parameter-map
/// accumulation. `MaskRasterizer` is the CPU reference for all of it.
///
/// One `encode(masks:)` call produces
///
/// ```
/// paramsA  rgba16Float  (dExposure, dContrast, dHighlights, dShadows)
/// paramsB  r16Float     dClarity
/// ```
///
/// at pipeline resolution, both clamped to the documented ranges. Per mask:
///
/// ```
/// coverage = 0
/// for each stroke:  coverage = merge(coverage, rasterise(stroke))   1 dispatch
/// paramsA += coverage * mask.adjustments                            1 dispatch
/// ```
///
/// Coverage textures are `r16Float`. Everything ping-pongs between two textures
/// rather than using `read_write`, which keeps the formats unconstrained.
final class MaskStage {
    private let context: MetalContext

    private let clearPipeline: MTLComputePipelineState
    private let strokePipeline: MTLComputePipelineState
    private let unionPipeline: MTLComputePipelineState
    private let accumulatePipeline: MTLComputePipelineState
    private let clampPipeline: MTLComputePipelineState
    private let clarityAmountPipeline: MTLComputePipelineState

    /// The two per-pixel parameter textures the stages read.
    struct Maps {
        let paramsA: MTLTexture
        let paramsB: MTLTexture
    }

    init(context: MetalContext) throws {
        self.context = context
        clearPipeline = try context.computePipeline("maskClearKernel")
        strokePipeline = try context.computePipeline("maskStrokeKernel")
        unionPipeline = try context.computePipeline("maskUnionKernel")
        accumulatePipeline = try context.computePipeline("maskAccumulateKernel")
        clampPipeline = try context.computePipeline("maskClampKernel")
        clarityAmountPipeline = try context.computePipeline("maskClarityAmountKernel")
    }

    // MARK: - Coverage

    /// Rasterises one mask's coverage into a fresh `r16Float` texture.
    func encodeCoverage(_ cb: MTLCommandBuffer,
                        mask: Mask,
                        width: Int, height: Int) throws -> MTLTexture {
        var front = try context.makeAmountTexture(width: width, height: height)
        var back = try context.makeAmountTexture(width: width, height: height)
        try encodePass(cb, clearPipeline, width, height) { e in
            e.setTexture(front, index: 0)
        }

        for stroke in mask.strokes {
            let stamps = MaskRasterizer.stamps(for: stroke, width: width, height: height)
            if stamps.isEmpty { continue }
            var packed = stamps.map {
                MaskStampGPU(cx: Float($0.x), cy: Float($0.y),
                             radius: Float($0.radius), innerRadius: Float($0.innerRadius),
                             alpha: Float($0.alpha))
            }
            guard let buf = context.device.makeBuffer(
                bytes: &packed,
                length: MemoryLayout<MaskStampGPU>.stride * packed.count,
                options: .storageModeShared) else { throw MetalError.textureAllocationFailed }
            var u = MaskStrokeUniforms(stampCount: UInt32(packed.count),
                                       density: Float(stroke.brush.densityCeiling),
                                       erase: stroke.erase ? 1 : 0)
            try encodePass(cb, strokePipeline, width, height) { e in
                e.setTexture(front, index: 0)
                e.setTexture(back, index: 1)
                e.setBuffer(buf, offset: 0, index: 0)
                e.setBytes(&u, length: MemoryLayout<MaskStrokeUniforms>.stride, index: 1)
            }
            swap(&front, &back)
        }
        return front
    }

    /// `max` union of every enabled mask's coverage (or of one selected mask).
    func encodeUnionCoverage(_ cb: MTLCommandBuffer,
                             masks: [Mask],
                             width: Int, height: Int) throws -> MTLTexture {
        var front = try context.makeAmountTexture(width: width, height: height)
        var back = try context.makeAmountTexture(width: width, height: height)
        try encodePass(cb, clearPipeline, width, height) { e in
            e.setTexture(front, index: 0)
        }
        for mask in masks {
            let coverage = try encodeCoverage(cb, mask: mask, width: width, height: height)
            try encodePass(cb, unionPipeline, width, height) { e in
                e.setTexture(front, index: 0)
                e.setTexture(coverage, index: 1)
                e.setTexture(back, index: 2)
            }
            swap(&front, &back)
        }
        return front
    }

    // MARK: - Parameter maps

    /// Accumulates every mask in `masks` into the two parameter textures.
    /// `masks` should already be filtered to the ones that can change a pixel.
    func encodeMaps(_ cb: MTLCommandBuffer,
                    masks: [Mask],
                    width: Int, height: Int) throws -> Maps {
        var frontA = try context.makeWorkingTexture(width: width, height: height)
        var backA = try context.makeWorkingTexture(width: width, height: height)
        var frontB = try context.makeAmountTexture(width: width, height: height)
        var backB = try context.makeAmountTexture(width: width, height: height)
        try encodePass(cb, clearPipeline, width, height) { e in e.setTexture(frontA, index: 0) }
        try encodePass(cb, clearPipeline, width, height) { e in e.setTexture(frontB, index: 0) }

        for mask in masks {
            let coverage = try encodeCoverage(cb, mask: mask, width: width, height: height)
            let a = mask.adjustments.clamped
            var u = MaskAccumulateUniforms(dExposure: Float(a.exposure),
                                           dContrast: Float(a.contrast),
                                           dHighlights: Float(a.highlights),
                                           dShadows: Float(a.shadows),
                                           dClarity: Float(a.clarity))
            try encodePass(cb, accumulatePipeline, width, height) { e in
                e.setTexture(coverage, index: 0)
                e.setTexture(frontA, index: 1)
                e.setTexture(backA, index: 2)
                e.setTexture(frontB, index: 3)
                e.setTexture(backB, index: 4)
                e.setBytes(&u, length: MemoryLayout<MaskAccumulateUniforms>.stride, index: 0)
            }
            swap(&frontA, &backA)
            swap(&frontB, &backB)
        }

        // One clamp at the end, not per mask: overlapping masks sum first and
        // saturate only at the documented range edges.
        var clampU = MaskClampUniforms(exposureLimit: Float(MaskAdjustments.exposureLimit),
                                       otherLimit: Float(MaskAdjustments.otherLimit))
        try encodePass(cb, clampPipeline, width, height) { e in
            e.setTexture(frontA, index: 0)
            e.setTexture(backA, index: 1)
            e.setTexture(frontB, index: 2)
            e.setTexture(backB, index: 3)
            e.setBytes(&clampU, length: MemoryLayout<MaskClampUniforms>.stride, index: 0)
        }
        return Maps(paramsA: backA, paramsB: backB)
    }

    /// Builds the clarity stage's per-pixel amount map from `paramsB`:
    /// `amount(x) = clamp(global + Δclarity(x), 0, 100) / 100`. Local deltas are
    /// still ±100, so a mask can pull a region below the global value; below
    /// zero it saturates at amount 0, which is exactly the identity.
    ///
    /// Normalised against the **fixed** full-scale clarity (100), which is also
    /// what `ClarityStage` builds its pyramid at. Before wave 3 this divided by
    /// the frame's largest |clarity|, so adding a local clarity mask changed the
    /// effective global clarity everywhere else in the frame (audit
    /// `clarity-local` #6): global 25 with a +20 mask gave amount 25/45 of a
    /// strength-45 rendition, which under the old convex slider response was an
    /// effective clarity of ~35 outside the mask, and two disjoint +50 masks each
    /// rendered at strength 100 · 0.5. With a fixed reference and a lift that is
    /// linear in the slider, `amount·L_llf(100)` *is* `L_llf(c)` exactly.
    func encodeClarityAmount(_ cb: MTLCommandBuffer,
                             paramsB: MTLTexture,
                             globalClarity: Double,
                             width: Int, height: Int) throws -> MTLTexture {
        let amount = try context.makeAmountTexture(width: width, height: height)
        var u = MaskClarityUniforms(globalClarity: Float(min(max(globalClarity, 0), 100)),
                                    invReference: 1.0 / 100.0)
        try encodePass(cb, clarityAmountPipeline, width, height) { e in
            e.setTexture(paramsB, index: 0)
            e.setTexture(amount, index: 1)
            e.setBytes(&u, length: MemoryLayout<MaskClarityUniforms>.stride, index: 0)
        }
        return amount
    }

    // MARK: - Helpers

    private func encodePass(_ cb: MTLCommandBuffer,
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
