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
decode(+WB)  ->  tone  ->  clarity  ->  bwMix  ->  toning  ->  output  ->  histogram
```

Each stage is one `rgba16Float -> rgba16Float` compute pass, ping-ponging
between two working textures (`clarity` is many passes, but it has the same
signature and allocates its own scratch). `clarity` is skipped when the slider
is exactly 0; `bwMix` is skipped when `bwMix.enabled == false` (colour
passthrough, a debugging aid); `toning` is skipped when both saturations are
zero. `Pipeline.render(upTo:)` can stop at any stage boundary, which is what the
golden tests use to inspect linear intermediates.

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

## Clarity — fast local Laplacian filter

Implemented from the papers (Paris/Hasinoff/Kautz, SIGGRAPH 2011; Aubry/Paris/
Hasinoff/Kautz/Durand, "Fast Local Laplacian Filters", ACM TOG 2014). No GPL
code was consulted; darktable's write-up was read for the streaming idea only.

`Stages/ClarityMapping.swift` is the pure, unit-testable half (slider mapping,
remap, gamma grid, pyramid geometry); `Stages/ClarityStage.swift` orchestrates
the GPU passes; `Shaders/Clarity.metal` holds the kernels.

### Working signal

`L = log2(max(Y, 2⁻¹⁴))`. Detail magnitudes are then photographic stops, which
is the only scale on which a single set of constants can work across an image.
The result is applied back multiplicatively,

```
rgb' = rgb · 2^(L_out − L)
```

so — exactly like the tone stage — channel ratios, and therefore hue and
saturation, are untouched.

### The filter

With `G[l]` the Gaussian pyramid of `L` and `r_g` a point-wise remap centred on
`g`, the *true* local Laplacian filter sets each output Laplacian coefficient to
`Lap[r_{G[l][p]}(L)][l][p]` — one full pyramid per pixel, which is why it is
slow. The fast version discretises the centre: K gamma levels `g_0 … g_{K−1}`
span the working range, each gets one pyramid of `r_k(L)`, and the coefficients
are interpolated at `G[l][p]`:

```
Lap_out[l][p] = Σ_k w_k(G[l][p]) · Lap[r_k(L)][l][p],
w_k(v)        = max(0, 1 − |t(v) − k|),   t(v) = clamp((v − g_0)/step, 0, K−1)
```

The hat weights are a partition of unity, so an identity remap reproduces `L`
exactly. The coarsest level is kept as the **original** residual `G[N−1]`: this
is detail manipulation only, it never compresses tone. Levels are accumulated
level-by-level over k (one scratch pyramid, reused), so peak memory is three
single-channel float32 pyramids ≈ `3 × 4 bytes × pixels`, ~280 MB at 24 MP
(measured: +190 MB of peak footprint over a clarity = 0 render). The level-0
remapped image is never stored — the remap is fused into the first downsample.
Cost on an M2 Max, 3968×5952, release build: ~70 ms for the whole stage.

Pyramid operators are Burt-Adelson 5-tap `[1,4,6,4,1]/16`, clamp-to-edge, coarse
size `ceil(w/2)` so non-power-of-two images work. Upsampling collapses, per
axis, to `{1,6,1}/16` on even coordinates and `{4,4}/16` on odd ones (×4 in 2-D).
Depth: halve while the short side stays ≥ 32 px, at most 8 levels — 7 levels for
a 5952×3968 frame, 4 for 256×256.

### The remap, and why it is not `x^α`

The milestone specified the classic detail remap
`r_g(v) = g + sign(d)·σ_r·(|d|/σ_r)^α`. Measured on the test image that
*attenuated* texture at clarity +80, and the reason is structural. Linearising
the filter around a local mean shows the effective fine-detail gain of the
*discretised* filter at a pixel whose Gaussian value lies a fraction `t` between
two gamma levels is

```
gain(t) = (1−t)·r'(t·step) + t·r'((1−t)·step)
```

— the remap's derivative is only ever sampled **within one gamma step** of the
grid. `d/dx x^α = α·x^(α−1)` is singular at 0 and drops below 1 for
`x > α^(1/(1−α))`, so with K = 8 over 13 stops the effective gain swings from
2.2× at `t = 0` down to **0.91×** at `t = 0.5`: half the tonal range gets its
texture flattened. Reaching a flat gain with that remap needs ~50 gamma levels.

Grayroom uses a Gaussian-windowed linear lift instead:

```
r_g(v) = v + lift · d · exp(−d² / 2σ_r²),    d = v − g
```

* `r'(g) = 1 + lift` — the fine-detail gain, and `r''(g) = 0`, so the
  derivative is *flat* where the discretisation samples it.
* `r − v → 0` as `|d|` grows: large edges pass through untouched. That is the
  halo suppression, and it needs no hard `|d| < σ_r` cutoff (which would put a
  slope break in the middle of the tonal range).
* Odd in `d`, C^∞, and monotone while `|lift| < 1/0.4463 = 2.24` (the minimum of
  `(1−y²)e^{−y²/2}`). The mapping never gets near that.

### Constants

| | | |
|---|---|---|
| `gammaLevelCount` K | 16 | worst-case `gain(t)` = 0.81 × ideal; K = 8 would be 0.59 |
| `sigmaR` σ_r | 1.0 stop | lift negligible past ~3σ_r, i.e. a ~3-stop effective window |
| working range | −8 … +3 EV re 0.18 | `step` = 11/15 = 0.733 stops |
| `epsLuminance` | 2⁻¹⁴ | luminance floor before the log |
| `maxAppliedStops` | 6 | safety clamp on `2^(L_out−L)` |
| pyramid | ≥ 32 px short side, ≤ 8 levels | |

Outside the working range the weights clamp onto the end levels, where the remap
is essentially the identity — clarity fades out instead of misbehaving.

### Slider mapping

`a = |clarity|/100`:

```
gain  = a
alpha = 1 − 0.6·a   (clarity > 0, boost)      detail slope = 1 + gain·(1/alpha − 1)
      = 1 + 2.0·a   (clarity < 0, smooth)
```

`gain` blends the remap with the identity, so **clarity = 0 is exactly the
identity** for any alpha — and the stage is skipped outright anyway, so a
default edit is bit-for-bit what it was before M2. `alpha` keeps its usual
reading: `1/alpha` is the fine-detail gain, `<1` boosts, `>1` smooths. The two
excursions are asymmetric because the slope is `1/alpha`: ±100 give detail
×2.5 and ×1/3.

Measured on the synthetic step-plus-ripple test image at clarity +80: fine
texture 0.087 → 0.143 stops RMS (×1.65), while the flat region 4 px from a
4-stop edge moves by 0.0006 stops. An unsharp mask tuned to the same texture
gain moves it by 0.042 stops — 65× more.

### Per-pixel amount (the M3 contract)

The last kernel is

```
L_out = mix(L, L_llf, amountTex(x))
```

with `amountTex` clamped-sampled, so a **1×1 texture is the global case** and no
shader change is needed when M3 arrives. The contract for masks:

* The sign of clarity selects which variant is computed — boost or smooth — so
  one pass covers all pixels of one sign. If a frame ends up with both signs,
  M3 runs the stage twice (the plan's "second pyramid pass only when any
  negative amount exists").
* `L_llf` is computed once at **full strength for the largest |clarity| present**
  in the frame (global slider or mask delta), and `amountTex(x) =
  |clarity(x)| / |clarity_max|` scales it per pixel. Blending within one sign is
  linear, which is exactly what a coverage mask wants.
* Today `amountTex` is 1×1 holding 1.0, and the strength lives in the remap.

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

## Known limitations (M1 + M2)

* `masks` is an empty placeholder array (M3); clarity's amount map is still 1×1.
* Clarity amplifies noise along with texture — there is no noise floor in the
  remap, so ±100 on a high-ISO frame is grainy. A detail-magnitude threshold (or
  running the stage on a denoised guide) is a v2 question.
* Clarity's gamma grid is fixed, not fitted to the image histogram, and its
  effective strength still varies by ~19% with tone across the grid.
* The clarity stage allocates its pyramids per render (~280 MB at 24 MP) instead
  of using a persistent pool.
* White balance is applied at decode time, so changing temp/tint forces a
  re-decode. Decode results are not cached yet.
* Whites/blacks never hard-clip; see above.
* No dithering yet — 8-bit exports of smooth gradients can band.
