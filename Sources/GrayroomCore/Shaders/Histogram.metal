// 256-bin luminance histogram + clipping counters.
//
// The tap is on the **linear** image, one stage before the output transform, so
// that a single path serves both output modes: the values are scaled by the
// display ceiling `W` and sRGB-encoded here.
//
//   e = sRGBEncode(clamp(rgb / W, 0, 1))
//
// At `W = 1` that is arithmetically the file transform, so the plot describes
// the exported bytes; it is computed at float precision rather than from the
// encoded value's half-float storage, so a bin can sit an ulp from what reading
// the file back would give. At `W > 1` it is the EDR rendition on the same 0…1
// axis, and "highlight clipped" means "at or above W" — the right statement in
// both modes.
//
// Layout of the `counters` buffer (all atomic_uint):
//   [0   .. 255]  luminance bins
//   [256]         shadow-clipped pixel count  (min channel <= 0.5/255)
//   [257]         highlight-clipped pixel count (max channel >= 254.5/255)

kernel void histogramKernel(texture2d<float, access::read> src [[texture(0)]],
                            device atomic_uint *counters       [[buffer(0)]],
                            constant float &displayWhite       [[buffer(1)]],
                            uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= src.get_width() || gid.y >= src.get_height()) return;

    // grSRGBEncode clamps to [0,1] itself.
    float3 c = grSRGBEncode(src.read(gid).rgb / displayWhite);
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
