import Foundation

/// The single source of truth for a develop session.
///
/// `EditState` is a plain Codable value type. It is serialized to a
/// pretty-printed JSON sidecar next to the RAW file
/// (`IMG_1234.DNG.grayroom.json`). Decoding is deliberately tolerant: unknown
/// keys are ignored and every missing key falls back to its default, so old and
/// new sidecars can be read by the same binary.
public struct EditState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var whiteBalance: WhiteBalance
    public var tone: Tone
    public var bwMix: BWMix
    /// Global clarity amount (0…100). Clarity is positive-only: there is no
    /// smoothing/glow operator, so negative values have no meaning and are
    /// clamped away (see `init(from:)` and `ClarityMapping.parameters(for:)`).
    /// Per-mask clarity deltas are still ±100 — a mask may reduce clarity below
    /// the global value, and the effective amount is
    /// `clamp(global + Σ Δ, 0, 100)`.
    public var clarity: Double
    public var toning: Toning
    /// Brush-painted local adjustments (M3). Schema version stays 1: `masks` was
    /// already part of it, so a sidecar with `"masks": []` still decodes.
    public var masks: [Mask]
    /// Render for an EDR (HDR) display: the tone curve's shoulder asymptotes to
    /// `ToneCurve.hdrDisplayWhite` instead of SDR white, and the canvas shows the
    /// result on an extended-range drawable.
    ///
    /// It is a **tone** setting, not a display preference, which is why it lives
    /// in the sidecar and is undoable: it changes the rendition above the
    /// shoulder knee. Below the knee the curve is identical either way.
    ///
    /// File export is always SDR, so exporting an HDR edit clips everything
    /// above SDR white — see README, "Output modes".
    public var hdr: Bool

    public init(
        version: Int = EditState.currentVersion,
        whiteBalance: WhiteBalance = WhiteBalance(),
        tone: Tone = Tone(),
        bwMix: BWMix = BWMix(),
        clarity: Double = 0,
        toning: Toning = Toning(),
        masks: [Mask] = [],
        hdr: Bool = false
    ) {
        self.version = version
        self.whiteBalance = whiteBalance
        self.tone = tone
        self.bwMix = bwMix
        self.clarity = clarity
        self.toning = toning
        self.masks = masks
        self.hdr = hdr
    }

    private enum CodingKeys: String, CodingKey {
        case version, whiteBalance, tone, bwMix, clarity, toning, masks, hdr
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? EditState.currentVersion
        whiteBalance = try c.decodeIfPresent(WhiteBalance.self, forKey: .whiteBalance) ?? WhiteBalance()
        tone = try c.decodeIfPresent(Tone.self, forKey: .tone) ?? Tone()
        bwMix = try c.decodeIfPresent(BWMix.self, forKey: .bwMix) ?? BWMix()
        // Lenient, not strict: sidecars written before clarity became
        // positive-only (and `--set clarity=-50`) load with the value clamped
        // into 0…100 rather than failing.
        clarity = min(max(try c.decodeIfPresent(Double.self, forKey: .clarity) ?? 0, 0), 100)
        toning = try c.decodeIfPresent(Toning.self, forKey: .toning) ?? Toning()
        masks = try c.decodeIfPresent([Mask].self, forKey: .masks) ?? []
        // Absent means SDR, so every sidecar written before EDR existed loads
        // as exactly the render it described.
        hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr) ?? false
    }

    /// The display ceiling this edit renders toward, in linear units relative to
    /// SDR white. The tone shoulder and the display output clamp share it.
    public var displayWhite: Double { ToneCurve.displayWhite(hdr: hdr) }

    /// The masks that can actually change a pixel.
    public var activeMasks: [Mask] { masks.filter { !$0.isIdentity } }

    /// `true` when some part of the frame asks for clarity — a positive global
    /// amount, or an active mask with a nonzero delta. This is exactly the
    /// condition under which `Pipeline` runs the clarity stage, and it is by far
    /// the most expensive thing the pipeline can do, so the interactive loop
    /// consults it to decide whether a render needs a draft pass.
    public var clarityActive: Bool {
        if clarity > 0 { return true }
        return activeMasks.contains { $0.adjustments.clarity != 0 }
    }

    // MARK: - Nested types

    /// `nil` means "use the camera as-shot value".
    public struct WhiteBalance: Codable, Equatable, Sendable {
        /// Kelvin, 2000…50000.
        public var temperature: Double?
        /// −150…150.
        public var tint: Double?

        public init(temperature: Double? = nil, tint: Double? = nil) {
            self.temperature = temperature
            self.tint = tint
        }

        private enum CodingKeys: String, CodingKey { case temperature, tint }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
            tint = try c.decodeIfPresent(Double.self, forKey: .tint)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(temperature, forKey: .temperature)
            try c.encodeIfPresent(tint, forKey: .tint)
        }
    }

    public struct Tone: Codable, Equatable, Sendable {
        /// EV, −5…+5.
        public var exposure: Double
        /// −100…+100 each.
        public var contrast: Double
        public var highlights: Double
        public var shadows: Double
        public var whites: Double
        public var blacks: Double

        public init(
            exposure: Double = 0,
            contrast: Double = 0,
            highlights: Double = 0,
            shadows: Double = 0,
            whites: Double = 0,
            blacks: Double = 0
        ) {
            self.exposure = exposure
            self.contrast = contrast
            self.highlights = highlights
            self.shadows = shadows
            self.whites = whites
            self.blacks = blacks
        }

        private enum CodingKeys: String, CodingKey {
            case exposure, contrast, highlights, shadows, whites, blacks
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
            contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
            highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
            shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
            whites = try c.decodeIfPresent(Double.self, forKey: .whites) ?? 0
            blacks = try c.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
        }

        /// Params clamped to their documented ranges.
        public var clamped: Tone {
            Tone(
                exposure: min(max(exposure, -5), 5),
                contrast: min(max(contrast, -100), 100),
                highlights: min(max(highlights, -100), 100),
                shadows: min(max(shadows, -100), 100),
                whites: min(max(whites, -100), 100),
                blacks: min(max(blacks, -100), 100)
            )
        }
    }

    /// The 8 Lightroom-style B&W mix channels, −100…+100 each.
    public struct BWMix: Codable, Equatable, Sendable {
        public var red: Double
        public var orange: Double
        public var yellow: Double
        public var green: Double
        public var aqua: Double
        public var blue: Double
        public var purple: Double
        public var magenta: Double
        /// `false` renders a colour passthrough (debugging aid).
        public var enabled: Bool

        public init(
            red: Double = 0, orange: Double = 0, yellow: Double = 0, green: Double = 0,
            aqua: Double = 0, blue: Double = 0, purple: Double = 0, magenta: Double = 0,
            enabled: Bool = true
        ) {
            self.red = red
            self.orange = orange
            self.yellow = yellow
            self.green = green
            self.aqua = aqua
            self.blue = blue
            self.purple = purple
            self.magenta = magenta
            self.enabled = enabled
        }

        private enum CodingKeys: String, CodingKey {
            case red, orange, yellow, green, aqua, blue, purple, magenta, enabled
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            red = try c.decodeIfPresent(Double.self, forKey: .red) ?? 0
            orange = try c.decodeIfPresent(Double.self, forKey: .orange) ?? 0
            yellow = try c.decodeIfPresent(Double.self, forKey: .yellow) ?? 0
            green = try c.decodeIfPresent(Double.self, forKey: .green) ?? 0
            aqua = try c.decodeIfPresent(Double.self, forKey: .aqua) ?? 0
            blue = try c.decodeIfPresent(Double.self, forKey: .blue) ?? 0
            purple = try c.decodeIfPresent(Double.self, forKey: .purple) ?? 0
            magenta = try c.decodeIfPresent(Double.self, forKey: .magenta) ?? 0
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        }

        /// Sliders in Lightroom hue-band order (red … magenta), clamped.
        public var sliders: [Double] {
            [red, orange, yellow, green, aqua, blue, purple, magenta]
                .map { min(max($0, -100), 100) }
        }
    }

    public struct Toning: Codable, Equatable, Sendable {
        /// 0…360.
        public var shadowHue: Double
        /// 0…100.
        public var shadowSaturation: Double
        public var highlightHue: Double
        public var highlightSaturation: Double
        /// −100…+100; shifts the shadow/highlight crossover.
        public var balance: Double

        public init(
            shadowHue: Double = 0,
            shadowSaturation: Double = 0,
            highlightHue: Double = 0,
            highlightSaturation: Double = 0,
            balance: Double = 0
        ) {
            self.shadowHue = shadowHue
            self.shadowSaturation = shadowSaturation
            self.highlightHue = highlightHue
            self.highlightSaturation = highlightSaturation
            self.balance = balance
        }

        private enum CodingKeys: String, CodingKey {
            case shadowHue, shadowSaturation, highlightHue, highlightSaturation, balance
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            shadowHue = try c.decodeIfPresent(Double.self, forKey: .shadowHue) ?? 0
            shadowSaturation = try c.decodeIfPresent(Double.self, forKey: .shadowSaturation) ?? 0
            highlightHue = try c.decodeIfPresent(Double.self, forKey: .highlightHue) ?? 0
            highlightSaturation = try c.decodeIfPresent(Double.self, forKey: .highlightSaturation) ?? 0
            balance = try c.decodeIfPresent(Double.self, forKey: .balance) ?? 0
        }

        public var isIdentity: Bool {
            shadowSaturation <= 0 && highlightSaturation <= 0
        }
    }

}
