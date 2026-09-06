import Foundation
import Metal

/// Split toning: a shadow tint and a highlight tint, crossfaded across the
/// tonal range around the balance pivot and largely luminance-neutral. See
/// `Toning.metal` and `ToningWeights`.
final class ToningStage {
    private let context: MetalContext
    private let toningKernel: MTLComputePipelineState

    init(context: MetalContext) throws {
        self.context = context
        toningKernel = try context.computePipeline("toningKernel")
    }

    func encode(_ cb: MTLCommandBuffer,
                source: MTLTexture,
                destination: MTLTexture,
                toning t: EditState.Toning) throws {
        var u = ToningUniforms(
            shadowHue: Float(t.shadowHue),
            shadowSat: Float(min(max(t.shadowSaturation, 0), 100) / 100),
            highlightHue: Float(t.highlightHue),
            highlightSat: Float(min(max(t.highlightSaturation, 0), 100) / 100),
            balance: Float(min(max(t.balance, -100), 100) / 100),
            strength: StageConstants.toningStrength,
            crossoverHalfWidth: StageConstants.toningCrossoverHalfWidth,
            lumaPreserve: StageConstants.toningLumaPreserve)
        try context.encodePass(cb, toningKernel,
                               width: destination.width, height: destination.height) { e in
            e.setTexture(source, index: 0)
            e.setTexture(destination, index: 1)
            e.setBytes(&u, length: MemoryLayout<ToningUniforms>.stride, index: 0)
        }
    }
}
