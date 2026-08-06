# Grayroom — a native macOS B&W RAW developer

A personal, focused subset of Lightroom Classic: B&W processing of RAW files only.
No library/organization features. macOS only, Apple Silicon, macOS 14+.

Research background (with sources) lives in `research/`.

## V1 feature set (agreed)

1. Open a RAW file → linear scene-referred color → display with zoom/pan
2. White balance (temp/tint) + Exposure / Contrast / Highlights / Shadows / Whites / Blacks
3. 8-channel B&W mix (red, orange, yellow, green, aqua, blue, purple, magenta) with
   click-and-drag targeted adjustment on the image
4. **Clarity via fast local Laplacian pyramid** (Aubry et al. approximation, as in
   darktable's local-contrast module — implemented from the papers, not their GPL code)
5. Brush-based local adjustments: size / feather / flow / density, eraser; per-mask
   exposure, contrast, highlights, shadows, clarity
6. Two-tone toning: shadows hue+sat, highlights hue+sat, balance
7. Histogram with clipping indicators, before/after toggle
8. JSON sidecar persistence + undo, 16-bit TIFF / JPEG / PNG export

Deferred: tone curve, texture/dehaze, grain, vignette, sharpening/NR, linear/radial
gradients, range masks, AI masks, any browsing/catalog.

## Non-negotiable engineering principle: headless first

Everything in the imaging core must run and be verifiable **without the GUI**:

- `grayroom` CLI can decode a DNG, apply an edit (from a sidecar JSON and/or
  `--set key=value` overrides), and export PNG/JPEG/16-bit TIFF.
- `grayroom probe` prints decode metadata; `--histogram` dumps a luminance histogram
  as text; exit codes and stderr diagnostics are script-friendly.
- `swift build && swift test` must pass on a plain terminal (no Xcode GUI).
- GPU stages get **property-based golden tests** on synthetic textures (gradients,
  color wheels, noise): e.g. exposure +1 EV doubles linear values; the red mixer
  slider darkens a red patch and leaves a neutral gray patch untouched; clarity
  increases local variance while approximately preserving low-frequency means;
  toning tints shadows toward the chosen hue.
- End-to-end smoke test renders a real DNG (path via `GRAYROOM_TEST_DNG` env var or
  `testdata/`, which is gitignored) and asserts basic output statistics.

The GUI app arrives only in M4, as a thin shell over the same core.

## Architecture

Swift Package (tools 6.0, **language mode .v5** to keep strict-concurrency friction
out of v1), targets:

- **`GrayroomCore`** (library) — all imaging:
  - `Decode/` — CIRAWFilter wrapper: neutralized decode (baselineExposure/boost/
    localToneMap zeroed, gamut mapping off) → linear Rec.709-primaries half-float
    `MTLTexture` via a Metal-backed CIContext with linear working space. WB
    (temp/tint) is applied at decode via `neutralTemperature`/`neutralTint` in v1;
    decode results are cached keyed by (URL, WB) since WB changes force re-decode.
  - `Engine/` — `MetalContext` (device/queue/library), `Pipeline` (fixed-order stage
    graph on `rgba16Float`/`r16Float` textures), texture pool.
  - `Stages/` — one file per stage + one `.metal` per stage. Shaders are bundled as
    text resources and compiled at runtime with `makeLibrary(source:)` (robust under
    SPM CLI builds; no metallib bundling issues).
  - `EditState.swift` — one Codable value-type struct, the single source of truth.
    Versioned (`"version": 1`). Sidecar = pretty-printed JSON next to the RAW
    (`IMG_1234.DNG.grayroom.json`).
  - `Masks/` — brush strokes as vector polylines (points + per-point radius/pressure,
    feather/flow/density), stamp-model rasterizer into `r16Float` mask textures,
    parameter-delta accumulation (below).
  - `Export/` — ImageIO: 16-bit TIFF, PNG, JPEG with correct color space tagging.
- **`grayroom`** (executable) — swift-argument-parser CLI: `render`, `probe`.
- **`GrayroomApp`** (executable, M4) — SwiftUI shell + MTKView canvas.
- **`GrayroomCoreTests`**.

### Pipeline order (fixed)

```
decode(+WB) → [linear RGB rgba16Float]
  → tone (exposure, contrast, highlights, shadows, whites, blacks; per-pixel params)
  → clarity (fast local Laplacian on log-luminance; per-pixel amount)
  → B&W mix (8 hue bands, saturation-weighted so neutrals are unaffected) → [gray]
  → two-tone toning (shadows/highlights hue+sat, balance) → [RGB again]
  → output transform (linear → sRGB/display), histogram tap, clipping flags
```

### Local adjustments: per-pixel parameter maps

Masks never multiply full-image passes. Each mask rasterizes to a coverage texture;
all mask parameter deltas accumulate into shared **parameter textures** (e.g. one
rgba16Float holding per-pixel Δexposure/Δcontrast/Δhighlights/Δshadows, one channel
for Δclarity). Stages read `global + paramTex(x)`. Clarity blends per-pixel between
original and the Laplacian-enhanced image (enhanced computed once at full strength;
amount map controls the mix; negative amounts blend toward a softened variant —
second pyramid pass only when any negative amount exists).

### B&W mix semantics

Computed on white-balanced linear RGB before gray conversion:
`gray = Y · (1 + Σ_bands w_band(hue) · slider_band · sat_weight)`, with smooth
(cubic) band interpolation across the 8 Lightroom hue centers and saturation
weighting so neutral pixels are unaffected. Compute in a wide-enough working space
and dither/organize math to avoid banding (see PV6 note in research).

### Toning semantics (classic split-tone)

On the gray image: shadows wheel (hue 0-360, sat 0-100), highlights wheel, balance
−100..+100 shifting the shadow/highlight crossover. Extreme blacks/whites stay
neutral (Lightroom behavior).

## Milestones

- **M0 — scaffold + decode + export.** Package builds headlessly; `grayroom probe`
  prints DNG metadata; `grayroom render` does decode → output transform → PNG
  (still color, no adjustments). Smoke test on a real Leica DNG.
- **M1 — global adjustments.** Tone stage, B&W mix, toning, histogram tap,
  `--set`/sidecar plumbing, golden tests. CLI produces a finished global B&W.
- **M2 — clarity.** Fast local Laplacian (MPS pyramids + remap kernels), golden
  tests, CLI `--set clarity=…`.
- **M3 — masks.** Stroke model + rasterizer + param accumulation; sidecar schema for
  masks; CLI renders masked edits headlessly (strokes authored in JSON for testing).
- **M4 — GUI.** SwiftUI app: MTKView canvas (zoom/pan as render transform), sliders,
  histogram + clipping, brush painting with A/B/eraser, targeted-adjustment drag for
  the B&W mixer, before/after, undo (EditState snapshots), sidecar autosave.
- **M5 — polish.** EDR preview, performance passes, export sharpening if wanted.

## Testing inputs

`testdata/` (gitignored) holds copies of a few personal Leica DNGs for smoke tests;
unit tests use synthetic textures generated in-code, so CI-style runs need no DNGs.

## License notes

Apple frameworks only in v1 (no LibRaw needed while CIRAWFilter covers the Leica
files). darktable/RawTherapee are **reference reading only** — algorithms come from
the published papers (Paris/Hasinoff/Kautz 2011; Aubry et al. 2014; He et al. guided
filter if ever needed). No GPL code enters this repo.
