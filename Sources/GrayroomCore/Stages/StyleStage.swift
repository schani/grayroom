import Foundation
import Metal

/// The colour style: one preset rendition — curve, chroma, an 8-band table and
/// a split tone — in a single pass. See `Style.metal` and
/// `ColorStyleParameters`.
final class StyleStage {
    private let context: MetalContext
    private let styleKernel: MTLComputePipelineState

    init(context: MetalContext) throws {
        self.context = context
        styleKernel = try context.computePipeline("styleKernel")
    }

    func encode(_ cb: MTLCommandBuffer,
                source: MTLTexture,
                destination: MTLTexture,
                parameters p: ColorStyleParameters) throws {
        func clampBand(_ v: [Double], _ limit: Double) -> [Float] {
            (0..<8).map { Float(min(max($0 < v.count ? v[$0] : 0, -limit), limit)) }
        }
        // hue[8], saturation[8], luminance[8], as the kernel indexes them.
        var bands = clampBand(p.bandHue, 45)
            + clampBand(p.bandSaturation, 100)
            + clampBand(p.bandLuminance, 100)

        var u = StyleUniforms(
            contrast: Float(min(max(p.contrast, -100), 100)),
            blacks: Float(min(max(p.blacks, -100), 100)),
            shoulder: Float(min(max(p.shoulder, 0), 100)),
            saturation: Float(min(max(p.saturation, -100), 100)),
            vibrance: Float(min(max(p.vibrance, -100), 100)),
            density: Float(min(max(p.density, 0), 100)),
            vibranceChroma: Float(ColorStyleChroma.vibranceChroma),
            hkGain: Float(ColorStyleChroma.hkGain),
            densityReach: Float(ColorStyleChroma.densityReach),
            densityChroma: Float(ColorStyleChroma.densityChroma),
            bandLuminanceEV: Float(ColorStyleCurve.bandLuminanceEV),
            satExponent: Float(BWMixBands.saturationExponent),
            satKnee: Float(BWMixBands.saturationKnee),
            shadowHue: Float(p.shadowHue),
            shadowSat: Float(min(max(p.shadowSaturation, 0), 100) / 100),
            highlightHue: Float(p.highlightHue),
            highlightSat: Float(min(max(p.highlightSaturation, 0), 100) / 100),
            balance: Float(min(max(p.balance, -100), 100) / 100),
            strength: StageConstants.toningStrength,
            crossoverHalfWidth: StageConstants.toningCrossoverHalfWidth,
            lumaPreserve: StageConstants.toningLumaPreserve)

        try context.encodePass(cb, styleKernel,
                               width: destination.width, height: destination.height) { e in
            e.setTexture(source, index: 0)
            e.setTexture(destination, index: 1)
            e.setBytes(&u, length: MemoryLayout<StyleUniforms>.stride, index: 0)
            e.setBytes(&bands, length: MemoryLayout<Float>.stride * 24, index: 1)
        }
    }
}
