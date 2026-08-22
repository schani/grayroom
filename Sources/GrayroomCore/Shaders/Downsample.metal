// Draft downsample: the decoded full-resolution linear image reduced once, at
// decode time, to the resolution the interactive draft pass renders at.
//
// A 3x3 grid of bilinear taps across the destination texel's footprint,
// averaged. Each tap already covers a 2x2 source neighbourhood and the taps sit
// a third of a destination texel apart, so together they span a box of about
// six source pixels — enough for every reduction the draft edge (2560) asks
// for, including the ~4.6x of a 100 MP frame. Fewer taps aliased there.
//
// The grid is symmetric about the texel centre, so a linear ramp comes through
// exactly (`PreviewPathTests.testDownsamplePreservesALinearGradient`).
//
// It is a draft: the refine pass that follows re-renders from the untouched
// full-resolution decode, so nothing that reaches a file or a histogram goes
// through this kernel.

kernel void downsampleKernel(texture2d<float, access::sample> src [[texture(0)]],
                             texture2d<float, access::write>  dst [[texture(1)]],
                             uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);

    float2 dstSize = float2(dst.get_width(), dst.get_height());
    float2 base = (float2(gid) + 0.5f) / dstSize;
    float2 step = (1.0f / 3.0f) / dstSize;

    float4 acc = float4(0.0f);
    for (int dy = -1; dy <= 1; ++dy) {
        for (int dx = -1; dx <= 1; ++dx) {
            acc += src.sample(s, base + float2(float(dx), float(dy)) * step);
        }
    }
    dst.write(acc * (1.0f / 9.0f), gid);
}
