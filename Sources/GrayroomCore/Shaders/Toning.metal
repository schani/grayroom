// Split toning on the gray image.
//
// Tonal position: t = sqrt(clamp(Y, 0, 1)). sqrt is a cheap stand-in for a
// perceptual lightness (it sits between linear and the sRGB/L* curves) and it is
// monotonic, which is all the crossover needs. Working from a perceptual t
// means "shadows" means what it looks like, not what it measures linearly.
//
// Crossover (wave 2, audit bwmix-toning.json #1). The two weights are
// *complementary* across a band of half-width `crossoverHalfWidth` centred on
// the balance pivot:
//
//     w_h = smootherstep(pivot - hw, pivot + hw, t),   w_s = 1 - w_h
//
// so w_s + w_h == 1 through the whole midrange and there is no untinted band.
// Before wave 2 they were two independent smoothsteps that were *both* zero at
// the pivot, leaving everything between ~33 % and ~73 % grey essentially
// neutral -- setting both wheels to the same sepia gave tinted ends and a grey
// middle, which is not what Lightroom does.
//
// Both weights are then faded out at the very ends of the range, so extreme
// black and extreme white stay neutral (documented Lightroom behaviour).
//
// Tint construction. Each hue becomes a fully saturated RGB normalised to
// *equal RGB energy* (r+g+b == 3) rather than to luminance 1, and the two tints
// are combined by weight:
//
//     factor = 1 + w_s * a_s * (tint_s - 1) + w_h * a_h * (tint_h - 1)
//
// Two things follow. Equal hue and saturation on both wheels collapse to one
// uniform tint by construction (the classic sepia/selenium recipe), and the
// factor carries a *luminance* excursion -- warm tints lift, cool tints darken --
// because equal-energy normalisation does not force dot(factor, kLuma) to 1.
//
// That excursion is then partly normalised away:
//
//     factor /= pow(dot(factor, kLuma), lumaPreserve)
//
// lumaPreserve = 1 is the exactly-chroma-only stage we had before wave 2; 0 is
// the raw tint; 0.5 keeps half the excursion in stops. Lightroom's toning does
// move lightness -- Adobe's own guidance is to pull the per-range Luminance
// slider back down when "adding a color to the shadows brightens the image" --
// and that lift is a large part of why LR toning reads as a toned print rather
// than as a hue overlay (audit #2).

struct ToningUniforms {
    float shadowHue;          // degrees
    float shadowSat;          // 0..1
    float highlightHue;       // degrees
    float highlightSat;       // 0..1
    float balance;            // -1..1, positive favours highlights
    float strength;           // global scale on saturation
    float crossoverHalfWidth; // in t
    float lumaPreserve;       // 1 = luminance-preserving, 0 = raw tint
};

// The crossover uses `grSmootherstep` (Common.metal): C2 rather than smoothstep
// because it modulates the whole midrange, where a curvature jump at the band
// edges would show as a faint contour on a clean gradient.

// Fully saturated RGB for a hue, normalised to r+g+b == 3. Neutral energy, so
// the sign of the luminance excursion is set by where the hue sits relative to
// the Rec.709 weights: warm/green hues lift, blue/magenta darken.
inline float3 grToningTint(float hueDeg) {
    float3 t = grHueToRGB(hueDeg);
    return t * (3.0f / max(t.r + t.g + t.b, 1e-4f));
}

kernel void toningKernel(texture2d<float, access::read>  src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant ToningUniforms &u          [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

    float4 s = src.read(gid);
    float3 rgb = max(s.rgb, 0.0f);
    float Y = grLuminance(rgb);
    float t = sqrt(clamp(Y, 0.0f, 1.0f));

    float pivot = clamp(0.5f - 0.35f * u.balance, 0.08f, 0.92f);
    float hw = max(u.crossoverHalfWidth, 1e-3f);

    float hwt = grSmootherstep(pivot - hw, pivot + hw, t);
    float swt = 1.0f - hwt;

    // Keep the extremes neutral. Both weights get the same fade, so their sum
    // goes to 0 at pure black and pure white and is exactly 1 in between.
    float fade = smoothstep(0.0f, 0.08f, t) * (1.0f - smoothstep(0.92f, 1.0f, t));
    swt *= fade;
    hwt *= fade;

    float sAmt = clamp(u.shadowSat, 0.0f, 1.0f) * u.strength;
    float hAmt = clamp(u.highlightSat, 0.0f, 1.0f) * u.strength;

    float3 factor = 1.0f
        + swt * sAmt * (grToningTint(u.shadowHue) - 1.0f)
        + hwt * hAmt * (grToningTint(u.highlightHue) - 1.0f);
    factor = max(factor, 0.0f);

    // Partially normalise the tint's luminance (see the header).
    factor /= pow(max(grLuminance(factor), 1e-4f), u.lumaPreserve);

    dst.write(float4(rgb * factor, s.a), gid);
}
