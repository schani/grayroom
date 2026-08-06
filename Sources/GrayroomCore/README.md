# GrayroomCore

The imaging core. Everything here runs headlessly; the GUI (M4) will be a thin
shell over these types.

```
Decode/     CIRAWFilter -> linear scene-referred rgba16Float MTLTexture
Engine/     MetalContext (runtime-compiled shader library), Pipeline, Renderer, Histogram
Stages/     CPU-side stage support (currently the tone curve + its LUT)
Shaders/    MSL source, bundled as *text* resources
Export/     texture readback + ImageIO writers
EditState.swift / EditStateIO.swift
```

## Shader loading

The `.metal` files are declared as `.copy` resources in `Package.swift`, read as
text at startup, concatenated (`Common.metal` first) and compiled with
`MTLDevice.makeLibrary(source:options:)`. No metallib is produced or bundled, so
`swift build && swift test` works from a plain terminal with no Xcode project.

## Pipeline order

```
decode(+WB)  ->  tone  ->  [clarity: M2]  ->  bwMix  ->  toning  ->  output  ->  histogram
```

Each stage is one `rgba16Float -> rgba16Float` compute pass, ping-ponging
between two working textures. `bwMix` is skipped when `bwMix.enabled == false`
(colour passthrough, a debugging aid); `toning` is skipped when both saturations
are zero. `Pipeline.render(upTo:)` can stop at any stage boundary, which is what
the golden tests use to inspect linear intermediates.

## Tone curve

### Why EV space

The curve is defined on **log2 luminance relative to middle gray**:

```
x  = log2(Y / 0.18)          input, in EV
y  = g(x)                    the curve
Y' = 0.18 * 2^y              output, linear
```

Three things fall out of this choice:

* **Identity is `g(x) = x`.** Every control is an additive offset, so "all
  sliders zero" is exactly the identity map, with no floating-point drift.
* **Exposure is a shift.** `g(x) = x + EV` gives `Y' = Y * 2^EV` exactly. All
  the other controls are evaluated on `x + EV`, i.e. on the *exposed* image,
  which matches Lightroom's ordering.
* **Monotonicity is a slope bound.** `dY'/dY > 0` iff `dy/dx > 0`, and since
  `g(x) = x + Σ Δ_i(x)`, it suffices that `Σ |dΔ_i/dx| < 1` — a condition on
  five bounded bumps, which can be checked by hand and is asserted by the tests.

### The five controls

All slider values below are normalised to −1…1 (slider/100).

**Contrast** — an odd bump centred on the pivot:

```
Δ_c(x) = c * A * x * exp(-x² / 2σ²)          A = 0.55, σ = 2.5 EV
```

This adds slope `c·A` at middle gray and decays to zero at the extremes, so
contrast steepens the midtones without moving black or white. Its derivative is
`c·A·(1 − x²/σ²)·exp(−x²/2σ²)`, which lies in `c·A·[−0.446, 1]`.

**Highlights / Shadows** — one-sided quintic smootherstep ramps that saturate to
a constant EV offset inside their zone:

```
Δ_h(x) = h * 1.2 EV * smootherstep(0.25,  4.0,  x)
Δ_s(x) = s * 1.2 EV * smootherstep(0.25,  4.0, -x)
```

Positive brightens (Lightroom sign convention). Smootherstep (`6t⁵−15t⁴+10t³`)
has zero first *and* second derivative at both ends, so the controls fade in
without a slope break; its peak slope is `1.875/width`.

**Whites / Blacks** — the same shape, but reaching further out and with more
authority, so they act on the endpoints rather than the shoulder:

```
Δ_w(x) = w * 1.5 EV * smootherstep(1.0, 7.5,  x)
Δ_b(x) = b * 1.5 EV * smootherstep(1.0, 7.5, -x)
```

These are *soft* endpoint controls: they never clip, they only compress or
expand the far ends. That differs from Lightroom, where extreme blacks genuinely
crush to zero. Deliberate for v1 — it keeps the curve invertible and monotone.

### Monotonicity

The tuning constants were picked so the worst-case total derivative stays
positive. The tightest spot is the positive side around `x ≈ 2.1`, where the
highlight ramp is steepest and negative contrast subtracts the most:

```
dy/dx  ≥  1 − 0.60 (highlights) − 0.14 (whites) − 0.11 (contrast)  ≈  0.15
```

The negative side mirrors it. `ToneCurveTests` verifies this two ways: 400
seeded random slider combinations and all 3⁵ slider corners, each sampled every
0.02 EV over the full −14…+8 EV domain, asserting a strictly increasing curve
and a minimum slope above 0.05.

`makeLUT` additionally forces the sampled curve non-decreasing with a running
max. With the constants above that pass is a no-op; it exists so that retuning
the constants can never produce a LUT with an inversion.

### The LUT

`ToneCurve.makeLUT` samples the curve into **4096 linear output luminances**
over `x ∈ [−14, +8] EV` (0.0054 EV per step; linear interpolation between
samples costs ~2·10⁻⁶ relative error). It is uploaded as an `r32Float`
`4096 × 1` texture and fetched with an explicit `read()` + lerp rather than a
sampler, so the GPU result matches `ToneCurve.applyLUT` bit-for-bit modulo
float32 rounding — the CPU function is therefore a real reference implementation,
and it is what the GPU golden tests compare against.

Outside the domain the LUT would clamp, which would turn into a divide-by-zero
blow-up in the ratio `Y'/Y`. Instead the endpoints' *gains* (`values[0]/Y_min`
and `values[N−1]/Y_max`) are passed as uniforms and applied multiplicatively, so
the mapping stays continuous and finite all the way to `Y = 0`.

### Ratio preservation

The kernel applies the curve to luminance only:

```
Y  = dot(rgb, (0.2126, 0.7152, 0.0722))
Y' = lut(Y)
rgb' = rgb * (Y' / Y)
```

Channel ratios — and therefore hue and HSV saturation — are untouched by
construction. `testTonePreservesRatiosNoHueShift` asserts it on saturated
patches.

## B&W mix

`gray = Y · (1 + Σ_bands w_band(hue) · slider_band · sat)`.

Hue and saturation come from an HSV decomposition of the **gamma-encoded**
(1/2.2) linear RGB; encoding first keeps hue stable in the deep shadows. The 8
band centres are `0, 30, 60, 120, 180, 240, 280, 320` degrees — the conventional
approximation of Adobe's mixer channels; Adobe does not publish the real ones.

Interpolation is a smoothstep between the two bracketing centres, which makes
the implied band weights a C¹ partition of unity: a pixel exactly on a centre
gets that band's slider and nothing else, and the blend is continuous across the
320° → 0° wrap.

Saturation multiplies the whole term, so a neutral pixel (`sat = 0`) is
bit-identical regardless of the sliders. `±100` maps to `±0.8` gray gain at full
saturation (`StageConstants.bwGainPerUnit = 0.008`).

## Toning

Split toning on the gray image. Tonal position is `t = sqrt(clamp(Y, 0, 1))` —
a cheap monotone stand-in for perceptual lightness, so "shadows" means what it
looks like rather than what it measures linearly.

`balance` moves the crossover: `pivot = clamp(0.5 − 0.35·balance, 0.08, 0.92)`.
Shadow weight is `1 − smoothstep(0, pivot, t)`, highlight weight
`smoothstep(pivot, 1, t)`; both are faded out at the very ends so pure black and
pure white stay neutral.

Each hue is converted to a fully saturated RGB and **normalised to luminance 1**
before mixing, and the product of the two factors is renormalised, so
`dot(factor, kLuma) == 1` and the stage changes chroma only. `strength = 0.75`
scales saturation 0…100 to a 0…0.75 mix toward the pure hue.

## Output transform

Plain IEC 61966-2-1 sRGB encoding with a 0…1 clamp. Files are tagged sRGB and
written without alpha (8-bit PNG/JPEG, 16-bit PNG/TIFF).

The histogram tap runs on this output-referred image: 256 luminance bins plus
per-pixel shadow (`min channel ≤ 0.5/255`) and highlight (`max channel ≥
254.5/255`) clip counters, accumulated with `atomic_fetch_add` in one compute
pass.

## Known limitations (M1)

* `clarity` is present in `EditState` but ignored by the pipeline (M2).
* `masks` is an empty placeholder array (M3).
* White balance is applied at decode time, so changing temp/tint forces a
  re-decode. Decode results are not cached yet.
* Whites/blacks never hard-clip; see above.
* No dithering yet — 8-bit exports of smooth gradients can band.
