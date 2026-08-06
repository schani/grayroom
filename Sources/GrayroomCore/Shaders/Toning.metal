// Classic split toning on the gray image.
//
// Tonal position: t = sqrt(clamp(Y, 0, 1)). sqrt is a cheap stand-in for a
// perceptual lightness (it sits between linear and the sRGB/L* curves) and it is
// monotonic, which is all the crossover needs. Working from a perceptual t
// means "shadows" means what it looks like, not what it measures linearly.
//
// The tint is applied as a *chroma-only* multiplier: each hue is normalised to
// luminance 1 before mixing, and the product of the shadow and highlight
// factors is renormalised, so dot(factor, kLuma) == 1 exactly and the stage
// leaves luminance invariant.
//
// Extreme black and white stay neutral: both weights are faded out at the ends
// of the range (Lightroom behaviour).

struct ToningUniforms {
    float shadowHue;          // degrees
    float shadowSat;          // 0..1
    float highlightHue;       // degrees
    float highlightSat;       // 0..1
    float balance;            // -1..1, positive favours highlights
    float strength;           // global scale on saturation
};

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

    float sw = 1.0f - smoothstep(0.0f, pivot, t);
    float hw = smoothstep(pivot, 1.0f, t);

    // Keep the extremes neutral.
    sw *= smoothstep(0.0f, 0.08f, t);
    hw *= 1.0f - smoothstep(0.92f, 1.0f, t);

    float3 factor = float3(1.0f);

    float sAmt = clamp(u.shadowSat * u.strength * sw, 0.0f, 1.0f);
    if (sAmt > 0.0f) {
        float3 tint = grHueToRGB(u.shadowHue);
        tint /= max(grLuminance(tint), 1e-4f);
        factor *= mix(float3(1.0f), tint, sAmt);
    }

    float hAmt = clamp(u.highlightSat * u.strength * hw, 0.0f, 1.0f);
    if (hAmt > 0.0f) {
        float3 tint = grHueToRGB(u.highlightHue);
        tint /= max(grLuminance(tint), 1e-4f);
        factor *= mix(float3(1.0f), tint, hAmt);
    }

    // Renormalise so the tint carries no luminance.
    factor /= max(grLuminance(factor), 1e-4f);

    dst.write(float4(rgb * factor, s.a), gid);
}
