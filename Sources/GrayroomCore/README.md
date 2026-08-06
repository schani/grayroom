# GrayroomCore

The imaging core. Everything here runs headlessly; the GUI (M4) will be a thin
shell over these types.

```
Decode/     CIRAWFilter -> linear scene-referred rgba16Float MTLTexture
Engine/     MetalContext (runtime-compiled shader library), Pipeline, Renderer, Histogram
Stages/     CPU-side stage support (the tone curve + its LUT, the clarity mapping)
Masks/      stroke model, CPU reference rasterizer, GPU rasterisation + param maps
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
decode(+WB)  ->  [masks]  ->  tone  ->  clarity  ->  bwMix  ->  toning  ->  output  ->  histogram
```

Each stage is one `rgba16Float -> rgba16Float` compute pass, ping-ponging
between two working textures (`clarity` is many passes, but it has the same
signature and allocates its own scratch). `clarity` is skipped when neither the
slider nor any mask asks for it; `bwMix` is skipped when `bwMix.enabled ==
false` (colour passthrough, a debugging aid); `toning` is skipped when both
saturations are zero. `Pipeline.render(upTo:)` can stop at any stage boundary,
which is what the golden tests use to inspect linear intermediates.

`[masks]` is not an image stage: it runs before `tone` and produces the two
per-pixel parameter textures that `tone` and `clarity` read. With no *effective*
mask (none present, all disabled, all strokeless, or all adjustments zero) it is
skipped entirely and every downstream kernel takes exactly its pre-M3 path, so
the output is bit-for-bit what it was — `MaskTests.testPipelineIsUnchanged-
WithoutEffectiveMasks` asserts that on a full-pipeline render.

## Tone curve

Retuned in **Lightroom-parity wave 1** (`research/audit/tone.json` deviations
#0–#4 plus `research/audit/decode-output.json` deviation #0). What changed, and
why, is at the bottom of this section.

### Why EV space

The curve is defined on **log2 luminance relative to middle gray**:

```
x  = log2(Y / 0.18)          input, in EV
y  = g(x)                    the curve
Y' = 0.18 * 2^y              output, linear
```

with the pipeline

```
x_r = baseline(x0)                    fixed rendition curve ("the profile")
x   = x_r + exposure                  exposure is a pure EV shift
y   = x + Δ_c + Δ_h + Δ_s + Δ_w       zone controls, evaluated on x
y   = shoulder(y)                     always-on soft highlight rolloff
Y'  = blackPedestal(0.18 · 2^y)       Blacks, in the linear output domain
```

Three things fall out of the EV-space choice:

* **Exposure is a shift.** Because it is applied *after* the baseline and
  *before* the shoulder, `Y' = Y_rendered · 2^EV` holds exactly for every tone
  that stays below the shoulder knee (scene luminance up to ~0.125 at the
  default rendition). Above the knee the shoulder compresses, by design.
* All the other controls are evaluated on `x`, i.e. on the *exposed, rendered*
  image — which is also the space Lightroom's histogram zones are defined in.
* **Monotonicity is a slope bound.** `dY'/dY > 0` iff `dy/dx > 0`. The baseline's
  derivative is `≥ 0` everywhere and the shoulder's is in `(0, 1]`, so it
  suffices that the additive zone sum satisfies `Σ |dΔ_i/dx| < 1` — a condition
  on four bounded bumps, checked by the tests.

### Baseline rendition — what "all sliders zero" means

**The all-zero curve is not the identity.** Lightroom's zero is not linear
either: opening a raw applies a camera profile whose baseline tone curve
"brightens essentially all pixel values while increasing shadow contrast and
decreasing highlight contrast". Grayroom's decode is deliberately neutralised
(`RawDecoder.neutralize()` zeroes Apple's boost), so before wave 1 the pipeline
started from scene-linear and every frame looked ~1 stop dark and ~1.7 stops
flat.

Rather than re-enabling Apple's opaque boost, the rendition is an explicit,
inspectable curve in the tone stage — part of the fixed pipeline, not a sidecar
field, so `bwMix.enabled=false` passthrough still shows it:

```
baseline(x) = x − 1.0 + 2.0 · smootherstep(−6.0, +0.8, x)          [EV]
```

i.e. deep shadows are pushed down 1 EV, everything from ~+0.8 EV up is lifted
1 EV, and the crossover is at −2.6 EV. Its constants were fitted to the measured
neutralized→Apple-default transfer on `testdata/L1000003.DNG`, which gives four
genuine points on that curve (percentiles map monotonically):

| percentile | scene linear | Apple default | ours |
|---|---|---|---|
| p05 | 0.0108 | 21/255 | 21/255 |
| p50 | 0.0848 | 105/255 | 105/255 |
| p95 | 0.264 | 191/255 | 191/255 |
| p99 | 0.312 | 203/255 | 203/255 |

Peak added slope is `1.875/6.8 × 2.0 = 0.55`, i.e. the steepest part of the
rendition runs at slope 1.55 — a "medium contrast" S-curve. Because that slope
is never negative it can only *help* monotonicity.

### The display shoulder

The last thing the EV curve does is roll off toward display white
(`W = log2(1/0.18) = 2.4739 EV`):

```
shoulder(y) = y                                            y ≤ k
            = k + (W − k)·(1 − exp(−(y − k)/(W − k)))      y > k     k = 1.4 EV
```

C¹ at the knee (slope 1 on both sides), strictly increasing, and asymptotic to
linear 1.0 — so **nothing tone-driven ever hard-clips**. Before wave 1, Exposure
+1 sent everything above linear 0.5 to pure white and Contrast +100 blew out
every tone above sRGB 79.5%; now both roll off instead.

The one route to a genuine clip that remains is the LUT's out-of-domain gain:
above `+8 EV` of *scene* luminance the endpoint gain is extrapolated
multiplicatively and the output clamp takes over.

### The five controls

All slider values below are normalised to −1…1 (slider/100), and `x` is the
**rendered** EV (post-baseline, post-exposure).

**Contrast** — an odd bump centred on the pivot:

```
Δ_c(x) = c * A * x * exp(-x² / 2σ²)          A = 0.40, σ = 1.2 EV
```

Peak displacement now sits at `±σ = ±1.2 EV`, i.e. squarely in the midtones as
Adobe documents ("mainly affecting midtones"), instead of at ±2.5 EV — which was
*above* display white, so the old bump was still climbing when it ran out of
range. Slope at the pivot is `1 + c·A`, so ±100 gives 1.40 / 0.60. Its derivative
is `c·A·(1 − x²/σ²)·exp(−x²/2σ²)`, which lies in `c·A·[−0.446, 1]`.

**Highlights / Shadows** — one-sided quintic smootherstep ramps:

```
Δ_h(x) = h * 1.3 EV * smootherstep(−2.7, 5.3,  x)
Δ_s(x) = s * 1.3 EV * smootherstep(−2.7, 5.3, −x)
```

The 50% point of each ramp lands at ±1.3 EV — Lightroom's measured
Highlights/Shadows histogram zone centres — and the ramps are wide enough that
**both weights are still ~22% at middle gray**. That is the LR taper ("greatest
effect on the darkest shadows, tapering off to a minimal effect on the
highlights"), not the old dead band, which was exactly zero for `|x| < 0.25 EV`
and only reached 50% at ±2.1 EV, inside LR's Whites/Blacks territory.

Measured authority at ±100: 0.28 EV at middle gray, 0.65 EV at the zone centres,
0.95 EV at display white. Highlights −100 + Shadows +100 cancel exactly at
middle gray but cut the local slope there to 0.53, which is what actually
flattens a picture — on `L1000003.DNG` it moves the sky bands down 9–31 levels
and the foreground bands up 7–19, against ≤2 levels before.

**Whites** — the same shape, placed on Lightroom's Whites zone:

```
Δ_w(x) = w * 0.6 EV * smootherstep(0.8, 3.4, x)
```

50% weight at +2.1 EV (LR's Whites zone centre) instead of +4.25 EV, which was
1.8 stops above anything the output transform could display. At ±100 an sRGB 85%
gray now moves +0.14 / −0.19 EV (it moved ±0.04 EV before). Whites still cannot
*create* clipping, because the shoulder is always on — see "Known limitations".

**Blacks** — a pedestal in the **output linear** domain, not an EV offset:

```
p = 0.02 · |blacks|/100
Y'' = max(0, Y' − p) / (1 − p)        blacks < 0   (crush)
Y'' = Y' · (1 − p) + p                blacks > 0   (lift)
```

Adobe: "Blacks — adjusts black clipping. Drag to the left to increase black
clipping (map more shadows to pure black)." A bounded EV offset can never reach
zero, so Blacks left the additive sum. At −100 the black point lands at 2% of
white (−3.17 EV, inside LR's Blacks zone) and everything at or below it is
genuinely 0, which is what makes the shadow-clip counter and a Zone-system black
placement possible at all. Blacks is not maskable, so `Tone.metal` is unaffected.

### Monotonicity

The curve is monotone **non-decreasing**, and strictly increasing everywhere
above the black point. The carve-out is deliberate: Blacks < 0 saturates a toe of
the domain to exactly 0 (that *is* the control), so "strictly increasing
everywhere" and "min slope > 0.05" are no longer the right statements. Neither is
a global slope floor: the shoulder's slope decays to 0 as the input runs away, by
construction.

What the tuning constants are actually chosen for is the **additive zone sum**
`x + Δ_c + Δ_h + Δ_s + Δ_w`. Its worst case over all slider corners is

```
dy/dx ≥ 1 − 0.43 (whites) − 0.29 (highlights) − 0.18 (contrast) − 0.02 (shadows)
      ≈ 0.08     at x ≈ +2.0 EV
```

with the middle-gray case (contrast −100, highlights −100, shadows +100) closing
at `1 − 0.40 − 0.24 − 0.24 = 0.12`. `ToneCurveTests` verifies all of this three
ways: `testZoneSumSlopeStaysPositive` over the 81 zone corners, and
`testMonotonicUnderRandomCombos` / `testMonotonicAtAllSliderCorners` over 400
seeded slider combinations and all 3⁶ corners (exposure included), each sampled
every 0.02 EV over the full −14…+8 EV domain.

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

### Local (per-pixel) tone deltas

A mask gives every pixel its *own* (Δev, Δcontrast, Δhighlights, Δshadows), so
the LUT trick stops working — a LUT per pixel is not a thing. The curve is
therefore factored into its additive components (`ToneCurve.contrastDeltaEV`,
`highlightsDeltaEV`, `shadowsDeltaEV`) and the shader evaluates the same three
analytically, in `grToneDeltaEV`. **Composition order:**

```
Y  --global LUT-->  Y'  --local delta-->  Y''      rgb'' = rgb · (Y''/Y)
```

and inside the local delta the global curve's own ordering is mirrored —
Δexposure is a pure EV shift, the zone controls are evaluated on the shifted
value:

```
x   = log2(Y'/0.18) + Δev
Y'' = 0.18 · 2^( x + Δ_c(x) + Δ_h(x) + Δ_s(x) )
```

Two consequences worth being explicit about:

* This is **not** the same as building one curve from `global + local` and
  applying it once — the composition is a curve of a curve. For the pure cases
  it is exact (a Δev of +1 doubles linear luminance whatever the global curve
  did, because exposure is a shift and the delta's other terms are zero) and for
  combined global+local it is a defensible, monotone approximation, but it is
  not slider-additive: contrast 25 global + 25 local ≠ contrast 50.
* Zero deltas are the **identity bit-for-bit**, not merely to within rounding:
  both the CPU reference and the shader early-out on an all-zero parameter
  vector rather than round-tripping through `log2`/`exp2`. That is what makes an
  unmasked pixel byte-identical to a pre-M3 render.

The baseline rendition, the shoulder and the black pedestal are **not** part of
the local path: they are properties of the global curve and are already baked
into `Y'` by the time the delta runs. In particular the local path does not
re-apply the shoulder (that would compress twice), so a large local Δexposure
can push a masked highlight past display white and into the output clamp.

Whites and blacks are deliberately not maskable (PLAN.md's per-mask set is
exposure/contrast/highlights/shadows/clarity), so `grToneDeltaEV` implements
three components, not five. Its constants live in two places —
`ToneCurve.swift`'s `contrastGain/contrastSigma/highlightRange/shadowRange/
zoneRamp` and `Tone.metal`'s `kTone*` — and **must be changed together**:
`MaskTests.testGPUToneDeltaMatchesCPUReference` compares the GPU against the CPU
components over a grid of 40 luminances × 14 delta vectors (worst relative error
5·10⁻⁴, i.e. the `rgba16Float` round trip), and
`testToneDeltaIsMonotoneInLuminance` checks 200 seeded random delta vectors over
−14…+8 EV.

### Lightroom parity — what wave 1 implemented, and what it did not

Implemented (`research/audit/tone.json`):

| # | Deviation | Fix |
|---|---|---|
| 0 | Exposure has no rolloff, hard-clips | always-on display shoulder, knee 1.4 EV |
| 1 | Contrast σ = 2.5 EV blows the whites | σ 2.5 → 1.2 EV, gain 0.55 → 0.40 |
| 2 | Highlights/Shadows dead band, ~1 EV too far out | ramp (0.25, 4.0) → (−2.7, 5.3), range 1.2 → 1.3 EV |
| 3 | Whites inert (50% weight 1.8 stops above display white) | ramp (1.0, 7.5) → (0.8, 3.4), range 1.5 → 0.6 EV |
| 4 | Blacks cannot reach zero | out of the EV sum, into a linear output-domain pedestal |

Plus `research/audit/decode-output.json` #0 (baseline rendition), above.

Deferred, deliberately:

* **#5 — highlight recovery does not desaturate.** The tone kernel is exactly
  ratio-preserving; LR's recovery converges toward neutral. Needs a change to the
  kernel's colour behaviour and would retire
  `testTonePreservesRatiosNoHueShift`.
* **#6 — Highlights/Shadows are a global 1-D curve; LR's are edge-aware.**
  Architectural (L): would drive the zone weights from the clarity stage's
  Gaussian pyramid instead of the pixel luminance.
* **#7 — Whites/Blacks are not available per mask.** Blocked on a second
  `rgba16Float` parameter texture, and now also on the fact that Whites and
  Blacks are no longer additive-EV shapes, so the per-pixel version would have to
  be designed from scratch.
* **#8 — the curve is not image-adaptive.** A deterministic curve is the better
  design for this tool; recorded here rather than "fixed".

Deviations from the audit's *proposed* constants, and why:

* Highlights/Shadows: the audit proposed `smootherstep(−1.0, 3.5)` × 1.8 EV. That
  ramp is too steep — at middle gray it contributes 0.36 of slope *per side*, so
  contrast −100 + highlights −100 + shadows +100 lands at
  `1 − 0.40 − 0.72 = −0.12` and the curve folds over. (The audit only checked the
  budget at x ≈ 1.25, where the shadow ramp contributes nothing.) The wider,
  lower ramp used here keeps the same 50% points, gives *more* middle-gray reach
  than the proposal (0.28 EV vs 0.135, against the 0.25 EV requirement) and
  closes the budget at 0.12.
* Whites: the audit's first choice was a white-point rescale `Y ← Y/whitePoint`
  before the curve. With an always-on shoulder that is just a second Exposure —
  the mechanism it relies on (clipping against the output clamp) no longer
  exists. The audit's fallback (a ramp on LR's Whites zone) is what shipped.
* Shoulder knee 1.4 EV rather than the audit's 1.2: 1.4 is what makes the
  baseline hit all four measured Apple-default percentiles exactly.
* Blacks pedestal is applied in the **output** linear domain, not the input one:
  after the baseline the curve is display-referred, which is the space Adobe's
  "map more shadows to pure black" is a statement about.

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

### Per-pixel amount (the M3 contract, now implemented)

The last kernel is

```
L_out = mix(L, L_llf, amountTex(x))
```

with `amountTex` clamped-sampled, so a **1×1 texture is the global case** and no
shader change was needed for M3. What M3 actually put in it:

* `L_llf` is computed **once**, at full strength for the largest |clarity|
  present in the frame (global slider or accumulated mask delta), and

  ```
  c(x)      = clamp(clarity_global + Δclarity(x), −100, 100)
  amount(x) = clamp(sign_dominant · c(x), 0, |c_max|) / |c_max|
  ```

  scales it per pixel (`maskClarityAmountKernel`). Blending within one sign is
  linear, which is exactly what a coverage mask wants.
* `c_max` is the end of the range `[global + Σ min(Δ,0), global + Σ max(Δ,0)]`
  with the larger magnitude — a bound, since every coverage is ≤ 1, so
  `amount ≤ 1` always.
* **Sign conflict rule (v1, chosen deliberately):** when the range straddles
  zero, only the **dominant** sign's variant is rendered and the opposite side
  is clamped to amount 0 — those pixels are left untouched rather than getting a
  second pyramid pass. The plan allowed "a second pass when any negative amount
  exists"; that would double the cost of the most expensive stage in the
  pipeline for a case (a smoothing mask under a boosting global, or vice versa)
  that is rare and whose failure mode is benign. `MaskTests.-
  testClarityVariantPicksTheDominantSign` pins the rule.
* The price of the single-variant model: with global 25 and a +20 mask the frame
  is rendered as clarity 45 at amount 25/45 outside the mask, which is a *linear
  blend* toward the strength-45 result rather than the exact strength-25 result.
  Measured on the M3 reference render that is a 0.1 % luminance shift in the
  unmasked bottom third — visible in no way, but it is not bit-identity, and the
  end-to-end test asserts 0.5 % rather than equality.

## Masks — brush-painted local adjustments

`Masks/Mask.swift` is the model, `Masks/MaskRasterizer.swift` the pure CPU
reference (stamp placement, profile, compositing, accumulation),
`Masks/MaskStage.swift` the GPU orchestration and `Shaders/Mask.metal` the
kernels. Strokes are stored as **vector** data in the sidecar (darktable-style),
never raster: tiny to persist and re-rasterisable at any pipeline resolution.

```
Mask             id, name, enabled, adjustments, strokes[]
MaskAdjustments  exposure (EV, ±4), contrast, highlights, shadows, clarity (±100)
Stroke           brush, erase, points[]
BrushParams      size, feather, flow, density
StrokePoint      x, y, pressure
```

### Coordinate and unit conventions

* **Space.** Stroke points are normalised `0…1` in the **oriented image space**
  — the space the decoded texture is already in (EXIF orientation applied). `x`
  runs right, `y` runs **down from the top-left corner**: `(0,0)` is the
  top-left pixel corner, `(1,1)` the bottom-right one, pixel *centres* are at
  `((i+0.5)/w, (j+0.5)/h)`. That matches `MTLTexture` row order (row 0 = top)
  and the exported PNG.
* Coordinates outside `0…1` are legal — a stroke may start or end off-canvas,
  which is how you paint a clean edge-to-edge sweep.
* **`size` is the brush *diameter* as a fraction of the image long edge**
  (`max(w, h)`), so masks are resolution-independent and the brush stays round
  on non-square images. Everything else is unitless: `feather`, `flow` and
  `density` are 0…100, `pressure` is 0…1.
* `pressure` scales the stamp **radius**, not its alpha.

### The stamp model

Standard paint-engine construction (see `research/mac-app-stack.md` §3):

```
diameter = size · max(w, h)                      [px]
spacing  = max(0.15 · diameter, 1 px)            along the polyline
radius   = 0.5 · diameter · pressure             [per stamp]
inner    = min(hardness · radius, radius − 1)    hardness = 1 − feather/100
alpha(d) = flow/100 · (1 − smoothstep(inner, radius, d))
```

* A stamp is placed on the first point and then every `spacing` px of arc
  length; position and pressure are interpolated **linearly** between authored
  points, with the leftover distance carried across segment boundaries. Spacing
  uses the *nominal* (pressure-1) diameter so a pressure ramp does not change
  how densely the stroke is sampled. Catmull-Rom interpolation is future work —
  at GUI event rates the input points are dense enough not to care.
* `inner = radius − 1` at `feather = 0` is the **1 px antialias minimum**: a
  "hard" brush still gets one pixel of ramp instead of a jaggy disc.
* Stamps composite into a per-**stroke** buffer with over-compositing,
  `a ← a + s·(1 − a)`, so flow builds up sub-linearly: two passes at flow 20 give
  0.36, not 0.4. That buffer is clamped at `density/100` **before** merging,
  which is what makes "one stroke never exceeds its density where it crosses
  itself" work. On the GPU the stroke buffer never exists as a texture: each
  thread walks the stroke's stamps in order in a register.
* Strokes merge into the mask in order: `mask = max(mask, stroke)` normally,
  `mask = mask·(1 − stroke)` for an eraser. Erase is scoped to its own mask.

One compute dispatch per stroke, brute force over the stamp list per pixel with
a bounding-box reject. That is O(pixels × stamps) and is fine at v1 sizes (the
M3 reference render: 3 strokes, ~30 stamps, 1067×1600 — under a millisecond);
a stamp-bucketed grid is the obvious optimisation if it ever matters.

Coverage textures are `r16Float`, everything ping-pongs between two textures
rather than using `read_write` so no pixel format is constrained.

### Parameter accumulation

All enabled masks accumulate into two textures at pipeline resolution:

```
paramsA  rgba16Float  Σ coverage_i · (Δexposure, Δcontrast, Δhighlights, Δshadows)_i
paramsB  r16Float     Σ coverage_i · Δclarity_i
```

The sum is clamped **once at the end**, to ±4 EV and ±100, not per mask — so a
negative delta can pull an over-range partial sum back, and **overlapping masks
saturate at the range edges** rather than running away. `tone` reads `paramsA`,
the clarity amount kernel reads `paramsB`. Stages read `global + params(x)`;
masks never multiply full-image passes.

Rasterisation depends only on the strokes and the resolution — never on the
sliders — so `Pipeline` caches the maps against the mask array and the size. In
M4 that is what makes dragging a slider cheap; the GUI will want a proper
invalidation key (and a lower-resolution mask for interaction) rather than a
one-entry array comparison.

### CLI

```
grayroom render <raw> -o out.png --edit sidecar.json \
    --set 'masks[0].adjustments.exposure=1.5'
grayroom mask-preview <raw> -o mask.png --edit sidecar.json [--mask N] [--max-dimension N]
```

`--set` reaches array elements with a bracket subscript; the mask must already
exist (`--set` edits masks, it does not create them — strokes come from the
sidecar). `mask-preview` writes the rasterised coverage as an 8-bit grayscale
PNG, **linearly** (`round(255·coverage)`, no transfer function): it is data, not
a picture. With no `--mask` it shows the union of every enabled mask.

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

## Known limitations (M1 + M2 + M3)

* Local tone deltas compose *after* the global curve rather than being folded
  into one curve, so global and local sliders are not additive (see above).
* One clarity variant per frame: opposite-sign clarity is dropped, and the
  single-variant linear blend is an approximation for pixels whose |clarity|
  is below the frame maximum.
* Mask rasterisation is brute force per stamp, at full pipeline resolution, and
  re-runs whenever the strokes or the size change (one-entry cache). No
  half-resolution mask, no guided-filter edge snapping.
* Stroke interpolation is linear, not Catmull-Rom, so a sparse fast stroke has
  visibly straight segments.
* Only drawn masks exist: no gradients, no radial shapes, no parametric or range
  masks, no per-mask invert/intersect, no reuse of one mask by several stages.
* Clarity amplifies noise along with texture — there is no noise floor in the
  remap, so ±100 on a high-ISO frame is grainy. A detail-magnitude threshold (or
  running the stage on a denoised guide) is a v2 question.
* Clarity's gamma grid is fixed, not fitted to the image histogram, and its
  effective strength still varies by ~19% with tone across the grid.
* The clarity stage allocates its pyramids per render (~280 MB at 24 MP) instead
  of using a persistent pool.
* White balance is applied at decode time, so changing temp/tint forces a
  re-decode. Decode results are not cached yet.
* The tone curve is never the identity: "all sliders zero" is the baseline
  rendition (see above). That invariant was retired on purpose in parity wave 1,
  and with it the "exposure +1 doubles linear luminance" statement above the
  shoulder knee.
* Whites cannot *create* highlight clipping, because the shoulder is always on
  and asymptotes below display white. Adobe documents Whites as a clipping
  control; an Option-drag threshold view built on this curve would show an empty
  frame at Whites +100. Blacks *can* clip (that side is a pedestal).
* Above +8 EV of scene luminance the LUT's endpoint gain is extrapolated
  multiplicatively, which bypasses the shoulder — the one path by which the tone
  stage can still hand the output clamp a value above 1.0.
* Highlights/Shadows are a global 1-D curve, so lifting the shadows flattens the
  local contrast inside them; Lightroom's are edge-aware (audit tone.json #6).
* Highlight recovery is exactly ratio-preserving and therefore does not
  desaturate the way Lightroom's does (audit tone.json #5).
* No dithering yet — 8-bit exports of smooth gradients can band.
