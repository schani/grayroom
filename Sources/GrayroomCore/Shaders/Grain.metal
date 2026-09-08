// Monochromatic photographic grain in width-normalized image coordinates.
//
// Three independently rotated bands of smooth hashed lattice noise avoid a
// repeating tile and the square-grid look of one value-noise field. Their fixed
// RMS-normalised blend combines fine flecks, base particles, and coarse clumps.
//
// Each band's energy is attenuated when its correlation radius falls below the
// render pixel's source-image footprint. That approximates integrating grain
// over a reduced output pixel and suppresses thumbnail/draft aliasing.

struct GrainUniforms {
    float amplitude;
    float baseRadius;
    float pixelFootprint;
    float displayWhite;
    float blurRadius;
    float blurBlend;
};

inline float grGrainHash(int2 p, uint seed) {
    uint h = as_type<uint>(p.x) * 0x8da6b343u;
    h ^= as_type<uint>(p.y) * 0xd8163841u;
    h ^= seed * 0xcb1ab31fu;
    h ^= h >> 16;
    h *= 0x7feb352du;
    h ^= h >> 15;
    h *= 0x846ca68bu;
    h ^= h >> 16;
    return float(h & 0x00ffffffu) * (2.0f / 16777215.0f) - 1.0f;
}

inline float grGrainValueNoise(float2 p, uint seed) {
    int2 cell = int2(floor(p));
    float2 f = p - floor(p);
    // Quintic interpolation makes every lattice boundary C2-continuous.
    float2 u = f * f * f * (f * (f * 6.0f - 15.0f) + 10.0f);
    float a = grGrainHash(cell, seed);
    float b = grGrainHash(cell + int2(1, 0), seed);
    float c = grGrainHash(cell + int2(0, 1), seed);
    float d = grGrainHash(cell + int2(1, 1), seed);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

inline float grGrainBand(float2 sourcePosition, float radius, float footprint,
                         float2 rotationX, float2 rotationY, uint seed) {
    float2 p = float2(dot(sourcePosition, rotationX), dot(sourcePosition, rotationY));
    // Spatial RMS of 2-D quintic-interpolated U(-1,1) lattice noise is ~0.452.
    float noise;
    float filterMix = grSmootherstep(1.0f, 2.0f, footprint);
    if (filterMix > 0.0f) {
        // Drafts and reduced exports integrate four positions across their
        // source footprint. They have far fewer pixels than a full render, so
        // this extra work removes sub-Nyquist structure without taxing 1:1.
        float2 ox = float2(rotationX.x, rotationY.x) * (footprint * 0.25f);
        float2 oy = float2(rotationX.y, rotationY.y) * (footprint * 0.25f);
        float invRadius = 1.0f / max(radius, 0.05f);
        float filtered = (grGrainValueNoise((p - ox - oy) * invRadius, seed)
                        + grGrainValueNoise((p + ox - oy) * invRadius, seed)
                        + grGrainValueNoise((p - ox + oy) * invRadius, seed)
                        + grGrainValueNoise((p + ox + oy) * invRadius, seed)) * 0.25f;
        if (filterMix < 1.0f) {
            filtered = mix(grGrainValueNoise(p * invRadius, seed), filtered, filterMix);
        }
        noise = filtered * 2.212f;
    } else {
        noise = grGrainValueNoise(p / max(radius, 0.05f), seed) * 2.212f;
    }
    float ratio = footprint / max(radius, 0.05f);
    // Approximate a box-filtered stationary field. In two dimensions RMS falls
    // in inverse proportion to footprint once many grains fit in one pixel.
    float attenuation = rsqrt(1.0f + mix(0.36f, 0.12f, filterMix) * ratio * ratio);
    return noise * attenuation;
}

kernel void grainKernel(texture2d<float, access::sample> src [[texture(0)]],
                        texture2d<float, access::write>  dst [[texture(1)]],
                        constant GrainUniforms &u            [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler px(coord::pixel, filter::linear, address::clamp_to_edge);
    float2 center = float2(gid) + 0.5f;
    float4 original = src.sample(px, center);

    // Lightroom introduces a little softness above Size 25. Keep it subtle and
    // proportional to Amount so Amount 0 remains an exact bypass in Pipeline.
    float4 s = original;
    if (u.blurBlend > 0.0f && u.blurRadius > 0.0f) {
        float2 dx = float2(u.blurRadius, 0.0f);
        float2 dy = float2(0.0f, u.blurRadius);
        float4 neighbours = (src.sample(px, center + dx) + src.sample(px, center - dx)
                           + src.sample(px, center + dy) + src.sample(px, center - dy)) * 0.25f;
        s.rgb = mix(original.rgb, neighbours.rgb, u.blurBlend);
    }

    float2 sourcePosition = center * u.pixelFootprint;
    float radius = u.baseRadius;
    float fine = grGrainBand(sourcePosition, radius * 0.47f, u.pixelFootprint,
                             float2(0.819152f, 0.573576f),
                             float2(-0.573576f, 0.819152f), 0x93a4b12du);
    float base = grGrainBand(sourcePosition, radius, u.pixelFootprint,
                             float2(-0.342020f, 0.939693f),
                             float2(-0.939693f, -0.342020f), 0x57c8e91bu);
    float coarse = grGrainBand(sourcePosition, radius * 1.9f, u.pixelFootprint,
                               float2(0.965926f, -0.258819f),
                               float2(0.258819f, 0.965926f), 0xd3f17a65u);

    float3 weights = float3(0.65f, 0.75f, 0.70f);
    float noise = dot(float3(fine, base, coarse), weights)
                * rsqrt(max(dot(weights, weights), 1e-5f));
    noise = clamp(noise, -2.5f, 2.5f);

    float3 c = clamp(s.rgb, 0.0f, u.displayWhite);
    float Y = grLuminance(c);
    float t = sqrt(clamp(Y / u.displayWhite, 0.0f, 1.0f));
    float endpoints = grSmootherstep(0.0f, 0.10f, t)
                    * (1.0f - grSmootherstep(0.90f, 1.0f, t));
    float shadowBias = mix(1.15f, 0.70f, grSmootherstep(0.15f, 0.85f, t));
    float requested = u.amplitude * endpoints * shadowBias;
    float a = min(requested, 0.39f);
    // Shared noise with symmetric per-channel bounds preserves average colour.
    // Its +/-2.5 bound keeps every result between black and display white.
    float3 amplitude = min(c * a, (u.displayWhite - c) * 0.4f);
    float3 result = c + noise * amplitude;
    dst.write(float4(result, original.a), gid);
}
