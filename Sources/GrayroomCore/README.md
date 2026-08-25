# GrayroomCore

The imaging core. Everything here runs headlessly; the GUI (M4) will be a thin
shell over these types.

```
Decode/     CIRAWFilter (RAW) or CIImage (JPEG/TIFF/PNG/HEIC)
            -> linear scene-referred rgba16Float MTLTexture
Engine/     MetalContext (runtime-compiled shader library), Pipeline, Renderer, Histogram
Stages/     CPU-side stage support (the tone curve + its LUT, the clarity mapping)
Masks/      stroke model, CPU reference rasterizer, GPU rasterisation + param maps
Shaders/    MSL source, bundled as *text* resources
Export/     texture readback + ImageIO writers
EditState.swift / EditStateIO.swift
```

Edits are persisted by `GrayroomLibrary`, a sibling target — see *The library*.

## Shader loading

The `.metal` files are declared as `.copy` resources in `Package.swift`, read as
text at startup, concatenated (`Common.metal` first) and compiled with
`MTLDevice.makeLibrary(source:options:)`. No metallib is produced or bundled, so
`swift build && swift test` works from a plain terminal with no Xcode project.

## Decode — two paths, one contract

`ImageDecoder` dispatches on the file's UTType (`ImageFormat.isRAW`):

**RAW** goes through `CIRAWFilter` with Apple's "pleasing rendering" zeroed
(`neutralize()`: baseline exposure, shadow bias, boost, local tone map, gamut
mapping and capture sharpening all off) and **highlight recovery on** wherever
the decoder supports it. Recovery is not part of that look: reconstructing a
channel that clipped while the other two did not is demosaic work, and the
sensor data it needs is gone by the time the pipeline sees a texture. There is
no user option, as there is none in Lightroom. Temp/tint set
`neutralTemperature` / `neutralTint`, i.e. they choose which illuminant the
sensor data is interpreted against.

A decoder option like that changes what an unchanged edit renders to, which
would leave every stored preview a picture of the old rendition.
`Pipeline.rendererVersion` is the answer: it is mixed into
`EditState.fingerprint`, so bumping it makes every row in `previews.sqlite`
stale and nothing else — the developments themselves are untouched.

**Standard images** (JPEG, TIFF, PNG, HEIC) go through
`CIImage(contentsOf:options: [.applyOrientationProperty: true])`, which honours
the embedded ICC profile. Rendering through the shared `CIContext` — whose
working space is extended linear sRGB — is what linearizes them: an sRGB code
value of 128 lands at 0.2159, not 0.5 (measured; the sRGB EOTF gives 0.21586).
Core Image applies no auto-enhance or tone mapping unless asked, and this does
not ask.

The two paths differ in what white balance *means*, and the difference is real
rather than an implementation detail. A RAW has an illuminant to name. A JPEG has
already been demosaiced and white-balanced once and is D65 by construction, so
there is nothing left to name: temp/tint become a **relative** shift, applied
with `CITemperatureAndTint` before the render, and `asShotTemperature` /
`asShotTint` report 6500 / 0 so the UI's "As Shot" reset lands on no correction.

The argument order in that filter is worth stating, because the obvious
assignment is backwards. `CITemperatureAndTint` adapts *from* `neutral` *to*
`targetNeutral`, so putting the slider value in `targetNeutral` makes a higher
Kelvin **cool** the image — the opposite of `CIRAWFilter`, where raising
`neutralTemperature` warms it (measured on a test DNG: R/B 0.18 at 3624 K, 0.84
at 6040 K, 1.55 at 9665 K). A slider that reverses meaning depending on the
file's format would be a bug, so the slider value goes in `neutral` and the D65
reference in `targetNeutral`. Measured that way, the standard path tracks the RAW
one on both axes: R/B 0.35 at 4000 K and 1.49 at 9000 K, and (R+B)/2G 0.68 at
tint −60 and 1.59 at tint +80, against 0.70 and 1.61 from `CIRAWFilter`.

Both paths share the reduction / origin / flip / render tail, so preview and
export cannot drift apart between formats. Fields that only mean something for a
RAW — decoder version, lens correction, a separate preview image — report their
honest "not applicable" value for a standard image rather than a plausible
fiction, and `ImageInfo.isRAW` says which path a file took.

Because white balance is applied at decode time on **both** paths, `DecodeKey`
still has to include temp/tint: changing them invalidates the decode cache, not
just the pipeline.

## Pipeline order

```
decode(+WB)  ->  [masks]  ->  tone  ->  clarity  ->  bwMix  ->  toning  ->  output
                                                                   |
                                                                   +->  histogram
```

Each stage is one `rgba16Float -> rgba16Float` compute pass, ping-ponging
between two working textures (`clarity` is many passes, but it has the same
signature and allocates its own scratch). `clarity` is skipped when neither the
slider nor any mask asks for it; `bwMix` is skipped when `bwMix.enabled ==
false` (colour passthrough, a debugging aid); `toning` is skipped when both
saturations are zero. `Pipeline.render(upTo:)` can stop at any stage boundary,
which is what the golden tests use to inspect linear intermediates.

`output` has two forms, chosen by `Pipeline.render(output:)` — see *Output
modes* — and the histogram taps the **linear** texture the output stage reads,
not its result, so one tap serves both.

`[masks]` is not an image stage: it runs before `tone` and produces the two
per-pixel parameter textures that `tone` and `clarity` read. With no *effective*
mask (none present, all disabled, all strokeless, or all adjustments zero) it is
skipped entirely and every downstream kernel takes exactly its pre-M3 path, so
the output is bit-for-bit what it was — `MaskTests.testPipelineIsUnchanged-
WithoutEffectiveMasks` asserts that on a full-pipeline render.

The mask rasterisation cache holds **two** entries, keyed by strokes plus
resolution. Two, not one, because the interactive loop alternates two
resolutions of the same strokes (see *Draft and refine* below) and a single
entry would re-stamp every brush dab on every frame of a drag.

## Draft and refine

The GUI decodes at **full resolution** — above 100 % the canvas shows the file's
own pixels — so a preview render is a full-resolution render, and the full
pipeline on a 24 MP frame costs far more than a frame's worth of time. Measured
on an M2 Max, 3968x5952:

| render | wall time |
| --- | --- |
| full, `clarity = 0`, with histogram | 34 ms |
| full, `clarity = 59`, with histogram | 130 ms |
| draft (1707x2560), `clarity = 59`, no histogram | 24 ms |
| the one-off reduction that builds the draft input | 3 ms |

130 ms is well past the point where a slider stops feeling attached to the
mouse, so an expensive edit renders **twice**: a reduced draft while the gesture
is live, then a refine of the same edit at full resolution as soon as nothing
newer is pending. `PreviewStrategy` (in `GrayroomUI`) is the whole policy —

* `draftLongEdge(fullSize:clarityActive:)` — draft at 2560 when clarity is
  active, or when the frame is over 30 MP (where even the clarity-free pipeline
  is too slow to drag against); otherwise `nil`, i.e. go straight to full.
  `clarityActive` is `EditState.clarityActive`, *the same predicate the pipeline
  uses to decide whether to run the clarity stage at all*, so the two can never
  disagree about which frame is the expensive one.
* `nextStep(hasPendingEdit:lastRenderWasDraft:draftLongEdge:)` — a newer edit
  always beats an owed refine, so a fast drag never pays for a full-resolution
  render it would have thrown away, and a drag settles on exactly one refine.

The draft **input** is the decode reduced once per decode by
`Downsampler` / `Downsample.metal` (four bilinear taps averaged, a box over the
destination footprint). Nothing that reaches a file or a histogram goes through
it: the draft pass skips the histogram, and the refine re-renders from the
untouched decode. The refine also re-rasterises the mask coverage overlay, which
is always produced at the resolution of the input it accompanies — overlay and
image are addressed by the same normalised uv, so they cannot describe different
extents.

The targeted-adjustment tool samples the draft too. It runs the pipeline as far
as `clarity` to read one neighbourhood's hue, and paying full resolution for
that would put a visible hitch on the mouse-down that starts the drag; the
stages ahead of the tap are ratio-preserving and the reduction is an average, so
the hue is the same either way.

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
(`ImageDecoder.neutralize()` zeroes Apple's boost), so before wave 1 the pipeline
started from scene-linear and every frame looked ~1 stop dark and ~1.7 stops
flat.

Rather than re-enabling Apple's opaque boost, the rendition is an explicit,
inspectable curve in the tone stage — part of the fixed pipeline, not an
`EditState` field, so `bwMix.enabled=false` passthrough still shows it:

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

### The display shoulder, and the display ceiling

The last thing the EV curve does is roll off toward the display ceiling. The
ceiling is a linear number `W` — SDR white is `W = 1`, and `EditState.hdr`
selects `ToneCurve.hdrDisplayWhite = 4.0` (+2 EV) instead — and it enters the
curve as the shoulder's asymptote, `W_EV = log2(W/0.18)`: 2.4739 EV in SDR,
4.4739 EV in HDR.

```
shoulder(y) = y                                                  y ≤ k
            = k + (W_EV − k)·(1 − exp(−(y − k)/(W_EV − k)))      y > k   k = 1.4 EV
```

C¹ at the knee (slope 1 on both sides), strictly increasing, and asymptotic to
linear `W` — so **nothing tone-driven ever hard-clips**. Before wave 1, Exposure
+1 sent everything above linear 0.5 to pure white and Contrast +100 blew out
every tone above sRGB 79.5%; now both roll off instead.

The one route to a genuine clip that remains is the LUT's out-of-domain gain:
above `+8 EV` of *scene* luminance the endpoint gain is extrapolated
multiplicatively and the output clamp takes over.

**The knee does not move with the ceiling** — 1.4 EV in both modes — so below it
the two curves are the *same curve, bit for bit*
(`ToneCurveTests.testTheCurveBelowTheKneeIsBitEqualInBothModes` walks all 4096
LUT entries and asserts equality on every one whose shoulder input is under the
knee). HDR buys headroom above the knee; it does not re-render the picture, and
the toggle is safe to flip mid-edit. The **black pedestal stays absolute** too —
0.02 of *SDR* white in both modes — so raising the ceiling does not also move the
black point and Blacks means the same thing on either display.

An HDR render uses much less than the +2 EV it is given, because the shoulder
only approaches its asymptote: on `testdata/L1000327.DNG` at clarity 30 the peak
rendered luminance is 2.15 (+1.11 EV over SDR white), no pixel reaches `W`, and
0.33 % of the frame sits above SDR white at all. The headroom is a rolloff
target, not an exposure boost.

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
| `levelGains` | 0, 0.4, then 1 | pixel-scale band passed through (wave 3) |
| `toneWeightSigmaEV` | 3 EV | midtone weighting, Gaussian around 0.18 (wave 3) |
| `toneWeightFloor` | 0.2 | extremes attenuated, never switched off |

Outside the working range the weights clamp onto the end levels, where the remap
is essentially the identity — clarity fades out instead of misbehaving.

### Slider mapping

Clarity is **positive only: 0…100**. `a = clarity/100`:

```
gain  = a
alpha = 0.4                            lift = gain·(1/alpha − 1) = 1.5·a
                                       detail slope = 1 + lift
```

`gain` blends the remap with the identity, so **clarity = 0 is exactly the
identity** — and the stage is skipped outright anyway, so a default edit is
bit-for-bit what it was before M2. `alpha` keeps its usual reading: `1/alpha` is
the fine-detail gain at full scale; +100 gives detail ×2.5.

There is **no negative branch and no smoothing operator**. There used to be one
(`alpha = 3.0`, lift −0.667·a, detail ×1/3 at −100) and it was dropped by user
decision: it was a mirror of the boost, not Lightroom's negative clarity (glow
and bloom with a midtone lift — audit `clarity-local` #4), and nobody used it.
Everything that depended on the sign went with it: the dominant-sign variant
selection, the sign-conflict rule in the mask contract, and the `isSmoothing`
plumbing from `ClarityMapping` through `ClarityStage` to the amount kernel.

Values outside 0…100 clamp rather than being rejected, at three places that
agree: `EditState.init(from:)` (so a stored edit with `"clarity": -80`, or
`--set clarity=-50`, loads as 0), `ClarityMapping.parameters(for:)` and
`Pipeline` (which skips the stage when nothing asks for clarity).

**Wave 3 (audit `clarity-local` #0) linearised this.** `alpha` used to slide with
the slider too (`1 − 0.6a`), which made `lift` strongly convex — detail slope
1.006 at +10, 1.044 at +25, 1.214 at +50 — so the first half of the slider was
dead and the whole perceptual range lived in +60…+100. Lightroom's documented
working range is +10…+25. Pinning `alpha` at its endpoint and letting `gain`
interpolate keeps the endpoint exactly where it was and makes everything below
it linear: **1.15 at +10, 1.375 at +25, 1.75 at +50, 2.5 at +100**.
Measured on the M2 reference frame (1067×1600, span-16 local-contrast RMS,
relative to clarity 0): +10 went from +0.25 % to +2.2 %, +25 from +1.8 % to
+5.7 %, +60 unchanged at +14 %.

Linearity is also structural, not cosmetic. The pyramid operators and the hat
weights are linear and the weights read the *unremapped* Gaussian pyramid, so
the whole filter is exactly affine in `lift`:

```
L_llf(lift) = L + lift · R,      R independent of lift
```

That is what lets the per-pixel amount map be exact — see below.

### Band weighting

`Lap_out[l] ← Lap[L][l] + g_l · (Lap_out[l] − Lap[L][l])` with
`g = (0, 0.4, 1, 1, …)`, one pass per level after the k loop
(`clarityLevelGainKernel`). The identity above is what makes that one pass
instead of an extra pyramid: the unlifted part of the accumulated Laplacian is
just `Lap[L][l]`, which is `G[l] − up(G[l+1])`.

Level 0 is pixel scale, i.e. sensor noise. Lightroom's Clarity is the
mid/large-radius local-contrast control — Texture is the mid-frequency one and
was explicitly engineered to spare the finest content so it does not amplify
noise, and Clarity sits coarser still. Ours lifted every level equally, so at
+100 grain was multiplied by 2.5× exactly like real texture (audit #2). Measured
on the reference frame, pixel-scale (span-1) RMS at clarity +60: **+9.7 % before,
−0.1 % now**, while the coarse band is unchanged. On the synthetic image a
period-16 ripple gains ×1.52 at +80 where a period-4 ripple gains ×1.00.

The complementary weights are what a future Texture slider would use.

### Midtone weighting

`amount(x) ← amount(x) · w(L)` in the apply kernel, with

```
w(L) = max(0.2, exp(−½·((L − log2 0.18) / 3)²))
```

Clarity in Lightroom is a midtone control: highlights and deep shadows are
protected, which is why a heavy push does not blow speculars or crush blacks
(audit #1). σ = 3 EV keeps the diffuse range (±2 EV, w ≥ 0.80) near full strength
and rolls off into the shadows and the highlight shoulder; the floor means the
extremes are attenuated rather than switched off, so there is no strength edge
across a smooth gradient. Measured at +80 on a flat ripple: ×1.13 at −5 EV,
×1.61 at 0 EV, ×1.52 at +2.5 EV. It multiplies the amount, so **clarity 0 is
still exactly the identity** and the M3 mask contract is untouched.

Measured on the synthetic step-plus-ripple test image at clarity +80: texture
0.132 → 0.200 stops RMS (×1.52), while the flat region 4 px from a 4-stop edge
moves by 0.0023 stops. An unsharp mask tuned to the same texture gain moves it by
0.52 stops — 230× more.

### Per-pixel amount (the M3 contract, now implemented)

The last kernel is

```
L_out = mix(L, L_llf, amountTex(x))
```

with `amountTex` clamped-sampled, so a **1×1 texture is the global case** and no
shader change was needed for M3. What M3 actually put in it:

* `L_llf` is computed **once**, at the **fixed full-scale lift**, and

  ```
  c(x)      = clamp(clarity_global + Δclarity(x), 0, 100)
  amount(x) = c(x) / 100
  ```

  scales it per pixel (`maskClarityAmountKernel`). Since the filter is affine in
  `lift` and `lift` is linear in the slider, `amount · (L_llf(100) − L)` **is**
  `L_llf(c(x)) − L`, exactly. Per-mask deltas keep the full **−100…+100** range
  even though the global slider does not: a mask that *reduces* clarity is
  useful (less on a face than the scene gets). The clamp at 0 is where negative
  clarity now goes — a region driven below zero gets amount 0, which is the
  identity, and `MaskTests.testMaskDeltaGivesTheComposedEffectiveClarity`
  checks the composition itself: global 30 with a −20 mask is bit-identical to a
  direct clarity-10 render inside the mask (0 differing samples).
* **Wave 3 fixed a real bug here (audit #6).** The reference used to be the
  frame's largest |clarity|, so global 25 with a +20 mask built the pyramid at
  strength 45 and blended it at 25/45 *everywhere outside the mask* — and under
  the old convex response that linear blend was not the strength-25 rendition
  but roughly a strength-35 one, a 40 % error in slider terms. Two disjoint +50
  masks summed to `c_max = 100`, so each region rendered at strength 100 × 0.5.
  With a fixed reference an unmasked pixel takes an arithmetically identical
  path whether or not masks exist, so the invariant is now **bit** equality:
  `MaskTests.testAClarityMaskDoesNotChangeTheRenditionOutsideIt` renders global
  25 with and without a small +20 dab and asserts zero differing pixels outside
  it. (The old code passed any tolerance-based version of that test — the README
  measured its error at 0.1 % on a low-detail frame — which is exactly why the
  test asserts equality.)
* **One caveat on that bit equality, found while removing negative clarity.**
  The amount map is `r16Float`. Without masks the 1×1 amount is converted on the
  CPU (`Float16`, round-to-nearest); with masks it is computed by
  `maskClarityAmountKernel` and rounded by the GPU's texture write, which on the
  test machine rounds *toward zero*. When `global/100` is not exactly
  representable in half the two disagree by one half-ulp: at global 30 the
  unmasked path stores 0.30004883 and the masked path 0.2998047, which moves
  ~0.7 % of the pixels outside the mask by one rgba16Float ulp. At global 25
  (0.25, exact) and 10 (both paths land on 0.09997559) they agree exactly, which
  is what the two bit-equality tests use. Not worth fixing by changing the
  global path's quantisation — that would move every existing render — and the
  error is 8·10⁻⁴ of the lift.
* There is no sign-conflict rule any more: there is only one variant, so a mask
  can only ask for less clarity than the frame's maximum, never for a different
  operator.

## Masks — brush-painted local adjustments

`Masks/Mask.swift` is the model, `Masks/MaskRasterizer.swift` the pure CPU
reference (stamp placement, profile, compositing, accumulation),
`Masks/MaskStage.swift` the GPU orchestration and `Shaders/Mask.metal` the
kernels. Strokes are stored as **vector** data (darktable-style), never raster:
tiny to persist and re-rasterisable at any pipeline resolution.

```
Mask             id, name, enabled, adjustments, strokes[]
MaskAdjustments  exposure (EV, ±4), contrast, highlights, shadows, clarity (±100)
                 (clarity here is a *delta*, so it keeps both signs; the global
                  slider it adds to is 0…100 and the sum clamps at 0)
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
  `density` are 0…100, `pressure` is 0…1. `flow` is the **rate** one pass
  deposits and `density` the **absolute ceiling** the passes build toward — see
  the stamp model below.
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
* Stamps composite into a per-**stroke** buffer with `max`, and the buffer is
  over-composited into the mask, capped at `density/100`:

  ```
  within a stroke:  s ← max(s, alpha(d))
  paint merge:      m ← min(m + s·(1 − m), max(m, density))
  erase merge:      m ← m · (1 − min(s, density))
  ```

  On the GPU the stroke buffer never exists as a texture: each thread walks the
  stroke's stamps in order in a register. Erase is scoped to its own mask.

  This is the standard non-incremental paint model, and it is what makes **Flow
  a rate that accumulates across strokes**, as in Lightroom: one pass over an
  area deposits ~flow (0.2 at flow 20), a second takes it to 0.36, a third to
  0.49, asymptotically to the ceiling. That is the dodge-and-burn mechanic.
  **Density is an absolute ceiling on the mask**, not a per-stroke one — no
  number of strokes gets past it — and `max(m, density)` means painting at a low
  density over denser coverage leaves that coverage alone rather than pulling it
  down.

  Wave 3 swapped the two rules round (audit `clarity-local` #7/#8). Before, the
  build-up was *within* a stroke and the merge was `max(mask, stroke)`: with 15 %
  spacing about 7 stamps overlap on the centreline, so a single flow-20 stroke
  already reached 0.67, and repainting it added exactly nothing because
  `max(x, x) = x`. Flow was a compressed one-shot opacity control, not a rate.
  Re-rendering the M3 reference mask with the new rules moved its mean coverage
  0.378 → 0.363: the core of a flow-100 stroke is unchanged, the feathered rim is
  genuinely soft again instead of being hardened by stamp accumulation.

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
grayroom render <raw> -o out.png --set 'masks[0].adjustments.exposure=1.5'
grayroom mask-preview <raw> -o mask.png [--mask N] [--max-dimension N]
```

Both take their base edit from the same three places, in order: `--edit
file.json`, else the input file's development in the library (`--development N`
picks another), else a default `EditState`. `--set` overrides apply on top
either way, and `render --save` writes the result back to that development. See
*The library*.

`--set` reaches array elements with a bracket subscript; the mask must already
exist (`--set` edits masks, it does not create them — strokes are painted).
`mask-preview` writes the rasterised coverage as an 8-bit grayscale PNG,
**linearly** (`round(255·coverage)`, no transfer function): it is data, not a
picture. With no `--mask` it shows the union of every enabled mask.

## B&W mix

Retuned in **Lightroom-parity wave 2** (`research/audit/bwmix-toning.json`
deviations #0 and #5); the audit table is at the end of the Toning section.

```
gray = Y · 2^(maxEV · (mix/100) · w(sat))
mix  = Σ_bands w_band(hue) · slider_band          −100 … 100
w(s) = s^0.6,  linearised below s = 0.02
```

Hue and saturation come from an HSV decomposition of the **gamma-encoded**
(1/2.2) linear RGB; encoding first keeps hue stable in the deep shadows.

**Authority.** The law is exponential and symmetric in stops: ±100 on a band
moves a fully saturated pixel of that band by ∓/±3 stops — ×1/8 to ×8. That is
the reach Lightroom's mixer has (the "red filter" sky effect: Blue/Aqua at −100
renders an ordinary sky nearly black, and Adobe shipped PV6 specifically to
reduce banding from large Color/B&W Mixer moves). The pre-wave-2 law was linear,
`1 + mix·0.008·sat`, i.e. ×0.2 … ×1.8 — asymmetric at −2.3 EV / +0.85 EV, and it
could never brighten a colour by a full stop.

**Saturation weighting.** The exponent is sub-linear because the 1/2.2 encode
*lowers* HSV saturation (`sat_enc = 1 − (mn/mx)^(1/2.2) < 1 − mn/mx`), so a
linear weight left ordinary subjects nearly inert. Worked numbers on the patches
the tests use:

| patch | `sat_enc` | old gain at −100 | new gain at −100 |
|---|---|---|---|
| `(0.40, 0.00, 0.00)` pure red | 1.000 | ×0.200 (−2.32 EV) | ×0.125 (−3.00 EV) |
| `(0.40, 0.02, 0.02)` | 0.744 | ×0.405 (−1.30 EV) | ×0.175 (−2.51 EV) |
| clear blue sky `(0.25, 0.45, 1.0)` | 0.467 | ×0.626 (−0.68 EV) | ×0.268 (−1.90 EV) |

(The sky sits at hue 218°, so it is Blue *and* Aqua that have to move; Blue alone
at −100 gives ×0.388, −1.37 EV, measured.)

`w(0) = 0` exactly either way, so a neutral pixel is bit-identical regardless of
the sliders (`testNeutralPatchInvariantForAnySlider`). `s^0.6` has an *unbounded*
derivative at `s = 0`, though, which turns the half-float quantisation of a
near-neutral gradient into jitter; below `saturationKnee = 0.02` the weight
follows the straight line through `(knee, knee^0.6)` instead, capping the slope
at 4.79. Measured on a 512-px gradient with a 0.4 % cast at slider ±100: max step
2 codes with the knee and without it, but 1-code reversals drop from 21 to 9. No
plateaus in either case — `testMixerDoesNotBandANearNeutralGradient` pins step
≤ 2 codes, ≥ 85 % of the 8-bit levels used, and no reversal larger than 1 code.

**Band centres** are `0, 30, 60, 120, 180, 240, 270, 300` degrees: the three
primaries and the three secondaries on their exact HSV angles, Orange and Purple
at the midpoints of the two 60° gaps. Wave 2 moved Purple 280 → 270 and Magenta
320 → 300, because with Magenta at 320 a *pure* magenta pixel (HSV 300°) got a
50/50 blend of Purple and Magenta instead of landing on Magenta — visible as
"the wrong slider moves" under the targeted adjustment tool. Adobe does not
publish the real centres and no credible measurement exists, so this is an
approximation, not a fact; the audit gives the LrC procedure to measure them.

Interpolation is a smoothstep between the two bracketing centres, which makes
the implied band weights a C¹ partition of unity: a pixel exactly on a centre
gets that band's slider and nothing else, and the blend is continuous across the
300° → 0° wrap.

Constants live in `BWMixBands` (`Engine/Uniforms.swift`) and reach the kernel as
uniforms, except the centres, which are duplicated as `kBandCenters` in
`BWMix.metal` and pinned to the Swift array by
`GPUStageTests.testBandCentresMatchTheShader`. `BWMixBands.gain` and
`.saturationWeight` are the Swift mirror of the law, pinned by
`testMixerGainMatchesTheDocumentedLaw`; `GrayroomUI/TATBandMath.swift` reads the
centres from the same array so the drag tool cannot drift from the shader.

## Toning

Split toning on the gray image, rewritten in **wave 2**
(`research/audit/bwmix-toning.json` #1 and #2). Tonal position is
`t = sqrt(clamp(Y, 0, 1))` — a cheap monotone stand-in for perceptual lightness,
so "shadows" means what it looks like rather than what it measures linearly.

### Crossover

```
pivot = clamp(0.5 − 0.35·balance, 0.08, 0.92)
w_h   = smootherstep(pivot − 0.35, pivot + 0.35, t)
w_s   = 1 − w_h
fade  = smoothstep(0, 0.08, t) · (1 − smoothstep(0.92, 1, t))     (both weights)
```

The two weights are **complementary**, so `w_s + w_h == 1` through the whole
midrange. Before wave 2 they were two independent smoothsteps —
`1 − smoothstep(0, pivot, t)` and `smoothstep(pivot, 1, t)` — which are *both*
zero at the pivot: everything between roughly 33 % and 73 % grey came out
essentially untinted and mid-grey was exactly neutral, so setting both wheels to
the same sepia gave tinted ends around a grey middle. Lightroom's crossover
overlaps through the midtones (the amount is its Blending slider, default 50);
only the extreme shadows and highlights stay black and white, which is what the
`fade` term does. The half-width 0.35 is the fixed stand-in for Blending = 50.

`ToningWeights` (`Engine/Uniforms.swift`) is the Swift mirror, pinned to the
kernel by `GPUStageTests.testToningWeightsMatchTheShader`.

### Tint and luminance

```
tint(h) = 3 · hueRGB(h) / Σ hueRGB(h)                    equal RGB energy
factor  = 1 + w_s·a_s·(tint(h_s) − 1) + w_h·a_h·(tint(h_h) − 1)
factor /= dot(factor, kLuma)^lumaPreserve                lumaPreserve = 0.5
```

with `a = saturation/100 · strength`, `strength = 0.75`. Two consequences.

Combining the tints **by weight** rather than by multiplying two independent
factors means equal hue and saturation on both wheels collapse to one uniform
tint by construction — `testEqualWheelsGiveAUniformTintWithNoNeutralMidtones`
asserts the chroma varies by under 15 % across the whole ramp.

And the stage is **no longer exactly luminance-preserving**. Lightroom's toning
moves lightness — Adobe's own guidance is to pull the per-range Luminance slider
back down when "adding a particular color to the shadows … brightens the image"
— and that lift is a large part of why LR toning reads as a toned print rather
than a hue overlay. Getting it required dropping the old per-hue normalisation
to luminance 1: with it, `dot(factor, kLuma)` is identically 1 under the new
weight-blend and the partial renormalisation is a no-op. Equal-RGB-energy
normalisation instead leaves the sign of the excursion to where the hue sits
relative to the Rec.709 weights, so warm and green hues lift and blue/magenta
darken, and `lumaPreserve = 0.5` keeps half of it. Measured at mid grey,
saturation 100, both wheels on one hue:

| hue | ΔEV |
|---|---|
| 120 (green) | +0.447 |
| 60 (yellow) | +0.186 |
| 40 (sepia) | +0.119 |
| 180 (aqua) | +0.091 |
| 210 | −0.081 |
| 0 (red) | −0.229 |
| 300 (magenta) | −0.405 |
| 240 (blue) | −0.639 ← worst case over the circle |

At ordinary settings it is small: the sepia preset below moves every tone by
+0.031 … +0.038 EV. `lumaPreserve = 1` restores the old exactly-chroma-only
behaviour in one constant.

Equal-energy normalisation also, as a side effect, takes most of the sting out of
the hue-dependent strength the audit flags separately as #3: a saturation-100
blue tint used to multiply the blue channel by ~10.7, and now multiplies it by
3.9. That item is *not* implemented — the opponent-space rewrite it asks for is
still open, and strength still varies with hue.

### Audit status

`research/audit/bwmix-toning.json`, after wave 2:

| # | item | status |
|---|---|---|
| 0 | mixer authority + saturation weighting | **done** — exponential ±3 EV law, `s^0.6` weight |
| 1 | split-tone crossover dead zone | **done** — complementary weights, tints blended by weight |
| 2 | luminance preservation vs LR | **done** — `lumaPreserve = 0.5` on an equal-energy tint |
| 5 | band centres (purple/magenta) | **done** — 270 / 300, documented as an approximation |
| 3 | hue-dependent toning strength | deferred — needs the opponent-space tint |
| 4 | Auto B&W Mix | deferred |
| 6 | base grey conversion is Rec.709 luma, not a monochrome profile | deferred — belongs with camera profiles |
| 7 | Color Grading: midtones/global wheels, Blending, per-range Luminance | deferred — additive once the crossover is fixed |

Constants #0 and #2 are the audit's own tuning targets, not measurements: Adobe
publishes behaviour, not math, for both panels, and no credible reverse
engineering of the slider-to-gain law, the band centres or the tonal weighting
curve exists. The direction and rough magnitude are solid; the exact numbers are
ours.

### Wave 3

`research/audit/clarity-local.json` #0, 1, 2, 6, 7, 8 and
`research/audit/decode-output.json` #1, 3, 8, 9 — the clarity response curve,
midtone weighting and band weighting; the mask amount normalisation; the brush
flow/density model; the clip threshold, capture sharpening, 8-bit dither and
canvas colour management. Each is written up in its own section above.
**`DEVIATIONS.md` in the repo root is the living record** of where every audit
item across all four files stands.

## Output modes

There are two output points, selected by `Pipeline.render(output:)`, and they
are different kernels rather than one kernel with a flag:

| mode | kernel | writes | used by |
|---|---|---|---|
| `.file` (default) | `outputKernel` | sRGB-encoded, clamped `[0, 1]` | CLI, export, every golden test |
| `.display` | `displayOutputKernel` | **linear**, clamped `[0, W]` | the canvas: preview, draft and before/after |

`.file` is plain IEC 61966-2-1 sRGB encoding with a 0…1 clamp. Files are tagged
sRGB and written without alpha (8-bit PNG/JPEG, 16-bit PNG/TIFF). It does not
consult `hdr` at all: `W` for the *clamp* is always 1 on this path.

`.display` writes linear light because the drawable is an extended-linear-sRGB
float16 surface (see *Canvas display*): the window server owns the transfer
function, and values above 1.0 land in the panel's EDR headroom. It also skips
the dither — a float16 drawable has no 8-bit quantisation step to dither at.

**Export is always SDR.** `hdr` reaches the *tone curve* whatever the output
mode is, because it is part of the rendition, so exporting an HDR edit writes
that rendition **clipped at SDR white** rather than a different picture. Below
the shoulder knee the two files are byte-identical; above it, the HDR rendition's
highlights pile onto 1.0. Measured on `testdata/L1000327.DNG` at clarity 30:
0.24 % of the frame clips in the SDR export, 0.33 % in the HDR one. Gain-map or
HDR-container export is future work (`DEVIATIONS.md`, "Beyond the audit").

### The histogram tap

The tap runs on the **linear** texture the output stage reads — one pass for both
modes — and does the scaling and encoding itself:

```
e   = sRGBEncode(clamp(rgb / W, 0, 1))
bin = min(floor(luma(e) · 256), 255)
```

256 luminance bins plus per-pixel shadow (`min channel ≤ 0.5/255`) and highlight
(`max channel ≥ 254.5/255`) clip counters, accumulated with `atomic_fetch_add`.
`W` is the ceiling that output mode actually clamps at: SDR white for a file
(so `--histogram` describes the bytes on disk), the edit's ceiling for the
canvas. At `W = 1` the arithmetic is the file transform's, computed at float
precision rather than from the encoded value's half-float storage, so a bin can
sit an ulp from what reading the exported file back would give.

"Highlight clipped" therefore means **at or above the ceiling** in both modes,
which is the statement worth making: in HDR a pixel between SDR white and `W` is
headroom, not clipping, and the panel shows it. The UI lights its clipping
triangles at **32 clipped pixels**, an absolute count rather than a fraction of
the frame (`HistogramModel.clipWarningPixels`, wave 3, audit `decode-output` #1).
A fraction — it was 0.1 % — meant ~3 000 pixels on the preview and ~24 000 on a
24 MP export, so a blown light source never lit it *and* the preview and the
export disagreed about the same edit. Lightroom's triangles light on essentially
any clipped pixel, which is what makes "push Whites until the triangle just
lights" usable.

Because the axis is `Y/W`, SDR white stops being the right-hand edge in HDR: it
sits at `sRGBEncode(1/W)`, 0.537 at `W = 4`. `HistogramModel.sdrWhiteMarker-
Position(displayWhite:)` is that number and the panel draws it as a dashed
vertical line — everything to its right is headroom an export would clip.

### 8-bit dithering

`Export/Dither.swift`. The 8-bit output point — `ImageWriter.makeCGImage`'s
8-bit branch — quantises by **stochastic rounding**: the value picks between the
two codes bracketing it, with probability equal to its fractional part, from a
hash of `(x, y, channel)`.

```
s = clamp(v,0,1)·255;   out = floor(s) + (hash(x,y,c) < frac(s) ? 1 : 0)
```

It bites harder in a monochrome app than in a colour one: a grey sky has no
chroma noise to break up the contours and the tone/clarity stages are smooth
analytic functions, so a gradient spanning five codes over a thousand pixels came
out as five hard bands. Measured on that ramp: **6 codes / max run 201 / 5
transitions → 7 codes / max run 47 / 329 transitions**, mean preserved to 0.03 of
a code. `out/k-dither-ramp.png` is the side-by-side (top half undithered).

Not the textbook ±1 LSB triangular dither, deliberately: TPDF moves an *exactly
representable* value to a neighbouring code with probability 1/8 regardless, so
pure black would speckle to 1 and a clipped highlight to 254 — a worse artefact
than the banding, and one that clamping to the bracketing pair does not fix.
Stochastic rounding preserves the mean exactly, never leaves the bracketing
codes, and degenerates to "do nothing" as the fractional part goes to zero. Its
cost is signal-dependent noise power (`frac·(1−frac)`), which is precisely the
behaviour wanted at the ends of the scale.

This is the only place it happens. Not in `outputKernel`, whose result is what
`ImageWriter` then quantises — dithering it first would be noise the exporter
dithers a second time. Not in `writeGray`, which writes data. Not on 16-bit
export. And not on the canvas, whose drawable is `rgba16Float` and has no
quantisation step to dither at.

### Canvas display

The drawable is `rgba16Float`, its layer is tagged **extended linear sRGB**, and
its `preferredDynamicRange` is `.high` with `contentsHeadroom` at `W`. All three
are load-bearing:

* **Half-float**, because the values are linear light and the display output
  clamps at `W`, not at SDR white — an 8-bit unorm surface can hold neither the
  range nor the precision.
* **Extended linear sRGB**, because that hands the transfer function to the
  window server, which is also what colour-matches the frame to the display
  profile (wave 3, audit `decode-output` #9: untagged, the pipeline's encoded
  values were interpreted in the display's *own* space, so on a P3 or wider panel
  every toned image was drawn more saturated than the exported sRGB file and the
  split-toning sliders lied. A neutral B&W frame is unaffected either way, which
  is why it went unnoticed).
* **The EDR opt-in**, because without it the layer is an ordinary SDR surface
  that happens to be float and everything above 1.0 is clamped away.
  `.high` rather than `.automatic`: this is the editing canvas the user is
  looking at, which is the case Apple names for it. The headroom tag is what
  says how much of the range the drawable actually uses — a layer asking for
  high dynamic range with untagged contents gets none.

The system can also ask every app to stop showing HDR content
(`NSApplicationShouldBeginSuppressingHighDynamicRangeContentNotification`, and
its `...End...` partner). `HDRSuppression` carries that state, and it takes both
halves: the layer drops to `.standard` *and* the render loop switches to the
edit's SDR rendition — `hdr` off, so the tone shoulder aims at 1.0, exactly what
an export writes. Dropping the layer alone would clip the highlights instead of
rolling them off. The edit itself never moves, so the picture comes back when
the system says it may.

The fragment shader therefore encodes nothing: it samples the display texture
and returns it. Every constant it composites — the letterbox backdrop, the
mask-overlay tint — is authored in sRGB and **decoded to linear** in
`CanvasColors`, which is also where the clear colour comes from, so they look
exactly as they did on the old encoded drawable. (The brush cursor's ring is
pure black and white, the same numbers in either space; only the alpha blends
now happen in linear light.) `CanvasDisplayInputTests` pins the pixel format,
the colourspace, the dynamic range and its suppressed state, the
straight-through pass and the backdrop decode.

On the machine this was developed on (M2 Max, XDR panel) `NSScreen`'s
`maximumExtendedDynamicRangeColorComponentValue` is 1.0 while nothing on screen
is asking for headroom and rises to ~4.7 once EDR content is up, against a panel
potential of 16 — so `W = 4` is within what the display sustains rather than
what it can peak at.

### Canvas display sampling

The texture the canvas is handed carries a **mip pyramid**:
`Pipeline.render(generateDisplayMipmaps:)` allocates the working textures
mipmapped and encodes a blit `generateMipmaps` on the output in the same command
buffer. Only the app's preview path passes it; export and the CLI leave it off
and are unaffected pixel for pixel (`PreviewPathTests` asserts both the byte
equality of level 0 and the absence of a pyramid on the file path).

It is needed because the canvas fits a full-resolution render into a window: a
24 MP frame at fit zoom on a laptop is a ~4x minification, and a bilinear
sampler at that ratio is point sampling roughly every fourth pixel of the
render, with all the aliasing that implies.

The level is **explicit**, `CanvasTransform.displayLOD(zoom:textureScale:)`
computed on the CPU and passed in as a uniform. It has to be: the fragment
shader draws one full-screen quad, computes its texture coordinate by inverting
the canvas transform, and does so inside a branch testing whether the fragment is
on the image at all — so the implicit derivatives a sampler picks its own level
from are undefined there. `textureScale` is the displayed texture's width over
the image width, which is below 1 while a draft is up; without it a draft would
be blurred by its own reduction factor a second time.

Above 2x the canvas switches to a nearest sampler at level 0 — pixel peeping
shows the actual pixels. That cutover is keyed on the *image* zoom, i.e. on what
the user asked for and on what the refine is about to show, not on the texture's
own magnification: a draft crosses 2x of its own texels while it is still being
minified on screen, and keying on that would turn a shrunk frame blocky. The
coverage overlay is never mipmapped and is always sampled at level 0; it is a
soft mask, so aliasing in it is invisible.

The pyramid is built on the display output, which is **linear**, so every level
is a box average in linear light and the reduction is energy-preserving: a
black/white checkerboard mips to linear 0.5, and fine high-contrast texture keeps
its brightness at fit zoom instead of coming out slightly dark the way an average
of encoded values does.

### Capture sharpening

`ImageDecoder.neutralize` sets `sharpnessAmount = 0` (wave 3, audit `decode-output`
#3). Apple's per-camera default for the test Leicas is 0.9 — measured +83 %
Laplacian-of-log-luminance RMS on a full-res centre crop — and CIRAWFilter
silently disables it whenever `scaleFactor < 1`, so it is not a value the
pipeline can rely on being applied at all. What it *is* reliably is
uncontrollable: an unknown amount of edge gain ahead of clarity, which then
amplifies the halos it produces. 0 is the only setting that makes the whole
pipeline mean one thing at every resolution. A real Amount/Radius/Detail/Masking
stage is deferred. NR keeps its per-camera defaults — measured scale-invariant,
so it stays consistent either way.

## The library

`GrayroomLibrary` is a single SQLite database (GRDB, WAL) holding every edit and
every piece of organization. Default location `~/Library/Application
Support/Grayroom/library.sqlite`; every entry point takes an explicit path, and
the CLI's `--library` / `$GRAYROOM_LIBRARY` override it.

A photo is identified by the **SHA-256 of the whole file** (`FileHash`, streamed
in 1 MB chunks), so the same file at two paths is one photo with two locations
and re-importing a path costs a hash and nothing else. A photo has any number of
**developments**; a development is one `EditState`, stored as JSON in
`developments.edit_json`. Colour is a single-valued Lightroom-style label, tags
are free-form many-to-many.

```
cameras      id, make, model                          UNIQUE(make, model)
photos       id, hash BLOB UNIQUE, byte_size, original_name, imported_at, captured_at,
             camera_id -> cameras (nullable), width, height,
             latitude, longitude, altitude (nullable), color
locations    id, photo_id -> photos (cascade), path TEXT UNIQUE
developments id, photo_id -> photos (cascade), ordinal, edit_json (json_valid),
             created_at, updated_at                   UNIQUE(photo_id, ordinal)
tags         id, name UNIQUE COLLATE NOCASE
photo_tags   photo_id -> photos, tag_id -> tags        PRIMARY KEY(photo_id, tag_id)
```

`Importer` hashes a file, probes it for capture date, camera and GPS through
`ImageDecoder.probe` (metadata only, no GPU), and upserts the photo and its
location. A path whose bytes have changed is repointed at the photo they now
hash to.

### CLI

```
grayroom import <paths...> [--no-recursive]
grayroom ls [--color red|yellow|green|blue|purple|unlabeled] [--tag name] [--camera id]
grayroom show <photo>
grayroom tag add|rm <photo> <name>
grayroom color <photo> <label>
grayroom developments ls <photo>              # `dev` is an alias for `developments`
grayroom developments add <photo> [--edit file.json]
grayroom developments rm <development-id>
grayroom developments export <development-id> <out.json>
grayroom developments set <development-id> key=value...
```

`<photo>` is a photo id, a hash prefix (which must be unique), or a path to the
file (hashed and looked up). Ids win over hash prefixes, because ids are what
`ls` prints.

`developments set` takes the same dotted key paths as `render --set`, so the
whole `--set` surface works against a stored development as well as against a
render.

## Known limitations (M1 + M2 + M3)

* Local tone deltas compose *after* the global curve rather than being folded
  into one curve, so global and local sliders are not additive (see above).
* There is no negative clarity at all: the global slider is 0…100 and the
  smoothing operator has been deleted (audit `clarity-local` #4 and #5 are
  *removed*, not deferred — see `DEVIATIONS.md`). A mask with a negative delta
  excludes its region from the global clarity; it cannot soften it.
* There is no non-edge-aware halo component, so high positive clarity gains
  micro-texture but never the broad edge gradients LR gives (audit #3).
* Clarity's band weighting is defined on *pyramid* levels, so "pixel scale"
  means pixel scale of the rendition being computed: a 2560 px draft and the
  full-resolution refine of the same edit exclude different real-world detail
  sizes, so the draft is not a preview of the refine's clarity, only of its
  tonality. Measured at clarity +60 on the reference frame, the coarse-band gain
  is the same either way; what changes is how much resampled detail counts as
  level 0.
* Mask rasterisation is brute force per stamp, at full pipeline resolution, and
  re-runs whenever the strokes or the size change (two-entry cache: one draft
  resolution and one full). At 24 MP the two entries are ~480 MB, held until a
  different image is opened. No half-resolution mask, no guided-filter edge
  snapping.
* The mask coverage overlay bypasses that cache entirely: with the overlay on,
  every render re-stamps the selected mask at its own input's resolution, in its
  own command buffer. Measured ~10-25 ms on top of a 24 MP refine.
* Stroke interpolation is linear, not Catmull-Rom, so a sparse fast stroke has
  visibly straight segments.
* Only drawn masks exist: no gradients, no radial shapes, no parametric or range
  masks, no per-mask invert/intersect, no reuse of one mask by several stages.
* Clarity's gamma grid is fixed, not fitted to the image histogram, and its
  effective strength still varies by ~19% with tone across the grid.
* The clarity stage allocates its pyramids per render (~280 MB at 24 MP) instead
  of using a persistent pool, and `Pipeline.render` allocates its pair of working
  textures per call — mipmapped for display, so ~510 MB at 24 MP. Interactive
  full-resolution rendering pays that on every refine.
* White balance is applied at decode time, so changing temp/tint forces a
  re-decode. Decode results are not cached yet. Each such decode also rebuilds
  the before/after texture at full resolution (~34 ms and a retained 256 MB at
  24 MP) whether or not anyone is holding `\` to look at it — small next to the
  decode itself, but the largest thing the app holds for a feature that is off
  most of the time.
* The tone curve is never the identity: "all sliders zero" is the baseline
  rendition (see above). That invariant was retired on purpose in parity wave 1,
  and with it the "exposure +1 doubles linear luminance" statement above the
  shoulder knee.
* The HDR ceiling is one fixed number (`W = 4`, +2 EV), not a slider and not
  driven by the display's reported headroom. A panel with less headroom than
  that tone-maps the top of the range itself; one with more does not get used.
* Toning's shadow/highlight crossover clamps its tonal position at `sqrt(min(Y,
  1))`, so in HDR every pixel above SDR white takes the full highlight tint
  rather than continuing to move along the crossover. Acceptable for v1 — the
  region is small and already the most tinted — but it is a real difference
  between the HDR and SDR renditions of the same toning settings.
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
* **An SDR export of an HDR edit clips.** `hdr` changes the tone curve, and the
  file transform still ends at SDR white, so everything the shoulder rolled into
  the headroom piles onto 1.0 — 0.33 % of the reference frame against 0.24 % for
  the same edit in SDR. There is no HDR file format here: no gain map, no PQ or
  HLG container, no 10-bit AVIF/HEIC path. Turning HDR on for a picture you are
  about to export is a way to make the highlights worse, and the sidebar says so.
  The honest export of an HDR edit is future work (`DEVIATIONS.md`).
* Export is always sRGB, 3 channels, no output-sharpening choice; there is no
  in-image clipping overlay (LR's `J`), no Option-drag threshold view on
  Whites/Blacks, no pixel readout, no WB presets or eyedropper, and the
  histogram is luminance-only (audit `decode-output` #2, 4, 5, 7, 10–13 — all
  deferred, see `DEVIATIONS.md`). The histogram is computed only on
  full-resolution renders, so during a drag on an expensive edit it lags the
  canvas by one refine.
* Toning strength still depends strongly on hue: the tint is built from a fully
  saturated primary, so saturation 100 is much more forceful for blue than for
  yellow (audit bwmix-toning.json #3, deferred — it needs an opponent-space
  tint). Extreme tints can still push a channel above 1.0 and get clipped by the
  output transform, which is the one path by which toning loses luminance.
* No Auto B&W Mix (audit #4), and the base conversion is Rec.709 luma rather
  than a monochrome camera profile, so foliage renders lighter and deep blues
  darker than a Lightroom default conversion of the same file (audit #6).
* Toning has two wheels, not Lightroom's four: no Midtones, no Global, no
  per-range Luminance, and Blending is a hard-coded crossover half-width of 0.35
  rather than a slider (audit #7).
