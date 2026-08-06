# Tech Stack Research: Native macOS B&W RAW Editor (2026)

Practical survey based on current documentation and community consensus as of mid-2026. Items not fully verified are flagged.

---

## 1. GPU image processing on macOS

### Option A: Core Image with custom Metal kernels

Core Image (CI) is a lazy, graph-based image pipeline. Filters build a recipe (a DAG of kernels); nothing executes until you render into a destination. The runtime concatenates chained kernels into fewer GPU passes, tiles large images automatically, and handles caching/purgeable intermediates ([Core Image: The Basics](https://blog.jacobstechtavern.com/p/core-image-the-basics)).

- **Custom kernels in Metal Shading Language**: `CIKernel`/`CIColorKernel`/`CIBlendKernel` bodies written in MSL, compiled at build time with the `-fcikernel` compile *and* link flags ([WWDC20: Build Metal-based Core Image kernels](https://developer.apple.com/videos/play/wwdc2020/10021/), [WWDC21: kernel improvements](https://developer.apple.com/videos/play/wwdc2021/10159/), [pitfalls writeup](https://juniperphoton.substack.com/p/pitfalls-and-solutions-when-building)).
- **Escape hatch**: `CIImageProcessorKernel` inserts an arbitrary Metal compute pass (or MPS call) into a CI graph — the standard way to mix hand-rolled Metal stages (guided filter, pyramids) into a CI pipeline. WWDC26 reportedly added new CIImageProcessor APIs with finer tile/buffer control ([WWDC26 session 305](https://developer.apple.com/videos/play/wwdc2026/305/) — *exact API names unverified*).
- **Key gotcha**: CI's tiling model assumes kernels have bounded, declared regions-of-interest. Global/large-neighborhood operations — histograms, big pyramids, large-radius guided filters — fight the tiling model; you end up declaring huge ROIs (defeating tiling) or dropping into `CIImageProcessorKernel` anyway.

### RAW support: CIRAWFilter — big news in 2026

`CIRAWFilter` decodes RAW with adjustable exposure, temperature/tint, NR, sharpness, local tone map, etc., outputting a `CIImage`. Used by Photos, Pixelmator Pro, Nitro, Acorn ([Apple docs](https://developer.apple.com/documentation/coreimage/cirawfilter)).

At WWDC26 Apple shipped **Core Image RAW v9** — first major update since RAW 8 (2017) — for macOS 27: a CoreML model performs **joint demosaic + denoise** on the Neural Engine, with significantly better sharpness, color, and high-ISO noise handling; 784 camera models supported. More resource-intensive — apps must think about when to run it (full-quality vs. draft decode) ([WWDC26 session 305](https://developer.apple.com/videos/play/wwdc2026/305/), [PetaPixel coverage](https://petapixel.com/2026/06/10/apples-raw-processing-is-finally-evolving-after-a-decade-and-its-a-big-deal/)).

Strong argument for CIRAWFilter as the **decode front-end** even when owning the rest of the pipeline: a maintained, camera-matrix-aware, NPU-accelerated demosaicer for ~800 cameras for free. The alternative (LibRaw + custom demosaic) is a large project on its own.

### Option B: Hand-rolled Metal compute pipeline (MetalKit)

Full control: allocate `MTLTexture`s (typically `rgba16Float`), write compute shaders, chain passes explicitly, present via `MTKView`/`CAMetalLayer`.

- **Pros**: precise control over intermediates (whole-image access needed for Laplacian pyramids, guided-filter box sums, histograms); no opaque caching layer; easy incremental "recompute only downstream stages" rendering; deterministic memory; easier EDR output control.
- **Cons**: you own tiling for >16384-px textures (Apple GPU max texture dimension — relevant for 60–100 MP raws in one dimension), caching, and color management.

### MPS primitives you'd actually use

Metal Performance Shaders — tuned kernels callable on your own textures/command buffers:

- `MPSImageGaussianBlur`, `MPSImageBox`, `MPSImageTent`, `MPSImageConvolution`, `MPSImageMedian`, `MPSImageSobel`
- `MPSImageGaussianPyramid` / `MPSImageLaplacianPyramid` (+ Add/Subtract for reconstruction) — pyramid levels in mipmap levels ([docs](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagegaussianpyramid?language=objc))
- `MPSImageHistogram`, `MPSImageHistogramEqualization` — GPU histogram straight into a `MTLBuffer`, ideal for a live histogram panel
- `MPSImageStatisticsMinAndMax` / `...Mean` for auto-levels

`MPSImageBox` gives the O(1)-per-pixel box filter a guided filter needs: guided filter ≈ 6 box blurs + 2 small compute kernels.

### Recommended shape

Hybrid: **CIRAWFilter for decode → export to `MTLTexture` → custom Metal compute pipeline for the editing stack → CAMetalLayer for display**. Core Image renders directly into a Metal texture (`CIContext.render(_:to:)`), so the seam is clean. CI end-to-end only works if ops stay local/point-wise; Clarity/local-contrast built on pyramids or guided filters is much more natural in raw Metal.

---

## 2. How "Clarity" / local contrast is implemented

Four families, in rough order of quality vs. cost:

1. **Large-radius unsharp mask on luminance** (radius ~5–20% of image size, low amount). Cheap (one Gaussian + blend) but produces **halos and gradient reversals** at strong edges. Doing it on a log/tone-mapped luminance domain reduces (doesn't eliminate) halos.
2. **Bilateral/edge-aware base–detail decomposition**: `base = bilateral(L)`, `detail = L − base`, boost detail. darktable's local contrast "bilateral grid" mode does exactly this on Lab L ([darktable manual](https://docs.darktable.org/usermanual/4.8/en/module-reference/processing-modules/local-contrast/)). The **guided filter** (He, Sun, Tang, TPAMI 2013) is the modern substitute: exact O(N) cost independent of radius, no gradient reversal ([paper](https://www.computer.org/csdl/journal/tp/2013/06/ttp2013061397/13rRUxYrbNs), [Fast Guided Filter, arXiv:1505.00996](https://arxiv.org/abs/1505.00996)). On GPU: a few box filters — very fast.
3. **Local Laplacian Filters** (Paris, Hasinoff, Kautz, SIGGRAPH 2011 / CACM 2015): per-coefficient remapping in a Laplacian pyramid; state-of-the-art halo-free detail enhancement ([Adobe Research](https://research.adobe.com/publication/local-laplacian-filters-edge-aware-image-processing-with-a-laplacian-pyramid/), [CACM](https://dl.acm.org/doi/10.1145/2723694), [reference impl](https://github.com/hassenkassim/LocalLaplace)). The **fast approximation** (Aubry et al.) discretizes the remapping into N intensity levels → N blurred pyramids, interpolated. **darktable's default "local laplacian" mode is this fast approximation**, deliberately anti-halo, with separate detail/highlight-contrast/shadow-contrast controls; their engineering writeup covers the streaming/tiled GPU implementation ([darktable blog: local laplacian pyramids](https://www.darktable.org/2017/11/local-laplacian-pyramids/)). Target this for Lightroom-class Clarity — MPS pyramids + one remap compute kernel gets most of the way.
4. **Wavelet decomposition**: RawTherapee's approach — ~5–9 detail levels, per-level contrast curves ([RawPedia: Wavelet Levels](https://rawpedia.rawtherapee.com/Wavelet_Levels), [Local Adjustments](https://rawpedia.rawtherapee.com/Local_Adjustments)). Fine per-scale control, fiddlier to tune than local Laplacians.

Practical note for B&W: operate on a single luminance channel in a perceptual or log domain (darktable uses Lab L; scene-referred variants use log of linear). Single-channel makes all of the above ~3–4× cheaper.

---

## 3. Brush-based local adjustments

Near-universal architecture across darktable / RawTherapee / Capture One / Lightroom:

**Mask = grayscale image at pipeline resolution; adjustment = same parametric operation everywhere, blended per-pixel by mask opacity**: `out = mix(in, op(in, params), mask)`. You never "paint pixels"; you paint the *mask*, and parameter changes re-render through the unchanged mask — this keeps it non-destructive and re-editable.

- **darktable**: every module can have a *drawn mask* (vector shapes: brush strokes stored as paths with per-node pressure/hardness, circles, gradients — rasterized on demand at pipe resolution) and/or a *parametric mask* (per-channel opacity functions of pixel values), combined via union/intersection with per-mask polarity; masks reusable across modules ([masks overview](https://darktable-org.github.io/dtdocs/en/darkroom/masking-and-blending/overview/), [parametric masks](https://darktable-org.github.io/dtdocs/en/darkroom/masking-and-blending/masks/parametric/)). darktable stores brush strokes as *vector data* in the XMP, not raster — resolution-independent and tiny to persist.
- **Capture One**: up to 16 adjustment layers per image; each layer holds one raster mask plus a full set of adjustment parameters; masks combine via Add/Subtract/Intersect; filled layers enable global-with-opacity edits ([Overview of Layers and Masks](https://support.captureone.com/hc/en-us/articles/360002601658-Overview-of-Layers-and-Masks)).

**Brush engine (stamp model)** — standard implementation, matching Photoshop semantics ([O3DE paintbrush docs](https://www.docs.o3de.org/docs/user-guide/components/reference/paintbrush/paintbrush/), [Ciallo, SIGGRAPH 2024](https://dl.acm.org/doi/10.1145/3641519.3657418)):

- A stroke is a sequence of **stamps** (soft discs) placed along the interpolated input path at fixed **spacing** (typically 5–25% of diameter).
- **Hardness** = fraction of radius at full opacity before falloff begins; use smoothstep or Gaussian-ish falloff.
- **Flow** = per-stamp alpha; overlapping stamps accumulate.
- **Opacity/density** = per-*stroke* ceiling: composite stamps into a temporary stroke buffer with `max` blending, clamp at opacity, merge stroke buffer into the mask on mouse-up. This two-buffer scheme makes "one stroke never exceeds opacity X even where it self-overlaps" work.
- On Metal: mask is `r8Unorm`/`r16Float`; stamps rendered as instanced quads (fragment shader computes radial falloff) or a compute kernel; eraser = subtractive blend. Keep the mask at a fixed fraction of full-res (half/quarter) and upsample with the guided filter for edge-aware refinement — this is how Lightroom-style auto-mask/edge-snapping behaves (*inference, not documented by Adobe*).
- Persist strokes as vector path + parameters (darktable-style) for resolution independence and small sidecars; cache the rasterization.

---

## 4. UI framework: SwiftUI vs AppKit

Consensus in 2025/2026: **SwiftUI-first with AppKit escape hatches is the default for new Mac apps, but document infrastructure and the canvas still lean AppKit** ([Eclectic Light explainer, Apr 2026](https://eclecticlight.co/2026/04/04/explainer-appkit-and-swiftui/), [performance comparison](https://digitalblake.com/2026/04/28/swiftui-vs-appkit-macos-ui-performance/)).

- **Inspector panels, sliders, histogram, settings**: SwiftUI is clearly right — `.inspector()` exists; Swift Charts or a custom `Canvas` draws a histogram trivially.
- **Document handling**: SwiftUI `DocumentGroup`/`FileDocument` remains poorer than `NSDocument` ([Eclectic Light: SwiftUI Documents](https://eclecticlight.co/2024/05/16/swiftui-on-macos-documents/)). But Lightroom-style editors are **not document-based** — they're a browser + sidecar model, which sidesteps `NSDocument` entirely. Likely the best move.
- **The canvas**: embed `MTKView` via `NSViewRepresentable` with a `Coordinator` as `MTKViewDelegate` — well-trodden ([walkthrough](https://medium.com/@mateusz.kosikowski/image-processing-in-metal-part-1-creating-swiftui-view-edf01fdf82df)). **Do zoom/pan in the shader/vertex transform, not a giant MTKView in NSScrollView** — the latter hits the 16384-px texture limit and wastes memory ([Apple forums](https://developer.apple.com/forums/thread/651229)). The MTKView stays window-sized; render the visible crop with a zoom/offset matrix. Handle magnify/scroll/pinch at the AppKit level for correct trackpad behavior; SwiftUI's precise trackpad magnification on macOS is still weaker (*mildly uncertain — improving each release*).
- Known rough edges: MTKView-in-SwiftUI presentation quirks in sheets/windows on recent macOS ([forums](https://developer.apple.com/forums/thread/764470)). Nothing blocking.

**Recommendation**: SwiftUI app shell + panels; one `NSViewRepresentable`-wrapped `MTKView` (or plain NSView with your own `CAMetalLayer`, which gives EDR control) for the canvas; skip `NSDocument`/`DocumentGroup` in favor of a library + sidecar model.

---

## 5. Color management, EDR, and float textures

- **Working space**: edit in **linear light**, wide gamut (extended linear sRGB or linear Display P3, or camera-native → working transform). CIRAWFilter hands you extended-range linear data. Tone-map to display space as the *last* stage (darktable's scene-referred pipeline is the reference model).
- **Texture formats**: `rgba16Float` (or `r16Float` for B&W luminance planes) is the workhorse — half memory/bandwidth, fast native half math on Apple GPUs. Use `float32` where accumulation error matters: histogram bins, box-filter running sums / integral images, pyramid reconstruction if banding appears. half has ~11 bits of mantissa — fine for pixels, risky for large sums.
- **Display / ColorSync**: with Core Image display, `CIContext` + specified working/output color spaces handles ColorSync matching. With your own `CAMetalLayer`, set `layer.colorspace` (e.g. `kCGColorSpaceExtendedLinearDisplayP3`) and the system matches to the display.
- **EDR**: float pixel values >1.0 render brighter than SDR white on capable displays (XDR MacBook Pros, Pro Display XDR). Recipe: `CAMetalLayer.wantsExtendedDynamicRangeContent = true`, `rgba16Float`, extended-linear colorspace; query `NSScreen.maximumExtendedDynamicRangeColorComponentValue` for current headroom ([WWDC21: Explore HDR rendering with EDR](https://developer.apple.com/videos/play/wwdc2021/10161/), [Adventures in EDR](https://rioogino.com/posts/2024/edr_2_metal/)). For a B&W editor the killer feature: **highlight-clipping-free preview while editing raws** — >1.0 highlights display as actually-brighter instead of clipped. Watch for known HDR color-shift bugs on CAMetalLayer under some colorspace combos ([forums](https://developer.apple.com/forums/thread/745810)) — test on real XDR hardware.

---

## 6. Non-destructive edit architecture

Industry-standard pattern (darktable is the best-documented open example):

- **Never touch the original file.** Store an ordered list of operations with parameters; re-render by replaying through the pipeline ([darktable sidecar files](https://docs.darktable.org/usermanual/development/en/overview/sidecar-files/sidecar/)). darktable uses SQLite for the library + XMP sidecars next to the raws, auto-synced without a save button.
- **For a personal tool**: a versioned **JSON (or plist) sidecar per image** — human-readable, diffable, versioned with a `"version"` key, survives database corruption, raw+sidecar pair is self-contained. Codable structs map 1:1. SQLite/Core Data/SwiftData only for a catalog layer (folders, ratings, thumbnail index) if ever needed. SwiftData is production-usable in 2025/2026 but weaker than Core Data on migrations; plain GRDB/SQLite or no catalog at all is fine for a personal editor.
- **Edit model**: prefer a **fixed-order pipeline with per-stage parameter structs** (Lightroom model) over darktable's reorderable module stack — vastly simpler, and for a focused B&W editor the fixed order (decode → WB/exposure → denoise → B&W conversion/channel mixer → tone curve → local contrast → local adjustments → grain/vignette → output transform) is a feature. The whole edit state is one value-type `EditState` struct.
- **Recompute strategy**: with a value-type `EditState`, re-render the whole pipeline per slider change at *preview* resolution (a 2–6 MP proxy renders in a few ms on Apple Silicon); debounce a full-res render for 1:1 view/export. Cache expensive upstream results keyed by parameter sub-struct (post-decode texture, post-denoise texture) so late-stage slider drags only recompute downstream — a "dirty from stage N" invalidation. RAW v9's expensive neural decode makes caching the decoded texture essentially mandatory.
- **Undo**: `EditState` is a small value type — snapshot it into `UndoManager` on each committed gesture (slider mouse-up, stroke end), not every continuous change. Gives darktable-style history UI for free. Brush strokes: undo at stroke granularity (stroke vector data is part of `EditState`).

---

## Suggested stack (summary)

| Layer | Choice |
|---|---|
| RAW decode | `CIRAWFilter` (Core Image RAW v9 on macOS 27) → render to `MTLTexture` |
| Pipeline | Hand-rolled Metal compute passes on `r16Float`/`rgba16Float`; MPS for blur/box/pyramids/histogram |
| Clarity | Fast local Laplacian (darktable-style) or guided-filter base/detail as the cheaper first version |
| Local adjustments | Vector brush strokes → rasterized grayscale mask texture → per-pixel `mix()` of parametric deltas |
| Canvas | `CAMetalLayer`/`MTKView` in an `NSViewRepresentable`; zoom/pan as a render transform; EDR opt-in |
| UI shell | SwiftUI (panels, sliders, histogram via Charts/Canvas); AppKit only where needed |
| Persistence | JSON sidecar per image (Codable `EditState`); optional SQLite/Core Data catalog |
| Undo | Value-type `EditState` snapshots via `UndoManager` |

Flagged uncertainties: exact WWDC26 CIImageProcessor API additions (verify against [session 305](https://developer.apple.com/videos/play/wwdc2026/305/)); Lightroom auto-mask internals (inferred, proprietary); current SwiftUI trackpad-gesture fidelity on macOS (verify on target OS).
