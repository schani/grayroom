import Foundation
import Metal
import XCTest
@testable import GrayroomCore

/// Shared Metal context: compiling the shader library once keeps the suite fast.
enum TestGPU {
    static let shared: (context: MetalContext, pipeline: Pipeline)? = {
        guard let ctx = try? MetalContext(), let pipe = try? Pipeline(context: ctx) else { return nil }
        return (ctx, pipe)
    }()

    static func require(file: StaticString = #filePath, line: UInt = #line) throws -> (MetalContext, Pipeline) {
        guard let s = shared else {
            throw XCTSkip("No Metal device / shader compilation failed")
        }
        return (s.context, s.pipeline)
    }
}

extension MetalContext {
    /// Builds an `rgba16Float` texture from RGB patches laid out left to right,
    /// one column each, `height` rows tall.
    func makePatchTexture(_ patches: [(Float, Float, Float)], height: Int = 4) throws -> MTLTexture {
        let w = patches.count
        var halfs = [Float16](repeating: 0, count: w * height * 4)
        for y in 0..<height {
            for x in 0..<w {
                let i = (y * w + x) * 4
                halfs[i] = Float16(patches[x].0)
                halfs[i + 1] = Float16(patches[x].1)
                halfs[i + 2] = Float16(patches[x].2)
                halfs[i + 3] = Float16(1)
            }
        }
        let t = try makeWorkingTexture(width: w, height: height)
        halfs.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, w, height),
                      mipmapLevel: 0,
                      withBytes: raw.baseAddress!,
                      bytesPerRow: w * 4 * MemoryLayout<Float16>.size)
        }
        return t
    }
}

extension MetalContext {
    /// Builds an `rgba16Float` texture from a per-pixel closure.
    func makeTexture(width: Int, height: Int,
                     _ pixel: (Int, Int) -> (Float, Float, Float)) throws -> MTLTexture {
        var halfs = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                let i = (y * width + x) * 4
                halfs[i] = Float16(r)
                halfs[i + 1] = Float16(g)
                halfs[i + 2] = Float16(b)
                halfs[i + 3] = Float16(1)
            }
        }
        let t = try makeWorkingTexture(width: width, height: height)
        halfs.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, width, height),
                      mipmapLevel: 0,
                      withBytes: raw.baseAddress!,
                      bytesPerRow: width * 4 * MemoryLayout<Float16>.size)
        }
        return t
    }
}

extension MetalContext {
    /// Builds an `rgba16Float` texture from a per-pixel closure that supplies all
    /// four channels — the mask parameter maps use every one of them
    /// (`.a` is Δshadows), so the RGB-only helper above will not do.
    func makeRGBATexture(width: Int, height: Int,
                         _ pixel: (Int, Int) -> (Float, Float, Float, Float)) throws -> MTLTexture {
        var halfs = [Float16](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = pixel(x, y)
                let i = (y * width + x) * 4
                halfs[i] = Float16(r)
                halfs[i + 1] = Float16(g)
                halfs[i + 2] = Float16(b)
                halfs[i + 3] = Float16(a)
            }
        }
        let t = try makeWorkingTexture(width: width, height: height)
        halfs.withUnsafeBytes { raw in
            t.replace(region: MTLRegionMake2D(0, 0, width, height),
                      mipmapLevel: 0,
                      withBytes: raw.baseAddress!,
                      bytesPerRow: width * 4 * MemoryLayout<Float16>.size)
        }
        return t
    }
}

/// Deterministic LCG so property tests are reproducible.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var x = state
        x ^= x >> 33
        x = x &* 0xff51afd7ed558ccd
        x ^= x >> 33
        return x
    }
    mutating func double(in range: ClosedRange<Double>) -> Double {
        let u = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + u * (range.upperBound - range.lowerBound)
    }
}

func sRGBEncodeReference(_ c: Double) -> Double {
    let x = min(max(c, 0), 1)
    return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1.0 / 2.4) - 0.055
}

func testDataURL(_ name: String) -> URL? {
    if let env = ProcessInfo.processInfo.environment["GRAYROOM_TEST_DNG"] {
        let u = URL(fileURLWithPath: env)
        if FileManager.default.fileExists(atPath: u.path) { return u }
    }
    // Walk up from this source file to the package root.
    var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<6 {
        let candidate = dir.appendingPathComponent("testdata").appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        dir = dir.deletingLastPathComponent()
    }
    return nil
}
