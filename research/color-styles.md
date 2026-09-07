# Colour styles — research for the style module

The colour treatment is a fixed set of preset renderings; the user picks one.
This file records what the established colour looks are, precisely enough to
reproduce them with four parametric blocks, and which ten span the space.
Claims marked *(inference)* are not from a source.

## Building blocks

Every look below decomposes into:

| Block | Carries |
|---|---|
| Style tone curve | contrast, black point (lifted / anchored / crushed), highlight roll-off |
| Global saturation, vibrance | overall chroma; vibrance protects skin while pulling the surround |
| 8 hue bands × (hue shift, saturation, luminance) | all per-colour character: the Kodak/Fuji green split, teal skies, magenta suppression |
| Split tone (shadow tint, highlight tint) | colour casts, and crossovers such as amber shadows under cyan highlights |

Black point is the strongest single discriminator between looks. The second is
the green: Kodak stocks pull greens toward yellow, Fuji stocks toward blue/cyan.
The third is where the cast lives: shadows only, highlights only, both ends the
same, or a crossover.

This matches how the industry parametrises looks. A Fujifilm recipe is a
film-simulation base (the band table) plus Color −4…+4 (global saturation),
Highlight/Shadow Tone (curve ends), DR 100/200/400 (roll-off) and a two-axis
white-balance shift (a global cast). An Adobe DCP creative profile is a
hue/saturation/value delta grid applied after exposure and before its tone
curve, i.e. a fine-grained band table plus a curve. A print-film emulation LUT
is three per-channel density curves with different gammas plus dye crosstalk:
the gamma mismatch is the split tone, the crosstalk is the band table.

Two traits do not map and are out of scope: halation (CineStill 800T) is
spatial, and tungsten balance (Vision3 500T) is white balance upstream of the
stages. Local tone mapping (Olympus Dramatic Tone, Ricoh HDR Tone) is not a
colour look.

**Per-channel curve.** A style curve applied per channel, not as a
luminance-ratio-preserving gain, desaturates highlights toward white on its own
shoulder. That is the "path to white" of every filmic transform and what
Grayroom's ratio-preserving tone stage lacks (DEVIATIONS.md, tone #5).

## Looks

Bands: R O Y G Aq B P M. `→` is a hue rotation.

### Fujifilm film simulations

| Look | Contrast | Sat | Hue biases | Shadow / highlight | Black pt | Distinctive |
|---|---|---|---|---|---|---|
| Provia | med | med | none | neutral | normal | the neutral reference |
| Velvia | high | very high | B→P; G "nuclear"; Y→G; R near clip | neutral, clips both ends | crushed | saturation ceiling |
| Astia | soft in skin, else med | above Provia | G strongly →Y; skin desaturated | flat colour contrast | crushed | soft only in skin |
| Classic Chrome | med-high, strong in shadows | low | magenta removed from B → teal; R earthy; G olive-khaki | cooler skin | normal | subtractive sky |
| Classic Neg | high both ends | med-low | G→Y-green and blue-ward; R→O; B→teal | amber shadows / cyan-blue highlights | crushed | Superia 100 model |
| Nostalgic Neg | med-low | med-high | G→Y; magenta in mids | amber shadows and amber highlights | lifted | 1970s New American Color |
| Reala Ace | med | slightly under Provia | B slightly deeper | neutral | normal | Pro Neg Std tuned up |
| Pro Neg Hi | med | med-low | R/M cut hard; G→Y; B slightly cyan | deep blacks | crushed | Pro 160NS model |
| Pro Neg Std | low | low | further R/O/M cut | soft shadow contrast | crushed | flattest skin |
| Eterna | low | low | G, M, P desaturated most; B lean cyan | lifted shadows, very long roll-off | lifted | flattest curve |
| Eterna Bleach Bypass | high | near-mono | cool metallic residue | tight range, clipped ends | crushed | contrast up, chroma gutted |

### Film stocks

Kodak rows and the Fuji rows are datasheet plus side-by-side tests; consumer
and cine rows are secondary sources.

| Stock | Contrast | Sat | Hue biases | Shadow / highlight cast | Black pt | Distinctive |
|---|---|---|---|---|---|---|
| Portra 160 | low | low-mod | R restrained, G olive | neutral-cool / creamy | lifted | neutral skin |
| Portra 400 | low | mod | skin→peach; G warm olive; B muted | warm / warm peach | lifted | longest highlight shoulder |
| Ektar 100 | high | very high | R+M hard, O held back, B deep, cyan cut | cool blue-cyan / clean | near-crushed | vivid, punishes skin |
| Kodachrome 64 | high, gentle S | high, controlled | R magenta-shifted; G olive blue-green; B restrained | untinted deep blacks | crushed | neutral blacks plus the red |
| Velvia 50 | very high | extreme | G→cyan and darker; R roll to maroon; strong sky separation | green in shadows / magenta in mids and highlights | crushed, saturated | magenta clouds over saturated blacks |
| Velvia 100 | very high | extreme | as Velvia 50 | magenta shadows | crushed | the magenta-shadow one |
| Provia 100F | med-high, linear | med | cool, cyan tinge, low separation | cool / neutral | open | calm slide |
| Pro 400H | low-med | restrained | G dense and cool → mint; skin de-warmed | cool green-cyan / clean | lifted | minty pastel at +3 stops |
| Superia X-TRA 400 | low-med | high | cool deep G; bright pinks; greys collapse into sky teal | teal, green when under / magenta-pink | lifted | teal-locked neutrals |
| Gold 200 | mod | mod-high | global golden yellow, G→Y | warm brown / yellow-gold | slightly lifted | the gold cast |
| Ultramax 400 | high | high | as Gold with truer blues, less yellow in greens | muddy / warm | neutral to slightly crushed | Gold's print family, datasheet-confirmed |
| Agfa Vista 200/400 | low-med | high | cool blue-green base, hot reds and magentas | green / clean | deeper than Kodak | 2013–2018 stock was rebadged Fuji C200 / Superia 400 |
| Cinestill 800T | low-mod | mod | daylight blue-cyan, orange sources | teal / red halation | lifted | halation, not colour |
| Vision3 500T / 250D | very low | low | 500T blue-cyan in daylight | cool / cool | very lifted | a grading base |

### In-camera modes

| Mode | Maker | Character |
|---|---|---|
| Contemporary | Leica | low-mid contrast, natural sat, reddish tint, lifted shadows |
| Classic | Leica | high contrast with low saturation, warm washed highlights |
| Eternal | Leica | punchy with a magenta tint |
| Positive Film | Ricoh | mid-high contrast, high sat, solid red, yellowish green |
| Negative Film | Ricoh | same tone parameters as Positive Film; bluish green, muted blue, lifted shadows |
| Bleach Bypass | Ricoh | very low sat, high contrast, desaturated highlights with coloured shadows |
| Retro | Ricoh | low contrast, warm, hazy lifted highlights |
| Cross Processing | Ricoh | oranges against cyan/pink casts |
| FL (Film) | Sony | contrast up; sky and greens boosted while other hues are muted |
| IN (Instant) | Sony | suppressed contrast and saturation, matte both ends |
| SH (Soft Highkey) | Sony | low contrast, vivid colour, lifted highlights |
| L.ClassicNeo | Panasonic | low-mid contrast and sat, cyan-ward muted blues, warm light skin, soft blacks |
| Bleached | Nikon | high contrast, low sat, green cast |
| Denim / Toy | Nikon | blue cast; blues to cyan (Denim) or indigo (Toy) |
| Vintage I–III | Olympus | low contrast, low sat, heavily lifted, tinted per variant |
| Instant Film | Olympus | green shadows, warm highlights, lifted |
| HNCS | Hasselblad | one universal profile, not a look |

### Software and cinema

| Look | Origin | Contrast | Sat | Hue biases | Shadow / highlight | Black pt | Distinctive |
|---|---|---|---|---|---|---|---|
| Faded matte | Capture One Matte, VSCO F/M | very low, lifted toe and lowered white | −10…−25 % | broad desat | warm-neutral or cool-green / milky | strongly lifted | milky blacks, capped whites |
| Cross-process | E-6 in C-41; VSCO P, RNI Instant | +30…50 %, blocked toe | strongly + | G sat ++ →Y; B→cyan | cyan-blue lifted / yellow-green | lifted, blue-tinted | inverted blue curve |
| Teal and orange | Bad Boys II, 2003 | med-high | near neutral | O sat +, lum +; Y +; Aq/B → ~205°, sat +; G sat −, →Y | teal / amber | crushed, cool | skin against teal |
| Bleach bypass | ENR silver retention | steep S, both ends clip | −60…−85 % | none | slight cool / neon white | crushed hard | silver mids over black |
| Print film 2383 | Kodak Vision Color Print | hard S | +15…25 % | Y sat +; G→Y | cool-cyan / golden | dense | golden highlights |
| Fincher | Zodiac, Mindhunter | low slope | not desaturated | M/P sat −20…−35; Y sat +, →G | neutral 3 % black / coloured 90 % white | anchored, not crushed | yellow-green from magenta suppression |
| Nordic noir | The Bridge | low; lifted blacks, pulled whites | −20…−30, vibrance + | B/Aq→cyan, sat +; G/Y sat −−, lum − | blue-grey / milky | lifted | milky sky, amber practicals stay contained |
| Wes Anderson pastel | Asteroid City | low, soft early shoulder | neutral, vibrance + | R/M sat +, lum +; B/Aq sat −, lum +; Y/O→G, lum + | warm / chalky | lifted 4–8 % | pink and yellow lift, chalky sky |
| Mexico filter | Traffic | high | flat | Y/O sat +, lum +; G→Y hard, sat −; B/Aq sat −−, lum − | neutral / cream clip | crushed | cast in mids and highlights |
| Filmic (ARRI K1S1, Vision3) | LogC display | moderate S, long shoulder | neutral, vibrance + | R→M, sat −; O held; G cooler, sat − | slightly warm / neutral | slightly lifted | skin protected |

Adobe's own profiles: Color (default), Landscape (blues and greens, more
contrast), Portrait (skin remapped, rest as Standard), Vivid, Neutral,
Standard. The creative groups Modern 01–10, Vintage 01–10 and Artistic 01–08
are unnamed LUT looks with an Amount slider.

## Clusters

Near-duplicates, one slot each:

- Neutral: Provia, Reala Ace, Provia 100F, Sony ST/NT, Adobe Color.
- Vivid: Velvia, Velvia 50, Sony VV, Ricoh Vivid, Adobe Vivid/Landscape. Ektar splits off as red-and-blue vivid with orange held back.
- Muted chrome: Classic Chrome, Leica Chrome.
- Warm negative, lifted: Nostalgic Neg, Gold 200, Ultramax, Ricoh Retro, Leica Classic.
- Same film: Agfa Vista 400 and Superia 400; Vista 200 and C200; CineStill 800T and Vision3 500T minus halation.
- Soft portrait: Pro Neg Std, Pro Neg Hi, Portra 160/400/800, Astia's skin.
- Cool pastel: Pro 400H, Astia's greens, Superia's teal.
- Flat cinema: Eterna, Cinelike D, Nikon Flat, Vision3, Faded matte.
- Near-mono contrast: Eterna Bleach Bypass, Ricoh Bleach Bypass, Nikon Bleached, ENR.

## The ten

Neutral is not a style: it is the colour treatment with no style, the
pipeline's own rendition curve to sRGB. The ten sit beside it.

| # | Name | Modelled on | Curve | Saturation | Bands | Split tone | Subject |
|---|---|---|---|---|---|---|---|
| 1 | Vivid Slide | Velvia 50 | high S, crushed saturated blacks, hard clip | strongly + | G→cyan, lum −; R sat +, lum − on saturated reds; B sat + | slight green shadows / magenta highlights | landscape |
| 2 | Chrome | Kodachrome 64 | high, gentle S, deep untinted blacks | moderately +, controlled | R→M, sat +, lum −; G olive, sat +; B restrained | none | reportage, archival |
| 3 | Muted Chrome | Classic Chrome | med-high, strong in shadows, normal black | − | B lose magenta → teal, lum −; R earthy; G olive; skin cooler | none | documentary, travel |
| 4 | Portrait Negative | Portra 400 | low, lifted blacks, long shoulder | −, vibrance + | R/O→Y peach, sat −, lum +; G→Y olive, sat −; B muted | warm cream highlights, slight warm shadows | portraits |
| 5 | Pastel Negative | Pro 400H | low, lifted blacks | −, pastel | G→cyan mint, lum +; B sat +, lum +; R/O→M, sat − | cool cyan shadows / neutral | outdoor portrait |
| 6 | Nostalgic Negative | Nostalgic Neg, Gold 200 | med-low, lifted | med-high | G→Y; Y/O sat +, lum +; B sat − | amber shadows and amber highlights | 1970s colour |
| 7 | Retro Negative | Classic Neg, Superia | high both ends, crushed | med-low | G→Y-green; R→O; B→teal | amber shadows / cyan-blue highlights | street, snapshot |
| 8 | Soft Cinema | Eterna | low, lifted shadows, very long roll-off | low | G, M, P sat − most; B→cyan | none | cinematic |
| 9 | Teal and Orange | Hollywood grade | med-high, crushed cool blacks | near neutral | O sat +, lum +; Y sat +; Aq/B→205°, sat +; G sat −, →Y | teal shadows / amber highlights | people on location |
| 10 | Bleach Bypass | ENR, Eterna Bleach Bypass | steep S, both ends clip | −60…−85 % | none | slight cool | noir |

Coverage: crushed and lifted at both high and low saturation; warm, cool and
neutral; Kodak yellow-green (2, 4, 6) and Fuji blue-green (1, 5); casts in the
shadows only (9), at both ends alike (6), as a crossover (7), and absent
(2, 3, 8, 10); a near-monochrome bridge to the B&W treatment (10).

First alternates, in order: Cross-process (blue-lifted toe, yellow-green
highlights, high saturation), Vivid Warm (Ektar), Faded Matte (capped whites),
Fincher, Wes Anderson pastel.

## Lightroom's presentation

The Profile browser lives in the Basic panel: grid or list, hover previews on
the image, double-click applies, a star favourites a profile into the Basic
panel's Profile pop-up. Applying a profile moves no sliders; the look sits
under the user's edits. Creative profiles have an Amount slider, 0–200,
default 100; Adobe Raw profiles have none. Picking a B&W profile flips
Treatment to Black & White and swaps the Color Mixer for the B&W panel;
setting Treatment to Black & White selects Adobe Monochrome. The DCP look
table is applied after exposure and before the profile's tone curve.

## Sources

Fujifilm: <https://www.fujifilm-x.com/en-us/products/film-simulation/> ·
<https://www.fujifilm-x.com/global/stories/film-simulation-classic-chrome/> ·
<https://www.fujifilm-x.com/global/products/film-simulation/nostalgic-neg/> ·
<https://www.fujifilm-x.com/global/stories/tales-of-the-x-t4-tale-3-eterna-bleach-bypass/> ·
<https://fujifilm-dsc.com/en-int/manual/x-t5/menu_shooting/image_quality_setting/index.html> ·
<https://www.fujifilm-x.com/en-us/stories/advanced-month-4-camera-features-13-color-chrome-and-film-grain-effects/> ·
<https://www.jmpeltier.com/fujifilm-film-simulation-differences/> ·
<https://www.jmpeltier.com/classic-neg-vs-nostalgic-neg-comparison/> ·
<https://www.fujivsfuji.com/film-simulation-modes-compared> ·
<https://fujixweekly.com/2022/11/28/kodachrome-64-fujifilm-x-t5-x-trans-v-film-simulation-recipe/> ·
<https://fujixweekly.com/2024/03/23/the-new-reala-ace-film-simulation-is-actually/>

Film stocks: Kodak datasheets E-4050, E-4051, E-4040 (Portra), E-4046 (Ektar), E-7022 (Gold), E-7023 (Ultramax), H-1-5219 / H-1-5207 (Vision3) ·
Fujifilm datasheets AF3-0221E2 (Velvia 50), AF3-036E (Provia 100F), AF3-176E (Pro 400H), AF3-0217E (Superia X-TRA 400) ·
<https://www.timparkin.co.uk/2009/06/fuji-velvia-provia-astia-and-pro160/> ·
<https://www.alexburkephoto.com/blog/2013/02/25/color-film-choices-for-landscapes> ·
<https://www.analog.cafe/r/fujifilm-fujicolor-pro-400h-film-review-rau5> ·
<https://www.analog.cafe/r/fujifilm-superia-x-tra-400-film-review-zc0y> ·
<https://emulsive.org/reviews/film-reviews/film-stock-review-comparing-kodak-ektar-100-to-fujifilm-velvia-50> ·
<https://www.35mmc.com/21/12/2020/kodachrome-64-digitising-for-the-look-by-david-hume/>

Makers: <https://leica-camera.com/en-US/photography/leica-looks> ·
<https://www.ricoh-imaging.co.jp/english/products/gr-3/feature/03.html> ·
<https://helpguide.sony.net/ilc/2230/v1/en/contents/TP0002911200.html> ·
<https://www.hasselblad.com/learn/hasselblad-natural-colour-solution/> ·
<https://onlinemanual.nikonimglib.com/z8/en/picture_controls_37.html> ·
<https://imaging.nikon.com/imaging/support/digitutor/z_8/techniques/201902_25_03_ml.html> ·
<https://shop.panasonic.com/pages/lumix-l10-design-expressive-color-creation> ·
<https://learning.omsystem.com/OM-3/zz_html_manual/en/picture_mode_130.html>

Adobe and ecosystems: <https://jkost.com/blog/2024/07/the-power-of-profiles-in-lightroom-classic.html> ·
<https://blog.adobe.com/en/publish/2018/03/28/april-lightroom-adobe-camera-raw-releases-new-profiles> ·
<https://www.lightroomqueen.com/camera-profiles/> ·
<https://dcptool.sourceforge.net/DCP%20FIles.html> ·
<https://www.captureone.com/en/products/styles/film-styles> ·
<https://www.dxo.com/dxo-filmpack/science-of-film/> ·
<https://support.vsco.co/hc/en-us/articles/360043269391-Preset-Guide> ·
<https://www.dehancer.com/learn/articles/print-film-profiles-in-dehancer>

Cinema: <https://kevinraposo.com/a-guide-to-the-orange-and-teal-look/> ·
<https://www.cinematography.net/edited-pages/BLEACH.htm> ·
<https://theasc.com/article/saving-private-ryan-cinematography-kaminski/> ·
<https://www.kodak.com/en/motion/product/post/print-films/vision-color-2383-3383/> ·
<https://thefincheranalyst.com/2019/03/18/colorist-ian-vertovecs-instagram-notes-on-his-work-for-david-fincher/> ·
<https://en.wikipedia.org/wiki/Mexican_filter> ·
<https://www.kodak.com/en/motion/blog-post/asteroid-city/> ·
<https://www.arri.com/en/learn-help/learn-help-camera-system/image-science/log-c> ·
<https://chrisbrejon.com/articles/ocio-display-transforms-and-misconceptions/>

## What makes a look pop

Measured 2026-09-06 on five daylight test RAWs (Leica M, Fuji GFX 50S, Sony,
Hasselblad X2D II and H4D) at 512 px, against each file's embedded camera JPEG.
Statistics on 8-bit sRGB: mean chroma (max − min), luminance standard
deviation, clipped fraction (any channel ≥ 250).

**The neutral rendition already matches the camera JPEGs**: mean chroma 0.99×,
luminance spread 0.97×. The base was not the problem.

**The first styles were chroma-only.** With the smoothstep-mix contrast, every
style left luminance spread within 0.85–1.12× of neutral, while chroma ran from
0.34× (Bleach Bypass) to 1.55× (Vivid Slide). Three causes, in order:

1. A curve fixed at 0 and 1 has a mean slope of exactly 1; mixing toward a
   smoothstep redistributes contrast (1.22 at mid grey for +45, 0.7 in the toe)
   and cannot add any. Real renderings get slope above 1 from a pivot power and
   a shoulder.
2. A per-channel curve multiplies chroma by its local slope, so the weak curve
   was also a weak chroma engine, and it desaturated toe and shoulder.
3. Chroma scaled in linear RGB around Y meets the gamut wall at ×1.42 on
   foliage and ×1.55 on grass, then clips a channel and turns the hue; and
   holding Y fixed while raising chroma is the dilute direction. Richness is
   chroma up **and** lightness down (Fujifilm's Color Chrome Effect; the
   Helmholtz–Kohlrausch effect makes the darkening nearly free).

**Operators now** (`Stages/ColorStyle.swift`, `Shaders/Style.metal`): contrast
as a mid-grey pivot power with slope `1.6^(contrast/100)`, an exponential
shoulder, blacks last; chroma in OKLab with a vibrance weight
`1/(1 + (C/0.08)²)`, HK-neutral lightness coupling, a **density** term
`L ·= 1 − 0.35·d·min(C′/0.25, 1)`, and gamut recovery by shrinking chroma at
constant lightness and hue.

**Magnitudes from the literature.** Imaging Resource's colour-checker
measurements put default camera JPEGs at about 110 % of colorimetric chroma
("a more typical 10 %"); Imatest calls 110–120 % common and anything over
120 % excessive; the most saturated default found was a Pentax K-3 at 121 %.
Camera JPEG tone curves have gamma 0.45–0.6 against sRGB's 0.4545, i.e. a
mid-tone contrast multiplier of 1.0–1.32 in encoded space; sRGB specifies a
viewing gamma of 1.125, BT.2390 gives SDR television a system gamma of 1.2 and
cinema 1.6–1.8. From Fujifilm's published characteristic curves, Velvia 100's
gamma is 1.34× Provia 100F's. So: standard ≈ 1.1× chroma and 1.1–1.13× slope
over a colorimetric rendering; vivid ≈ 1.2× and 1.3; extreme ≈ 1.3–1.35× and
1.6–1.8.

**Tuned result**, ratios to neutral averaged over the five files:

| style | chroma | luminance spread | extra clipping |
|---|---|---|---|
| Vivid Slide | 1.47 | 1.27 | +3.4 % |
| Chrome | 1.26 | 1.27 | +3.5 % |
| Muted Chrome | 0.87 | 1.24 | +1.7 % |
| Portrait Negative | 0.92 | 1.00 | 0 |
| Pastel Negative | 0.91 | 0.99 | 0 |
| Nostalgic Negative | 1.18 | 1.05 | 0 |
| Retro Negative | 1.13 | 1.25 | +3.3 % |
| Soft Cinema | 0.77 | 0.89 | 0 |
| Teal and Orange | 1.42 | 1.27 | +0.1 % |
| Bleach Bypass | 0.36 | 1.37 | +4.2 % |

Vivid Slide and Teal and Orange sit above the "excessive" line on purpose; the
muted styles were lifted from 0.6–0.7× to 0.77–0.92× so they read as a look
rather than a loss. Neutral itself clips 14 % of the X2D frame and 10 % of the
H4D frame where the camera JPEG clips none; that is the tone stage's rendition,
not the styles, and is open.

Sources: <https://www.imatest.com/docs/colorcheck/> ·
<https://www.imatest.com/imaging/tonal-response-gamma/> ·
<https://www.imaging-resource.com/cameras/nikon-d7500-review/exposure/> ·
<https://www.imaging-resource.com/cameras/pentax-k-3-review/exposure/> ·
<https://www.w3.org/Graphics/Color/sRGB.html> ·
<https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-BT.2390-11-2023-PDF-E.pdf> ·
<https://docs.acescentral.com/system-components/output-transforms/technical-details/tone-mapping/> ·
<https://docs.acescentral.com/rgc/overview/> ·
<https://www.darktable.org/2013/10/about-basecurves/> ·
<https://eng.aurelienpierre.com/2022/02/color-saturation-control-for-the-21th-century/> ·
<https://bottosson.github.io/posts/oklab/> ·
<https://bottosson.github.io/posts/gamutclipping/> ·
<https://www.fujifilm-x.com/en-gb/learning-centre/color-chrome-and-film-grain-effects/> ·
<https://en.wikipedia.org/wiki/Helmholtz–Kohlrausch_effect> ·
<https://chrisbrejon.com/articles/ocio-display-transforms-and-misconceptions/> ·
<https://asset.fujifilm.com/master/emea/files/2020-10/2f3c7f90a0b0c6e605e84f98b7d489c2/films_velvia-100_datasheet_01.pdf>
