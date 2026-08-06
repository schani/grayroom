# Grayroom vs Lightroom Classic — deviation register

Every item from `research/audit/*.json`, with where it stands. This is the
living record: when a wave lands, the status column moves, nothing is deleted.
Details and measurements for everything marked *done* live in
`Sources/GrayroomCore/README.md`; the audit JSON holds the original evidence and
the proposed fix for everything deferred.

Severity/effort are the auditor's, unchanged. "Deferred" means a considered
decision, not a backlog: the rationale is the point of the column.

## Tone — `research/audit/tone.json`

| # | Aspect | Status | Rationale if deferred | Sev/Eff |
|---|--------|--------|-----------------------|---------|
| 0 | Exposure has no highlight rolloff, hard-clips | done, wave 1 | — | high / M |
| 1 | Contrast σ = 2.5 EV blows the whites | done, wave 1 (σ 2.5→1.2 EV, gain 0.55→0.40) | — | high / S |
| 2 | Highlights/Shadows dead band through the midtones | done, wave 1 (ramp (0.25,4.0)→(−2.7,5.3)) | — | high / S |
| 3 | Whites inert — ramp sits 2 EV above display white | done, wave 1 (ramp (1.0,7.5)→(0.8,3.4)) | — | high / S |
| 4 | Blacks never reach zero | done, wave 1 (output-domain pedestal) | — | high / M |
| 5 | Highlight recovery does not desaturate | deferred | tone stage is exactly ratio-preserving by design; fixing it retires `testTonePreservesRatiosNoHueShift` and changes the kernel's colour behaviour | medium / M |
| 6 | Highlights/Shadows are a global 1-D curve; LR's are edge-aware | deferred | architectural: needs the zone weights driven from the clarity pyramid rather than pixel luminance | medium / L |
| 7 | Whites/Blacks not available per mask | deferred | needs a third parameter texture, and post-wave-1 Whites/Blacks are no longer additive-EV shapes, so the per-pixel form must be redesigned | medium / M |
| 8 | Tone controls are a fixed curve; LR's are image-adaptive | deferred | a deterministic curve is the better design for this tool; recorded, not a defect | low / L |

## B&W mixer and toning — `research/audit/bwmix-toning.json`

| # | Aspect | Status | Rationale if deferred | Sev/Eff |
|---|--------|--------|-----------------------|---------|
| 0 | Mixer authority and saturation weighting | done, wave 2 (exponential ±3 EV, `s^0.6` weight, knee 0.02) | — | high / S |
| 1 | Split-tone neutral dead zone in the midtones | done, wave 2 (complementary crossover weights) | — | high / S |
| 2 | Split toning is exactly luminance-preserving; LR's is not | done, wave 2 (`lumaPreserve = 0.5`) | — | medium / S |
| 3 | Toning saturation is strongly hue-dependent | deferred | needs an opponent-space tint rather than a fully saturated primary; a retune of the current form would only move the imbalance around | medium / M |
| 4 | Auto B&W Mix | deferred | a feature, not a parity defect; wants a scene-analysis pass | medium / M |
| 5 | Band centres, especially purple/magenta | done, wave 2 (280→270, 320→300) | — | low / S |
| 6 | Base grey conversion is Rec.709 luma, not a monochrome camera profile | deferred | belongs with camera-profile support; changing it alone would re-anchor every existing sidecar | medium / M |
| 7 | Color Grading: midtones/global wheels, Blending, per-range Luminance | deferred | additive once the crossover is right (it now is); scope, not risk | low / M |

## Clarity and local adjustments — `research/audit/clarity-local.json`

| # | Aspect | Status | Rationale if deferred | Sev/Eff |
|---|--------|--------|-----------------------|---------|
| 0 | Clarity response curve — first half of the slider is dead | done, wave 3 (α pinned, `lift` linear: slope 1.15 @ +10, 1.375 @ +25, endpoints unchanged) | — | high / S |
| 1 | No midtone targeting | done, wave 3 (Gaussian tone weight, σ = 3 EV, floor 0.2) | — | high / S |
| 2 | Lifts the pixel-scale band, so it amplifies noise | done, wave 3 (`levelGains = 0, 0.4, 1…`) | — | medium / S |
| 3 | No halos at high settings — LR's Clarity has them | deferred | needs a deliberately non-edge-aware component blended in; the halo-free design is a stated goal and this trades it away, so it wants a look decision, not a constant | medium / M |
| 4 | Negative clarity is detail flattening, not glow/bloom | deferred | needs a separate operator for the negative branch (screen-blended blur + midtone lift), not a retune; sizeable and independent of wave 3's changes | high / M |
| 5 | Opposite-sign local clarity is dropped, not applied | deferred | needs a second local-Laplacian pass and a 4-input apply kernel — doubles the cost of the most expensive stage for a rare case. Note the linearised response makes this cheap to add later: the filter is affine in `lift`, so one unit-lift pyramid could serve both signs | high / M |
| 6 | A local clarity mask changes the rendering *outside* it | done, wave 3 (amount normalised against a fixed full-scale reference; now bit-exact outside the mask) | — | medium / S |
| 7 | Brush Flow does not build up across strokes | done, wave 3 (max within a stroke, over-composite across them) | — | high / S |
| 8 | Density is a per-stroke ceiling, not an absolute one | done, wave 3 (`m ← min(m + s(1−m), max(m, density))`) | — | medium / S |
| 9 | Overlapping masks clamp the *sum* at ±4 EV / ±100 | deferred | the cheap half (raise the ceiling) changes the documented range contract; the real fix is sequential per-mask evaluation, i.e. N tone passes | medium / M |
| 10 | No Auto Mask (edge-aware brushing) | deferred | guided filter or a luminance-similarity kernel; also forces the mask cache to key on the tone parameters, which is the expensive part | medium / L |
| 11 | Clarity does not affect saturation; LR's does | deferred | the ratio-preserving design is a stated goal and the B&W-visible effect is second order (it only reaches the mixer's saturation weighting) | low / M |
| 12 | No A/B brush presets | deferred | pure UI state; `Stroke` already carries its own `BrushParams`, so it is a sidebar change with no core work | low / S |

## Decode, output and histogram — `research/audit/decode-output.json`

| # | Aspect | Status | Rationale if deferred | Sev/Eff |
|---|--------|--------|-----------------------|---------|
| 0 | Baseline rendition: images start too flat/dark | done, wave 1 (baseline curve + shoulder in the tone stage) | — | high / S |
| 1 | Clip indicator threshold is 0.1 % of the frame | done, wave 3 (absolute count, 32 px) | — | high / S |
| 2 | No in-image clipping overlay (LR's `J`) | deferred | needs an overlay pass in the canvas shader plus UI state; wave 3 made the *indicator* honest first, which is the prerequisite | high / M |
| 3 | Capture sharpening differs between preview and export | done, wave 3 (`sharpnessAmount = 0` unconditionally) | — | high / S |
| 4 | No Option-drag threshold clipping view on Whites/Blacks | deferred | same machinery as #2; and post-wave-1 Whites cannot create highlight clipping, so the view would be empty on that side until that is revisited | medium / M |
| 5 | No white-balance presets or eyedropper | deferred | UI feature; the eyedropper also needs #6 to be usable interactively | medium / S |
| 6 | Every temp/tint change re-decodes the RAW | deferred | WB at decode time is the v1 design (PLAN.md); moving it into the pipeline means carrying camera matrices ourselves | medium / L |
| 7 | No pixel value readout | deferred | UI feature, no core work | medium / S |
| 8 | 8-bit output is not dithered — banding in grey gradients | done, wave 3 (stochastic rounding in `ImageWriter` and the canvas shader) | — | medium / S |
| 9 | Canvas is not colour-managed to the display profile | done, wave 3 (`CAMetalLayer.colorspace = sRGB`) | — | medium / S |
| 10 | Output clamp is per-channel with no rolloff | deferred | only reachable with heavy toning; a rolloff here would fight the tone stage's shoulder, which is where highlight behaviour is defined | low / S |
| 11 | Histogram is luminance-only; no per-channel layers | deferred | for a B&W pipeline the two agree except under toning; wants the toning-aware channel view to be worth it | low / M |
| 12 | Histogram/clipping measured on the preview, not the export | deferred | a full-res histogram pass per edit is the cost; wave 3's absolute clip threshold at least makes the *indicator* resolution-independent | low / S |
| 13 | Export is always sRGB 3-channel; no colour space or output sharpening | deferred | needs a real output-sharpening stage (M5) to be worth a dialog | low / M |

## Summary

| | tone | bwmix/toning | clarity/local | decode/output | total |
|---|---|---|---|---|---|
| implemented | 5 | 4 | 6 | 5 | **20** |
| deferred | 4 | 4 | 7 | 9 | **24** |

Of the 16 items the audits rated *high* severity, 13 are implemented. The three
open ones are clarity-local #4 (negative clarity is not a glow), #5 (opposite-sign
local clarity is dropped) and decode-output #2 (no in-image clipping overlay).
