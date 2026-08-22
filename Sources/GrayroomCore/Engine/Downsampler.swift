import Foundation
import Metal

/// Reduces a decoded linear image to the resolution the interactive draft pass
/// renders at.
///
/// This runs **once per decode**, not once per render: the draft input is
/// cached next to the full-resolution decode and every slider move reuses it.
/// The reduction itself is `Downsample.metal` — a box of bilinear taps, which
/// is all a draft needs, because the refine pass that follows always re-renders
/// from the full-resolution decode.
public final class Downsampler {
    private let context: MetalContext
    private let pipeline: MTLComputePipelineState

    public init(context: MetalContext) throws {
        self.context = context
        pipeline = try context.computePipeline("downsampleKernel")
    }

    /// The size `source` reduces to so that its long edge is `longEdge`, keeping
    /// the aspect ratio and never rounding an edge below 1. `nil` when the
    /// source already fits — there is nothing to gain from a copy.
    public static func targetSize(width: Int, height: Int,
                                  longEdge: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0, longEdge > 0 else { return nil }
        let source = max(width, height)
        guard source > longEdge else { return nil }
        let scale = Double(longEdge) / Double(source)
        return (max(1, Int((Double(width) * scale).rounded())),
                max(1, Int((Double(height) * scale).rounded())))
    }

    /// `source` reduced to `longEdge`, or `nil` when it already fits.
    public func downsampled(_ source: MTLTexture, longEdge: Int) throws -> MTLTexture? {
        guard let size = Downsampler.targetSize(width: source.width, height: source.height,
                                                longEdge: longEdge) else { return nil }
        let dst = try context.makeWorkingTexture(width: size.width, height: size.height)
        guard let cb = context.commandQueue.makeCommandBuffer(),
              let e = cb.makeComputeCommandEncoder() else { throw MetalError.encoderFailed }
        e.setComputePipelineState(pipeline)
        e.setTexture(source, index: 0)
        e.setTexture(dst, index: 1)
        context.dispatch(e, pipeline, width: size.width, height: size.height)
        e.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let err = cb.error { throw err }
        return dst
    }
}
