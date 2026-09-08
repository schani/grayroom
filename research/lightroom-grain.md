# Lightroom-style grain

Research checked 2026-09-07.

## Lightroom behavior

Grain is a section in Develop > Effects. Its controls, in order, are Amount,
Size, and Roughness. All run from 0 to 100. Defaults are Amount 0, Size 25, and
Roughness 50. Amount 0 disables the effect; Lightroom then disables the other
two controls.

- Amount controls visibility.
- Size controls particle size. Adobe's Camera Raw manual says values of 25 or
  more may slightly blur the image.
- Roughness controls regularity: left is uniform; right is uneven.
- Size and Roughness jointly determine character. Adobe recommends judging the
  result at several zoom levels.

Camera Raw stores these as `GrainAmount`, `GrainSize`, and `GrainFrequency`;
the last property is Lightroom's Roughness control.

Adobe's current Lightroom help says “blue is added” at Size 25. This appears to
be a transcription error: Adobe's older Camera Raw reference says “the image
may appear slightly blurred.” Do not add blue color.

## Rendering basis

Physical film grain is signal-dependent and spatially correlated. Newson et
al. model exposed grains as a Poisson Boolean process of discs. Grain radii may
follow a log-normal distribution; image intensity sets grain density, and
optical blur plus pixel integration produces the rendered value. This gives
plausible particles at any resolution, but its Monte Carlo renderer is too
expensive for Grayroom's interactive path.

Grayroom's chosen design is an original GPU approximation:

- Combine three independently seeded, rotated lattice-noise bands with quintic
  interpolation and a fixed broad blend of fine flecks and coarse clumps.
  Normalize RMS so Size does not change Amount.
- Size sets the bands' spatial scale as a fraction of photo width. Size 0 is
  approximately single-pixel texture at 11,608 px wide (about 100 MP); Size 25
  has a base radius near 1/6000 width.
- Shape a zero-mean noise field from square-root luminance and apply it to every
  RGB channel. Symmetric per-channel bounds preserve average colour while
  keeping black and display white in gamut. Away from either boundary, the
  channels share one scalar gain and preserve their ratios.
- Above Size 25, apply gentle detail softening before grain. Skip both softening
  and grain when Amount is zero.
- Anchor hashing in photo-width-relative coordinates with a stable global seed,
  so redraws and resized renders retain the same grain field.
- At reduced resolutions, integrate four samples per band and attenuate
  residual high-frequency energy as it approaches the Nyquist limit.

The stage runs after toning and before the output transform. The implementation
uses smooth noise fields rather than simulating individual physical grains.

This matches the documented character of Lightroom's Amount and Size controls,
not Adobe's proprietary pixels. Exact slider-to-radius, amplitude, tonal
response, crop, and export-resize mappings are unpublished and require visual
calibration.

## Validation

GPU tests cover deterministic output, Amount strength, Size correlation,
black/display-white protection, average colour, saturated SDR/HDR skies, and
reduced-render filtering. They also verify that the field scales with photo
width, remains unchanged when only height changes, and tracks an averaged
full-resolution render when resized.

## Sources

- [Adobe Lightroom Classic: Simulate film grain](https://helpx.adobe.com/lightroom-classic/desktop/process-and-develop-photos/retouch-photos.html#simulate-film-grain)
- [Adobe Photoshop CS6 reference: Camera Raw grain](https://helpx.adobe.com/pdf/cs6/photoshop_reference.pdf)
- [Adobe Camera Raw XMP namespace](https://developer.adobe.com/xmp/docs/xmp-namespaces/crs/)
- [Newson et al., Realistic Film Grain Rendering](https://www.ipol.im/pub/art/2017/192/)
- [Norkin et al., AV1 film-grain synthesis](https://norkin.org/pdf/DCC_2018_AV1_film_grain.pdf)

The Newson reference implementation is GPLv3. It was studied only as published
research; none of its code should be copied.
