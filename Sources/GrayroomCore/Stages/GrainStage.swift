import Foundation
import Metal

/// Parameter mapping shared by the renderer and statistical tests. Grain sizes
/// are fractions of image width, independent of pixel dimensions.
enum GrainMapping {
    static let referenceWidth = 6000.0

    /// Correlation radius as a fraction of image width. Size 25 is about
    /// 1/6000 of the image width.
    static func radiusFraction(size: Double) -> Double {
        let size = min(max(size, 0), 100)
        let belowDefault = max(1 - size / 25, 0)
        let exponent = size / 39.3
                     + log2(0.25 / 0.65) * belowDefault * belowDefault
        return 0.65 * exp2(exponent) / referenceWidth
    }

    /// RMS-relative luminance modulation before tone and endpoint weighting.
    static func amplitude(amount: Double) -> Double {
        let amount = min(max(amount, 0), 100) / 100
        return 0.32 * pow(amount, 0.9)
    }
}

final class GrainStage {
    private let context: MetalContext
    private let kernel: MTLComputePipelineState

    init(context: MetalContext) throws {
        self.context = context
        kernel = try context.computePipeline("grainKernel")
    }

    func encode(_ cb: MTLCommandBuffer,
                source: MTLTexture,
                destination: MTLTexture,
                grain: EditState.Grain,
                displayWhite: Double) throws {
        let grain = grain.clamped
        let pixelFootprint = GrainMapping.referenceWidth / Double(max(source.width, 1))
        let aboveDefault = max((grain.size - 25) / 75, 0)
        var uniforms = GrainUniforms(
            amplitude: Float(GrainMapping.amplitude(amount: grain.amount)),
            baseRadius: Float(GrainMapping.radiusFraction(size: grain.size)
                            * GrainMapping.referenceWidth),
            pixelFootprint: Float(pixelFootprint),
            displayWhite: Float(max(displayWhite, 1e-6)),
            blurRadius: Float(0.85 * aboveDefault / pixelFootprint),
            blurBlend: Float(0.18 * aboveDefault * grain.amount / 100))
        try context.encodePass(cb, kernel,
                               width: destination.width, height: destination.height) { encoder in
            encoder.setTexture(source, index: 0)
            encoder.setTexture(destination, index: 1)
            encoder.setBytes(&uniforms, length: MemoryLayout<GrainUniforms>.stride, index: 0)
        }
    }
}
