// 256-bin luminance histogram + clipping counters, computed on the
// OUTPUT-REFERRED (sRGB-encoded) image.
//
// Layout of the `counters` buffer (all atomic_uint):
//   [0   .. 255]  luminance bins
//   [256]         shadow-clipped pixel count  (min channel <= 0.5/255)
//   [257]         highlight-clipped pixel count (max channel >= 254.5/255)

kernel void histogramKernel(texture2d<float, access::read> src [[texture(0)]],
                            device atomic_uint *counters       [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;

    float3 c = clamp(src.read(gid).rgb, 0.0f, 1.0f);
    float y = grLuminance(c);

    uint bin = min(uint(y * 256.0f), 255u);
    atomic_fetch_add_explicit(&counters[bin], 1u, memory_order_relaxed);

    float lo = min(c.r, min(c.g, c.b));
    float hi = max(c.r, max(c.g, c.b));
    if (lo <= 0.5f / 255.0f) {
        atomic_fetch_add_explicit(&counters[256], 1u, memory_order_relaxed);
    }
    if (hi >= 254.5f / 255.0f) {
        atomic_fetch_add_explicit(&counters[257], 1u, memory_order_relaxed);
    }
}
