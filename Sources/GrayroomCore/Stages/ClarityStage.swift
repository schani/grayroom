import Foundation
import Metal

/// GPU side of the clarity stage: a fast local Laplacian filter (Aubry et al.
/// 2014) on log2 luminance.
///
/// Structure of one `encode` call, for an N-level pyramid and K gamma levels:
///
/// ```
///  logLuma        rgba16Float -> r32Float  L          (= G[0])
///  downsample     G[l] -> G[l+1]                      N-1 passes
///  clear          A[0..N-2] = 0
///  for k in 0..<K:
///      remap+downsample   L -> S[1]                   (r_k fused into the blur)
///      downsample         S[l] -> S[l+1]              l = 1..N-2
///      accumulate         A[l] += w_k(G[l]) * (r_k-Laplacian at l)
///  collapse       A[N-2] += up(G[N-1]); A[l] += up(A[l+1])   -> A[0] = L'
///  apply          rgb * 2^(mix(L, L', amount) - L)
/// ```
///
/// Only the level-0 remapped image is ever fused away (it would be the single
/// biggest allocation); the peak footprint is one Gaussian pyramid of L, one
/// accumulator pyramid and one scratch pyramid above level 0, i.e. about
/// `3 * 4 bytes * pixels` — ~280 MB at 24 MP.
final class ClarityStage {
    private let context: MetalContext

    private let logLuma: MTLComputePipelineState
    private let downsample: MTLComputePipelineState
    private let remapDownsample: MTLComputePipelineState
    private let clear: MTLComputePipelineState
    private let accumulate: MTLComputePipelineState
    private let collapse: MTLComputePipelineState
    private let apply: MTLComputePipelineState

    init(context: MetalContext) throws {
        self.context = context
        logLuma = try context.computePipeline("clarityLogLumaKernel")
        downsample = try context.computePipeline("clarityDownsampleKernel")
        remapDownsample = try context.computePipeline("clarityRemapDownsampleKernel")
        clear = try context.computePipeline("clarityClearKernel")
        accumulate = try context.computePipeline("clarityAccumulateKernel")
        collapse = try context.computePipeline("clarityCollapseKernel")
        apply = try context.computePipeline("clarityApplyKernel")
    }

    /// Encodes the whole stage into `cb`. `source` and `destination` are the
    /// pipeline's `rgba16Float` ping-pong textures; everything else is allocated
    /// here and released when the command buffer completes.
    ///
    /// `amount` defaults to the global scalar; passing a texture is the M3 hook.
    func encode(_ cb: MTLCommandBuffer,
                source: MTLTexture,
                destination: MTLTexture,
                clarity: Double,
                amountTexture explicitAmount: MTLTexture? = nil) throws {
        let params = ClarityMapping.parameters(for: clarity)
        let w = source.width, h = source.height

        // --- L = log2(max(Y, eps)); this is also G[0]. -----------------------
        let levels = ClarityMapping.pyramidLevelCount(width: w, height: h)
        var gauss: [MTLTexture] = []
        for l in 0..<levels {
            let s = ClarityMapping.levelSize(width: w, height: h, level: l)
            gauss.append(try context.makeScalarTexture(width: s.width, height: s.height))
        }
        var eps = Float(ClarityMapping.epsLuminance)
        try encodePass(cb, logLuma, w, h) { e in
            e.setTexture(source, index: 0)
            e.setTexture(gauss[0], index: 1)
            e.setBytes(&eps, length: MemoryLayout<Float>.stride, index: 0)
        }

        // A degenerate pyramid (tiny image) has no detail levels at all: the
        // filter is the identity, so skip straight to the (identity) apply.
        if levels >= 2 && !params.isIdentity {
            for l in 1..<levels {
                try encodePass(cb, downsample, gauss[l].width, gauss[l].height) { e in
                    e.setTexture(gauss[l - 1], index: 0)
                    e.setTexture(gauss[l], index: 1)
                }
            }

            // --- accumulator (output Laplacian) and scratch pyramids ---------
            var accum: [MTLTexture] = []
            for l in 0..<(levels - 1) {
                accum.append(try context.makeScalarTexture(width: gauss[l].width,
                                                           height: gauss[l].height))
                try encodePass(cb, clear, gauss[l].width, gauss[l].height) { e in
                    e.setTexture(accum[l], index: 0)
                }
            }
            // scratch[l] holds the remapped Gaussian pyramid for l >= 1;
            // scratch[0] is never allocated (fused into remapDownsample).
            var scratch: [MTLTexture?] = [nil]
            for l in 1..<levels {
                scratch.append(try context.makeScalarTexture(width: gauss[l].width,
                                                             height: gauss[l].height))
            }

            for k in 0..<ClarityMapping.gammaLevelCount {
                var u = ClarityUniforms(
                    sigmaR: Float(ClarityMapping.sigmaR),
                    lift: Float(params.lift),
                    gamma0: Float(ClarityMapping.gamma0),
                    gammaStep: Float(ClarityMapping.gammaStep),
                    center: Float(ClarityMapping.gammaLevels[k]),
                    levelIndex: UInt32(k),
                    levelCount: UInt32(ClarityMapping.gammaLevelCount),
                    remapFine: 0)

                // r_k(L) blurred straight down to level 1.
                try encodePass(cb, remapDownsample, gauss[1].width, gauss[1].height) { e in
                    e.setTexture(gauss[0], index: 0)
                    e.setTexture(scratch[1]!, index: 1)
                    e.setBytes(&u, length: MemoryLayout<ClarityUniforms>.stride, index: 0)
                }
                for l in 2..<levels {
                    try encodePass(cb, downsample, gauss[l].width, gauss[l].height) { e in
                        e.setTexture(scratch[l - 1]!, index: 0)
                        e.setTexture(scratch[l], index: 1)
                    }
                }

                for l in 0..<(levels - 1) {
                    u.remapFine = (l == 0) ? 1 : 0
                    let fine = (l == 0) ? gauss[0] : scratch[l]!
                    try encodePass(cb, accumulate, gauss[l].width, gauss[l].height) { e in
                        e.setTexture(fine, index: 0)
                        e.setTexture(scratch[l + 1]!, index: 1)
                        e.setTexture(gauss[l], index: 2)
                        e.setTexture(accum[l], index: 3)
                        e.setBytes(&u, length: MemoryLayout<ClarityUniforms>.stride, index: 0)
                    }
                }
            }

            // --- collapse: the residual is the *original* coarsest Gaussian --
            for l in stride(from: levels - 2, through: 0, by: -1) {
                let coarse = (l == levels - 2) ? gauss[levels - 1] : accum[l + 1]
                try encodePass(cb, collapse, accum[l].width, accum[l].height) { e in
                    e.setTexture(coarse, index: 0)
                    e.setTexture(accum[l], index: 1)
                }
            }

            try encodeApply(cb, source: source, destination: destination,
                            logIn: gauss[0], logOut: accum[0],
                            amount: explicitAmount ?? (try globalAmountTexture(params.amount)))
        } else {
            try encodeApply(cb, source: source, destination: destination,
                            logIn: gauss[0], logOut: gauss[0],
                            amount: explicitAmount ?? (try globalAmountTexture(0)))
        }
    }

    // MARK: - Helpers

    private func encodeApply(_ cb: MTLCommandBuffer,
                             source: MTLTexture,
                             destination: MTLTexture,
                             logIn: MTLTexture,
                             logOut: MTLTexture,
                             amount: MTLTexture) throws {
        var u = ClarityApplyUniforms(maxStops: Float(ClarityMapping.maxAppliedStops))
        try encodePass(cb, apply, destination.width, destination.height) { e in
            e.setTexture(source, index: 0)
            e.setTexture(logIn, index: 1)
            e.setTexture(logOut, index: 2)
            e.setTexture(amount, index: 3)
            e.setTexture(destination, index: 4)
            e.setBytes(&u, length: MemoryLayout<ClarityApplyUniforms>.stride, index: 0)
        }
    }

    /// The global amount as a 1x1 texture. M3 swaps in a full-size per-pixel
    /// amount texture; the kernel clamps its coordinates, so both work without a
    /// shader change.
    private func globalAmountTexture(_ amount: Double) throws -> MTLTexture {
        let t = try context.makeAmountTexture(width: 1, height: 1)
        var v = Float16(min(max(amount, 0), 1))
        withUnsafeBytes(of: &v) { raw in
            t.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                      mipmapLevel: 0,
                      withBytes: raw.baseAddress!,
                      bytesPerRow: MemoryLayout<Float16>.size)
        }
        return t
    }

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
