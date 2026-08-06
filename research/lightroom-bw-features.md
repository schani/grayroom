# Adobe Lightroom Classic — B&W Processing Feature Inventory

All facts below are drawn from Adobe's official Lightroom Classic documentation (fetched via archived copies of helpx.adobe.com, current as of the Feb 2025 page revisions) plus reputable secondary sources, cited inline. Slider ranges marked "(UI)" are the well-known values shown in the application UI; Adobe's help pages mostly describe behavior without printing numeric ranges, so where a range is not confirmed by a cited source I say so.

---

## 1. B&W Conversion

**Treatment mode.** In the Develop module's Basic panel, the Treatment control has two states: Color and Black & White. Selecting **Black & White** (keyboard shortcut **V**) converts the photo to grayscale non-destructively; the underlying color data remains and drives the B&W Mix ([Adobe: Work with image tone and color](https://helpx.adobe.com/lightroom-classic/help/image-tone-color.html)).

**B&W Mix panel.** The HSL/Color panel becomes the **B&W panel** (panel group header "HSL/Color/B&W") after conversion. Per Adobe: "Black & White Mix in the B&W panel converts color images to monochrome grayscale images, providing control over how individual colors convert to gray tones… Drag the individual color sliders to adjust the gray tone for all similar colors in the original photo" ([Adobe](https://helpx.adobe.com/lightroom-classic/help/image-tone-color.html)). The panel contains **eight sliders: Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta**, each controlling the gray brightness of that source-color range ([CaptureLandscapes](https://www.capturelandscapes.com/hsl-color-panel-in-lightroom/), [iPhotography](https://www.iphotography.com/blog/edit-black-and-white-photos-lightroom/)). Range: **−100..+100, default 0** (UI; not printed in the Adobe help text retrieved).

**Auto mix.** Clicking **Auto** "sets a grayscale mix that maximizes the distribution of gray tones," which Adobe describes as a good starting point. A preference — "Apply Auto Mix When First Converting To Black And White" (Preferences > Presets) — applies it automatically on conversion ([Adobe](https://helpx.adobe.com/lightroom-classic/help/image-tone-color.html)).

**Targeted Adjustment Tool (TAT).** A TAT sits in the upper-left of the B&W panel: click it, hover over an image area, then click and **drag up/down (or press Up/Down arrows) to lighten or darken the grays for all similarly colored areas** of the original photo — Lightroom moves the underlying color-channel sliders for you. The same TAT mechanism exists in the Tone Curve and HSL panels ([Adobe](https://helpx.adobe.com/lightroom-classic/help/image-tone-color.html)).

**Two routes to B&W** (worth noting): Treatment = Black & White (enables B&W Mix), or applying a monochrome **profile** (see §5) — and desaturating via Saturation −100 is a third, inferior route that keeps the Color mixer instead of the B&W mixer.

---

## 2. Global Tonal Controls

From [Adobe's tone/color page](https://helpx.adobe.com/lightroom-classic/help/image-tone-color.html), Process Version 2012+ (current) Basic-panel tone controls:

| Slider | Range | Adobe's description |
|---|---|---|
| Exposure | **−5.00..+5.00 stops** (UI; the ±5-stop span is corroborated at [Lightroom Queen forums](https://www.lightroomqueen.com/community/)) | "Sets overall image brightness. Values are in increments equivalent to aperture values (f-stops)… +1.00 is similar to opening the aperture 1 stop." |
| Contrast | −100..+100 (UI) | "Increases or decreases image contrast, mainly affecting midtones." |
| Highlights | −100..+100 (UI) | "Adjusts bright image areas. Drag left to darken highlights and recover 'blown out' highlight details." |
| Shadows | −100..+100 (UI) | "Adjusts dark image areas… drag right to brighten shadows and recover shadow details." |
| Whites | −100..+100 (UI) | "Adjusts white clipping." |
| Blacks | −100..+100 (UI) | "Adjusts black clipping." |
| Texture | −100..+100 (UI) | "Smoothens or accentuates textured details… color or tonality does not change" ([Adobe masking page](https://helpx.adobe.com/lightroom-classic/help/masking.html)). |
| Clarity | −100..+100 (UI) | "Adds depth to an image by increasing local contrast… increase until you see halos near edge details, then reduce slightly." |
| Dehaze | −100..+100 (UI) | "Controls the amount of haze. Drag right to remove haze; left to add haze." |

An **Auto** button sets the tone sliders "to maximize the tonal scale and minimize highlight and shadow clipping." Slider values can be nudged with arrow keys; double-clicking a slider resets it. (Vibrance/Saturation, −100..+100, still exist but are moot in B&W treatment; Saturation −100 = monochrome per Adobe.)

**Texture vs. Clarity vs. Dehaze (technical):**
- **Texture** was developed by Adobe's ACR team (lead engineer Max Wendt) from a skin-*smoothing* prototype ("Smoothing" slider) and targets **mid-frequency detail** — it enhances/blurs medium-scale detail while deliberately sparing the finest high-frequency content (so it avoids amplifying noise) and, per Adobe, does not change color or tonality/saturation ([PetaPixel launch coverage](https://petapixel.com/2019/05/14/adobe-adds-texture-control-slider-to-lightroom-and-camera-raw/), [Adobe blog "From the ACR Team: Introducing the Texture Control"](https://theblog.adobe.com/from-the-acr-team-introducing-the-texture-control/), [Adobe masking page](https://helpx.adobe.com/lightroom-classic/help/masking.html)).
- **Clarity** boosts **midtone-weighted local contrast** over a larger radius ("thicker edges") than Texture, and measurably affects luminance and saturation; it can produce halos at extremes ([PhotoshopCafe comparison](https://photoshopcafe.com/texture-clarity-and-dehaze-in-lightroom-acr-explained-the-ultimate-comparision/), [PetaPixel explainer](https://petapixel.com/2021/01/05/understanding-the-differences-between-clarity-texture-and-dehaze/)).
- **Dehaze** operates mostly on **low-frequency contrast** and is based on a **physical model of atmospheric light transmission/scattering**; it shifts contrast and saturation strongly and can darken and tint images (negative values add haze — an ability formally added in Process Version 5) ([PhotoshopCafe](https://photoshopcafe.com/texture-clarity-and-dehaze-in-lightroom-acr-explained-the-ultimate-comparision/), [Adobe process versions](https://helpx.adobe.com/camera-raw/using/process-versions.html)).
- Frequency ordering, per these sources: Texture (highest of the three, minus fine noise) → Clarity (mid) → Dehaze (low).

**Tone Curve panel** ([Adobe](https://helpx.adobe.com/lightroom-classic/help/image-tone-color.html)):
- **Parametric curve**: four Region sliders — **Highlights, Lights, Darks, Shadows** (each −100..+100, UI). "Darks and Lights affect mainly the middle region of the curve; Highlights and Shadows affect mainly the ends." Three **split controls** at the bottom of the graph move the boundaries between the four regions.
- **TAT**: click the targeted adjustment icon, then drag on the photo (or arrow keys) to raise/lower all similar tones.
- **Point curve**: presets Linear / Medium Contrast / Strong Contrast; Edit Point Curve mode lets you click to add points, drag to move, right-click to delete, "Flatten Curve" to reset. A **Channel menu** lets you edit the composite or the **Red, Green, Blue channels individually** (RGB channel curves still function on B&W-treated images and act as a toning mechanism — the composite curve is the tonally relevant one for B&W). Input/output values are displayed in the upper-left as you drag (shown as percentages in LR Classic's UI — the % readout is UI behavior, not stated on the help page).

**Histogram & clipping** ([Adobe](https://helpx.adobe.com/lightroom-classic/help/image-tone-color.html)): luminance-percentage histogram (0% left to 100% right) with RGB channel layers; you can **drag directly in histogram zones** to move the corresponding Basic slider. **Clipping indicators** at top left (shadow/black) and right (highlight/white): indicator turns white when all channels clip, colored when 1–2 channels clip; click to lock the preview — clipped blacks show blue, clipped whites show red in the image. Alt/Option-dragging Whites/Blacks shows a threshold clipping view. RGB readout under the histogram shows per-pixel percentages (optionally Lab values via right-click).

---

## 3. Local Adjustments / Masking

Source: [Adobe: Lightroom Classic Masking tool](https://helpx.adobe.com/lightroom-classic/help/masking.html) (current mask-based system, introduced Oct 2021, LrC 11 — [Adobe what's-new](https://helpx.adobe.com/lightroom-classic/help/whats-new/2022.html)) and [Apply local adjustments](https://helpx.adobe.com/lightroom-classic/help/apply-local-adjustments.html).

**Mask creation tools:**
- **AI/automatic**: **Select Subject**, **Select Sky**, **Select Background**, **Select Objects** (Brush Select — rough-brush over the object — or Rectangle Select), **Select People** (detects each person; per-person sub-regions selectable: Face Skin, Body Skin, Eyebrows, Eye Sclera, Iris & Pupil, Lips, Teeth, Hair, Facial Hair, Clothes), and **Select Landscape** with sub-features **Sky, Snow, Architecture, Vegetation, Water, Natural Ground, Artificial Ground, Mountains**. AI masks can be batch-applied via copy/paste/sync (LrC 11.4+) and refreshed with "Update AI Masks."
- **Manual**: **Brush**, **Linear Gradient**, **Radial Gradient** (with Feather slider; adjust inside or outside the ellipse).
- **Range masks**: **Color Range** (sample with selector; click-drag an area; Shift-click up to **5 color samples**; Alt/Option-click removes a sample; **Refine** slider narrows/broadens the color range), **Luminance Range** (endpoint slider defining the selected brightness band, click-drag sampling, **Show Luminance Mask** B&W visualization; the endpoint slider also has feather/smoothness handles), **Depth Range** (only for photos with embedded depth maps, e.g. iOS Portrait-mode HEIC; endpoint slider, Depth Range Selector, **Show Depth Mask**). Range masks require Process Version 4+ ([Adobe process versions](https://helpx.adobe.com/camera-raw/using/process-versions.html)).

**Brush parameters** ([Adobe](https://helpx.adobe.com/lightroom-classic/help/masking.html), [local adjustments page](https://helpx.adobe.com/lightroom-classic/help/apply-local-adjustments.html)):
- **Size** — brush-tip diameter in pixels (UI range 0.1–100 units).
- **Feather** — soft-edged transition; the gap between inner and outer brush circles shows the feather amount (0–100, UI).
- **Flow** — "rate of application"; strokes build up (e.g., Flow 20 → first stroke 20% strength, next stroke 40%) (0–100, UI).
- **Density** — caps maximum stroke opacity (e.g., Density 40 → brush never paints beyond 40% opacity) (0–100, UI).
- **Auto Mask** — "confines brush strokes to areas of similar color" (edge-aware painting); improved noise handling in PV4.
- A/B brush presets plus an **Erase** brush; Erase-mode painting subtracts within a brush component.

**Combining masks:** Each mask is a container of components. From the Masks panel or per-mask menu: **Add** (union with any tool), **Subtract** (erase with any tool), **Intersect Mask with** (any tool or another mask; also via Alt/Option), **Invert Mask**, **Duplicate**, **Duplicate and Invert**, Rename, Hide, Delete, Delete Empty Masks. Overlay modes: Color Overlay, Color Overlay on B&W, Image on B&W, Image on Black, Image on White, White on Black, with selectable overlay color ([Adobe](https://helpx.adobe.com/lightroom-classic/help/masking.html)).

**Adjustments available inside a mask** (segmented into Tone / Color / Effects / Detail sub-panels, per [Adobe](https://helpx.adobe.com/lightroom-classic/help/masking.html)): **Temp, Tint, Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Texture, Clarity, Dehaze, Hue (with "Use Fine Adjustment"), Saturation, Color (tint swatch — "the Color effect is preserved if you convert the photo to black and white"), Sharpness (negative = blur), Noise (luminance NR), Moiré, Defringe, Grain Amount** (local grain amount; its Roughness and Size are shared with the global Effects panel), and a **local point Curve** with a **Refine Saturation** slider. Local **Exposure spans −4..+4 stops** (vs. ±5 global); most other local sliders run −100..+100 (UI; the ±4 figure corroborated at [Lightroom Queen](https://www.lightroomqueen.com/community/)). There is no local Vibrance (Saturation only). Each mask also has an overall Amount slider that scales all of that mask's settings (UI feature; range not confirmed in the retrieved docs). The legacy pre-11 tools (Adjustment Brush, Graduated/Radial Filter + Range Mask dropdown) exposed the same effect sliders ([Adobe local adjustments](https://helpx.adobe.com/lightroom-classic/help/apply-local-adjustments.html)).

---

## 4. Toning (Sepia / Selenium-style "Two-Tone")

**Color Grading panel** (replaced Split Toning in **LrC 10, October 2020** — [The Lens Lounge](https://thelenslounge.com/2020-lightroom-update-color-grading/), [Julieanne Kost](https://jkost.com/blog/2020/10/lightroom-classic-v10.html)):
- **Four wheels**: Shadows, Midtones, Highlights (3-Way view) + **Global**; each wheel sets **Hue** (0–360°) and **Saturation** (0–100, center→edge) and has a **Luminance** slider beneath it (−100..+100, UI) to darken/lighten that range. Adobe's grayscale-toning procedure: "adjust the Hue and Saturation for the Highlights, Midtones, and Shadows… The extreme shadows and highlights remain black and white" ([Adobe](https://helpx.adobe.com/lightroom-classic/help/image-tone-color.html)).
- **Blending** (0–100, default 50 — UI): "sets the amount of overlap between shadows and highlights. Drag right to maximize the overlap" ([Adobe](https://helpx.adobe.com/lightroom-classic/help/image-tone-color.html)); at 0 the tint bands stay nearly pure, at 100 they cross over ([Kost](https://jkost.com/blog/2020/10/lightroom-classic-v10.html)).
- **Balance** (−100..+100, UI): ">0 increases the effect of the highlights, <0 increases the effect of the shadows" ([Adobe](https://helpx.adobe.com/lightroom-classic/help/image-tone-color.html)) — i.e., it shifts which tones count as shadow/highlight.
- Modifiers: Option/Alt-drag = fine adjust; Shift-drag = saturation only; Cmd/Ctrl-drag = hue only; Option/Alt+arrows nudge hue/sat by 1 (with Shift, by 10) ([Adobe](https://helpx.adobe.com/lightroom-classic/help/image-tone-color.html)).
- Works on grayscale-mode (single-channel) imports too; LrC treats and exports them as RGB ([Adobe](https://helpx.adobe.com/lightroom-classic/help/image-tone-color.html)).

**Legacy Split Toning panel** (LrC ≤9): **Highlights Hue (0–360) / Saturation (0–100)**, **Shadows Hue / Saturation**, and **Balance (−100..+100)**; Option/Alt-dragging Hue previewed at full saturation. On upgrade, old Split Tone settings are mapped onto the Shadows/Highlights wheels (plus Blending where needed) "to achieve a perfect match," so existing sepia/selenium-style edits render identically ([Kost](https://jkost.com/blog/2020/10/lightroom-classic-v10.html), [The Lens Lounge](https://thelenslounge.com/2020-lightroom-update-color-grading/)). This two-wheel (shadows+highlights) usage is exactly the classic "two-tone" sepia/selenium workflow.

---

## 5. Other B&W-Relevant Features

**Grain** (Effects panel, from [Adobe: retouch/effects](https://helpx.adobe.com/lightroom-classic/help/retouch-photos.html)): "stylistic effect reminiscent of particular film stocks"; can also mask resampling artifacts.
- **Amount** (0–100, UI; 0 disables), **Size** (0–100, default 25, UI) — "at sizes of 25 or greater, blue is added to make the effect look better with noise reduction," **Roughness** (0–100, default 50, UI) — "controls the regularity of the grain… right = more uneven." Adobe advises checking grain at multiple zoom levels. Grain Amount is also available per-mask; Size/Roughness stay global ([Adobe masking](https://helpx.adobe.com/lightroom-classic/help/masking.html)).

**Post-Crop Vignetting** (Effects panel, [Adobe](https://helpx.adobe.com/lightroom-classic/help/retouch-photos.html)): applies to the cropped image and "adaptively adjusts the exposure… preserving original image contrast."
- **Style**: **Highlight Priority** (enables highlight recovery, may shift colors — moot in B&W), **Color Priority** (minimizes color shifts, no highlight recovery), **Paint Overlay** (blends with black/white pixels; "can result in a flat appearance").
- Sliders: **Amount** (−100..+100; negative darkens corners), **Midpoint** (0–100, default 50), **Roundness** (−100..+100; higher = more circular), **Feather** (0–100, default 50), **Highlights** (0–100; Highlight/Color Priority only, active with negative Amount — preserves highlight contrast, e.g. candles/lamps). (Ranges are UI; behavior text is Adobe's.) The Lens Corrections panel separately offers profile-based and Manual lens **vignette correction** (Amount/Midpoint).

**Detail panel — Sharpening** ([Adobe](https://helpx.adobe.com/lightroom-classic/help/retouch-photos.html)): work at ≥100% zoom.
- **Amount** (0–150, UI; 0 = off; default 40 for raw), **Radius** (0.5–3.0, default 1.0, UI) — size of sharpened detail, **Detail** (0–100, default 25, UI) — "how much high-frequency information is sharpened… higher values make textures more pronounced," **Masking** (0–100, UI) — edge mask; "at 100, sharpening is mostly restricted to areas near the strongest edges." **Alt/Option-drag any of these to see a grayscale visualization** (for Masking: white = sharpened, black = masked out).
- Output sharpening (Screen/Matte/Glossy, Low/Standard/High) is separate, at export/print.

**Detail panel — Noise Reduction** ([Adobe](https://helpx.adobe.com/lightroom-classic/help/retouch-photos.html)): Luminance section — **Luminance** (0–100), **Detail** (0–100, default 50) = luminance noise threshold, **Contrast** (0–100). Color section — **Color** (0–100, default 25), **Detail** (0–100, default 50), plus **Smoothness** (0–100, default 50). Chroma NR still matters for B&W because color noise would otherwise convert to luminance blotching. (Current versions also add AI **Denoise**/Raw Details via the Enhance dialog — separate from these sliders.)

**Camera profiles** ([Adobe tone/color page](https://helpx.adobe.com/lightroom-classic/help/image-tone-color.html), [Adobe Lightroom profiles doc](https://helpx.adobe.com/lightroom/web/edit-photos/apply-effects/use-profiles.html), [Mastering Lightroom](https://mastering-lightroom.com/black-white-profiles-lightroom-classic/)): since LrC 7.3 (April 2018) the Profile control sits at the top of the Basic panel with a Profile Browser. Groups include **Adobe Raw** (Adobe Color, **Adobe Monochrome**, Landscape, Neutral, Portrait, Standard, Vivid), **Camera Matching** (including manufacturers' in-camera monochrome simulations where available), **Adaptive**, and creative groups **Artistic, B&W, Modern, Vintage** — the **B&W group has ~17 creative black-and-white profiles (B&W 01–17)** (count is version-dependent). Creative profiles (including the B&W group) get an **Amount slider, 0–200** ([Adobe](https://helpx.adobe.com/lightroom/web/edit-photos/apply-effects/use-profiles.html)). **Setting Treatment to Black & White on a raw file applies Adobe Monochrome by default** (or a raw default you configure) ([Mastering Lightroom](https://mastering-lightroom.com/black-white-profiles-lightroom-classic/)). Profiles are applied as a rendering starting point and move no sliders.

**Virtual Copies and Snapshots** let you keep a color and one or more B&W interpretations of the same raw side-by-side without duplicating the file, and record develop states, respectively ([Adobe Develop module tools](https://helpx.adobe.com/lightroom-classic/help/develop-module-tools.html)).

---

## 6. Processing Pipeline / Process Versions

From [Adobe: Process versions in Camera Raw](https://helpx.adobe.com/camera-raw/using/process-versions.html) (LrC shares the ACR engine; LrC labels them Version 1–6 in the Calibration panel):

- **PV1 (2003)** — original engine (ACR ≤5.x); tone controls: Exposure, Recovery, Fill Light, Blacks, Brightness, Contrast.
- **PV2 (2010)** — improved sharpening and noise reduction (ACR 6).
- **PV3 (2012)** — current tone model: Highlights/Shadows/Whites/Blacks/Exposure/Contrast, new tone-mapping for high-contrast scenes; local WB/Highlights/Shadows/Noise/Moiré (ACR 7 / LR 4).
- **PV4** — Range Mask support and improved Auto Mask noise handling (ACR 10 / LrC 7.3-era).
- **PV5** — improved high-ISO rendering (removes purple shadow casts) and bidirectional Dehaze (add haze with negative values) (ACR 11 / LrC 8).
- **PV6** — "reduces banding when using the Color Mixer and **B&W Mixer** adjustments" (ACR 15.4, June 2023 / LrC 12.4). Direct official evidence that the B&W Mixer is an internal pipeline stage whose math Adobe revises per process version.

**What is documented about ordering:** Adobe states edits are parametric and non-destructive; the B&W mix is computed from the demosaiced, white-balanced color data — which is why Temp/Tint, camera Calibration sliders, and the chosen profile all still change a B&W-treated rendering, and why the mixer can separate colors that have identical luminance. **Adobe does not publish a full ordered pipeline specification.** The widely reported (but not officially documented — treat as uncertain) internal order is: decode/linearize → demosaic → white balance → camera profile/calibration → tonal controls (Exposure/Contrast/H/S/W/B, Texture/Clarity/Dehaze) → tone curve → HSL / B&W mix → color grading → detail (sharpen/NR) → lens corrections/effects (grain, post-crop vignette), applied in a **fixed sequence regardless of the order in which you move sliders**.

---

### Key sources
- Adobe: [Work with image tone and color](https://helpx.adobe.com/lightroom-classic/help/image-tone-color.html)
- Adobe: [Masking tool](https://helpx.adobe.com/lightroom-classic/help/masking.html) · [Apply local adjustments](https://helpx.adobe.com/lightroom-classic/help/apply-local-adjustments.html) · [Oct 2021 what's-new (mask system)](https://helpx.adobe.com/lightroom-classic/help/whats-new/2022.html)
- Adobe: [Retouch photos](https://helpx.adobe.com/lightroom-classic/help/retouch-photos.html) · [Process versions](https://helpx.adobe.com/camera-raw/using/process-versions.html) · [Profiles](https://helpx.adobe.com/lightroom/web/edit-photos/apply-effects/use-profiles.html) · [Develop module tools](https://helpx.adobe.com/lightroom-classic/help/develop-module-tools.html)
- Julieanne Kost (Adobe): [Color Grading in LrC v10](https://jkost.com/blog/2020/10/lightroom-classic-v10.html); [The Lens Lounge: Color Grading update](https://thelenslounge.com/2020-lightroom-update-color-grading/)
- Texture/Clarity/Dehaze internals: [PetaPixel (Texture launch)](https://petapixel.com/2019/05/14/adobe-adds-texture-control-slider-to-lightroom-and-camera-raw/) · [Adobe blog: Introducing the Texture Control](https://theblog.adobe.com/from-the-acr-team-introducing-the-texture-control/) · [PhotoshopCafe comparison](https://photoshopcafe.com/texture-clarity-and-dehaze-in-lightroom-acr-explained-the-ultimate-comparision/) · [PetaPixel explainer](https://petapixel.com/2021/01/05/understanding-the-differences-between-clarity-texture-and-dehaze/)
- B&W profiles/mix specifics: [Mastering Lightroom: B&W profiles](https://mastering-lightroom.com/black-white-profiles-lightroom-classic/) · [CaptureLandscapes: HSL/Mixer guide](https://www.capturelandscapes.com/hsl-color-panel-in-lightroom/)

**Flagged uncertainties:** exact numeric ranges marked "(UI)" come from the application interface as reported by secondary sources, not Adobe's help text; the per-mask Amount slider range, point-curve percentage readout, exact count of B&W creative profiles, and the detailed internal pipeline stage order are not confirmed by official documentation.
