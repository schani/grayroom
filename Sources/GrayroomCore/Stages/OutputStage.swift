import Foundation
import Metal

/// The final transform off the linear working space: sRGB-encoded and clamped
/// to `[0, 1]` for a file, or left linear and clamped to `[0, ceiling]` for the
/// canvas. See `Output.metal`.
final class OutputStage {
    private let context: MetalContext
    private let outputKernel: MTLComputePipelineState
    private let displayOutputKernel: MTLComputePipelineState

    init(context: MetalContext) throws {
        self.context = context
        outputKernel = try context.computePipeline("outputKernel")
        displayOutputKernel = try context.computePipeline("displayOutputKernel")
    }

    func encode(_ cb: MTLCommandBuffer,
                source: MTLTexture,
                destination: MTLTexture,
                mode: Pipeline.OutputMode,
                ceiling: Double) throws {
        let w = destination.width, h = destination.height
        switch mode {
        case .file:
            try context.encodePass(cb, outputKernel, width: w, height: h) { e in
                e.setTexture(source, index: 0)
                e.setTexture(destination, index: 1)
            }
        case .display:
            var white = Float(ceiling)
            try context.encodePass(cb, displayOutputKernel, width: w, height: h) { e in
                e.setTexture(source, index: 0)
                e.setTexture(destination, index: 1)
                e.setBytes(&white, length: MemoryLayout<Float>.stride, index: 0)
            }
        }
    }
}
