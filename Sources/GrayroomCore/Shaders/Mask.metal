// Mask rasterisation and per-pixel parameter accumulation (M3).
//
// The CPU reference for every function here is `Masks/MaskRasterizer.swift`;
// `MaskTests` compares the two on a synthetic stroke set.
//
// Coordinates: stamps arrive in *pixel* units, pixel centres at (i + 0.5).
// A stroke is one dispatch: each thread walks the stroke's stamps in order,
// taking the *maximum* alpha over them into a private accumulator (that
// accumulator is the per-stroke buffer of the two-buffer stamp model — it never
// needs to be materialised as a texture because it is only ever read by its own
// pixel), then over-composites that into the mask, capped at density.
//
// This is the standard non-incremental paint model, and it is what makes Flow a
// *rate*: one pass deposits ~flow, repeated passes build up toward the Density
// ceiling. See MaskRasterizer for the full rationale.

struct MaskStamp {
    float cx;
    float cy;
    float radius;        // alpha reaches 0 here
    float innerRadius;   // full alpha inside here
    float alpha;         // the brush's flow
};

struct MaskStrokeUniforms {
    uint  stampCount;
    float density;       // absolute ceiling on the merged mask, 0..1
    uint  erase;         // 1: mask *= (1 - stroke); 0: mask builds up toward density
};

struct MaskAccumulateUniforms {
    float dExposure;
    float dContrast;
    float dHighlights;
    float dShadows;
    float dClarity;
};

struct MaskClampUniforms {
    float exposureLimit;
    float otherLimit;
};

struct MaskClarityUniforms {
    float globalClarity;   // the global slider, -100..100
    float dominantSign;    // +1 boost variant, -1 smooth variant
    float invReference;    // 1 / 100 — the fixed full-scale reference
};

// Radial falloff, 0..1. Matches MaskRasterizer.profile.
inline float grMaskProfile(float d, float inner, float outer) {
    if (outer <= 0.0f) return 0.0f;
    if (d >= outer) return 0.0f;
    if (d <= inner) return 1.0f;
    return 1.0f - smoothstep(inner, outer, d);
}

kernel void maskClearKernel(texture2d<float, access::write> dst [[texture(0)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(float4(0.0f), gid);
}

// One stroke, rasterised and merged into the mask.
kernel void maskStrokeKernel(texture2d<float, access::read>  srcMask [[texture(0)]],
                             texture2d<float, access::write> dstMask [[texture(1)]],
                             device const MaskStamp *stamps           [[buffer(0)]],
                             constant MaskStrokeUniforms &u           [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dstMask.get_width() || gid.y >= dstMask.get_height()) return;
    float px = float(gid.x) + 0.5f;
    float py = float(gid.y) + 0.5f;

    float acc = 0.0f;
    for (uint i = 0u; i < u.stampCount; ++i) {
        MaskStamp s = stamps[i];
        float dx = px - s.cx;
        float dy = py - s.cy;
        // Bounding-box reject first: the stamp lists are short but most pixels
        // are outside most stamps.
        if (fabs(dx) >= s.radius || fabs(dy) >= s.radius) continue;
        float d = sqrt(dx * dx + dy * dy);
        float a = s.alpha * grMaskProfile(d, s.innerRadius, s.radius);
        acc = max(acc, a);                // within a stroke: one pass = flow
    }

    float m = srcMask.read(gid).r;
    if (u.erase != 0u) {
        m = m * (1.0f - min(acc, u.density));
    } else {
        // Build up toward the ceiling, and never pull existing coverage down:
        // painting at density 40 over an area already at 0.8 leaves it at 0.8.
        m = min(m + acc * (1.0f - m), max(m, u.density));
    }
    dstMask.write(float4(clamp(m, 0.0f, 1.0f), 0.0f, 0.0f, 0.0f), gid);
}

// Union of two coverage textures (mask-preview's "all enabled masks" view).
kernel void maskUnionKernel(texture2d<float, access::read>  a   [[texture(0)]],
                            texture2d<float, access::read>  b   [[texture(1)]],
                            texture2d<float, access::write> dst [[texture(2)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(float4(max(a.read(gid).r, b.read(gid).r), 0.0f, 0.0f, 0.0f), gid);
}

// paramsA += coverage * (dExposure, dContrast, dHighlights, dShadows)
// paramsB += coverage * dClarity
//
// The sum is left unclamped here and clamped once at the end (maskClampKernel),
// so a negative delta can pull an over-range partial sum back into range.
kernel void maskAccumulateKernel(texture2d<float, access::read>  coverage [[texture(0)]],
                                 texture2d<float, access::read>  srcA     [[texture(1)]],
                                 texture2d<float, access::write> dstA     [[texture(2)]],
                                 texture2d<float, access::read>  srcB     [[texture(3)]],
                                 texture2d<float, access::write> dstB     [[texture(4)]],
                                 constant MaskAccumulateUniforms &u       [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dstA.get_width() || gid.y >= dstA.get_height()) return;
    float c = coverage.read(gid).r;
    float4 a = srcA.read(gid);
    a += c * float4(u.dExposure, u.dContrast, u.dHighlights, u.dShadows);
    dstA.write(a, gid);
    dstB.write(float4(srcB.read(gid).r + c * u.dClarity, 0.0f, 0.0f, 0.0f), gid);
}

kernel void maskClampKernel(texture2d<float, access::read>  srcA [[texture(0)]],
                            texture2d<float, access::write> dstA [[texture(1)]],
                            texture2d<float, access::read>  srcB [[texture(2)]],
                            texture2d<float, access::write> dstB [[texture(3)]],
                            constant MaskClampUniforms &u        [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dstA.get_width() || gid.y >= dstA.get_height()) return;
    float4 a = srcA.read(gid);
    float4 lim = float4(u.exposureLimit, u.otherLimit, u.otherLimit, u.otherLimit);
    dstA.write(clamp(a, -lim, lim), gid);
    dstB.write(float4(clamp(srcB.read(gid).r, -u.otherLimit, u.otherLimit), 0.0f, 0.0f, 0.0f), gid);
}

// Per-pixel clarity amount for the clarity stage:
//
//   c(x) = clamp(global + dClarity(x), -100, 100)
//   a(x) = clamp(sign_dominant * c(x), 0, 100) / 100
//
// so pixels whose clarity has the *opposite* sign to the frame's dominant
// variant get amount 0 (the documented v1 conflict rule, see
// MaskRasterizer.clarityVariant).
//
// The reference is the **fixed** full-scale 100, not the frame's largest
// |clarity| as it was before wave 3. The pyramid is built at the full-scale lift
// to match, and since the filter is affine in lift this reproduces each pixel's
// own strength exactly *and* makes it independent of what other clarity values
// are present: adding a mask no longer changes the rendition outside it (audit
// `clarity-local` #6). With the old max-normalisation, global 25 plus a +20 mask
// rendered the unmasked frame at an effective clarity of ~35.
kernel void maskClarityAmountKernel(texture2d<float, access::read>  paramsB [[texture(0)]],
                                    texture2d<float, access::write> amount  [[texture(1)]],
                                    constant MaskClarityUniforms &u         [[buffer(0)]],
                                    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= amount.get_width() || gid.y >= amount.get_height()) return;
    float c = clamp(u.globalClarity + paramsB.read(gid).r, -100.0f, 100.0f);
    float a = max(u.dominantSign * c, 0.0f) * u.invReference;
    amount.write(float4(clamp(a, 0.0f, 1.0f), 0.0f, 0.0f, 0.0f), gid);
}
