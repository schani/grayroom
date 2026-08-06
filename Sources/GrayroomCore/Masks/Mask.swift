import Foundation

/// # Coordinate and parameter conventions for masks
///
/// **Space.** Stroke points are normalised `0…1` in the **oriented image
/// space** — the same space the decoded texture lives in, i.e. after the RAW's
/// EXIF orientation has been applied. `x` runs to the **right**, `y` runs
/// **down from the top-left corner**: `(0, 0)` is the top-left pixel corner,
/// `(1, 1)` the bottom-right one. Pixel *centres* are therefore at
/// `((i + 0.5) / width, (j + 0.5) / height)`, matching `MTLTexture` row order
/// (row 0 = top) and the PNG the exporter writes.
///
/// Coordinates outside `0…1` are legal: a stroke may start or end off-canvas,
/// and only the part of a stamp that lands on the canvas is rasterised.
///
/// **Resolution independence.** `BrushParams.size` is the brush **diameter as a
/// fraction of the image's long edge** (`max(width, height)`), so a mask
/// rasterises to the same picture at any pipeline resolution and the brush stays
/// round on non-square images. Everything else in the model is unitless.

// MARK: - Mask

/// One brush-painted local adjustment: a set of strokes (the shape) plus the
/// parameter deltas applied where those strokes cover.
///
/// Masks never multiply full-image passes. Every enabled mask's coverage is
/// multiplied by its adjustment values and summed into shared per-pixel
/// parameter textures which the tone and clarity stages read (see
/// `MaskStage` and `README.md`).
public struct Mask: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var adjustments: MaskAdjustments
    public var strokes: [Stroke]

    public init(id: UUID = UUID(),
                name: String = "Mask",
                enabled: Bool = true,
                adjustments: MaskAdjustments = MaskAdjustments(),
                strokes: [Stroke] = []) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.adjustments = adjustments
        self.strokes = strokes
    }

    private enum CodingKeys: String, CodingKey { case id, name, enabled, adjustments, strokes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Mask"
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        adjustments = try c.decodeIfPresent(MaskAdjustments.self, forKey: .adjustments) ?? MaskAdjustments()
        strokes = try c.decodeIfPresent([Stroke].self, forKey: .strokes) ?? []
    }

    /// `true` when this mask cannot change a single pixel.
    public var isIdentity: Bool {
        !enabled || strokes.isEmpty || adjustments.isIdentity
    }
}

// MARK: - Adjustments

/// The per-mask parameter deltas. Each is *added* to the global value at the
/// pixels the mask covers, scaled by coverage.
public struct MaskAdjustments: Codable, Equatable, Sendable {
    /// EV, −4…+4.
    public var exposure: Double
    /// −100…+100 each.
    public var contrast: Double
    public var highlights: Double
    public var shadows: Double
    public var clarity: Double

    /// Documented delta ranges. Accumulation across overlapping masks is
    /// clamped to these, so overlaps saturate rather than run away.
    public static let exposureLimit: Double = 4
    public static let otherLimit: Double = 100

    public init(exposure: Double = 0,
                contrast: Double = 0,
                highlights: Double = 0,
                shadows: Double = 0,
                clarity: Double = 0) {
        self.exposure = exposure
        self.contrast = contrast
        self.highlights = highlights
        self.shadows = shadows
        self.clarity = clarity
    }

    private enum CodingKeys: String, CodingKey { case exposure, contrast, highlights, shadows, clarity }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
    }

    public var clamped: MaskAdjustments {
        func c(_ v: Double, _ limit: Double) -> Double { min(max(v, -limit), limit) }
        return MaskAdjustments(
            exposure: c(exposure, MaskAdjustments.exposureLimit),
            contrast: c(contrast, MaskAdjustments.otherLimit),
            highlights: c(highlights, MaskAdjustments.otherLimit),
            shadows: c(shadows, MaskAdjustments.otherLimit),
            clarity: c(clarity, MaskAdjustments.otherLimit))
    }

    public var isIdentity: Bool {
        exposure == 0 && contrast == 0 && highlights == 0 && shadows == 0 && clarity == 0
    }

    /// `true` when only the tone stage is affected.
    public var affectsTone: Bool {
        exposure != 0 || contrast != 0 || highlights != 0 || shadows != 0
    }
}

// MARK: - Strokes

/// One brush stroke: a polyline plus the brush it was painted with.
///
/// Strokes are stored as **vector** data (darktable-style), not raster, so the
/// sidecar stays tiny and the mask can be re-rasterised at any resolution.
public struct Stroke: Codable, Equatable, Sendable {
    public var brush: BrushParams
    /// `true` subtracts this stroke from the mask instead of adding it.
    public var erase: Bool
    public var points: [StrokePoint]

    public init(brush: BrushParams = BrushParams(),
                erase: Bool = false,
                points: [StrokePoint] = []) {
        self.brush = brush
        self.erase = erase
        self.points = points
    }

    private enum CodingKeys: String, CodingKey { case brush, erase, points }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        brush = try c.decodeIfPresent(BrushParams.self, forKey: .brush) ?? BrushParams()
        erase = try c.decodeIfPresent(Bool.self, forKey: .erase) ?? false
        points = try c.decodeIfPresent([StrokePoint].self, forKey: .points) ?? []
    }

    /// Convenience for authoring strokes in tests and in the CLI.
    public init(brush: BrushParams, erase: Bool = false, polyline: [(Double, Double)]) {
        self.init(brush: brush, erase: erase,
                  points: polyline.map { StrokePoint(x: $0.0, y: $0.1) })
    }
}

/// The brush that painted a stroke. All four match the Lightroom controls.
public struct BrushParams: Codable, Equatable, Sendable {
    /// Brush **diameter** as a fraction of the image long edge (0.05 = 5%).
    /// Resolution-independent and UI-agnostic.
    public var size: Double
    /// 0…100. `hardness = 1 − feather/100`: the fraction of the radius that is
    /// at full opacity before the falloff starts.
    public var feather: Double
    /// 0…100. The **rate** of application: one pass over an area deposits this
    /// much coverage, and further passes build up over it (0.2 → 0.36 → 0.49 …)
    /// toward `density`. Overlapping stamps *within* one stroke do not build up.
    public var flow: Double
    /// 0…100. Absolute ceiling on the mask in the painted area: no number of
    /// strokes can push coverage past it. Painting at a density *below* the
    /// coverage already there leaves that coverage alone.
    public var density: Double

    public init(size: Double = 0.05, feather: Double = 50, flow: Double = 100, density: Double = 100) {
        self.size = size
        self.feather = feather
        self.flow = flow
        self.density = density
    }

    private enum CodingKeys: String, CodingKey { case size, feather, flow, density }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 0.05
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 50
        flow = try c.decodeIfPresent(Double.self, forKey: .flow) ?? 100
        density = try c.decodeIfPresent(Double.self, forKey: .density) ?? 100
    }

    /// Fraction of the radius at full opacity, 0…1.
    public var hardness: Double { 1 - min(max(feather, 0), 100) / 100 }
    /// Per-stamp alpha, 0…1.
    public var flowAlpha: Double { min(max(flow, 0), 100) / 100 }
    /// Absolute coverage ceiling, 0…1.
    public var densityCeiling: Double { min(max(density, 0), 100) / 100 }
}

/// One authored point of a stroke polyline.
public struct StrokePoint: Codable, Equatable, Sendable {
    /// Normalised 0…1, x to the right of the oriented image.
    public var x: Double
    /// Normalised 0…1, y **down** from the top of the oriented image.
    public var y: Double
    /// 0…1; scales the stamp *radius* (not its alpha).
    public var pressure: Double

    public init(x: Double, y: Double, pressure: Double = 1) {
        self.x = x
        self.y = y
        self.pressure = pressure
    }

    private enum CodingKeys: String, CodingKey { case x, y, pressure }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        pressure = try c.decodeIfPresent(Double.self, forKey: .pressure) ?? 1
    }
}
