# Grayroom — a native macOS B&W photo developer

A personal, focused subset of Lightroom Classic: B&W processing of RAW files and
standard images (JPEG, TIFF, PNG, HEIC). macOS only, Apple Silicon, macOS 14+.
Organization (M6) is a SQLite library, not a folder browser.

Research background (with sources) lives in `research/`.

## V1 feature set (agreed)

1. Open a RAW file or a standard image (JPEG / TIFF / PNG / HEIC) → linear
   scene-referred color → display with zoom/pan. RAW goes through `CIRAWFilter`
   with Apple's look neutralized; a standard image is read with `CIImage`
   honouring its embedded ICC profile and linearized by the extended-linear-sRGB
   working space.
2. White balance (temp/tint) + Exposure / Contrast / Highlights / Shadows / Whites / Blacks.
   On a RAW, temp/tint pick the illuminant the sensor data is interpreted
   against. A standard image has already been white-balanced once and is D65 by
   construction, so there is no illuminant left to name: temp/tint are instead a
   **relative** Core Image `CITemperatureAndTint` shift away from a 6500 K / 0
   reference, in the same direction as the RAW slider (higher Kelvin warms).
   "As Shot" on a standard image therefore means no correction at all.
3. 8-channel B&W mix (red, orange, yellow, green, aqua, blue, purple, magenta) with
   click-and-drag targeted adjustment on the image
4. **Clarity via fast local Laplacian pyramid** (Aubry et al. approximation, as in
   darktable's local-contrast module — implemented from the papers, not their GPL code)
5. Brush-based local adjustments: size / feather / flow / density, eraser; per-mask
   exposure, contrast, highlights, shadows, clarity
6. Two-tone toning: shadows hue+sat, highlights hue+sat, balance
7. Histogram with clipping indicators, before/after toggle
8. Library persistence (SQLite) + undo, 16-bit TIFF / JPEG / PNG export

Deferred: tone curve, texture/dehaze, grain, vignette, sharpening/NR, linear/radial
gradients, range masks, AI masks.

## Non-negotiable engineering principle: headless first

Everything in the imaging core must run and be verifiable **without the GUI**:

- `grayroom` CLI can decode a DNG, apply an edit (from the library, an explicit
  `--edit file.json`, and/or `--set key=value` overrides), and export PNG/JPEG/16-bit
  TIFF.
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
    Versioned (`"version": 1`). Persisted as a JSON blob in the library (see M6).
  - `Masks/` — brush strokes as vector polylines (points + per-point radius/pressure,
    feather/flow/density), stamp-model rasterizer into `r16Float` mask textures,
    parameter-delta accumulation (below).
  - `Export/` — ImageIO: 16-bit TIFF, PNG, JPEG with correct color space tagging.
- **`GrayroomLibrary`** (library) — the SQLite catalog (GRDB): hashing, schema,
  import, developments, tags, colors. Depends on `GrayroomCore`; Core stays DB-free.
- **`grayroom`** (executable) — swift-argument-parser CLI: `render`, `probe`,
  library commands.
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
- **M6 — library.** See below.

## M6 — Library (organization)

A single SQLite database (GRDB, WAL) is the source of truth for edits and
organization. There are no sidecars. Default location
`~/Library/Application Support/Grayroom/library.sqlite`; every entry point accepts an
explicit DB path so tests and the CLI can use throwaway databases. The grid's
pictures are the one thing kept outside it — `previews.sqlite`, beside the library
file — because they are derived data, rebuilt on demand, and nothing is lost by
deleting them (stage 3).

### Identity

A photo is identified by the **SHA-256 of the whole file** (CryptoKit, streamed in
1 MB chunks; disk-bound on Apple Silicon). The hash is the external identity (dedupe
on import, CLI addressing); tables use integer rowid keys internally. The same file
at two paths is one photo with two locations. Locations are trusted: we never
re-stat or re-hash a stored path, and a missing file is simply an error at open time.

### Schema (`PRAGMA user_version` migrations via GRDB)

```
cameras      id, make, model                          UNIQUE(make, model)
photos       id, hash BLOB UNIQUE, byte_size, original_name, imported_at, captured_at,
             camera_id → cameras (nullable), width, height,
             latitude, longitude, altitude (nullable),
             color INTEGER DEFAULT 0 (0 unlabeled, 1 red, 2 yellow, 3 green, 4 blue, 5 purple)
locations    id, photo_id → photos (cascade), path TEXT UNIQUE
developments id, photo_id → photos (cascade), ordinal, edit_json (json_valid, EditState),
             created_at, updated_at                   UNIQUE(photo_id, ordinal)
tags         id, name UNIQUE COLLATE NOCASE
photo_tags   photo_id → photos, tag_id → tags          PRIMARY KEY(photo_id, tag_id)
```

A photo has any number of locations (including zero) and any number of
**developments** (a development = one `EditState`; common counts are 0 and 1).
Developments are JSON blobs because `EditState` already decodes tolerantly;
`json_extract` is available if we ever need
to query inside. Color is a single-valued Lightroom-style label (how winners are
picked); tags are free-form many-to-many. No ratings for now.

### Stages

1. `GrayroomLibrary` target: GRDB dependency, `FileHash`, `Library` (open/migrate),
   records (`Camera`, `Photo`, `Location`, `Development`, `Tag`), `Importer` (hash →
   upsert photo/location, metadata incl. capture date, camera, GPS via the decoder's
   probe), operations (tags, color, developments, queries). Tests on a temp DB.
2. CLI: `import`, `ls` (filter by color/tag/camera), `tag`, `color`, `developments`;
   `render` takes its edit from the library (`--development`) or `--edit file.json`.
   Sidecar code removed entirely. App: `open` hashes, looks up/creates the photo,
   loads/autosaves development #1 from the library.
3. **Library module.** The app has Lightroom's two modules and Lightroom's keys
   for them: `g` for the Library grid, `d` for Develop, both as bare-key menu
   items (View › Library / Develop) so they work wherever the focus is. It opens
   in the Library unless launched at a file (argument or Finder), which is a
   request to develop that file.

   - `PhotoCatalog` (in `GrayroomUI`) holds the whole library in RAM — one
     `CatalogPhoto` per photo, sorted by capture date with undated frames last —
     built from a single `Library.catalogSnapshot()`: the photo rows plus the
     aggregates that go with them (every location, development count,
     development #1's fingerprint, tags). Locations come back as one ordered
     scan grouped in Swift rather than a `group_concat`, because a path may
     contain any byte but `/`. No query while scrolling; selection is a set of
     row ids.
   - **Folders panel.** Lightroom's left panel, reduced to its three sources: a
     Catalog section ("All Photographs" and its count), the folder tree, and a
     "Missing" row for the photos the library remembers and has no file for —
     drawn even at zero, greyed. `FolderTree` (in `GrayroomUI`) builds it from
     the catalog in one pass: roots are volumes (`/` under the boot volume's
     name, `/Volumes/<x>` beside it), a chain of directories with nothing in it
     but one subdirectory is drawn as one row named after the joined path
     ("Users/schani/Pictures"), and every row carries the number of *distinct*
     photos in it or below it. Selecting a row filters the grid
     (`FolderSelection` = the catalog, one folder and everything under it, or
     the missing files); the grid's highlight keeps only what is still on
     screen, the arrows and ⌘A span the filtered list, and the bottom bar
     counts it. The panel is mouse-driven — the arrows always belong to the
     grid — and it shows and hides with the standard title-bar button, ⌥⌘S, or
     View › Show/Hide Folders. `LibraryBrowserState` holds all of that state
     (selection, disclosure, filtered ids, highlight) with no SwiftUI in it, so
     every transition is an XCTest.
   - Grid: adaptive `LazyVGrid`, thumbnail-size slider (same default as the
     import window), "N photos · M selected", a cell per photo showing the
     picture fitted in a square, the filename, a badge when the photo has a
     development, and an exclamation badge when its file is missing.
   - Selection: `GridSelection<ID>` — plain click, shift-range in displayed
     order, cmd-click toggle, ⌘A, arrows by one/by a row and shift-arrow to grow
     the range from a fixed anchor (Finder/Lightroom semantics: the anchor stays,
     the moving end walks) — shared with the import window, which keeps its own
     checkbox semantics on top.
   - The grid itself is `ThumbnailGrid`, shared by both windows: adaptive
     layout, the column arithmetic the arrows need, scroll-to-a-cell, and a
     `ClickCatcher` `NSView` behind each cell that reads the modifiers off the
     real `NSEvent` (a tap gesture cannot see them).
   - The keyboard is **not** view focus. One local `NSEvent` monitor
     (`KeyRouter`) dispatches every bare key by key window and mode, so the
     arrows keep working after a click on the toolbar or the size slider, and
     stands aside for text fields, sheets and panels.
   - Colour labels, Lightroom's keys: `6`/`7`/`8`/`9` = red/yellow/green/blue,
     purple menu-only (Lightroom gives it no key), the same key again clears the
     label, and `1`–`5` are left alone because they are Lightroom's star
     ratings. The keys work on the highlight in the grid and on the open photo
     in Develop, where the status bar carries a dot for it. Photo › Set Color
     Label holds the same commands.
   - **Development-aware previews.** The grid shows what a photo *looks like*,
     which for a developed photo is not what the camera's embedded JPEG says. A
     preview is therefore one of two things, and the row records which:
     `source = 0` for the camera's embedded preview (a photo with no
     development) and `source = 1` for this app's pipeline run over development
     #1, stored alongside the `edit_fingerprint` it was rendered from. A stored
     preview is **current** iff there is no development and the source is
     embedded, or there is one and the source is rendered with a matching
     fingerprint; anything else is rebuilt. Deleting the development sends the
     cell back to the embedded preview by that same rule, with no case of its
     own.
   - The fingerprint is `EditState.fingerprint`: SHA-256 of the edit's canonical
     JSON, which is `jsonData()` — sorted keys, and byte for byte what the
     library stores in `developments.edit_json`. So `catalogSnapshot()` hashes
     the stored text directly (`EditState.fingerprint(ofEditJSON:)`) rather than
     decoding a hundred thousand edits to draw a grid, and the two roads reach
     the same 32 bytes.
   - `previews.sqlite` (GRDB, WAL, its own `DatabasePool`) sits beside
     `library.sqlite`:
     `previews(photo_id PK, source, edit_fingerprint, width, height, jpeg,
     updated_at)`. It is a separate file because it is derived data — two orders
     of magnitude larger than the catalogue, rewritten constantly, and worth
     nothing if lost. Nothing in SQLite can cascade across files, so
     `Library.previewStore` is the hook that takes a deleted photo's preview
     with it. `grayroom previews stats` / `previews clear` are the debugging
     handles.
   - `PreviewBuilder`: `NSCache` (256 MB, cost = real bytes, keyed by photo *and*
     fingerprint) in front of the store, and the store in front of the two
     generators — `EmbeddedPreview.thumbnail` (ImageIO, never the RAW decoder)
     or the real `Renderer` at 512 px, q 0.85, sRGB, aspect preserved. Requests
     are coalesced per photo and carry an `isStillNeeded` check so scrolling
     away abandons the read; the queue is a **stack**, so the cell the user is
     looking at now is served before everything it flew past. Rendered previews
     run on a `RenderService` queue of their own and are held back while the
     develop view is busy, so an autosave's rebuild can never land in the middle
     of a slider drag. One "Building previews" task appears in the activity
     centre while it is busy.
   - `GRAYROOM_SELFTEST=library` drives all of it in a throwaway home, as an
     accessory app whose windows sit below the desktop so a run never
     interrupts the user: import, then **real mouse events** (click,
     shift-click, cmd-click, double-click,
     with the modifier flags on the events) and **real key events** (arrows,
     shift-arrows, ⌘A, `8` → green in RAM *and* in SQLite, `8` again → cleared,
     `d` → Develop on that photo, `6` → red, `g` → back to the grid with it
     still highlighted). Return is asserted *not* to open Develop. It then
     checks the previews end to end: every cell the grid built has a `source = 0`
     row in `previews.sqlite` at 512 px with no fingerprint; developing one photo
     (+2 EV, autosaved) turns *its* row into a `source = 1` one whose fingerprint
     is development #1's; and the picture the grid holds afterwards is measurably
     brighter than the embedded preview it replaced. Then the Folders panel: the
     rows it draws, read back through **accessibility** (name and count), a real
     click on a subfolder filtering the grid to the one photo staged into it,
     its parent restoring the rest, the arrows still moving the *grid* after
     that click, the folder surviving `d`/`g`, a location removed through the
     library API turning up under Missing, and the panel folding away on ⌥⌘S
     and coming back.

   Still later: filtering (by colour, tag, camera, date), collections, the
   filmstrip in Develop, and sorting other than capture time.

## Testing inputs

`testdata/` (gitignored) holds copies of a few personal Leica DNGs for smoke tests;
unit tests use synthetic textures generated in-code, so CI-style runs need no DNGs.

## License notes

Apple frameworks only in v1 (no LibRaw needed while CIRAWFilter covers the Leica
files). darktable/RawTherapee are **reference reading only** — algorithms come from
the published papers (Paris/Hasinoff/Kautz 2011; Aubry et al. 2014; He et al. guided
filter if ever needed). No GPL code enters this repo.
