import Foundation

/// The pure, unit-testable half of the mask pipeline: stamp placement, the
/// stamp profile, stroke compositing and parameter accumulation.
///
/// `MaskStage` is the GPU orchestration that implements exactly this math in
/// `Shaders/Mask.metal`; the functions here are the reference implementation the
/// GPU is tested against (`MaskTests.testGPUMatchesCPURasterizer`).
///
/// ## The stamp model
///
/// A stroke is rasterised as a sequence of soft discs ("stamps") placed along
/// the interpolated polyline:
///
/// ```
/// diameter = brush.size · max(width, height)          [px]
/// spacing  = max(spacingFraction · diameter, 1 px)
/// radius   = 0.5 · diameter · pressure                [per stamp]
/// inner    = min(hardness · radius, radius − 1)       [1 px minimum antialias]
/// alpha(d) = flow · (1 − smoothstep(inner, radius, d))
/// ```
///
/// ## Flow, density and the composite rules (wave 3)
///
/// Stamps composite into a per-**stroke** buffer with `max`, and that buffer is
/// over-composited into the mask, capped at `density`:
///
/// ```
/// stroke:  s ← max(s, alpha(d))                       (within one stroke)
/// paint:   m ← min(m + s·(1 − m), max(m, density))     (merge)
/// erase:   m ← m · (1 − min(s, density))
/// ```
///
/// This is the standard non-incremental paint model, and it is what makes Flow
/// mean what Lightroom means by it: **a rate that accumulates across strokes**.
/// One pass deposits ~flow (0.2 at flow 20), a second takes it to 0.36, a third
/// to 0.49 … asymptotically to the density ceiling. That is the dodge-and-burn
/// mechanic — repeated light passes sculpt coverage.
///
/// Before wave 3 the rules were the other way round (over-composite *within* a
/// stroke, `max` merge *across* strokes), which made flow a one-shot opacity:
/// ~7 stamps overlap on the centreline at 15 % spacing, so a single flow-20
/// stroke already reached 0.67, and repainting it added nothing at all because
/// `max(x, x) = x`. Audit `clarity-local` #7/#8.
///
/// `density` is now an **absolute ceiling on the mask**, not a per-stroke one:
/// `max(m, density)` also means painting at density 40 over an area already at
/// 0.8 leaves it at 0.8 rather than pulling it down, matching Lightroom's "no
/// matter how many times you stroke it". The eraser keeps its own density as a
/// cap on how much one stroke can remove.
///
/// Position and pressure are interpolated **linearly** between authored points.
/// Catmull-Rom interpolation (smoother for sparse, fast strokes) is future work;
/// at GUI event rates the points are dense enough that it does not matter.
public enum MaskRasterizer {

    /// Stamp spacing as a fraction of the stamp diameter. 15% is the middle of
    /// the 5–25% range every paint engine uses: dense enough that the falloff
    /// discs merge into a smooth ribbon, sparse enough to stay cheap.
    public static let spacingFraction: Double = 0.15

    /// One rasterised stamp, in **pixels**.
    public struct Stamp: Equatable, Sendable {
        /// Centre, in pixel coordinates (pixel centres are at `i + 0.5`).
        public var x: Double
        public var y: Double
        /// Outer radius: alpha is 0 at and beyond this.
        public var radius: Double
        /// Inner radius: full `alpha` inside this.
        public var innerRadius: Double
        /// Peak alpha of this stamp (the brush's flow).
        public var alpha: Double
    }

    // MARK: - Stamp placement

    /// Cubic smoothstep, clamped — the same function `Mask.metal` uses.
    @inline(__always)
    static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        guard e1 > e0 else { return x < e0 ? 0 : 1 }
        let t = min(max((x - e0) / (e1 - e0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Radial falloff of a stamp at distance `d` from its centre, 0…1.
    @inline(__always)
    public static func profile(distance d: Double, inner: Double, outer: Double) -> Double {
        guard outer > 0 else { return 0 }
        if d >= outer { return 0 }
        if d <= inner { return 1 }
        return 1 - smoothstep(inner, outer, d)
    }

    /// The stamps a stroke rasterises to at this resolution, in placement order.
    public static func stamps(for stroke: Stroke, width: Int, height: Int) -> [Stamp] {
        let longEdge = Double(max(max(width, height), 1))
        let diameter = max(stroke.brush.size, 0) * longEdge
        guard diameter > 0, !stroke.points.isEmpty else { return [] }
        // Spacing uses the *nominal* diameter (pressure 1), so a pressure ramp
        // does not change how densely the stroke is sampled.
        let spacing = max(spacingFraction * diameter, 1)
        let alpha = stroke.brush.flowAlpha
        let hardness = stroke.brush.hardness

        func stamp(x: Double, y: Double, pressure: Double) -> Stamp? {
            let r = 0.5 * diameter * min(max(pressure, 0), 1)
            guard r > 0 else { return nil }
            let inner = min(hardness * r, max(r - 1, 0))
            return Stamp(x: x * Double(width), y: y * Double(height),
                         radius: r, innerRadius: inner, alpha: alpha)
        }

        var out: [Stamp] = []
        let p0 = stroke.points[0]
        if let s = stamp(x: p0.x, y: p0.y, pressure: p0.pressure) { out.append(s) }
        guard stroke.points.count > 1 else { return out }

        // Distance is measured in pixels so that spacing is isotropic on
        // non-square images.
        var carry = 0.0   // distance travelled since the last stamp
        for i in 1..<stroke.points.count {
            let a = stroke.points[i - 1], b = stroke.points[i]
            let ax = a.x * Double(width), ay = a.y * Double(height)
            let bx = b.x * Double(width), by = b.y * Double(height)
            let segLen = ((bx - ax) * (bx - ax) + (by - ay) * (by - ay)).squareRoot()
            if segLen <= 0 { continue }
            var d = spacing - carry
            while d <= segLen {
                let u = d / segLen
                if let s = stamp(x: a.x + (b.x - a.x) * u,
                                 y: a.y + (b.y - a.y) * u,
                                 pressure: a.pressure + (b.pressure - a.pressure) * u) {
                    out.append(s)
                }
                d += spacing
            }
            carry = segLen - (d - spacing)
        }
        return out
    }

    // MARK: - CPU rasterizer (reference)

    /// Rasterises one mask's coverage. Reference implementation; the GPU path in
    /// `MaskStage` does the same arithmetic in `float` instead of `Double`.
    ///
    /// Intended for tests and small images — it is brute force per stamp over
    /// the stamp's bounding box.
    public static func rasterize(_ mask: Mask, width: Int, height: Int) -> [Float] {
        var coverage = [Double](repeating: 0, count: max(width * height, 0))
        guard width > 0, height > 0 else { return [] }
        var strokeBuf = [Double](repeating: 0, count: width * height)

        for stroke in mask.strokes {
            let list = stamps(for: stroke, width: width, height: height)
            if list.isEmpty { continue }
            for i in 0..<strokeBuf.count { strokeBuf[i] = 0 }

            for s in list {
                let x0 = max(Int((s.x - s.radius).rounded(.down)), 0)
                let x1 = min(Int((s.x + s.radius).rounded(.up)), width - 1)
                let y0 = max(Int((s.y - s.radius).rounded(.down)), 0)
                let y1 = min(Int((s.y + s.radius).rounded(.up)), height - 1)
                if x0 > x1 || y0 > y1 { continue }
                for y in y0...y1 {
                    let dy = Double(y) + 0.5 - s.y
                    for x in x0...x1 {
                        let dx = Double(x) + 0.5 - s.x
                        let d = (dx * dx + dy * dy).squareRoot()
                        let a = s.alpha * profile(distance: d, inner: s.innerRadius, outer: s.radius)
                        if a <= 0 { continue }
                        let i = y * width + x
                        strokeBuf[i] = max(strokeBuf[i], a)
                    }
                }
            }

            let ceiling = stroke.brush.densityCeiling
            if stroke.erase {
                for i in 0..<coverage.count {
                    coverage[i] *= 1 - min(strokeBuf[i], ceiling)
                }
            } else {
                for i in 0..<coverage.count {
                    let m = coverage[i]
                    coverage[i] = min(m + strokeBuf[i] * (1 - m), max(m, ceiling))
                }
            }
        }
        return coverage.map { Float(min(max($0, 0), 1)) }
    }

    /// Union (`max`) of several masks' coverage — what `mask-preview` shows when
    /// no single mask is selected.
    public static func rasterizeUnion(_ masks: [Mask], width: Int, height: Int) -> [Float] {
        var out = [Float](repeating: 0, count: max(width * height, 0))
        for m in masks where m.enabled {
            let c = rasterize(m, width: width, height: height)
            for i in 0..<out.count { out[i] = max(out[i], c[i]) }
        }
        return out
    }

    // MARK: - Parameter accumulation (reference)

    /// Per-pixel parameter deltas, the CPU mirror of the two parameter textures.
    public struct Params: Equatable, Sendable {
        public var exposure: Double
        public var contrast: Double
        public var highlights: Double
        public var shadows: Double
        public var clarity: Double
    }

    /// `Σ coverage_i · adjustments_i`, clamped to the documented ranges.
    ///
    /// Clamping happens **after** the sum, so a mask with a negative delta can
    /// still pull an over-range total back into range; overlapping masks
    /// saturate at the range edges (±4 EV, ±100).
    public static func accumulate(_ masks: [Mask], coverages: [[Float]], at index: Int) -> Params {
        var p = Params(exposure: 0, contrast: 0, highlights: 0, shadows: 0, clarity: 0)
        for (m, cov) in zip(masks, coverages) where m.enabled {
            let c = Double(cov[index])
            let a = m.adjustments.clamped
            p.exposure += c * a.exposure
            p.contrast += c * a.contrast
            p.highlights += c * a.highlights
            p.shadows += c * a.shadows
            p.clarity += c * a.clarity
        }
        return clamp(p)
    }

    public static func clamp(_ p: Params) -> Params {
        func c(_ v: Double, _ l: Double) -> Double { min(max(v, -l), l) }
        return Params(exposure: c(p.exposure, MaskAdjustments.exposureLimit),
                      contrast: c(p.contrast, MaskAdjustments.otherLimit),
                      highlights: c(p.highlights, MaskAdjustments.otherLimit),
                      shadows: c(p.shadows, MaskAdjustments.otherLimit),
                      clarity: c(p.clarity, MaskAdjustments.otherLimit))
    }

    // MARK: - Clarity range

    /// Bounds on the effective per-pixel clarity `global + Σ coverage·Δ`, given
    /// that every coverage is in 0…1. Used to pick the single local-Laplacian
    /// variant the frame is rendered with.
    public static func clarityRange(global: Double, masks: [Mask]) -> (lo: Double, hi: Double) {
        let g = min(max(global, -100), 100)
        var lo = g, hi = g
        for m in masks where m.enabled && !m.strokes.isEmpty {
            let d = m.adjustments.clamped.clarity
            if d > 0 { hi += d } else { lo += d }
        }
        return (min(max(lo, -100), 100), min(max(hi, -100), 100))
    }

    /// The clarity variant the frame is rendered with, per the README's M3
    /// contract.
    ///
    /// `L_llf` is computed once at the **full-scale** lift for one sign; the
    /// per-pixel amount is `|clarity(x)| / 100`. Only this function's *sign* is
    /// used for that (its magnitude is still what decides which sign wins, and
    /// `clarity == 0` still means "skip the stage"). When global and local
    /// clarity have **conflicting signs**
    /// the v1 rule is: render the variant of the *dominant* sign (the end of the
    /// range with the larger magnitude) and clamp the other side's amount to 0 —
    /// i.e. a small opposite-sign region is left untouched rather than being
    /// given a second pyramid pass. Deliberate: a second full pass would double
    /// the cost of the most expensive stage for a case that is rare in practice.
    public static func clarityVariant(global: Double, masks: [Mask]) -> (clarity: Double, sign: Double) {
        let r = clarityRange(global: global, masks: masks)
        let dominant = abs(r.hi) >= abs(r.lo) ? r.hi : r.lo
        return (dominant, dominant >= 0 ? 1 : -1)
    }
}
