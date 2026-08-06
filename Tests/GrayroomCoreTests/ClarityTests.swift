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
        XCTAssertEqual(p.amount, 0)
        XCTAssertEqual(p.lift, 0)
        XCTAssertTrue(p.isIdentity)
        XCTAssertEqual(p.detailSlope, 1)
        // gain = 0 makes the remap the identity for every value and centre.
        for g in ClarityMapping.gammaLevels {
            for v in stride(from: -14.0, through: 4.0, by: 0.25) {
                XCTAssertEqual(ClarityMapping.remap(v, center: g, p), v, accuracy: 0)
            }
        }
    }

    func testClarityMappingIsMonotoneInMagnitude() {
        var previousGain = -1.0
        for c in stride(from: 0.0, through: 100.0, by: 5) {
            let p = ClarityMapping.parameters(for: c)
            XCTAssertGreaterThan(p.gain, previousGain)
            // Wave 3: alpha is pinned at its endpoint value and `gain` does all
            // the interpolating, which is what makes `lift` linear.
            XCTAssertEqual(p.alpha, 1 - ClarityMapping.alphaBoostRange, accuracy: 1e-12)
            previousGain = p.gain
        }
        XCTAssertEqual(ClarityMapping.parameters(for: 100).gain, 1)
        XCTAssertEqual(ClarityMapping.parameters(for: 100).amount, 1)
        // Monotone in clarity all the way through to the remap's detail slope.
        var previousSlope = 1.0
        for c in stride(from: 5.0, through: 100.0, by: 5) {
            let s = ClarityMapping.parameters(for: c).detailSlope
            XCTAssertGreaterThan(s, previousSlope)
            previousSlope = s
        }
        // Out-of-range sliders clamp rather than extrapolate. Clarity is
        // positive-only, so everything below 0 is the identity — there is no
        // smoothing operator to reach.
        XCTAssertEqual(ClarityMapping.parameters(for: 250), ClarityMapping.parameters(for: 100))
        for c in [-1.0, -50, -100, -250] {
            XCTAssertEqual(ClarityMapping.parameters(for: c), ClarityMapping.parameters(for: 0),
                           "clarity \(c) must clamp to the identity")
            XCTAssertTrue(ClarityMapping.parameters(for: c).isIdentity)
        }
    }

    /// The whole slider does work, not just its top third (audit
    /// `clarity-local` #0). `lift` is linear in the slider with the endpoints
    /// unchanged, so the detail slope is 1.15 at +10 and 1.375 at +25 where it
    /// used to be 1.006 and 1.044.
    func testClarityResponseIsLinearInTheSlider() {
        let expected: [Double: Double] = [10: 1.15, 25: 1.375, 50: 1.75, 75: 2.125, 100: 2.5]
        for (c, slope) in expected {
            XCTAssertEqual(ClarityMapping.parameters(for: c).detailSlope, slope, accuracy: 1e-12,
                           "clarity +\(c)")
        }
        // Exactly linear: lift(c) = c/100 · lift(100).
        for c in stride(from: 0.0, through: 100.0, by: 2.5) {
            XCTAssertEqual(ClarityMapping.parameters(for: c).lift,
                           c / 100 * ClarityMapping.referenceLift, accuracy: 1e-12)
        }
        // …which is exactly what makes the mask amount map (c/100 against a
        // fixed full-scale pyramid) reproduce each pixel's own strength.
        XCTAssertEqual(ClarityMapping.referenceLift, 1.5, accuracy: 1e-12)
        XCTAssertLessThan(ClarityMapping.referenceLift, ClarityMapping.maxLift)
        // Still exactly the identity at 0, which is the invariant everything
        // else rests on.
        XCTAssertEqual(ClarityMapping.parameters(for: 0).lift, 0)
        XCTAssertEqual(ClarityMapping.parameters(for: 0).amount, 0)
    }

    func testClarityRemapIsMonotoneOddAndFadesOut() {
        let sigma = ClarityMapping.sigmaR
        for clarity in [20.0, 60, 100] {
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
            XCTAssertGreaterThan(p.detailSlope, 1)
        }
    }

    /// The discretisation only samples the remap's slope within one gamma step,
    /// so `gain(t)` has to stay flat across the grid or clarity strength would
    /// swing with tone. This is what pins K.
    func testEffectiveDetailGainIsFlatAcrossTheGammaGrid() {
        for clarity in [30.0, 80, 100] {
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

    /// 4-stop step edge at x = 128 plus a multiplicative ripple of a chosen
    /// spatial period.
    ///
    /// The period matters since wave 3: clarity is a mid/large-radius control
    /// and deliberately does **not** lift the pixel-scale band (that band is
    /// sensor noise, and Lightroom's Clarity does not amplify it either — see
    /// `ClarityMapping.levelGains`). Period 4 is the pixel-scale band, period 16
    /// is texture.
    ///
    /// The two plateaus straddle middle gray (±2 EV) rather than sitting 4 and 1
    /// stops *under* it as they used to. That is deliberate too: since wave 3 the
    /// lift is midtone-weighted, so a test image parked in the deep shadows
    /// measures the tone weight as much as the filter.
    private static let edgeX = 128
    private static let darkY: Float = 0.045
    private static let brightY: Float = 0.72
    private static let rippleAmplitude: Float = 0.12
    private static let texturePeriod = 16.0
    private static let noisePeriod = 4.0

    private func syntheticPixel(_ x: Int, _ y: Int) -> (Float, Float, Float) {
        ripplePixel(x, y, period: Self.texturePeriod)
    }

    private func ripplePixel(_ x: Int, _ y: Int, period: Double) -> (Float, Float, Float) {
        let base = x < Self.edgeX ? Self.darkY : Self.brightY
        let w = 2 * Double.pi / period
        let sx = Float(sin(Double(x) * w))
        let sy = Float(sin(Double(y) * w))
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
    // are multiples of both ripple periods (4 and 16) so the ripple cancels in
    // the means.
    private let farXs = 40..<88
    private let farYs = 40..<216
    private let nearLeftXs = 108..<124
    private let nearRightXs = 132..<148

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
        print("[clarity +80] texture RMS \(farBefore.std) -> \(farAfter.std) "
              + "(x\(farAfter.std / farBefore.std))")
        XCTAssertGreaterThan(farAfter.std, farBefore.std * 1.3,
                             "clarity +80 should clearly raise texture local contrast")

        // Halo suppression: the flat regions either side of the step must barely
        // move. Bound is in stops; 0.03 stops is ~2% in linear luminance.
        for xs in [nearLeftXs, nearRightXs] {
            let b = stats(before, width: w, xs, farYs)
            let a = stats(after, width: w, xs, farYs)
            print("[clarity +80] near-edge \(xs) mean shift \(a.mean - b.mean) stops")
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
        print("[clarity +80] near-edge shift: local Laplacian \(llfShift) vs unsharp "
              + "\(unsharpShift) stops (gain \(gain))")
        XCTAssertGreaterThan(unsharpShift, 3 * llfShift,
                             "unsharp \(unsharpShift) vs local Laplacian \(llfShift) stops")
    }

    /// Unsharp mask on the same synthetic image, in log2 luminance, with a
    /// sigma-8 Gaussian — twice the ripple period, so the ripple is essentially
    /// annihilated by the blur and the texture gain is close to `1 + amount`.
    /// The comparison only needs the *halo* it produces at the step edge.
    private func unsharpReference(amount: Double) -> [Double] {
        let w = 256, h = 256
        var base = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w { base[y * w + x] = log2(Double(syntheticPixel(x, y).0)) }
        }
        let sigma = 8.0, radius = 24
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

    /// Clarity is the mid/large-radius local-contrast control: it lifts texture
    /// and leaves the pixel-scale band — which on a real capture is sensor noise
    /// — essentially where it was (audit `clarity-local` #2).
    ///
    /// Two runs of the same test image with only the ripple period changed, so
    /// the amplitude, the tone and the step edge are identical and the only
    /// variable is spatial frequency.
    func testClarityLiftsTextureButNotThePixelScaleBand() throws {
        let w = 256
        func gain(period: Double) throws -> Double {
            let pixel = { (x: Int, y: Int) in self.ripplePixel(x, y, period: period) }
            let before = logLuminance(try runClarity(0, pixel: pixel))
            let after = logLuminance(try runClarity(80, pixel: pixel))
            let b = stats(before, width: w, farXs, farYs).std
            let a = stats(after, width: w, farXs, farYs).std
            return a / b
        }
        let texture = try gain(period: Self.texturePeriod)
        let noise = try gain(period: Self.noisePeriod)
        print("[clarity band] +80 gain: period-16 texture x\(texture), "
              + "period-4 pixel scale x\(noise)")

        XCTAssertGreaterThan(texture, 1.3, "texture must be lifted")
        // Level 0 is passed through with gain 0 and level 1 with 0.4, and a
        // period-4 ripple lives almost entirely in level 0.
        XCTAssertLessThan(noise, 1.10, "pixel-scale detail must be nearly untouched")
        XCTAssertGreaterThan(texture, 3 * (noise - 1) + 1,
                             "the band separation is the point: \(texture) vs \(noise)")
    }

    /// Clarity is a **midtone** control: the same texture gets less of the lift
    /// in the deep shadows and up in the highlights, which is why a heavy
    /// clarity push does not blow speculars or crush blacks (audit #1).
    func testClarityIsWeightedTowardTheMidtones() throws {
        // CPU mapping first: a Gaussian in stops around 0.18 with a floor.
        XCTAssertEqual(ClarityMapping.toneWeight(logLuminance: log2(0.18)), 1, accuracy: 1e-12)
        XCTAssertEqual(ClarityMapping.toneWeight(logLuminance: log2(0.18) + 3),
                       exp(-0.5), accuracy: 1e-12)
        XCTAssertEqual(ClarityMapping.toneWeight(logLuminance: log2(0.18) - 3),
                       exp(-0.5), accuracy: 1e-12)
        XCTAssertEqual(ClarityMapping.toneWeight(logLuminance: log2(0.18) + 9),
                       ClarityMapping.toneWeightFloor, accuracy: 1e-12)
        // Symmetric, monotone away from the peak, never zero.
        for ev in stride(from: 0.0, through: 8.0, by: 0.25) {
            let up = ClarityMapping.toneWeight(logLuminance: log2(0.18) + ev)
            let down = ClarityMapping.toneWeight(logLuminance: log2(0.18) - ev)
            XCTAssertEqual(up, down, accuracy: 1e-12)
            XCTAssertGreaterThanOrEqual(up, ClarityMapping.toneWeightFloor)
            XCTAssertLessThanOrEqual(up, 1)
        }

        // And the GPU honours it: the same ripple at three tone levels. 256²
        // so the pyramid actually has the levels clarity works on (a 64 px short
        // side would bottom out at two levels, i.e. level 0 only, which the band
        // weighting passes straight through).
        let w = 256, h = 256
        func gain(atEV ev: Double) throws -> Double {
            let base = 0.18 * exp2(ev)
            let pixel = { (x: Int, _: Int) -> (Float, Float, Float) in
                let v = Float(base * (1 + 0.12 * sin(Double(x) * 2 * .pi / Self.texturePeriod)))
                return (v, v, v)
            }
            let before = logLuminance(try runClarity(0, width: w, height: h, pixel: pixel))
            let after = logLuminance(try runClarity(80, width: w, height: h, pixel: pixel))
            let xs = 64..<192, ys = 64..<192
            return stats(after, width: w, xs, ys).std / stats(before, width: w, xs, ys).std
        }
        let mid = try gain(atEV: 0)
        let shadow = try gain(atEV: -5)
        let highlight = try gain(atEV: 2.5)
        print("[clarity midtone] gain at -5 EV \(shadow), 0 EV \(mid), +2.5 EV \(highlight)")
        XCTAssertGreaterThan(mid, shadow, "midtones must get more clarity than deep shadows")
        XCTAssertGreaterThan(mid, highlight, "midtones must get more clarity than highlights")
        // Attenuated, not switched off.
        XCTAssertGreaterThan(shadow, 1.05)
        XCTAssertGreaterThan(highlight, 1.05)
    }

    // MARK: - GPU: negative clarity is gone

    /// Clarity is positive-only. A negative value — from an old sidecar, from
    /// `--set clarity=-50`, from anywhere — renders exactly like clarity 0, and
    /// "exactly" means bit-identical: the negative operator does not exist, so
    /// there is nothing to run at reduced strength.
    func testNegativeGlobalClarityRendersAsZero() throws {
        let zero = try runClarity(0)
        for c in [-1.0, -50, -80, -100, -250] {
            let negative = try runClarity(c)
            var differing = 0
            for i in 0..<zero.pixels.count where zero.pixels[i] != negative.pixels[i] {
                differing += 1
            }
            XCTAssertEqual(differing, 0,
                           "clarity \(c) differs from clarity 0 in \(differing) samples")
        }
    }

    /// The sidecar path is lenient rather than strict: an old sidecar holding a
    /// negative clarity decodes to 0 and renders identically to one that says 0.
    func testOldSidecarWithNegativeClarityClampsToZero() throws {
        let old = Data(#"{"version": 1, "clarity": -80, "tone": {"contrast": 20}}"#.utf8)
        let decoded = try EditState.decode(from: old)
        XCTAssertEqual(decoded.clarity, 0)
        XCTAssertEqual(decoded.tone.contrast, 20, "the rest of the sidecar must survive")
        // Over-range positive values clamp too.
        XCTAssertEqual(try EditState.decode(from: Data(#"{"clarity": 250}"#.utf8)).clarity, 100)

        let (ctx, pipe) = try TestGPU.require()
        let input = try ctx.makeTexture(width: 256, height: 256, syntheticPixel)
        var zero = decoded
        zero.clarity = 0
        let a = try TextureReadback.read(
            pipe.render(input: input, edit: decoded, upTo: .clarity).texture)
        let b = try TextureReadback.read(
            pipe.render(input: input, edit: zero, upTo: .clarity).texture)
        for i in 0..<a.pixels.count {
            XCTAssertEqual(a.pixels[i], b.pixels[i], "at sample \(i)")
        }
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
        // The band profile is the interesting part on a real photograph: the
        // gain has to *grow* with scale, because clarity is the coarse
        // local-contrast control and the pixel-scale band (sensor noise, plus
        // resampling detail on this 1024 px preview) is meant to come through
        // untouched. Measured here at clarity +60, span 1 → 16:
        // 1.00, 1.02, 1.08, 1.16, 1.24.
        var previous = 0.0
        for s in [1, 2, 4, 8, 16] {
            let ratio = bandEnergy(b, span: s) / bandEnergy(a, span: s)
            print("[clarity e2e] band span \(s): \(bandEnergy(a, span: s)) -> "
                  + "\(bandEnergy(b, span: s)) (x\(ratio))")
            XCTAssertGreaterThan(ratio, previous, "band gain must grow with scale (span \(s))")
            previous = ratio
        }
        XCTAssertGreaterThan(bandEnergy(b, span: 16), bandEnergy(a, span: 16) * 1.15,
                             "clarity +60 must clearly raise coarse local contrast")
        XCTAssertLessThan(pixelScaleEnergy(b), pixelScaleEnergy(a) * 1.02,
                          "the pixel-scale band must be left alone")
        XCTAssertEqual(b.meanLuminance, a.meanLuminance, accuracy: a.meanLuminance * 0.1)
    }

    /// Mean squared horizontal *second* difference of log2 luminance at scale
    /// `span` — a crude but robust band-pass. It rejects both DC and a linear
    /// ramp, so unlike a first difference it is not diluted by the large-scale
    /// structure of a real photograph, and its passband is centred near period
    /// `4·span`. `span = 1` is the pixel-scale (noise) band; `span = 4` is the
    /// band clarity is supposed to work in.
    private func bandEnergy(_ img: FloatImage, span: Int) -> Double {
        let v = logLuminance(img)
        var acc = 0.0
        var n = 0.0
        for y in 0..<img.height {
            for x in span..<(img.width - span) {
                let d = v[y * img.width + x - span] - 2 * v[y * img.width + x]
                    + v[y * img.width + x + span]
                acc += d * d
                n += 1
            }
        }
        return acc / n
    }

    private func localContrastEnergy(_ img: FloatImage) -> Double { bandEnergy(img, span: 4) }
    private func pixelScaleEnergy(_ img: FloatImage) -> Double { bandEnergy(img, span: 1) }
}
