# Free/Open-Source RAW Processing Libraries for a Native macOS RAW Editor

Research snapshot: **August 2026**. Version numbers/dates were checked against current sources; items not fully verified are marked *(uncertain)*.

---

## 1. LibRaw — the default choice for RAW decoding

**What it is:** A C++ library (with a plain-C API layer) for reading and decoding RAW files, launched in 2008 as a fork/extension of Dave Coffin's `dcraw.c`, now maintained independently by the LibRaw team (LibRaw LLC).

- **License:** Dual-licensed — your choice of **LGPL 2.1** or **CDDL 1.0**. Both permit use in closed-source apps (LGPL requires dynamic linking or relinkable object files; CDDL is file-based copyleft and even friendlier for static linking). ([libraw.org/about](https://www.libraw.org/about))
- **Current release:** **0.22.1 (April 6, 2026)**, a bugfix/security release on top of **0.22.0 (January 13, 2026)**. Actively maintained; there is also a "snapshot" pre-release channel that gets new-camera support faster than stable releases. ([release notes](https://www.libraw.org/news/libraw-0-22-0-release), [GitHub releases](https://github.com/LibRaw/LibRaw/releases))
- **Camera support:** 0.22 supports **1,284 cameras**, including recent bodies (Canon R1/R5 II/R50/R100, Nikon Z6 III/Zf/Z8, Sony A9 III/A7CR, Fujifilm X-T50/GFX 100S II, Leica Q3/SL3, DJI/Skydio drones) and modern formats: DNG 1.7 incl. JPEG-XL compression, Sony YCC pseudo-RAW, Panasonic encoding 8, Canon CRN, Nikon pixel-shift NEFX. Camera support is genuinely current — this is LibRaw's core competency.
- **What it provides:**
  - **Decoding:** full unpack of raw sensor data plus metadata (Bayer pattern, black/white levels, WB coefficients, color matrices, crop/geometry) and embedded thumbnails/previews.
  - **Raw Bayer access before demosaic: yes** — after `unpack()`, `imgdata.rawdata.raw_image` holds the uninterpolated 16-bit sensor data (for non-Bayer sensors, sibling arrays like `color3_image`/`color4_image`). This is exactly what you want to feed a custom Metal pipeline. ([API docs](https://www.libraw.org/docs/API-CXX.html))
  - **Demosaicing/postprocessing:** `dcraw_process()` emulates dcraw's pipeline; `imgdata.params.user_qual` selects the demosaic (linear, VNG, PPG, AHD, DCB, DHT, AAHD). Output options include 8/16-bit, gamma control (linear possible via `gamm`), and output color spaces (raw, sRGB, Adobe RGB, Wide, ProPhoto, XYZ, ACES).
  - **Color management:** basic — camera→XYZ/sRGB matrices from its own tables plus an optional LCMS hook. Not a full CM engine; pair with Little-CMS.
- **Important caveat (from LibRaw themselves):** rendering code is "mainly for compatibility and rapid testing"; **production-quality rendering is out of scope**. The intended architecture for a serious editor: LibRaw for decode + metadata, your own demosaic/tone/color pipeline on top.
- **macOS:** fully supported (autotools/CMake/Makefile builds, Homebrew `brew install libraw`, arm64 and x86_64). Plain C++ API, no platform dependencies beyond optional zlib/jpeg/jasper/LCMS.

---

## 2. Apple built-in RAW: Core Image `CIRAWFilter`

The modern API is the **`CIRAWFilter` class** (macOS 12+, replacing the older CIFilter RAW options API). ([Apple docs](https://developer.apple.com/documentation/coreimage/cirawfilter), [WWDC21 "Capture and process ProRAW"](https://developer.apple.com/videos/play/wwdc2021/10160/))

- **Controls exposed:** `exposure`, `baselineExposure`, `shadowBias`, `boostAmount`/`boostShadowAmount` (the "Apple look" contrast boost), `neutralTemperature`/`neutralTint` (also `neutralChromaticity`, `neutralLocation` for click-WB), `luminanceNoiseReductionAmount`, `colorNoiseReductionAmount`, `sharpnessAmount`, `contrastAmount`, `detailAmount`, `moireReductionAmount`, `localToneMapAmount`, `extendedDynamicRangeAmount`, `isLensCorrectionEnabled`, gamut mapping toggle, draft mode, decoder version selection, `isXxxSupported` capability queries, ProRAW extras (portrait matte, semantic segmentation mattes).
- **Camera support:** whatever Apple's OS-level RAW decoder supports — published per OS release: [Digital camera RAW formats supported (support.apple.com/122870, updated July 2026)](https://support.apple.com/en-us/122870), plus generic DNG. Broad mainstream coverage; updates on Apple's schedule; no source access.
- **Linear scene-referred access:** you cannot get the raw Bayer mosaic out, but you can get close to scene-referred linear data two ways:
  1. **`linearSpaceFilter`** — a CIFilter applied while the image is still linear, *after* demosaic but *before* tone mapping/output conversion.
  2. **Neutralize the default look** — set `baselineExposure`, `shadowBias`, `boostAmount`, `localToneMapAmount` to 0, disable gamut mapping, render to a linear working space (e.g. linear extended sRGB, half-float) via a `CIContext` with linear working color space.
  This yields demosaiced linear RGB for a custom pipeline — but demosaic, highlight reconstruction, and NR remain Apple's black box.
- **Metal integration:** excellent — output is a `CIImage`; render through a Metal-backed `CIContext` directly into `MTLTexture`s; draft mode + scaleFactor give fast previews. Lowest-effort path to a working GPU RAW pipeline on macOS.
- **Limitations vs LibRaw:** closed box (can't change demosaic, no mosaic access, limited highlight-recovery control), camera support tied to OS updates, behavior can change between OS releases, the "default look" must be explicitly disabled for neutral output.

---

## 3. rawspeed (darktable's decoder)

- **Repo:** [github.com/darktable-org/rawspeed](https://github.com/darktable-org/rawspeed). **License: LGPL-2.1.**
- **Scope:** deliberately **decode-only**: "not intended to be a complete RAW file display library, but only acts as the first stage decoding" ([README](https://github.com/darktable-org/rawspeed/blob/develop/README.rst)). No demosaic, no color rendering. Fast (multithreaded, vectorized), heavily fuzzed.
- Camera metadata lives in an XML database (`data/cameras.xml`) you must ship and update.
- **Practicality:** possible to embed (CMake), but API not stability-guaranteed, docs thin, releases tied to darktable's needs, camera coverage somewhat narrower than LibRaw. Verdict: LibRaw is the safer embedding choice. *(API-stability characterization is an assessment from project docs, not an official statement.)*

---

## 4. dcraw / dcraw_emu

- **dcraw is dead:** last release **9.28, June 2018**; no cameras since ~2018 supported. Do not build on it. ([Wikipedia](https://en.wikipedia.org/wiki/Dcraw), [LibRaw forum](https://www.libraw.org/node/2293))
- **`dcraw_emu`** is a sample program shipped **with LibRaw** emulating the dcraw command line on top of LibRaw's current decoders — the practical successor.

---

## 5. RawTherapee, darktable (and vkdt) as reference implementations

All three are **GPL-3.0** — read freely, but any code you copy makes your whole app GPL (see §8).

- **RawTherapee** — current: **5.13 (July 2026)** ([rawtherapee.com/downloads](https://www.rawtherapee.com/downloads/)). Excellent reference for demosaic algorithms (AMaZE, RCD, LMMSE — among the best open implementations anywhere), highlight reconstruction, capture sharpening. The "rtengine" core is not packaged as a reusable library — extraction is a real project. Reference reading, not a dependency.
- **darktable** — stable **5.4.1 (Feb 2026)**, feature release **5.6.0** ([GitHub](https://github.com/darktable-org/darktable/releases/tag/release-5.6.0)). Reference gold for a **scene-referred linear pipeline** (filmic rgb / sigmoid, color balance rgb, diffuse-or-sharpen, denoise-profiled). Modules are relatively self-contained C files with OpenCL twins — great to *port conceptually* to Metal, but GPL and tied to darktable's pixelpipe. Runs on macOS, so you can A/B against it.
- **vkdt** — [hanatos/vkdt](https://github.com/hanatos/vkdt), darktable author's next-gen GPU-only raw pipeline (Vulkan compute, node graph, real-time). GPL-3.0. Relevant as the best existing example of a fully GPU-resident raw node-graph pipeline — architecturally closest to a Metal-based editor. macOS support via MoltenVK is marginal *(uncertain — check current readme)*.

---

## 6. Supporting libraries

| Library | Purpose | License | Status (checked Aug 2026) |
|---|---|---|---|
| **lensfun** | Lens distortion/CA/vignetting correction + lens DB | Library **LGPL-3**; database **CC-BY-SA 3.0** | Last tagged release **0.3.4 (July 2023)**; git master active, DB updated via `lensfun-update-data`. Semi-dormant releases; newest-lens coverage lags; many apps embed git master. ([lensfun.github.io](https://lensfun.github.io/)) |
| **Little-CMS (lcms2)** | ICC color management | **MIT** | v2.17 (Feb 2025); standard choice. Note macOS also has ColorSync natively. |
| **OpenImageIO** | Universal image I/O (wraps LibRaw for RAW) | **BSD-3 / Apache-2.0** | v3.1.12.0 (Apr 2026), ASWF-maintained. Heavyweight; only worth it for EXR + many formats in one dependency. |
| **libtiff / libjpeg-turbo** | TIFF/JPEG export | permissive | Both healthy. On macOS you can skip both and use **ImageIO.framework** (16-bit TIFF, HEIF, JPEG, PNG, DNG writing). |
| **Exiv2** | EXIF/IPTC/XMP metadata | **GPL-2+** — viral; linking makes your app GPL | v0.28.8 (Mar 2026), active. |
| **ExifTool** | Metadata swiss-army knife | Perl, Artistic/GPL dual | Fine to invoke as an **external process** (no license contamination). |

Metadata alternative: LibRaw exposes most shooting metadata needed for processing, and Apple's **ImageIO/CGImageSource** reads EXIF/makernote basics natively — Exiv2 may be unnecessary unless deep XMP writing is needed.

---

## 7. Integrating LibRaw into a Swift/SwiftUI Mac app

LibRaw's public API is C++-flavored but ships a **plain-C API** (`libraw_init`, `libraw_open_file`, `libraw_unpack`, …) which Swift can import directly.

Options, in order of recommendation for a personal app:

1. **Vendor the source into an Xcode/SPM C++ target.** LibRaw is ~a dozen .cpp files; build as a static library target, expose the C API via a module map / umbrella header, import from Swift. No runtime dependency, easy universal builds, version control. Swift 5.9+ C++ interop can even call the C++ classes directly, though the C API is simpler.
2. **Homebrew + module map:** `brew install libraw`, SPM `systemLibrary` target with a `module.modulemap` + `-lraw_r` (thread-safe variant). Works, but ties you to the machine's Homebrew and complicates distribution/notarization (bundle + re-sign dylib, fix `@rpath`).
3. **Existing wrappers:** e.g. **SwiftLibRaw** ([announcement](https://www.libraw.org/node/2858)) — useful as example code more than as a dependency.

Practical notes:
- Wrap LibRaw calls in an Objective-C++ or C shim to hide C++ exceptions/error handling; check return codes on every call.
- LibRaw instances are not thread-safe per-instance; one instance per file/thread is fine (`libraw_r`).
- Pipeline shape that works well: LibRaw `open_file`+`unpack` → copy `rawdata.raw_image` + blacks/WB/CFA/color matrix into your own struct → upload to `MTLTexture` (r16Uint) → Metal demosaic/tone pipeline → ColorSync/lcms2 for output profile → ImageIO for export.
- App Store sandboxing: LibRaw is pure computation, no entitlements issues.

---

## 8. License implications for a personal/native Mac app

- **LibRaw (LGPL-2.1 or CDDL):** safe for a closed-source app. LGPL requires relinkability — satisfied by dynamic linking (bundle `libraw.dylib` in the .app) or shipping relinkable object files. **CDDL** avoids even that: file-level copyleft, static linking unproblematic; you must only publish modifications to LibRaw's own files. Choosing CDDL is simplest. (CDDL is GPL-incompatible — irrelevant unless mixing GPL code in.)
- **rawspeed (LGPL-2.1), lensfun (LGPL-3):** dynamically link and you're fine.
- **lcms2 (MIT), OpenImageIO (BSD/Apache), libtiff/libjpeg-turbo:** permissive, attribution only.
- **GPL code (darktable, RawTherapee, vkdt, Exiv2):** copying *any* code — including porting an OpenCL kernel to Metal in a way that constitutes derivation — makes the entire app GPL-3 on distribution. Escape hatches: (a) a truly personal, never-distributed app has no GPL obligations (GPL triggers on distribution, not use); (b) reading GPL code to understand an algorithm and re-implementing independently from the papers (AMaZE, RCD, filmic curves are published techniques) is legitimate.
- **Apple CIRAWFilter:** OS API, no licensing concerns.

---

## Bottom-line recommendation

For a custom native macOS RAW editor with your own processing pipeline: **LibRaw (CDDL) for decode + metadata + raw Bayer access, your own Metal demosaic/tone pipeline, lensfun (dynamic-linked) for lens corrections, lcms2 or ColorSync for color management, ImageIO for export**, with **darktable/RawTherapee as algorithm references (read, don't copy)** and **CIRAWFilter as a useful A/B baseline** — or as a fast "phase 1" pipeline via `linearSpaceFilter` before a custom pipeline is ready.

**Sources:** [LibRaw about](https://www.libraw.org/about) · [LibRaw 0.22 release](https://www.libraw.org/news/libraw-0-22-0-release) · [LibRaw GitHub releases](https://github.com/LibRaw/LibRaw/releases) · [LibRaw C++ API](https://www.libraw.org/docs/API-CXX.html) · [CIRAWFilter docs](https://developer.apple.com/documentation/coreimage/cirawfilter) · [linearSpaceFilter](https://developer.apple.com/documentation/coreimage/cirawfilter/3801634-linearspacefilter) · [WWDC21 ProRAW session](https://developer.apple.com/videos/play/wwdc2021/10160/) · [Apple RAW camera list](https://support.apple.com/en-us/122870) · [rawspeed README](https://github.com/darktable-org/rawspeed/blob/develop/README.rst) · [dcraw Wikipedia](https://en.wikipedia.org/wiki/Dcraw) · [RawTherapee downloads](https://www.rawtherapee.com/downloads/) · [darktable 5.6.0](https://github.com/darktable-org/darktable/releases/tag/release-5.6.0) · [vkdt](https://github.com/hanatos/vkdt) · [lensfun](https://lensfun.github.io/) · [Little-CMS releases](https://github.com/mm2/Little-CMS/releases) · [OpenImageIO releases](https://github.com/AcademySoftwareFoundation/OpenImageIO/releases) · [Exiv2 0.28.8](https://github.com/Exiv2/exiv2/releases/tag/v0.28.8) · [SwiftLibRaw](https://www.libraw.org/node/2858)
