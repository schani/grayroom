// The colour style: one preset rendition, in the four blocks
// research/color-styles.md decomposes every look into.
//
// Block order, per pixel:
//
//   1  hue/sat of the gamma-encoded colour, exactly as bwMixKernel measures it
//   2  band luminance   (the mixer's gain law, colour kept)
//   3  chroma, in OKLab (band hue, band saturation x saturation x vibrance,
//                        the HK lightness coupling, density, gamut shrink)
//   4  the style curve  (contrast, shoulder, blacks), *per channel*
//   5  split tone
//
// Bands come first because they are statements about the colour that arrives:
// measuring hue after the curve would make every band read a different
// neighbourhood on a bright pixel than on a dark one. Band detection stays HSV
// so the bands mean the same thing here as in the B&W mixer.
//
// The curve is per channel, not a luminance-ratio gain like the tone stage.
// That is deliberate: a per-channel shoulder desaturates highlights toward
// white as they roll off, which is the "path to white" of every filmic
// transform and the one thing a ratio-preserving curve cannot do
// (DEVIATIONS.md, tone #5). Per channel it also multiplies chroma by the local
// slope, so contrast and chroma are not independent controls.
//
// It acts on the SDR range only. Anything above SDR white is HDR headroom and
// passes through *additively* (`curve(min(c,1)) + max(c-1, 0)`), so the mapping
// stays continuous and monotonic instead of slamming the headroom onto the
// shoulder.

struct StyleUniforms {
    float contrast;           // -100..100, slope at mid grey
    float blacks;             // -100..100
    float shoulder;           // 0..100
    float saturation;         // -100..100
    float vibrance;           // -100..100
    float density;            // 0..100, darkens saturated colour
    float vibranceChroma;     // OKLab chroma at which vibrance is half weight
    float hkGain;             // Helmholtz-Kohlrausch lightness coupling
    float densityReach;       // L multiplier taken away at density 100
    float densityChroma;      // OKLab chroma at which density is full strength
    float bandLuminanceEV;    // stops at band luminance +-100 on a saturated pixel
    float satExponent;        // as BWMixUniforms
    float satKnee;
    float shadowHue;          // as ToningUniforms
    float shadowSat;          // 0..1
    float highlightHue;
    float highlightSat;       // 0..1
    float balance;            // -1..1
    float strength;
    float crossoverHalfWidth;
    float lumaPreserve;
};

// Mirrored in ColorStyleCurve.
constant float kStyleGamma = 2.2f;
constant float kStyleBlackLift = 0.12f;      // encoded black at blacks +100
constant float kStyleBlackCrush = 0.06f;     // encoded value crushed to 0 at blacks -100
constant float kStyleShoulderReach = 0.5f;   // knee at 1 - reach when shoulder = 100
constant float kStyleContrastReach = 1.6f;   // slope at mid grey at contrast +-100

// Contrast, then the shoulder, then blacks, on a gamma-encoded 0..1 value.
//
// Contrast is a power law about the encoded mid grey: the log-log slope there
// is exactly `reach^(contrast/100)`, so the control raises the *mean* slope
// instead of trading one end against the other. It sends white above 1; the
// shoulder is what brings it back, and shoulder 0 is a hard clamp.
inline float grStyleCurve(float e, float contrast, float blacks, float shoulder) {
    float pivot = pow(kPivot, 1.0f / kStyleGamma);
    float slope = pow(kStyleContrastReach, clamp(contrast, -100.0f, 100.0f) * 0.01f);
    e = pivot * pow(e / pivot, slope);

    float s = clamp(shoulder, 0.0f, 100.0f) * 0.01f;
    if (s > 0.0f) {
        float k = 1.0f - kStyleShoulderReach * s;
        if (e > k) e = k + (1.0f - k) * (1.0f - exp(-(e - k) / (1.0f - k)));
    }
    e = clamp(e, 0.0f, 1.0f);

    float b = clamp(blacks, -100.0f, 100.0f) * 0.01f;
    if (b >= 0.0f) {
        e = kStyleBlackLift * b + e * (1.0f - kStyleBlackLift * b);
    } else {
        float crush = kStyleBlackCrush * (-b);
        e = max(e - crush, 0.0f) / (1.0f - crush);
    }
    return e;
}

// The same curve on a linear channel, with the headroom passthrough.
inline float grStyleCurveLinear(float c, constant StyleUniforms &u) {
    float lo = clamp(c, 0.0f, 1.0f);
    float curved = grStyleCurve(pow(lo, 1.0f / kStyleGamma), u.contrast, u.blacks, u.shoulder);
    return pow(curved, kStyleGamma) + (max(c, 0.0f) - lo);
}

// The chroma block, in OKLab: hue rotation, chroma scale, the lightness
// coupling, and a shrink back into the gamut. Mirrored by ColorStyleChroma.
//
// `chromaScale` is the band's own multiplier, `hueDegrees` its rotation.
// Positive degrees are toward the next band: OKLab hue runs red -> yellow ->
// green -> cyan -> blue -> magenta, the same order the bands do.
inline float3 grStyleChroma(float3 rgb, float hueDegrees, float chromaScale,
                            constant StyleUniforms &u) {
    float3 lab = grLinearToOKLab(rgb);
    float2 ab = lab.yz;
    float C = length(ab);

    if (hueDegrees != 0.0f) {
        float th = hueDegrees * (M_PI_F / 180.0f);
        float cs = cos(th), sn = sin(th);
        ab = float2(ab.x * cs - ab.y * sn, ab.x * sn + ab.y * cs);
    }

    // Vibrance is weighted toward low chroma, so it pulls the surround without
    // cooking skin or an already saturated sky.
    float w = 1.0f / (1.0f + (C / u.vibranceChroma) * (C / u.vibranceChroma));
    float k = chromaScale
            * max(0.0f, 1.0f + u.saturation * 0.01f)
            * (1.0f + u.vibrance * 0.01f * w);
    ab *= k;
    float C2 = C * k;

    // Helmholtz-Kohlrausch: chroma carries apparent lightness, so take the
    // change out of L and the pixel keeps the brightness it looked like.
    float L = lab.x * (1.0f + u.hkGain * C) / (1.0f + u.hkGain * C2);
    // Density darkens saturated colour, which is what reads as "rich".
    L *= 1.0f - u.densityReach * (u.density * 0.01f) * min(C2 / u.densityChroma, 1.0f);

    float3 out = grOKLabToLinear(float3(L, ab));
    // Out of gamut: shrink ab toward 0 at fixed L, so hue and lightness survive
    // where clipping a channel would twist both.
    if (min(out.r, min(out.g, out.b)) < 0.0f) {
        float lo = 0.0f, hi = 1.0f;
        for (int i = 0; i < 8; ++i) {
            float mid = 0.5f * (lo + hi);
            float3 t = grOKLabToLinear(float3(L, ab * mid));
            if (min(t.r, min(t.g, t.b)) >= 0.0f) lo = mid; else hi = mid;
        }
        out = grOKLabToLinear(float3(L, ab * lo));
    }
    return max(out, 0.0f);
}

kernel void styleKernel(texture2d<float, access::read>  src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant StyleUniforms &u           [[buffer(0)]],
                        constant float *bands               [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

    float4 s = src.read(gid);
    float3 rgb = max(s.rgb, 0.0f);

    // 1. Hue and saturation, as bwMixKernel measures them.
    float3 enc = pow(min(rgb, 64.0f), 1.0f / 2.2f);
    float hue, sat;
    grHueSat(enc, hue, sat);

    // 2. Band luminance. grSatWeight(0) == 0, so neutrals are untouched.
    rgb *= exp2(u.bandLuminanceEV * grBandMix(hue, bands + 16) * 0.01f
                * grSatWeight(sat, u.satExponent, u.satKnee));

    // 3. Chroma.
    rgb = grStyleChroma(rgb, grBandMix(hue, bands),
                        max(0.0f, 1.0f + grBandMix(hue, bands + 8) * 0.01f), u);

    // 4. The style curve, per channel.
    rgb = float3(grStyleCurveLinear(rgb.r, u),
                 grStyleCurveLinear(rgb.g, u),
                 grStyleCurveLinear(rgb.b, u));

    // 5. Split tone.
    float t = sqrt(clamp(grLuminance(rgb), 0.0f, 1.0f));
    rgb = grSplitTone(rgb, t, u.shadowHue, u.shadowSat, u.highlightHue, u.highlightSat,
                      u.balance, u.strength, u.crossoverHalfWidth, u.lumaPreserve);

    dst.write(float4(rgb, s.a), gid);
}
