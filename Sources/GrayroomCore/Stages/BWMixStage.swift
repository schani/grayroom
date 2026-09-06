import Foundation
import Metal

/// The black-and-white mixer: eight hue bands weight a per-pixel gray gain, so
/// a colour can be lightened or darkened by its hue. See `BWMix.metal` and
/// `BWMixBands`.
final class BWMixStage {
    private let context: MetalContext
    private let bwMixKernel: MTLComputePipelineState

    init(context: MetalContext) throws {
        self.context = context
        bwMixKernel = try context.computePipeline("bwMixKernel")
    }

    func encode(_ cb: MTLCommandBuffer,
                source: MTLTexture,
                destination: MTLTexture,
                mix: EditState.BWMix) throws {
        var sliders = mix.sliders.map { Float($0) }
        var u = BWMixUniforms(maxEV: Float(BWMixBands.maxEV),
                              satExponent: Float(BWMixBands.saturationExponent),
                              satKnee: Float(BWMixBands.saturationKnee))
        try context.encodePass(cb, bwMixKernel,
                               width: destination.width, height: destination.height) { e in
            e.setTexture(source, index: 0)
            e.setTexture(destination, index: 1)
            e.setBytes(&sliders, length: MemoryLayout<Float>.stride * 8, index: 0)
            e.setBytes(&u, length: MemoryLayout<BWMixUniforms>.stride, index: 1)
        }
    }
}
