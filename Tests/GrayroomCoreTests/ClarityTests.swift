import Metal
import XCTest
@testable import GrayroomCore

/// Clarity = fast local Laplacian filter (M2).
///
/// Measurements are taken in **log2 luminance**, which is the space the filter
/// works in. That matters for the halo assertions: the synthetic texture is a
/// symmetric ripple in log space, so boosting it leaves the log-mean of a patch
/// alone, whereas the *linear* mean would rise simply because 2^x is convex.
final class ClarityTests: XCTestCase {

    // MARK: - CPU: slider mapping

    func testClarityMappingIsIdentityAtZero() {
        let p = ClarityMapping.parameters(for: 0)
        XCTAssertEqual(p.gain, 0)
        XCTAssertEqual(p.alpha, 1)
        XCTAssertEqual(p.amount, 0)
        XCTAssertTrue(p.isIdentity)
        // gain = 0 makes the remap the identity for every value and centre.
        for g in ClarityMapping.gammaLevels {
            for v in stride(from: -14.0, through: 4.0, by: 0.25) {
                XCTAssertEqual(ClarityMapping.remap(v, center: g, p), v, accuracy: 0)
            }
        }
    }

    func testClarityMappingIsMonotoneInMagnitude() {
        var previousGain = -1.0
        var previousAlpha = 2.0
        for c in stride(from: 0.0, through: 100.0, by: 5) {
            let p = ClarityMapping.parameters(for: c)
            let n = ClarityMapping.parameters(for: -c)
            // Symmetric structure: the same gain and amount on both sides, the
            // sign only picks which way alpha moves away from 1.
            XCTAssertEqual(p.gain, n.gain)
            XCTAssertEqual(p.amount, n.amount)
            XCTAssertFalse(p.isSmoothing)
            XCTAssertEqual(n.isSmoothing, c > 0)

            XCTAssertGreaterThan(p.gain, previousGain)
            XCTAssertLessThan(p.alpha, previousAlpha)     // boost: alpha falls below 1
            XCTAssertGreaterThanOrEqual(n.alpha, 1)       // smooth: alpha rises above 1
            previousGain = p.gain
            previousAlpha = p.alpha
        }
        XCTAssertEqual(ClarityMapping.parameters(for: 100).gain, 1)
        XCTAssertEqual(ClarityMapping.parameters(for: 100).alpha,
                       1 - ClarityMapping.alphaBoostRange, accuracy: 1e-12)
        // Monotone in |clarity| all the way through to the remap's detail slope.
        var previousSlope = 1.0
        for c in stride(from: 5.0, through: 100.0, by: 5) {
            let s = ClarityMapping.parameters(for: c).detailSlope
            XCTAssertGreaterThan(s, previousSlope)
            previousSlope = s
            XCTAssertLessThan(ClarityMapping.parameters(for: -c).detailSlope, 1)
        }
        XCTAssertEqual(ClarityMapping.parameters(for: -100).alpha,
                       1 + ClarityMapping.alphaSmoothRange, accuracy: 1e-12)
        // Out-of-range sliders clamp rather than extrapolate.
        XCTAssertEqual(ClarityMapping.parameters(for: 250), ClarityMapping.parameters(for: 100))
        XCTAssertEqual(ClarityMapping.parameters(for: -250), ClarityMapping.parameters(for: -100))
    }

    func testClarityRemapIsMonotoneOddAndFadesOut() {
        let sigma = ClarityMapping.sigmaR
        for clarity in [-100.0, -60, -20, 20, 60, 100] {
            let p = ClarityMapping.parameters(for: clarity)
            XCTAssertLessThan(abs(p.lift), ClarityMapping.maxLift)

            let g = -2.0
            var previous = -Double.infinity
            for v in stride(from: g - 8 * sigma, through: g + 8 * sigma, by: 0.002) {
                let r = ClarityMapping.remap(v, center: g, p)
                XCTAssertGreaterThan(r, previous, "remap not monotone at v=\(v)")
                previous = r
                // Odd in d: detail is treated the same up and down.
                let mirrored = ClarityMapping.remap(2 * g - v, center: g, p)
                XCTAssertEqual(r - g, -(mirrored - g), accuracy: 1e-12)
                // Fades to the identity well outside the window: large edges are
                // untouched, which is what suppresses halos.
                if abs(v - g) >= 6 * sigma {
                    XCTAssertEqual(r, v, accuracy: 1e-6)
                }
            }
            XCTAssertEqual(ClarityMapping.remap(g, center: g, p), g, accuracy: 1e-12)

            // Fine-detail slope: 1/alpha, scaled by gain.
            XCTAssertEqual(p.detailSlope, 1 + p.gain * (1 / p.alpha - 1), accuracy: 1e-12)
            XCTAssertEqual(ClarityMapping.remapSlope(g, center: g, p), p.detailSlope, accuracy: 1e-12)
            if clarity > 0 {
                XCTAssertGreaterThan(p.detailSlope, 1)
            } else {
                XCTAssertLessThan(p.detailSlope, 1)
            }
        }
    }

    /// The discretisation only samples the remap's slope within one gamma step,
    /// so `gain(t)` has to stay flat across the grid or clarity strength would
    /// swing with tone. This is what pins K.
    func testEffectiveDetailGainIsFlatAcrossTheGammaGrid() {
        for clarity in [30.0, 80, 100, -80, -100] {
            let p = ClarityMapping.parameters(for: clarity)
            // Deviation from 1 = the strength of the effect; it must keep its
            // sign and stay within 20% of the ideal across the whole grid.
            let deviations = stride(from: 0.0, through: 1.0, by: 0.05)
                .map { ClarityMapping.effectiveDetailGain(at: $0, p) - 1 }
            let ideal = p.detailSlope - 1
            XCTAssertEqual(deviations[0], ideal, accuracy: 1e-9, "t = 0 must hit the ideal gain")
            for d in deviations {
                XCTAssertGreaterThan(d / ideal, 0.75,
                                     "gain varies by >25% across the gamma grid (clarity \(clarity))")
                XCTAssertLessThanOrEqual(d / ideal, 1 + 1e-9)
            }
        }
    }

    func testGammaWeightsArePartitionOfUnity() {
        for v in stride(from: -16.0, through: 6.0, by: 0.1) {
            var sum = 0.0
            for k in 0..<ClarityMapping.gammaLevelCount {
                sum += ClarityMapping.gammaWeight(v, level: k)
            }
            XCTAssertEqual(sum, 1, accuracy: 1e-12, "weights must sum to 1 at v=\(v)")
        }
    }

    func testPyramidGeometry() {
        XCTAssertEqual(ClarityMapping.pyramidLevelCount(width: 256, height: 256), 4)
        // 3968 -> 1984 -> 992 -> 496 -> 248 -> 124 -> 62; a 7th halving would
        // put the short side below 32.
        XCTAssertEqual(ClarityMapping.pyramidLevelCount(width: 5952, height: 3968), 7)
        XCTAssertEqual(ClarityMapping.levelSize(width: 5952, height: 3968, level: 6).height, 62)
        XCTAssertEqual(ClarityMapping.pyramidLevelCount(width: 40, height: 40), 1)
        // Non-power-of-two sizes round up at every level.
        XCTAssertEqual(ClarityMapping.levelSize(width: 999, height: 501, level: 1).width, 500)
        XCTAssertEqual(ClarityMapping.levelSize(width: 999, height: 501, level: 1).height, 251)
        XCTAssertEqual(ClarityMapping.levelSize(width: 999, height: 501, level: 3).width, 125)
    }

    // MARK: - GPU support

    /// 4-stop step edge at x = 128 plus a fine (period 4) multiplicative ripple.
    private static let edgeX = 128
    private static let darkY: Float = 0.0225
    private static let brightY: Float = 0.36
    private static let rippleAmplitude: Float = 0.12

    private func syntheticPixel(_ x: Int, _ y: Int) -> (Float, Float, Float) {
        let base = x < Self.edgeX ? Self.darkY : Self.brightY
        let sx = Float(sin(Double(x) * .pi / 2))
        let sy = Float(sin(Double(y) * .pi / 2))
        let v = base * (1 + Self.rippleAmplitude * 0.5 * (sx + sy))
        return (v, v, v)
    }

    private func logLuminance(_ img: FloatImage) -> [Double] {
        var out = [Double](repeating: 0, count: img.width * img.height)
        for y in 0..<img.height {
            for x in 0..<img.width {
                let (r, g, b) = img.rgb(x: x, y: y)
                let Y = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
                out[y * img.width + x] = log2(max(Y, 1e-9))
            }
        }
        return out
    }

    private func stats(_ v: [Double], width: Int,
                       _ xs: Range<Int>, _ ys: Range<Int>) -> (mean: Double, std: Double) {
        var sum = 0.0, n = 0.0
        for y in ys { for x in xs { sum += v[y * width + x]; n += 1 } }
        let mean = sum / n
        var acc = 0.0
        for y in ys { for x in xs { let d = v[y * width + x] - mean; acc += d * d } }
        return (mean, (acc / n).squareRoot())
    }

    private func runClarity(_ clarity: Double, width: Int = 256, height: Int = 256,
                            pixel: ((Int, Int) -> (Float, Float, Float))? = nil)
        throws -> FloatImage {
        let (ctx, pipe) = try TestGPU.require()
        let make = pixel ?? syntheticPixel
        let input = try ctx.makeTexture(width: width, height: height, make)
        var edit = EditState()
        edit.clarity = clarity
        let result = try pipe.render(input: input, edit: edit, upTo: .clarity)
        return try TextureReadback.read(result.texture)
    }

    // Far-from-edge texture patch and the two near-edge flat patches. All widths
    // are multiples of the ripple period (4) so the ripple cancels in the means.
    private let farXs = 40..<88
    private let farYs = 40..<216
    private let nearLeftXs = 104..<124
    private let nearRightXs = 132..<152

    // MARK: - GPU: identity

    func testClarityZeroIsBitwiseIdentity() throws {
        let (ctx, pipe) = try TestGPU.require()
        let input = try ctx.makeTexture(width: 256, height: 256, syntheticPixel)

        var edit = EditState()
        edit.clarity = 0
        let withStage = try TextureReadback.read(
            pipe.render(input: input, edit: edit, upTo: .clarity).texture)
        let withoutStage = try TextureReadback.read(
            pipe.render(input: input, edit: edit, upTo: .tone).texture)

        XCTAssertEqual(withStage.pixels.count, withoutStage.pixels.count)
        for i in 0..<withStage.pixels.count {
            XCTAssertEqual(withStage.pixels[i], withoutStage.pixels[i],
                           "clarity = 0 must be bit-identical to skipping the stage (i=\(i))")
        }
    }

    // MARK: - GPU: positive clarity

    func testPositiveClarityBoostsFineTextureWithoutHaloing() throws {
        let before = logLuminance(try runClarity(0))
        let after = logLuminance(try runClarity(80))
        let w = 256

        let farBefore = stats(before, width: w, farXs, farYs)
        let farAfter = stats(after, width: w, farXs, farYs)
        XCTAssertGreaterThan(farAfter.std, farBefore.std * 1.3,
                             "clarity +80 should clearly raise fine-texture local contrast")

        // Halo suppression: the flat regions either side of the step must barely
        // move. Bound is in stops; 0.03 stops is ~2% in linear luminance.
        for xs in [nearLeftXs, nearRightXs] {
            let b = stats(before, width: w, xs, farYs)
            let a = stats(after, width: w, xs, farYs)
            XCTAssertLessThan(abs(a.mean - b.mean), 0.03,
                              "near-edge mean shifted by \(a.mean - b.mean) stops")
        }

        // ... and it is genuinely better than a plain unsharp mask tuned to the
        // same fine-texture gain.
        let gain = farAfter.std / farBefore.std
        let unsharp = unsharpReference(amount: gain - 1)
        let llfShift = abs(stats(after, width: w, nearLeftXs, farYs).mean
                           - stats(before, width: w, nearLeftXs, farYs).mean)
        let unsharpShift = abs(stats(unsharp, width: w, nearLeftXs, farYs).mean
                               - stats(before, width: w, nearLeftXs, farYs).mean)
        XCTAssertGreaterThan(unsharpShift, 3 * llfShift,
                             "unsharp \(unsharpShift) vs local Laplacian \(llfShift) stops")
    }

    /// Unsharp mask on the same synthetic image, in log2 luminance, with a
    /// sigma-4 Gaussian. The ripple (period 4) is annihilated by that blur, so
    /// the fine-texture gain is exactly `1 + amount`.
    private func unsharpReference(amount: Double) -> [Double] {
        let w = 256, h = 256
        var base = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { base[y * w + x] = log2(Double(syntheticPixel(x, y).0)) }
        }
        let sigma = 4.0, radius = 12
        var kernel = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
        let ksum = kernel.reduce(0, +)
        kernel = kernel.map { $0 / ksum }

        var tmp = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var acc = 0.0
                for (i, k) in kernel.enumerated() {
                    acc += k * base[y * w + min(max(x + i - radius, 0), w - 1)]
                }
                tmp[y * w + x] = acc
            }
        }
        var blur = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var acc = 0.0
                for (i, k) in kernel.enumerated() {
                    acc += k * tmp[min(max(y + i - radius, 0), h - 1) * w + x]
                }
                blur[y * w + x] = acc
            }
        }
        return (0..<(w * h)).map { base[$0] + amount * (base[$0] - blur[$0]) }
    }

    // MARK: - GPU: negative clarity

    func testNegativeClaritySmoothsTextureAndKeepsTheStep() throws {
        let before = logLuminance(try runClarity(0))
        let after = logLuminance(try runClarity(-80))
        let w = 256

        let farBefore = stats(before, width: w, farXs, farYs)
        let farAfter = stats(after, width: w, farXs, farYs)
        XCTAssertLessThan(farAfter.std, farBefore.std * 0.7,
                          "clarity -80 should smooth the fine texture")

        // The step itself survives: the plateau means either side stay put and
        // their difference is still (close to) the 4 stops we put in.
        let leftBefore = stats(before, width: w, farXs, farYs)
        let leftAfter = stats(after, width: w, farXs, farYs)
        let rightBefore = stats(before, width: w, 168..<216, farYs)
        let rightAfter = stats(after, width: w, 168..<216, farYs)
        XCTAssertEqual(leftAfter.mean, leftBefore.mean, accuracy: 0.03)
        XCTAssertEqual(rightAfter.mean, rightBefore.mean, accuracy: 0.03)
        XCTAssertEqual(rightAfter.mean - leftAfter.mean,
                       rightBefore.mean - leftBefore.mean, accuracy: 0.05)
    }

    // MARK: - GPU: gradient sanity

    func testSmoothRampStaysMonotoneAfterClarity() throws {
        // Linear-in-Y ramp: log2 Y is *curved*, so it has real Laplacian
        // coefficients for the filter to amplify — an unstable filter or a bad
        // gamma-level interpolation would show up as reversals or banding.
        let w = 256, h = 64
        let out = try runClarity(60, width: w, height: h) { x, _ in
            let v = Float(0.02 + Double(x) * (0.9 - 0.02) / Double(w - 1))
            return (v, v, v)
        }
        for y in 0..<h {
            for x in 1..<w {
                let a = Double(out.rgb(x: x - 1, y: y).0)
                let b = Double(out.rgb(x: x, y: y).0)
                // Tolerance = one rgba16Float quantum at this magnitude.
                XCTAssertGreaterThanOrEqual(b, a - max(a, 1e-3) * 1e-3,
                                            "reversal at (\(x), \(y)): \(a) -> \(b)")
            }
        }
    }

    // MARK: - End to end

    func testEndToEndClarityRender() throws {
        guard let url = testDataURL("L1000003.DNG") else {
            throw XCTSkip("testdata/L1000003.DNG not present (set GRAYROOM_TEST_DNG to override)")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grayroom-clarity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("clarity.png")

        var edit = EditState()
        edit.tone = .init(exposure: 0.3, contrast: 25, highlights: -40, shadows: 20)
        edit.clarity = 60

        let renderer = try Renderer()
        let result = try renderer.render(rawURL: url, edit: edit, to: out, format: .png,
                                         maxDimension: 1024, computeHistogram: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(max(result.width, result.height), 1024)

        let h = try XCTUnwrap(result.histogram)
        XCTAssertEqual(h.pixelCount, result.width * result.height)
        XCTAssertGreaterThan(h.meanLuminance, 0.05)
        XCTAssertLessThan(h.meanLuminance, 0.95)
        XCTAssertLessThan(h.highlightClippedFraction, 0.5)
        XCTAssertLessThan(h.shadowClippedFraction, 0.5)

        // Clarity must raise local contrast on a real image, not just synthetics.
        let decoded = try renderer.decoder.decode(url: url, edit: edit, maxDimension: 1024)
        var plain = edit
        plain.clarity = 0
        let a = try TextureReadback.read(
            renderer.pipeline.render(input: decoded.texture, edit: plain, upTo: .clarity).texture)
        let b = try TextureReadback.read(
            renderer.pipeline.render(input: decoded.texture, edit: edit, upTo: .clarity).texture)
        XCTAssertGreaterThan(highFrequencyEnergy(b), highFrequencyEnergy(a) * 1.2)
        XCTAssertEqual(b.meanLuminance, a.meanLuminance, accuracy: a.meanLuminance * 0.1)
    }

    /// Mean squared horizontal first difference of log2 luminance — a crude but
    /// robust local-contrast measure.
    private func highFrequencyEnergy(_ img: FloatImage) -> Double {
        let v = logLuminance(img)
        var acc = 0.0
        var n = 0.0
        for y in 0..<img.height {
            for x in 1..<img.width {
                let d = v[y * img.width + x] - v[y * img.width + x - 1]
                acc += d * d
                n += 1
            }
        }
        return acc / n
    }
}
