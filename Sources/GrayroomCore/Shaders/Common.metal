// Shared helpers for every Grayroom stage.
//
// This file is bundled as a *text* resource and concatenated with the stage
// sources at runtime (see MetalContext.swift), so it deliberately has no
// `#include` guards or headers beyond the Metal standard library.

#include <metal_stdlib>
using namespace metal;

// Rec.709 / sRGB luminance weights. The decoded image has sRGB primaries.
constant float3 kLuma = float3(0.2126f, 0.7152f, 0.0722f);

// Linear middle gray.
constant float kPivot = 0.18f;

inline float grLuminance(float3 rgb) {
    return dot(rgb, kLuma);
}

// Quintic smootherstep, clamped: 6t^5 - 15t^4 + 10t^3. C2 at both ends, which
// matters wherever the result modulates a whole tonal range (the tone curve's
// zone ramps, the toning crossover) — a smoothstep's curvature jump shows up as
// a faint contour on a clean gradient.
inline float grSmootherstep(float e0, float e1, float x) {
    float t = clamp((x - e0) / max(e1 - e0, 1e-6f), 0.0f, 1.0f);
    return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
}

// Linear -> sRGB transfer function (IEC 61966-2-1).
inline float grSRGBEncode(float c) {
    c = clamp(c, 0.0f, 1.0f);
    return (c <= 0.0031308f) ? (12.92f * c)
                             : (1.055f * pow(c, 1.0f / 2.4f) - 0.055f);
}

inline float3 grSRGBEncode(float3 c) {
    return float3(grSRGBEncode(c.r), grSRGBEncode(c.g), grSRGBEncode(c.b));
}

// Linear sRGB <-> OKLab (Ottosson). The style stage's chroma block lives here:
// scaling `ab` scales chroma at a fixed hue and a fixed perceptual lightness,
// which linear-RGB scaling around Y does not do.
inline float3 grLinearToOKLab(float3 rgb) {
    float3 lms = float3(dot(rgb, float3(0.4122214708f, 0.5363325363f, 0.0514459929f)),
                        dot(rgb, float3(0.2119034982f, 0.6806995451f, 0.1073969566f)),
                        dot(rgb, float3(0.0883024619f, 0.2817188376f, 0.6299787005f)));
    float3 c = sign(lms) * pow(fabs(lms), 1.0f / 3.0f);   // sign-preserving cbrt
    return float3(dot(c, float3(0.2104542553f,  0.7936177850f, -0.0040720468f)),
                  dot(c, float3(1.9779984951f, -2.4285922050f,  0.4505937099f)),
                  dot(c, float3(0.0259040371f,  0.7827717662f, -0.8086757660f)));
}

inline float3 grOKLabToLinear(float3 lab) {
    float3 c = float3(lab.x + 0.3963377774f * lab.y + 0.2158037573f * lab.z,
                      lab.x - 0.1055613458f * lab.y - 0.0638541728f * lab.z,
                      lab.x - 0.0894841775f * lab.y - 1.2914855480f * lab.z);
    c = c * c * c;
    return float3(dot(c, float3( 4.0767416621f, -3.3077115913f,  0.2309699292f)),
                  dot(c, float3(-1.2684380046f,  2.6097574011f, -0.3413193965f)),
                  dot(c, float3(-0.0041960863f, -0.7034186147f,  1.7076147010f)));
}

// Fully saturated RGB for a hue in degrees (HSV with s = v = 1).
inline float3 grHueToRGB(float hueDeg) {
    float h = fmod(fmod(hueDeg, 360.0f) + 360.0f, 360.0f) / 60.0f;
    float x = 1.0f - fabs(fmod(h, 2.0f) - 1.0f);
    if (h < 1.0f) return float3(1.0f, x, 0.0f);
    if (h < 2.0f) return float3(x, 1.0f, 0.0f);
    if (h < 3.0f) return float3(0.0f, 1.0f, x);
    if (h < 4.0f) return float3(0.0f, x, 1.0f);
    if (h < 5.0f) return float3(x, 0.0f, 1.0f);
    return float3(1.0f, 0.0f, x);
}

// HSV hue (degrees) and saturation of an already gamma-encoded triple.
inline void grHueSat(float3 c, thread float &hueDeg, thread float &sat) {
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float d = mx - mn;
    sat = (mx > 1e-6f) ? (d / mx) : 0.0f;
    if (d < 1e-6f) {
        hueDeg = 0.0f;
        return;
    }
    float h;
    if (mx == c.r)      h = fmod((c.g - c.b) / d, 6.0f);
    else if (mx == c.g) h = (c.b - c.r) / d + 2.0f;
    else                h = (c.r - c.g) / d + 4.0f;
    h *= 60.0f;
    if (h < 0.0f) h += 360.0f;
    hueDeg = h;
}

// Fully saturated RGB for a hue, normalised to r+g+b == 3. Neutral energy, so
// the sign of the luminance excursion is set by where the hue sits relative to
// the Rec.709 weights: warm/green hues lift, blue/magenta darken.
inline float3 grToningTint(float hueDeg) {
    float3 t = grHueToRGB(hueDeg);
    return t * (3.0f / max(t.r + t.g + t.b, 1e-4f));
}

// Split tone at tonal position `t`: a shadow tint and a highlight tint blended
// by a complementary crossover around the balance pivot, faded out at the very
// ends, then partially renormalised to luminance. Toning.metal has the whole
// derivation; the style stage runs the same block from its own preset.
inline float3 grSplitTone(float3 rgb, float t,
                          float shadowHue, float shadowSat,
                          float highlightHue, float highlightSat,
                          float balance, float strength,
                          float crossoverHalfWidth, float lumaPreserve) {
    float pivot = clamp(0.5f - 0.35f * balance, 0.08f, 0.92f);
    float hw = max(crossoverHalfWidth, 1e-3f);

    float hwt = grSmootherstep(pivot - hw, pivot + hw, t);
    float swt = 1.0f - hwt;

    // Keep the extremes neutral. Both weights get the same fade, so their sum
    // goes to 0 at pure black and pure white and is exactly 1 in between.
    float fade = smoothstep(0.0f, 0.08f, t) * (1.0f - smoothstep(0.92f, 1.0f, t));
    swt *= fade;
    hwt *= fade;

    float sAmt = clamp(shadowSat, 0.0f, 1.0f) * strength;
    float hAmt = clamp(highlightSat, 0.0f, 1.0f) * strength;

    float3 factor = 1.0f
        + swt * sAmt * (grToningTint(shadowHue) - 1.0f)
        + hwt * hAmt * (grToningTint(highlightHue) - 1.0f);
    factor = max(factor, 0.0f);

    factor /= pow(max(grLuminance(factor), 1e-4f), lumaPreserve);
    return rgb * factor;
}
