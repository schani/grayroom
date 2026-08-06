// Clarity: fast local Laplacian filter on log2 luminance.
//
// Implements the discretised ("fast") local Laplacian filter of Aubry, Paris,
// Hasinoff, Kautz and Durand (ACM TOG 2014), which approximates the original
// local Laplacian filter (Paris, Hasinoff, Kautz, SIGGRAPH 2011):
//
//   * L = log2(max(Y, eps)) is the working signal (see ClarityMapping.swift).
//   * G[l] is the Gaussian pyramid of L.
//   * K gamma levels g_0..g_{K-1} discretise the working log range.
//     For each level k the image is remapped point-wise with r_k (a detail
//     manipulation centred on g_k), a Gaussian pyramid of r_k(L) is built and
//     its Laplacian coefficients are accumulated into the output pyramid with
//     the hat weight max(0, 1 - |t(G[l][p]) - k|), t = (v - g_0) / step.
//     Summing the hat weights over k is exactly the linear interpolation
//     between the two gamma levels bracketing G[l][p], and the weights are a
//     partition of unity, so r = identity reproduces L exactly.
//   * The coarsest level is the *original* residual G[N-1]: this filter only
//     manipulates detail, it never compresses tone.
//
// Pyramid operators are the standard Burt-Adelson 5-tap [1,4,6,4,1]/16 kernels
// with clamp-to-edge, coarse size ceil(w/2) so non-power-of-two images work.

struct ClarityUniforms {
    float sigmaR;          // detail-lift window width, in log2 stops
    float lift;            // gain * (1/alpha - 1) >= 0; boosts detail, 0 is identity
    float gamma0;          // g_0, in log2(Y)
    float gammaStep;       // (g_{K-1} - g_0) / (K - 1)
    float center;          // g_k for this pass
    uint  levelIndex;      // k
    uint  levelCount;      // K
    uint  remapFine;       // 1: the "fine" texture is L and must be remapped
};

struct ClarityApplyUniforms {
    float maxStops;        // safety clamp on the applied log2 ratio
    float toneCenter;      // log2(0.18): where the midtone weight peaks
    float toneSigma;       // width of the midtone weight, in stops
    float toneFloor;       // the weight never falls below this
};

struct ClarityLevelGainUniforms {
    float levelGain;       // scale on this level's lifted Laplacian, 0..1
};

constant float kClarityTap[5] = { 1.0f / 16.0f, 4.0f / 16.0f, 6.0f / 16.0f,
                                  4.0f / 16.0f, 1.0f / 16.0f };

inline float grClarityFetch(texture2d<float, access::read> t, int x, int y) {
    int w = int(t.get_width());
    int h = int(t.get_height());
    return t.read(uint2(uint(clamp(x, 0, w - 1)), uint(clamp(y, 0, h - 1)))).r;
}

// r_g(v) = v + lift * d * exp(-d^2 / 2 sigma_r^2),  d = v - g.
//
// A Gaussian-windowed linear lift: slope 1 + lift on fine detail, decaying back
// to the identity for |d| >> sigma_r so that large edges survive untouched.
// `lift = 0` (clarity = 0) is exactly the identity. See ClarityMapping.swift for
// why this shape rather than the classic (|d|/sigma_r)^alpha.
inline float grClarityRemap(float v, constant ClarityUniforms &u) {
    float d = v - u.center;
    float y = d / u.sigmaR;
    return v + u.lift * d * exp(-0.5f * y * y);
}

// Hat weight of gamma level k for a Gaussian-pyramid value v. Values outside
// [g_0, g_{K-1}] clamp onto the end levels, where the remap is the identity for
// anything more than sigma_r away — clarity fades out gracefully instead of
// producing an artefact.
inline float grClarityWeight(float v, constant ClarityUniforms &u) {
    float t = clamp((v - u.gamma0) / u.gammaStep, 0.0f, float(u.levelCount - 1u));
    return max(0.0f, 1.0f - fabs(t - float(u.levelIndex)));
}

// Burt-Adelson upsample of `coarse` evaluated at the fine pixel `gid`.
// Inserting zeros and convolving with 2*[1,4,6,4,1]/16 separably collapses, per
// axis, to weights {1,6,1}/16 on (c-1, c, c+1) for even coordinates and
// {4,4}/16 on (c, c+1) for odd ones; the 2-D weights sum to 1/4, hence the *4.
inline float grClarityUpsample(texture2d<float, access::read> coarse, uint2 gid) {
    int wx[3], wyIdx[3];
    float fx[3], fy[3];
    int nx, ny;

    int x = int(gid.x);
    if ((x & 1) == 0) {
        nx = 3;
        int c = x >> 1;
        wx[0] = c - 1; wx[1] = c; wx[2] = c + 1;
        fx[0] = 1.0f / 16.0f; fx[1] = 6.0f / 16.0f; fx[2] = 1.0f / 16.0f;
    } else {
        nx = 2;
        int c = x >> 1;
        wx[0] = c; wx[1] = c + 1;
        fx[0] = 4.0f / 16.0f; fx[1] = 4.0f / 16.0f;
    }

    int y = int(gid.y);
    if ((y & 1) == 0) {
        ny = 3;
        int c = y >> 1;
        wyIdx[0] = c - 1; wyIdx[1] = c; wyIdx[2] = c + 1;
        fy[0] = 1.0f / 16.0f; fy[1] = 6.0f / 16.0f; fy[2] = 1.0f / 16.0f;
    } else {
        ny = 2;
        int c = y >> 1;
        wyIdx[0] = c; wyIdx[1] = c + 1;
        fy[0] = 4.0f / 16.0f; fy[1] = 4.0f / 16.0f;
    }

    float acc = 0.0f;
    for (int j = 0; j < ny; ++j) {
        for (int i = 0; i < nx; ++i) {
            acc += fx[i] * fy[j] * grClarityFetch(coarse, wx[i], wyIdx[j]);
        }
    }
    return 4.0f * acc;
}

// L = log2(max(Y, eps)), the signal everything else works on.
kernel void clarityLogLumaKernel(texture2d<float, access::read>  src [[texture(0)]],
                                 texture2d<float, access::write> dst [[texture(1)]],
                                 constant float &epsLuma            [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float Y = grLuminance(max(src.read(gid).rgb, 0.0f));
    dst.write(float4(log2(max(Y, epsLuma)), 0.0f, 0.0f, 0.0f), gid);
}

kernel void clarityDownsampleKernel(texture2d<float, access::read>  src [[texture(0)]],
                                    texture2d<float, access::write> dst [[texture(1)]],
                                    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    int bx = int(gid.x) * 2;
    int by = int(gid.y) * 2;
    float acc = 0.0f;
    for (int j = 0; j < 5; ++j) {
        for (int i = 0; i < 5; ++i) {
            acc += kClarityTap[i] * kClarityTap[j] * grClarityFetch(src, bx + i - 2, by + j - 2);
        }
    }
    dst.write(float4(acc, 0.0f, 0.0f, 0.0f), gid);
}

// Fused r_k + downsample: builds level 1 of the remapped pyramid straight from
// L, so the full-resolution remapped image never has to be stored.
kernel void clarityRemapDownsampleKernel(texture2d<float, access::read>  src [[texture(0)]],
                                         texture2d<float, access::write> dst [[texture(1)]],
                                         constant ClarityUniforms &u         [[buffer(0)]],
                                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    int bx = int(gid.x) * 2;
    int by = int(gid.y) * 2;
    float acc = 0.0f;
    for (int j = 0; j < 5; ++j) {
        for (int i = 0; i < 5; ++i) {
            float v = grClarityFetch(src, bx + i - 2, by + j - 2);
            acc += kClarityTap[i] * kClarityTap[j] * grClarityRemap(v, u);
        }
    }
    dst.write(float4(acc, 0.0f, 0.0f, 0.0f), gid);
}

kernel void clarityClearKernel(texture2d<float, access::write> dst [[texture(0)]],
                               uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(float4(0.0f), gid);
}

// accum[l] += w_k(G[l]) * (fine - upsample(coarse)).
kernel void clarityAccumulateKernel(texture2d<float, access::read>       fine   [[texture(0)]],
                                    texture2d<float, access::read>       coarse [[texture(1)]],
                                    texture2d<float, access::read>       gauss  [[texture(2)]],
                                    texture2d<float, access::read_write> accum  [[texture(3)]],
                                    constant ClarityUniforms &u                 [[buffer(0)]],
                                    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= accum.get_width() || gid.y >= accum.get_height()) return;
    float f = fine.read(gid).r;
    if (u.remapFine != 0u) f = grClarityRemap(f, u);
    float lap = f - grClarityUpsample(coarse, gid);
    float w = grClarityWeight(gauss.read(gid).r, u);
    accum.write(float4(accum.read(gid).r + w * lap, 0.0f, 0.0f, 0.0f), gid);
}

// Per-level band weighting (audit clarity-local #2).
//
// After the k loop, accum[l] holds Sum_k w_k * Lap[r_k(L)][l]. Because the
// pyramid operators are linear and r_k(v) = v + lift*f_k(v),
//
//   Sum_k w_k * Lap[r_k(L)] = Lap[L] + lift * Sum_k w_k * Lap[f_k(L)]
//
// (the hat weights are a partition of unity, so the unlifted part comes through
// with weight 1). Scaling only the *lifted* part by g_l is therefore
//
//   accum[l] <- lapBase + g_l * (accum[l] - lapBase),   lapBase = G[l] - up(G[l+1])
//
// which is one pass per level instead of an extra pyramid, and needs no change
// to the k loop. g_l = 0 leaves that band exactly as the input had it.
kernel void clarityLevelGainKernel(texture2d<float, access::read>       gauss     [[texture(0)]],
                                   texture2d<float, access::read>       gaussNext [[texture(1)]],
                                   texture2d<float, access::read_write> accum     [[texture(2)]],
                                   constant ClarityLevelGainUniforms &u           [[buffer(0)]],
                                   uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= accum.get_width() || gid.y >= accum.get_height()) return;
    float lapBase = gauss.read(gid).r - grClarityUpsample(gaussNext, gid);
    float lifted = accum.read(gid).r;
    accum.write(float4(lapBase + u.levelGain * (lifted - lapBase), 0.0f, 0.0f, 0.0f), gid);
}

// One collapse step: fine = fine + upsample(coarse).
kernel void clarityCollapseKernel(texture2d<float, access::read>       coarse [[texture(0)]],
                                  texture2d<float, access::read_write> fine   [[texture(1)]],
                                  uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= fine.get_width() || gid.y >= fine.get_height()) return;
    fine.write(float4(fine.read(gid).r + grClarityUpsample(coarse, gid), 0.0f, 0.0f, 0.0f), gid);
}

// Midtone weight: a Gaussian in stops around middle gray, floored so the
// extremes are attenuated rather than switched off. See ClarityMapping.
inline float grClarityToneWeight(float l, constant ClarityApplyUniforms &u) {
    float y = (l - u.toneCenter) / u.toneSigma;
    return max(u.toneFloor, exp(-0.5f * y * y));
}

// Final application, hue-preserving:
//
//   L_out = mix(L, L_llf, amount(x) * w(L))
//   rgb'  = rgb * 2^(L_out - L)
//
// `amount` is a texture so that M3 masks can drive it per pixel; a 1x1 texture
// holding the global amount is the degenerate case used today (coordinates are
// clamped to the amount texture's extent). `w` is the midtone weight, which
// makes clarity a midtone control as in Lightroom; it multiplies the amount, so
// amount = 0 is still exactly the identity.
kernel void clarityApplyKernel(texture2d<float, access::read>  src    [[texture(0)]],
                               texture2d<float, access::read>  logIn  [[texture(1)]],
                               texture2d<float, access::read>  logOut [[texture(2)]],
                               texture2d<float, access::read>  amount [[texture(3)]],
                               texture2d<float, access::write> dst    [[texture(4)]],
                               constant ClarityApplyUniforms &u       [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 s = src.read(gid);
    float l0 = logIn.read(gid).r;
    float l1 = logOut.read(gid).r;
    uint2 ac = uint2(min(gid.x, amount.get_width() - 1u),
                     min(gid.y, amount.get_height() - 1u));
    float a = clamp(amount.read(ac).r, 0.0f, 1.0f) * grClarityToneWeight(l0, u);
    float dL = clamp(a * (l1 - l0), -u.maxStops, u.maxStops);
    dst.write(float4(max(s.rgb, 0.0f) * exp2(dL), s.a), gid);
}
