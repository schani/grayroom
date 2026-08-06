// Tone stage: baseline rendition + exposure + contrast/highlights/shadows/
// whites/blacks + the display shoulder.
//
// All the *global* curve math happens on the CPU (ToneCurve.swift) and arrives
// here as a 1-D LUT texture (r32Float, size x 1) over log2(Y/0.18) in
// [minEV, maxEV]. The baseline rendition curve, the always-on highlight
// shoulder and the Blacks pedestal live only in that LUT — they are not
// per-mask controls, so this kernel never evaluates them.
//
// M3 adds *local* (per-mask) deltas, which cannot go through a LUT: the mask
// stage hands over a per-pixel (dEV, dContrast, dHighlights, dShadows) in an
// rgba16Float texture, and this kernel evaluates the same curve components
// analytically on the LUT's output. Composition order is therefore
//
//     Y  --global LUT-->  Y'  --local delta-->  Y''
//
// and the kernel is a pure ratio-preserving remap: RGB is scaled by Y''/Y, so
// hue and saturation are untouched.

struct ToneUniforms {
    float minEV;
    float maxEV;
    float gainBelow;   // multiplicative gain below the LUT domain
    float gainAbove;   // multiplicative gain above the LUT domain
    uint  lutSize;
    uint  hasLocal;    // 1: `params` holds real per-pixel deltas
};

// These MUST stay identical to the constants in ToneCurve.swift — the two
// implementations are compared by MaskTests.testGPUToneDeltaMatchesCPUReference.
constant float kToneContrastGain  = 0.40f;
constant float kToneContrastSigma = 1.2f;
constant float kToneHighlightRange = 1.3f;
constant float kToneShadowRange    = 1.3f;
constant float kToneRampLo = -2.7f;
constant float kToneRampHi = 5.3f;

// Quintic smootherstep, clamped: 6t^5 - 15t^4 + 10t^3.
inline float grSmootherstep(float e0, float e1, float x) {
    float t = clamp((x - e0) / (e1 - e0), 0.0f, 1.0f);
    return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
}

// The three maskable curve components, summed. Sliders are -100..100.
// CPU reference: ToneCurve.toneDeltaEV.
inline float grToneDeltaEV(float x, float contrast, float highlights, float shadows) {
    float y = 0.0f;
    float c = clamp(contrast, -100.0f, 100.0f) / 100.0f;
    if (c != 0.0f) {
        float u = x / kToneContrastSigma;
        y += c * kToneContrastGain * x * exp(-0.5f * u * u);
    }
    float h = clamp(highlights, -100.0f, 100.0f) / 100.0f;
    if (h != 0.0f) {
        y += h * kToneHighlightRange * grSmootherstep(kToneRampLo, kToneRampHi, x);
    }
    float s = clamp(shadows, -100.0f, 100.0f) / 100.0f;
    if (s != 0.0f) {
        y += s * kToneShadowRange * grSmootherstep(kToneRampLo, kToneRampHi, -x);
    }
    return y;
}

// Local delta applied to an already globally-toned luminance.
// CPU reference: ToneCurve.applyToneDelta. Identity (bit-for-bit) at zero delta.
inline float grApplyToneDelta(float Y, float4 p) {
    if (p.x == 0.0f && p.y == 0.0f && p.z == 0.0f && p.w == 0.0f) return Y;
    if (Y <= 0.0f) return 0.0f;
    float ev = clamp(p.x, -4.0f, 4.0f);
    float x = log2(Y / kPivot) + ev;
    return kPivot * exp2(x + grToneDeltaEV(x, p.y, p.z, p.w));
}

kernel void toneKernel(texture2d<float, access::read>  src    [[texture(0)]],
                       texture2d<float, access::write> dst    [[texture(1)]],
                       texture2d<float, access::read>  lut    [[texture(2)]],
                       texture2d<float, access::read>  params [[texture(3)]],
                       constant ToneUniforms &u               [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

    float4 s = src.read(gid);
    float3 rgb = max(s.rgb, 0.0f);
    float Y = grLuminance(rgb);

    float3 outRGB;
    if (Y <= 1e-9f) {
        outRGB = rgb * u.gainBelow;
    } else {
        float x = log2(Y / kPivot);
        float Yp;
        if (x <= u.minEV) {
            Yp = Y * u.gainBelow;
        } else if (x >= u.maxEV) {
            Yp = Y * u.gainAbove;
        } else {
            float t = (x - u.minEV) / (u.maxEV - u.minEV) * float(u.lutSize - 1u);
            uint i0 = uint(t);
            uint i1 = min(i0 + 1u, u.lutSize - 1u);
            float f = t - float(i0);
            float a = lut.read(uint2(i0, 0)).r;
            float b = lut.read(uint2(i1, 0)).r;
            Yp = mix(a, b, f);
        }
        if (u.hasLocal != 0u) {
            Yp = grApplyToneDelta(Yp, params.read(gid));
        }
        outRGB = rgb * (Yp / Y);
    }

    dst.write(float4(outRGB, s.a), gid);
}
