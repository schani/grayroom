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

// Linear -> sRGB transfer function (IEC 61966-2-1).
inline float grSRGBEncode(float c) {
    c = clamp(c, 0.0f, 1.0f);
    return (c <= 0.0031308f) ? (12.92f * c)
                             : (1.055f * pow(c, 1.0f / 2.4f) - 0.055f);
}

inline float3 grSRGBEncode(float3 c) {
    return float3(grSRGBEncode(c.r), grSRGBEncode(c.g), grSRGBEncode(c.b));
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
