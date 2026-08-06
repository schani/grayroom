import Foundation
import Metal

public enum MetalError: Error, CustomStringConvertible {
    case noDevice
    case noCommandQueue
    case missingShaderResource(String)
    case compileFailed(String)
    case missingFunction(String)
    case textureAllocationFailed
    case encoderFailed

    public var description: String {
        switch self {
        case .noDevice: return "no Metal device available"
        case .noCommandQueue: return "could not create a Metal command queue"
        case .missingShaderResource(let n): return "missing bundled shader resource '\(n)'"
        case .compileFailed(let m): return "Metal shader compilation failed: \(m)"
        case .missingFunction(let n): return "Metal function '\(n)' not found"
        case .textureAllocationFailed: return "Metal texture allocation failed"
        case .encoderFailed: return "could not create a Metal command encoder"
        }
    }
}

/// Device + queue + the runtime-compiled shader library.
///
/// The `.metal` files ship as **text** resources and are compiled with
/// `makeLibrary(source:options:)` at startup. This sidesteps SPM's metallib
/// handling entirely, which is what keeps `swift build && swift test` working
/// from a plain terminal.
public final class MetalContext {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    public let library: MTLLibrary

    /// `Common.metal` is prepended to every stage source; the whole thing is
    /// compiled as one translation unit.
    static let shaderFiles = ["Common", "Tone", "BWMix", "Toning", "Output", "Histogram"]

    private var pipelineCache: [String: MTLComputePipelineState] = [:]
    private let cacheLock = NSLock()

    public init(device: MTLDevice? = nil) throws {
        guard let dev = device ?? MTLCreateSystemDefaultDevice() else { throw MetalError.noDevice }
        self.device = dev
        guard let queue = dev.makeCommandQueue() else { throw MetalError.noCommandQueue }
        self.commandQueue = queue

        let source = try MetalContext.combinedShaderSource()
        let options = MTLCompileOptions()
        options.languageVersion = .version3_0
        options.fastMathEnabled = false
        do {
            self.library = try dev.makeLibrary(source: source, options: options)
        } catch {
            throw MetalError.compileFailed(String(describing: error))
        }
    }

    static func combinedShaderSource() throws -> String {
        var parts: [String] = []
        for name in shaderFiles {
            guard let url = Bundle.module.url(forResource: name, withExtension: "metal")
                    ?? Bundle.module.url(forResource: name, withExtension: "metal", subdirectory: "Shaders")
            else { throw MetalError.missingShaderResource("\(name).metal") }
            parts.append("// ===== \(name).metal =====")
            parts.append(try String(contentsOf: url, encoding: .utf8))
        }
        return parts.joined(separator: "\n")
    }

    public func computePipeline(_ functionName: String) throws -> MTLComputePipelineState {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = pipelineCache[functionName] { return cached }
        guard let fn = library.makeFunction(name: functionName) else {
            throw MetalError.missingFunction(functionName)
        }
        let state = try device.makeComputePipelineState(function: fn)
        pipelineCache[functionName] = state
        return state
    }

    // MARK: - Texture helpers

    /// An `rgba16Float` working texture (shared storage: Apple Silicon unified
    /// memory makes readback free and keeps the export path simple).
    public func makeWorkingTexture(width: Int, height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: max(width, 1), height: max(height, 1), mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw MetalError.textureAllocationFailed }
        return t
    }

    /// A 1-D LUT as an `r32Float` `size x 1` texture.
    public func makeLUTTexture(_ values: [Float]) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float, width: values.count, height: 1, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .shared
        guard let t = device.makeTexture(descriptor: d) else { throw MetalError.textureAllocationFailed }
        values.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, values.count, 1),
                      mipmapLevel: 0,
                      withBytes: raw.baseAddress!,
                      bytesPerRow: values.count * MemoryLayout<Float>.size)
        }
        return t
    }

    /// Dispatch helper using non-uniform threadgroups (Apple Silicon supports
    /// `dispatchThreads`), with an in-kernel bounds guard as a belt-and-braces.
    func dispatch(_ encoder: MTLComputeCommandEncoder,
                  _ state: MTLComputePipelineState,
                  width: Int, height: Int) {
        let w = state.threadExecutionWidth
        let h = max(1, state.maxTotalThreadsPerThreadgroup / w)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
    }
}
