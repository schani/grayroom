import Foundation
import Metal

/// Exposure plus the five tone controls, as a ratio-preserving gain read from
/// the tone curve's LUT. Per-pixel mask deltas ride on top of the global
/// curve's output; see `Tone.metal` and `ToneCurve.applyToneDelta`.
final class ToneStage {
    private let context: MetalContext
    private let toneKernel: MTLComputePipelineState

    init(context: MetalContext) throws {
        self.context = context
        toneKernel = try context.computePipeline("toneKernel")
    }

    func encode(_ cb: MTLCommandBuffer,
                source: MTLTexture,
                destination: MTLTexture,
                tone: EditState.Tone,
                params: MTLTexture?,
                displayWhite: Double = 1.0) throws {
        let lut = ToneCurve.makeLUT(for: tone, displayWhite: displayWhite)
        let lutTexture = try context.makeLUTTexture(lut.values)
        // A texture is always bound (a 1x1 dummy when there are no masks) so the
        // kernel never reads an unbound argument; `hasLocal` gates the code path.
        let paramsTexture = try params ?? context.makeWorkingTexture(width: 1, height: 1)
        var u = ToneUniforms(minEV: lut.minEV, maxEV: lut.maxEV,
                             gainBelow: lut.gainBelow, gainAbove: lut.gainAbove,
                             lutSize: UInt32(lut.size),
                             hasLocal: params == nil ? 0 : 1)
        try context.encodePass(cb, toneKernel,
                               width: destination.width, height: destination.height) { e in
            e.setTexture(source, index: 0)
            e.setTexture(destination, index: 1)
            e.setTexture(lutTexture, index: 2)
            e.setTexture(paramsTexture, index: 3)
            e.setBytes(&u, length: MemoryLayout<ToneUniforms>.stride, index: 0)
        }
    }
}
