import Metal
import XCTest
@testable import GrayroomCore

/// M3: brush masks, parameter accumulation and the per-pixel stage hooks.
///
/// The CPU rasterizer in `MaskRasterizer` is the reference: the stamp-profile,
/// flow, density and erase tests pin the *semantics* there, and one test then
/// pins the GPU to it.
final class MaskTests: XCTestCase {

    // MARK: - CPU rasterizer: the stamp

    /// One stamp, hard and feathered. `feather = 0` still gets a 1 px antialias
    /// ramp (`inner = radius − 1`); `feather = 100` falls off from the centre.
    func testSingleStampRadialProfile() throws {
        let w = 64, h = 64
        // diameter = 0.5 * 64 = 32 px, so radius 16 centred on (32, 32).
        func coverage(feather: Double) -> [Float] {
            let mask = Mask(strokes: [Stroke(brush: BrushParams(size: 0.5, feather: feather,
                                                                flow: 100, density: 100),
                                             points: [StrokePoint(x: 0.5, y: 0.5)])])
            return MaskRasterizer.rasterize(mask, width: w, height: h)
        }
        // Sample along the +x axis from the stamp centre. Pixel (32, 31) has its
        // centre at (32.5, 31.5), i.e. 0.5 px off-axis — sample on row 31 and
        // account for it with the exact distance.
        func value(_ c: [Float], _ x: Int) -> Double { Double(c[31 * w + x]) }
        func distance(_ x: Int) -> Double {
            let dx = Double(x) + 0.5 - 32, dy = 31.5 - 32.0
            return (dx * dx + dy * dy).squareRoot()
        }

        let hard = coverage(feather: 0)
        let soft = coverage(feather: 100)

        for x in 32..<52 {
            let d = distance(x)
            let expectedHard = MaskRasterizer.profile(distance: d, inner: 15, outer: 16)
            let expectedSoft = MaskRasterizer.profile(distance: d, inner: 0, outer: 16)
            // The coverage array is Float; the reference is Double.
            XCTAssertEqual(value(hard, x), expectedHard, accuracy: 1e-6)
            XCTAssertEqual(value(soft, x), expectedSoft, accuracy: 1e-6)
        }

        // Shape: hard is flat then drops in ~1 px; soft is a smooth dome.
        XCTAssertEqual(value(hard, 32), 1, accuracy: 1e-9)
        XCTAssertEqual(value(hard, 44), 1, accuracy: 1e-9)          // d = 11.5 < 15
        XCTAssertEqual(value(hard, 47), 0.5, accuracy: 0.06)        // d = 15.5, mid-ramp
        XCTAssertEqual(value(hard, 48), 0, accuracy: 1e-9)          // d = 16.5 >= 16
        // Soft falls off from the centre, so even 0.7 px out it is below 1.
        XCTAssertGreaterThan(value(soft, 32), 0.99)
        XCTAssertLessThan(value(soft, 32), 1)
        XCTAssertEqual(value(soft, 40), 0.5, accuracy: 0.06)        // d ~ 8 = r/2
        XCTAssertLessThan(value(soft, 44), value(soft, 40))
        XCTAssertEqual(value(soft, 48), 0, accuracy: 1e-9)
        // A featherless brush covers strictly more than a feathered one.
        for i in 0..<(w * h) where soft[i] > 0 {
            XCTAssertGreaterThanOrEqual(hard[i], soft[i] - 1e-6)
        }
    }

    /// Stamp placement: spacing is 15% of the *nominal* diameter, measured in
    /// pixels along the polyline, with the first stamp on the first point.
    func testStampPlacementSpacing() {
        let stroke = Stroke(brush: BrushParams(size: 0.5, feather: 0),
                            polyline: [(0.25, 0.5), (0.75, 0.5)])
        let stamps = MaskRasterizer.stamps(for: stroke, width: 64, height: 64)
        // diameter 32 px -> spacing 4.8 px over a 32 px segment: 1 + 6 stamps.
        XCTAssertEqual(stamps.count, 7)
        XCTAssertEqual(stamps[0].x, 16, accuracy: 1e-9)
        for i in 1..<stamps.count {
            XCTAssertEqual(stamps[i].x - stamps[i - 1].x, 4.8, accuracy: 1e-9)
            XCTAssertEqual(stamps[i].y, 32, accuracy: 1e-9)
        }
        // Pressure scales the radius (and only the radius); spacing is unchanged.
        let ramped = Stroke(brush: BrushParams(size: 0.5, feather: 0),
                            points: [StrokePoint(x: 0.25, y: 0.5, pressure: 1),
                                     StrokePoint(x: 0.75, y: 0.5, pressure: 0)])
        let rampedStamps = MaskRasterizer.stamps(for: ramped, width: 64, height: 64)
        XCTAssertEqual(rampedStamps.count, 7)
        XCTAssertEqual(rampedStamps[0].radius, 16, accuracy: 1e-9)
        // The last stamp lands at u = 0.9 (the endpoint itself is never stamped
        // unless it falls exactly on the spacing grid), so pressure is 0.1.
        XCTAssertEqual(rampedStamps[6].radius, 1.6, accuracy: 1e-9)
        for i in 1..<rampedStamps.count {
            XCTAssertLessThan(rampedStamps[i].radius, rampedStamps[i - 1].radius)
            XCTAssertEqual(rampedStamps[i].alpha, rampedStamps[i - 1].alpha)
        }
        // Sub-spacing strokes still get their single stamp.
        let dot = Stroke(brush: BrushParams(size: 0.5), polyline: [(0.5, 0.5)])
        XCTAssertEqual(MaskRasterizer.stamps(for: dot, width: 64, height: 64).count, 1)
    }

    // MARK: - CPU rasterizer: flow, density, erase

    /// Flow is a **rate that builds up across strokes**, the Lightroom
    /// dodge-and-burn mechanic: one pass at flow 20 deposits 0.2 however many
    /// stamps overlap within it, a second pass takes it to 0.2 + 0.2·0.8 = 0.36,
    /// a third to 0.488.
    func testFlowBuildsUpAcrossStrokesNotWithinOne() {
        let w = 64, h = 64
        // Two stamps in ONE stroke: one on the first point, one 4.8 px down the
        // 6 px segment. (32, 34) is inside both stamps' full-opacity discs.
        let brush = BrushParams(size: 0.5, feather: 0, flow: 20, density: 100)
        let stroke = Stroke(brush: brush, polyline: [(0.5, 0.5), (0.5, 0.5 + 6.0 / 64.0)])
        XCTAssertEqual(MaskRasterizer.stamps(for: stroke, width: w, height: h).count, 2)
        let one = MaskRasterizer.rasterize(Mask(strokes: [stroke]), width: w, height: h)
        XCTAssertEqual(Double(one[34 * w + 32]), 0.2, accuracy: 1e-6,
                       "overlapping stamps inside one stroke must not build up")

        // Repeat the same stroke: now it builds, sub-linearly.
        for (passes, expected) in [(2, 0.36), (3, 0.488), (4, 0.5904)] {
            let c = MaskRasterizer.rasterize(
                Mask(strokes: [Stroke](repeating: stroke, count: passes)), width: w, height: h)
            XCTAssertEqual(Double(c[34 * w + 32]), expected, accuracy: 1e-6,
                           "\(passes) passes at flow 20")
        }

        // A single dab is still exactly the flow.
        let dab = Stroke(brush: brush, polyline: [(0.5, 0.5)])
        let c1 = MaskRasterizer.rasterize(Mask(strokes: [dab]), width: w, height: h)
        XCTAssertEqual(Double(c1[32 * w + 32]), 0.2, accuracy: 1e-6)
    }

    /// Density is an **absolute ceiling** on the mask: no number of strokes gets
    /// past it, and painting at a low density never pulls existing coverage down.
    func testDensityIsAnAbsoluteCeiling() {
        let w = 64, h = 64
        let brush = BrushParams(size: 0.5, feather: 0, flow: 20, density: 30)
        let stroke = Stroke(brush: brush, polyline: [(0.5, 0.5), (0.5, 0.5 + 6.0 / 64.0)])

        // 0.2, 0.36 → capped at 0.30, and it stays there however many passes.
        for passes in 1...6 {
            let c = MaskRasterizer.rasterize(
                Mask(strokes: [Stroke](repeating: stroke, count: passes)), width: w, height: h)
            XCTAssertEqual(Double(c[34 * w + 32]), min(1 - pow(0.8, Double(passes)), 0.30),
                           accuracy: 1e-6, "\(passes) passes at flow 20 / density 30")
        }

        // Below the ceiling nothing changes.
        var loose = brush
        loose.density = 100
        let unclamped = MaskRasterizer.rasterize(
            Mask(strokes: [Stroke(brush: loose, polyline: [(0.5, 0.5)])]), width: w, height: h)
        XCTAssertEqual(Double(unclamped[32 * w + 32]), 0.2, accuracy: 1e-6)

        // A low-density brush over an area that is already denser leaves it
        // alone — the ceiling caps build-up, it does not erase.
        var full = brush
        full.density = 100
        full.flow = 100
        var weak = brush
        weak.density = 40
        weak.flow = 100
        let over = MaskRasterizer.rasterize(
            Mask(strokes: [Stroke(brush: full, polyline: [(0.5, 0.5)]),
                           Stroke(brush: weak, polyline: [(0.5, 0.5)])]), width: w, height: h)
        XCTAssertEqual(Double(over[32 * w + 32]), 1.0, accuracy: 1e-9)
    }

    /// Normal strokes merge with `max`, erase strokes with `mask·(1 − stroke)`.
    func testEraseStrokeSubtracts() {
        let w = 64, h = 64
        let paint = Stroke(brush: BrushParams(size: 2.0, feather: 0, flow: 100),
                           polyline: [(0.5, 0.5)])
        let half = Stroke(brush: BrushParams(size: 0.5, feather: 0, flow: 50),
                          erase: true, polyline: [(0.5, 0.5)])
        let full = Stroke(brush: BrushParams(size: 0.5, feather: 0, flow: 100),
                          erase: true, polyline: [(0.5, 0.5)])

        let painted = MaskRasterizer.rasterize(Mask(strokes: [paint]), width: w, height: h)
        XCTAssertEqual(Double(painted[32 * w + 32]), 1, accuracy: 1e-9)
        XCTAssertEqual(Double(painted[0]), 1, accuracy: 1e-9, "a size-2.0 brush covers everything")

        let halfErased = MaskRasterizer.rasterize(Mask(strokes: [paint, half]), width: w, height: h)
        XCTAssertEqual(Double(halfErased[32 * w + 32]), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Double(halfErased[0]), 1, accuracy: 1e-9, "erase is local to its stamps")

        let erased = MaskRasterizer.rasterize(Mask(strokes: [paint, full]), width: w, height: h)
        XCTAssertEqual(Double(erased[32 * w + 32]), 0, accuracy: 1e-9)
        // ... and a normal stroke after the eraser paints back over the hole.
        let repainted = MaskRasterizer.rasterize(Mask(strokes: [paint, full, paint]),
                                                 width: w, height: h)
        XCTAssertEqual(Double(repainted[32 * w + 32]), 1, accuracy: 1e-9)
    }

    // MARK: - GPU vs CPU

    private func syntheticStrokeMask() -> Mask {
        Mask(name: "synthetic",
             adjustments: MaskAdjustments(exposure: 1),
             strokes: [
                // A soft diagonal, a hard dab with a pressure ramp, and an eraser.
                Stroke(brush: BrushParams(size: 0.30, feather: 70, flow: 60, density: 90),
                       polyline: [(0.15, 0.2), (0.5, 0.55), (0.85, 0.35)]),
                Stroke(brush: BrushParams(size: 0.18, feather: 10, flow: 100, density: 100),
                       points: [StrokePoint(x: 0.2, y: 0.8, pressure: 0.3),
                                StrokePoint(x: 0.8, y: 0.8, pressure: 1.0)]),
                Stroke(brush: BrushParams(size: 0.22, feather: 40, flow: 80, density: 70),
                       erase: true, polyline: [(0.35, 0.3), (0.6, 0.6)]),
             ])
    }

    func testGPUMatchesCPURasterizer() throws {
        let (_, pipe) = try TestGPU.require()
        let w = 96, h = 64
        let mask = syntheticStrokeMask()
        let gpu = try pipe.maskCoverage(masks: [mask], width: w, height: h, maskIndex: 0)
        let cpu = MaskRasterizer.rasterize(mask, width: w, height: h)

        XCTAssertEqual(gpu.count, cpu.count)
        var maxDelta = 0.0
        for i in 0..<cpu.count {
            maxDelta = max(maxDelta, abs(Double(gpu[i]) - Double(cpu[i])))
        }
        // r16Float storage quantises to ~1e-3 near 1.0; the arithmetic itself is
        // float32 on the GPU and Double on the CPU.
        XCTAssertLessThan(maxDelta, 2e-3, "GPU/CPU rasterizer disagree by \(maxDelta)")
        XCTAssertGreaterThan(cpu.reduce(0, +) / Float(cpu.count), 0.05, "test mask is empty")

        // The union of two masks is the max of their coverages.
        var other = mask
        other.strokes = [Stroke(brush: BrushParams(size: 0.4, feather: 0),
                                polyline: [(0.1, 0.1)])]
        let union = try pipe.maskCoverage(masks: [mask, other], width: w, height: h)
        let cpuUnion = MaskRasterizer.rasterizeUnion([mask, other], width: w, height: h)
        for i in 0..<union.count {
            XCTAssertEqual(Double(union[i]), Double(cpuUnion[i]), accuracy: 2e-3)
        }
    }

    // MARK: - Parameter accumulation

    /// Two masks covering the same pixels sum, then saturate at the documented
    /// range edges (±4 EV, ±100).
    func testParameterAccumulationSumsAndClamps() throws {
        let (ctx, pipe) = try TestGPU.require()
        let w = 32, h = 32
        // A size-2.0 brush covers the whole frame at coverage 1.
        func mask(_ a: MaskAdjustments) -> Mask {
            Mask(adjustments: a,
                 strokes: [Stroke(brush: BrushParams(size: 2.0, feather: 0, flow: 100),
                                  polyline: [(0.5, 0.5)])])
        }
        let masks = [
            mask(MaskAdjustments(exposure: 3, contrast: 60, highlights: -80, shadows: 10, clarity: 70)),
            mask(MaskAdjustments(exposure: 3, contrast: 60, highlights: -80, shadows: -40, clarity: 70)),
        ]

        guard let cb = ctx.commandQueue.makeCommandBuffer() else { return XCTFail("no cb") }
        let maps = try pipe.maskStage.encodeMaps(cb, masks: masks, width: w, height: h)
        cb.commit()
        cb.waitUntilCompleted()

        let a = try TextureReadback.read(maps.paramsA)
        let b = try TextureReadback.readScalar(maps.paramsB)
        let i = (16 * w + 16) * 4
        XCTAssertEqual(Double(a.pixels[i]), 4, accuracy: 1e-3)        // 3 + 3 -> clamped to 4
        XCTAssertEqual(Double(a.pixels[i + 1]), 100, accuracy: 1e-2)  // 60 + 60 -> clamped
        XCTAssertEqual(Double(a.pixels[i + 2]), -100, accuracy: 1e-2) // -80 - 80 -> clamped
        XCTAssertEqual(Double(a.pixels[i + 3]), -30, accuracy: 1e-2)  // 10 - 40, in range
        XCTAssertEqual(Double(b[16 * w + 16]), 100, accuracy: 1e-2)   // 70 + 70 -> clamped

        // The CPU reference agrees.
        let coverages = masks.map { MaskRasterizer.rasterize($0, width: w, height: h) }
        let p = MaskRasterizer.accumulate(masks, coverages: coverages, at: 16 * w + 16)
        XCTAssertEqual(p.exposure, 4, accuracy: 1e-9)
        XCTAssertEqual(p.contrast, 100, accuracy: 1e-9)
        XCTAssertEqual(p.highlights, -100, accuracy: 1e-9)
        XCTAssertEqual(p.shadows, -30, accuracy: 1e-9)
        XCTAssertEqual(p.clarity, 100, accuracy: 1e-9)
    }

    // MARK: - Tone delta

    /// Zero deltas must leave the tone stage **bit-for-bit** where it was: this
    /// is what makes an unmasked pixel identical to a pre-M3 render.
    func testToneDeltaIsBitwiseIdentityAtZero() throws {
        let (ctx, pipe) = try TestGPU.require()
        let w = 64, h = 8
        let input = try ctx.makeTexture(width: w, height: h) { x, _ in
            let v = Float(exp2(Double(x) / 8 - 6))
            return (v, v * 0.8, v * 1.2)
        }
        let zeros = try ctx.makeRGBATexture(width: w, height: h) { _, _ in (0, 0, 0, 0) }
        let tone = EditState.Tone(exposure: 0.3, contrast: 25, highlights: -40, shadows: 20)

        let withParams = try TextureReadback.read(
            pipe.renderToneOnly(input: input, tone: tone, params: zeros))
        let without = try TextureReadback.read(
            pipe.renderToneOnly(input: input, tone: tone, params: nil))
        for i in 0..<withParams.pixels.count {
            XCTAssertEqual(withParams.pixels[i], without.pixels[i],
                           "zero local delta must not perturb the tone stage (i=\(i))")
        }
    }

    /// The shader's `grToneDeltaEV` against `ToneCurve`'s components, over a grid
    /// of luminances and delta triples, composed after the global LUT.
    func testGPUToneDeltaMatchesCPUReference() throws {
        let (ctx, pipe) = try TestGPU.require()
        // Half-float-exact values so the texture round trip contributes nothing.
        let deltas: [(Float, Float, Float, Float)] = [
            (0, 0, 0, 0), (1, 0, 0, 0), (-1.5, 0, 0, 0),
            (0, 50, 0, 0), (0, -50, 0, 0),
            (0, 0, 60, 0), (0, 0, -60, 0),
            (0, 0, 0, 75), (0, 0, 0, -75),
            (0.5, 25, -40, 20), (-2, -25, 40, -20), (4, 100, 100, 100),
            (-4, -100, -100, -100), (1.5, 60, -80, 30),
        ]
        let luminances: [Float] = (0..<40).map { Float(exp2(Double($0) * 0.5 - 12)) }
        let w = luminances.count, h = deltas.count

        let input = try ctx.makeTexture(width: w, height: h) { x, _ in
            (luminances[x], luminances[x], luminances[x])
        }
        let params = try ctx.makeRGBATexture(width: w, height: h) { _, y in deltas[y] }
        let tone = EditState.Tone(exposure: 0.3, contrast: 25, highlights: -40, shadows: 20)
        let out = try TextureReadback.read(pipe.renderToneOnly(input: input, tone: tone, params: params))

        let lut = ToneCurve.makeLUT(for: tone)
        var worst = 0.0
        for y in 0..<h {
            let d = deltas[y]
            for x in 0..<w {
                let Y = Double(Float16(luminances[x]))
                let global = ToneCurve.applyLUT(lut, toLuminance: Y)
                let expected = ToneCurve.applyToneDelta(global,
                                                        exposure: Double(d.0),
                                                        contrast: Double(d.1),
                                                        highlights: Double(d.2),
                                                        shadows: Double(d.3))
                let got = Double(out.rgb(x: x, y: y).0)
                let tol = max(expected * 3e-3, 1e-7)
                // Below ~1e-4 the rgba16Float round trip dominates; the relative
                // summary only tracks values the format can actually resolve.
                if expected > 1e-4 { worst = max(worst, abs(got - expected) / expected) }
                XCTAssertEqual(got, expected, accuracy: tol,
                               "Y=\(Y) delta=\(d): GPU \(got) vs CPU \(expected)")
            }
        }
        XCTAssertLessThan(worst, 3e-3)
    }

    /// The local delta must stay monotone in Y, or masked highlights would fold
    /// over masked midtones. Seeded random deltas over the full slider ranges.
    func testToneDeltaIsMonotoneInLuminance() {
        var rng = SeededRandom(seed: 0x5EED_0003)
        for _ in 0..<200 {
            let ev = rng.double(in: -4...4)
            let c = rng.double(in: -100...100)
            let hi = rng.double(in: -100...100)
            let sh = rng.double(in: -100...100)
            var previous = -Double.infinity
            for i in 0...800 {
                let x = -14.0 + Double(i) * 22.0 / 800.0
                let y = ToneCurve.pivot * exp2(x)
                let out = ToneCurve.applyToneDelta(y, exposure: ev, contrast: c,
                                                   highlights: hi, shadows: sh)
                XCTAssertGreaterThan(out, previous,
                                     "not monotone at \(x) EV for (\(ev), \(c), \(hi), \(sh))")
                previous = out
            }
        }
    }

    // MARK: - Golden: a mask over half the frame

    /// One mask covering the left half at Δexposure +1 doubles linear luminance
    /// there and leaves the right half bit-for-bit alone.
    func testMaskedExposureDoublesTheCoveredHalf() throws {
        let (ctx, pipe) = try TestGPU.require()
        let w = 256, h = 256
        let input = try ctx.makeTexture(width: w, height: h) { x, y in
            let fx: Double = Double(x) / 255
            let fy: Double = Double(y) / 255
            let v = Float(0.02 + 0.3 * fx + 0.1 * fy)
            return (v, v * 0.9, v * 1.1)
        }
        // A wide hard brush dragged down past both edges of the frame: full
        // coverage out to x ~ 100, zero past x ~ 103.
        let mask = Mask(name: "left",
                        adjustments: MaskAdjustments(exposure: 1),
                        strokes: [Stroke(brush: BrushParams(size: 0.6, feather: 0,
                                                            flow: 100, density: 100),
                                         polyline: [(0.1, -0.2), (0.1, 1.2)])])
        var edit = EditState()
        edit.tone = .init(exposure: 0.3, contrast: 25)
        var masked = edit
        masked.masks = [mask]

        let plain = try TextureReadback.read(pipe.render(input: input, edit: edit, upTo: .tone).texture)
        let out = try TextureReadback.read(pipe.render(input: input, edit: masked, upTo: .tone).texture)

        // Left: x2 in linear luminance. Sampled away from the feathered edge.
        for y in stride(from: 8, to: h, by: 16) {
            for x in stride(from: 4, to: 80, by: 8) {
                let a = Double(plain.rgb(x: x, y: y).0)
                let b = Double(out.rgb(x: x, y: y).0)
                XCTAssertEqual(b / a, 2.0, accuracy: 0.02, "at (\(x), \(y))")
            }
        }
        // Right: outside every stamp the parameter map is exactly zero, so the
        // kernel takes the same path and the bits match.
        for y in 0..<h {
            for x in 110..<w {
                let i = (y * w + x) * 4
                XCTAssertEqual(out.pixels[i], plain.pixels[i], "at (\(x), \(y))")
                XCTAssertEqual(out.pixels[i + 1], plain.pixels[i + 1])
                XCTAssertEqual(out.pixels[i + 2], plain.pixels[i + 2])
            }
        }
        // The transition is monotone across the feathered boundary.
        let row = 128
        var previous = 0.0
        for x in stride(from: 108, through: 84, by: -1) {
            let ratio = Double(out.rgb(x: x, y: row).0) / Double(plain.rgb(x: x, y: row).0)
            XCTAssertGreaterThanOrEqual(ratio, previous - 1e-3, "ratio dipped at x=\(x)")
            previous = ratio
        }
    }

    // MARK: - Local clarity

    /// A clarity mask raises fine-texture contrast where it covers and leaves
    /// the rest of the frame bit-for-bit alone (amount 0 => `mix(L, L', 0)`).
    func testLocalClarityAffectsOnlyTheMaskedRegion() throws {
        let (ctx, pipe) = try TestGPU.require()
        let w = 256, h = 256
        // Flat base at middle gray with a period-16 multiplicative ripple: the
        // same texture ClarityTests uses, without the step edge. Period 16, not
        // 4, because since wave 3 the pixel-scale band is deliberately spared
        // (`ClarityMapping.levelGains`) — a period-4 ripple would measure the
        // band weighting rather than the mask.
        let input = try ctx.makeTexture(width: w, height: h) { x, y in
            let w0 = 2 * Double.pi / 16
            let sx = sin(Double(x) * w0), sy = sin(Double(y) * w0)
            let v = Float(0.18 * (1 + 0.12 * 0.5 * (sx + sy)))
            return (v, v, v)
        }
        let mask = Mask(name: "clarity left",
                        adjustments: MaskAdjustments(clarity: 80),
                        strokes: [Stroke(brush: BrushParams(size: 0.6, feather: 0,
                                                            flow: 100, density: 100),
                                         polyline: [(0.1, -0.2), (0.1, 1.2)])])
        var edit = EditState()
        var masked = edit
        masked.masks = [mask]

        let plain = try TextureReadback.read(pipe.render(input: input, edit: edit, upTo: .clarity).texture)
        let out = try TextureReadback.read(pipe.render(input: input, edit: masked, upTo: .clarity).texture)

        func textureRMS(_ img: FloatImage, _ xs: Range<Int>) -> Double {
            var acc = 0.0, n = 0.0, mean = 0.0
            var values: [Double] = []
            for y in 40..<216 {
                for x in xs {
                    let v = log2(max(Double(img.rgb(x: x, y: y).0), 1e-9))
                    values.append(v)
                    mean += v
                    n += 1
                }
            }
            mean /= n
            for v in values { acc += (v - mean) * (v - mean) }
            return (acc / n).squareRoot()
        }

        let before = textureRMS(plain, 8..<72)
        let after = textureRMS(out, 8..<72)
        XCTAssertGreaterThan(after, before * 1.3,
                             "masked clarity should raise fine texture (\(before) -> \(after))")

        // Unmasked half: amount = 0 means the clarity stage writes the input back
        // unchanged, and the no-mask render skips the stage entirely.
        for y in 0..<h {
            for x in 130..<w {
                let i = (y * w + x) * 4
                XCTAssertEqual(out.pixels[i], plain.pixels[i], "at (\(x), \(y))")
            }
        }
    }

    /// Adding a local clarity mask must not change how the *global* clarity
    /// renders anywhere else in the frame (audit `clarity-local` #6).
    ///
    /// This was a real bug and it is worth stating precisely what it was. The
    /// per-pixel amount used to be normalised against the frame's largest
    /// |clarity|: global 25 with a +20 mask built the pyramid at strength 45 and
    /// blended it at 25/45 everywhere outside the mask. Because the slider
    /// response was strongly convex, that linear blend of a strength-45
    /// rendition was *not* the strength-25 rendition — it came out at an
    /// effective clarity of ~35, a 40 % error in slider terms, and two disjoint
    /// +50 masks made every masked region render at strength 100 · 0.5.
    ///
    /// Two changes make it exact rather than merely close: the lift is now
    /// linear in the slider, and the pyramid is always built at the *fixed*
    /// full-scale lift with `amount = |c(x)|/100`. Since the filter is affine in
    /// lift, an unmasked pixel then takes an arithmetically identical path in
    /// both renders — so the assertion here is **bit** equality, not a
    /// tolerance. A tolerance would have passed on the old code too (the README
    /// measured the old error at 0.1 % on a low-detail frame).
    func testAClarityMaskDoesNotChangeTheRenditionOutsideIt() throws {
        let (ctx, pipe) = try TestGPU.require()
        let w = 256, h = 256
        // Detail at several scales so the level weighting has something to work
        // on at every pyramid level.
        let input = try ctx.makeTexture(width: w, height: h) { x, y in
            let fine = sin(Double(x) * .pi / 2) + sin(Double(y) * .pi / 2)
            let mid = sin(Double(x) * .pi / 8) * sin(Double(y) * .pi / 6)
            let v = Float(0.18 * exp2(0.6 * Double(x) / Double(w))
                          * (1 + 0.06 * fine + 0.25 * mid))
            return (v, v, v)
        }
        // A small dab in the top-left corner, nowhere near the sampled region.
        let mask = Mask(name: "clarity dab",
                        adjustments: MaskAdjustments(clarity: 20),
                        strokes: [Stroke(brush: BrushParams(size: 0.12, feather: 50,
                                                            flow: 100, density: 100),
                                         polyline: [(0.08, 0.08)])])
        var global = EditState()
        global.clarity = 25
        var masked = global
        masked.masks = [mask]

        let a = try TextureReadback.read(pipe.render(input: input, edit: global,
                                                     upTo: .clarity).texture)
        let b = try TextureReadback.read(pipe.render(input: input, edit: masked,
                                                     upTo: .clarity).texture)

        // Sanity: the mask does do something where it covers.
        let coverage = try pipe.maskCoverage(masks: masked.masks, width: w, height: h)
        XCTAssertGreaterThan(Double(coverage[Int(0.08 * 256) * w + Int(0.08 * 256)]), 0.9)
        var movedInside = false
        for y in 10..<32 where !movedInside {
            for x in 10..<32 where a.pixels[(y * w + x) * 4] != b.pixels[(y * w + x) * 4] {
                movedInside = true
            }
        }
        XCTAssertTrue(movedInside, "the mask must change the pixels it covers")

        // Far outside the mask (the stamp reaches x, y < 46): bit identity.
        var differing = 0
        for y in 96..<h {
            for x in 96..<w {
                let i = (y * w + x) * 4
                if a.pixels[i] != b.pixels[i] { differing += 1 }
            }
        }
        XCTAssertEqual(differing, 0,
                       "\(differing) pixels outside the mask changed when the mask was added")
    }

    /// Flat middle gray with a period-16 multiplicative ripple — the texture the
    /// clarity tests use, in the band clarity actually lifts.
    private static func rippleTexture(_ ctx: MetalContext,
                                      width: Int, height: Int) throws -> MTLTexture {
        try ctx.makeTexture(width: width, height: height) { (x: Int, y: Int) in
            let w0: Double = 2 * Double.pi / 16
            let sx: Double = sin(Double(x) * w0)
            let sy: Double = sin(Double(y) * w0)
            let v = Float(0.18 * (1 + 0.06 * (sx + sy)))
            return (v, v, v)
        }
    }

    /// The effective per-pixel clarity is `clamp(global + Σ Δ, 0, 100)`: local
    /// deltas keep their full ±100 range, the *result* is positive-only. There
    /// is only one local-Laplacian variant now, so the range exists only to say
    /// whether any pixel wants clarity at all.
    func testClarityRangeIsClampedToThePositiveHalf() {
        let boost = Mask(adjustments: MaskAdjustments(clarity: 40),
                         strokes: [Stroke(brush: BrushParams(), polyline: [(0.5, 0.5)])])
        let reduce = Mask(adjustments: MaskAdjustments(clarity: -90),
                          strokes: [Stroke(brush: BrushParams(), polyline: [(0.5, 0.5)])])

        // Global only.
        XCTAssertEqual(MaskRasterizer.clarityRange(global: 30, masks: []).hi, 30)
        // Global + a boosting mask: the maximum is the sum.
        XCTAssertEqual(MaskRasterizer.clarityRange(global: 30, masks: [boost]).hi, 70)
        // A reducing mask lowers the floor but never past 0…
        let mixed = MaskRasterizer.clarityRange(global: 30, masks: [boost, reduce])
        XCTAssertEqual(mixed.lo, 0)
        XCTAssertEqual(mixed.hi, 70)
        // …and with nothing but reduction there is no clarity anywhere, which is
        // what lets `Pipeline` skip the stage.
        XCTAssertEqual(MaskRasterizer.clarityRange(global: 0, masks: [reduce]).hi, 0)
        // Negative globals clamp on the way in.
        XCTAssertEqual(MaskRasterizer.clarityRange(global: -60, masks: [boost]).hi, 40)
        // Ranges saturate at 100.
        XCTAssertEqual(MaskRasterizer.clarityRange(global: 80, masks: [boost]).hi, 100)
        // Disabled masks do not count.
        var off = boost
        off.enabled = false
        XCTAssertEqual(MaskRasterizer.clarityRange(global: 10, masks: [off]).hi, 10)
    }

    /// A mask that pulls the effective clarity below zero is the identity there
    /// — not a smoothing pass, and not a partial one. The rest of the frame
    /// keeps the global clarity.
    ///
    /// `amount = clamp(25 − 60, 0, 100)/100 = 0`, and `mix(L, L', 0)` is exactly
    /// `L`, so the assertion is bit equality against a clarity-0 render.
    ///
    /// Global 25 rather than a rounder-looking number on purpose: 25/100 = 0.25
    /// is exact in the `r16Float` amount map, so the *outside* half of the
    /// assertion (bit equality with the unmasked render) is not measuring the
    /// one-ulp difference between the CPU's round-to-nearest `Float16` and the
    /// GPU's round-toward-zero texture write. See `README.md`.
    func testAMaskBelowZeroClarityIsTheIdentityThere() throws {
        let (ctx, pipe) = try TestGPU.require()
        let w = 256, h = 256
        let input = try MaskTests.rippleTexture(ctx, width: w, height: h)
        // A hard-edged vertical band covering the left third at coverage 1.
        let mask = Mask(name: "no clarity here",
                        adjustments: MaskAdjustments(clarity: -60),
                        strokes: [Stroke(brush: BrushParams(size: 0.5, feather: 0,
                                                            flow: 100, density: 100),
                                         polyline: [(-0.1, -0.2), (-0.1, 1.2)])])
        var global = EditState()
        global.clarity = 25
        var masked = global
        masked.masks = [mask]
        var off = global
        off.clarity = 0

        let plain = try TextureReadback.read(pipe.render(input: input, edit: global,
                                                         upTo: .clarity).texture)
        let out = try TextureReadback.read(pipe.render(input: input, edit: masked,
                                                       upTo: .clarity).texture)
        let identity = try TextureReadback.read(pipe.render(input: input, edit: off,
                                                            upTo: .clarity).texture)

        // The band reaches x = 38 (centre −25.6 px, radius 64 px), so 8..<32 is
        // solidly inside it and 160..< is far outside.
        let coverage = try pipe.maskCoverage(masks: masked.masks, width: w, height: h)
        XCTAssertEqual(Double(coverage[128 * w + 24]), 1, accuracy: 1e-6)
        XCTAssertEqual(Double(coverage[128 * w + 200]), 0, accuracy: 1e-6)

        // Inside the mask: bit-identical to clarity 0.
        for y in 0..<h {
            for x in 8..<32 {
                let i = (y * w + x) * 4
                XCTAssertEqual(out.pixels[i], identity.pixels[i], "inside at (\(x), \(y))")
            }
        }
        // Outside it: bit-identical to the unmasked clarity-25 render, and
        // actually different from the identity (the mask did not switch clarity
        // off globally).
        var moved = false
        for y in 0..<h {
            for x in 160..<w {
                let i = (y * w + x) * 4
                XCTAssertEqual(out.pixels[i], plain.pixels[i], "outside at (\(x), \(y))")
                if out.pixels[i] != identity.pixels[i] { moved = true }
            }
        }
        XCTAssertTrue(moved, "clarity 25 must still apply outside the mask")
    }

    /// Global 30 with a −20 mask is clarity 10 inside the mask. Wave 3 made the
    /// lift linear in the slider and the pyramid is built at a fixed full-scale
    /// reference, so `amount·(L_llf(100) − L)` *is* `L_llf(10) − L` — the
    /// composed value has to match a direct clarity-10 render, not merely
    /// resemble it.
    func testMaskDeltaGivesTheComposedEffectiveClarity() throws {
        let (ctx, pipe) = try TestGPU.require()
        let w = 256, h = 256
        let input = try MaskTests.rippleTexture(ctx, width: w, height: h)
        let mask = Mask(name: "less clarity",
                        adjustments: MaskAdjustments(clarity: -20),
                        strokes: [Stroke(brush: BrushParams(size: 0.5, feather: 0,
                                                            flow: 100, density: 100),
                                         polyline: [(-0.1, -0.2), (-0.1, 1.2)])])
        var composed = EditState()
        composed.clarity = 30
        composed.masks = [mask]
        var direct = EditState()
        direct.clarity = 10

        let a = try TextureReadback.read(pipe.render(input: input, edit: composed,
                                                     upTo: .clarity).texture)
        let b = try TextureReadback.read(pipe.render(input: input, edit: direct,
                                                     upTo: .clarity).texture)
        var worst: Double = 0
        var differing = 0
        for y in 0..<h {
            for x in 8..<32 {
                let i = (y * w + x) * 4
                let p = Double(a.pixels[i])
                let q = Double(b.pixels[i])
                if a.pixels[i] != b.pixels[i] { differing += 1 }
                let relative: Double = abs(p - q) / Swift.max(q, 1e-6)
                worst = Swift.max(worst, relative)
            }
        }
        print("[clarity compose] global 30 + mask -20 vs clarity 10: "
              + "\(differing) differing samples, max relative delta \(worst)")
        XCTAssertLessThan(worst, 1e-3,
                          "composed clarity should reproduce the direct render (\(worst))")
    }

    // MARK: - Gating

    /// Zero *effective* masks must leave the whole pipeline byte-identical to a
    /// pre-M3 render, whether the masks are absent, disabled or all-zero.
    func testPipelineIsUnchangedWithoutEffectiveMasks() throws {
        let (ctx, pipe) = try TestGPU.require()
        let w = 128, h = 96
        let input = try ctx.makeTexture(width: w, height: h) { x, y in
            (Float(0.05 + 0.4 * Double(x) / Double(w)),
             Float(0.05 + 0.3 * Double(y) / Double(h)),
             Float(0.2))
        }
        var base = EditState()
        base.tone = .init(exposure: 0.3, contrast: 25, highlights: -40, shadows: 20)
        base.clarity = 40
        base.bwMix = .init(red: -30, blue: -60)
        base.toning = .init(shadowHue: 215, shadowSaturation: 12,
                            highlightHue: 45, highlightSaturation: 10, balance: 10)

        let strokes = [Stroke(brush: BrushParams(size: 0.5, feather: 30),
                              polyline: [(0.2, 0.2), (0.8, 0.8)])]
        var disabled = base
        disabled.masks = [Mask(name: "off", enabled: false,
                               adjustments: MaskAdjustments(exposure: 2, clarity: -60),
                               strokes: strokes)]
        var zeroed = base
        zeroed.masks = [Mask(name: "flat", adjustments: MaskAdjustments(), strokes: strokes)]
        var strokeless = base
        strokeless.masks = [Mask(name: "empty",
                                 adjustments: MaskAdjustments(exposure: 2), strokes: [])]

        let reference = try TextureReadback.read(pipe.render(input: input, edit: base).texture)
        for (label, edit) in [("disabled", disabled), ("zero adjustments", zeroed),
                              ("no strokes", strokeless)] {
            let other = try TextureReadback.read(pipe.render(input: input, edit: edit).texture)
            for i in 0..<reference.pixels.count {
                XCTAssertEqual(other.pixels[i], reference.pixels[i],
                               "\(label) mask changed the output at index \(i)")
            }
        }
    }

    // MARK: - End to end

    func testEndToEndMaskedRender() throws {
        guard let url = testDataURL("L1000003.DNG") else {
            throw XCTSkip("testdata/L1000003.DNG not present (set GRAYROOM_TEST_DNG to override)")
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("grayroom-mask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A painted "graduated ND" over the top of the portrait frame: three
        // horizontal sweeps with a big soft brush.
        let brush = BrushParams(size: 0.25, feather: 60, flow: 100, density: 100)
        let mask = Mask(name: "sky",
                        adjustments: MaskAdjustments(exposure: -0.8, contrast: 15, clarity: 20),
                        strokes: (0..<3).map { i in
                            Stroke(brush: brush,
                                   polyline: [(-0.05, 0.06 + 0.10 * Double(i)),
                                              (1.05, 0.06 + 0.10 * Double(i))])
                        })
        var edit = EditState()
        edit.tone = .init(exposure: 0.3, contrast: 25, highlights: -40, shadows: 20)
        edit.clarity = 25
        edit.masks = [mask]

        let renderer = try Renderer()
        let out = dir.appendingPathComponent("masked.png")
        let result = try renderer.render(rawURL: url, edit: edit, to: out, format: .png,
                                         maxDimension: 1024, computeHistogram: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
        XCTAssertEqual(max(result.width, result.height), 1024)
        let histogram = try XCTUnwrap(result.histogram)
        XCTAssertGreaterThan(histogram.meanLuminance, 0.05)
        XCTAssertLessThan(histogram.meanLuminance, 0.95)

        // The coverage is where we said it is: heavy at the top, none at
        // the bottom.
        let coverage = try renderer.pipeline.maskCoverage(masks: edit.masks,
                                                          width: result.width,
                                                          height: result.height)
        func meanCoverage(_ rows: Range<Int>) -> Double {
            var acc = 0.0
            for y in rows { for x in 0..<result.width { acc += Double(coverage[y * result.width + x]) } }
            return acc / Double(rows.count * result.width)
        }
        XCTAssertGreaterThan(meanCoverage(0..<(result.height / 5)), 0.8)
        XCTAssertLessThan(meanCoverage((result.height * 2 / 3)..<result.height), 1e-4)

        // And the masked render differs from the unmasked one only up top.
        var plain = edit
        plain.masks = []
        let decoded = try renderer.decoder.decode(url: url, edit: edit, maxDimension: 1024)
        let a = try TextureReadback.read(
            renderer.pipeline.render(input: decoded.texture, edit: plain).texture)
        let b = try TextureReadback.read(
            renderer.pipeline.render(input: decoded.texture, edit: edit).texture)

        func bandMean(_ img: FloatImage, _ rows: Range<Int>) -> Double {
            var acc = 0.0
            for y in rows {
                for x in 0..<img.width {
                    let (r, g, bl) = img.rgb(x: x, y: y)
                    acc += 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(bl)
                }
            }
            return acc / Double(rows.count * img.width)
        }
        let topPlain = bandMean(a, 0..<(a.height / 5))
        let topMasked = bandMean(b, 0..<(b.height / 5))
        let bottomPlain = bandMean(a, (a.height * 2 / 3)..<a.height)
        let bottomMasked = bandMean(b, (b.height * 2 / 3)..<b.height)
        XCTAssertLessThan(topMasked, topPlain * 0.95, "the mask should darken the top")
        // The bottom is outside the mask, so since wave 3 it is *bit* identical
        // — the amount map is normalised against a fixed full-scale reference
        // rather than the frame's largest |clarity|, so adding the mask cannot
        // change the rendition elsewhere. (It used to be a 25/45 blend of a
        // strength-45 pass, for which this assertion had to be a 0.5 %
        // tolerance.) The synthetic version of this is
        // `testAClarityMaskDoesNotChangeTheRenditionOutsideIt`.
        XCTAssertEqual(bottomMasked, bottomPlain, accuracy: bottomPlain * 1e-9,
                       "the bottom is outside the mask and must not move at all")
        for y in (b.height * 3 / 4)..<b.height {
            for x in 0..<b.width {
                XCTAssertEqual(a.pixels[(y * b.width + x) * 4], b.pixels[(y * b.width + x) * 4],
                               "at (\(x), \(y))")
            }
        }
    }
}
