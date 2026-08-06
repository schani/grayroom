// 8-channel B&W mix.
//
//   gray = Y * (1 + sum_bands w_band(hue) * slider_band * satWeight)
//
// Hue and saturation come from an HSV decomposition of the *gamma-encoded*
// linear RGB (encoding first keeps the hue of very dark pixels stable; a proper
// perceptual space is a possible v2 refinement).
//
// The band centres approximate Adobe's Lightroom mixer channels. Adobe does not
// publish the exact centres; these are the conventional values and give a good
// match in practice.
constant float kBandCenters[8] = { 0.0f, 30.0f, 60.0f, 120.0f, 180.0f, 240.0f, 280.0f, 320.0f };

struct BWMixUniforms {
    float gainPerUnit;   // slider unit -> gray gain (0.008 => +-0.8 at +-100)
};

// Cyclic C1 interpolation between the 8 band sliders. Because we interpolate
// between the two bracketing centres with a smoothstep, the implied band
// weights form a partition of unity: a pure band centre gets exactly its own
// slider, and the blend is smooth across the 320 deg -> 0 deg wrap.
inline float grBandMix(float hueDeg, constant float *sliders) {
    float h = fmod(fmod(hueDeg, 360.0f) + 360.0f, 360.0f);
    int j = 7;
    for (int i = 0; i < 7; ++i) {
        if (h >= kBandCenters[i] && h < kBandCenters[i + 1]) { j = i; break; }
    }
    float c0 = kBandCenters[j];
    float c1 = (j == 7) ? 360.0f : kBandCenters[j + 1];
    float t = clamp((h - c0) / (c1 - c0), 0.0f, 1.0f);
    float w = t * t * (3.0f - 2.0f * t);
    return mix(sliders[j], sliders[(j + 1) & 7], w);
}

kernel void bwMixKernel(texture2d<float, access::read>  src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant float *sliders             [[buffer(0)]],
                        constant BWMixUniforms &u           [[buffer(1)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

    float4 s = src.read(gid);
    float3 rgb = max(s.rgb, 0.0f);
    float Y = grLuminance(rgb);

    // Gamma-encode for a hue/sat estimate that behaves like the on-screen colour.
    float3 enc = pow(min(rgb, 64.0f), 1.0f / 2.2f);
    float hue, sat;
    grHueSat(enc, hue, sat);

    float mixAmount = grBandMix(hue, sliders);
    float gain = 1.0f + mixAmount * u.gainPerUnit * clamp(sat, 0.0f, 1.0f);
    float gray = max(Y * gain, 0.0f);

    dst.write(float4(gray, gray, gray, s.a), gid);
}
