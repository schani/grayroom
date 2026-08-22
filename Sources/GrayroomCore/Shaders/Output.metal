// Output transform.
//
// Two output points, one pipeline:
//
//   outputKernel         file output — linear -> sRGB display encoding, [0,1].
//   displayOutputKernel  canvas output — stays LINEAR, clamped to [0, W].
//
// The display kernel does no encoding because the canvas drawable is an
// extended-linear-sRGB float16 surface: the window server applies the display's
// own transfer function, and values above 1 land in the panel's EDR headroom.
// It also does no dithering — a float16 drawable has no 8-bit step to dither at.

kernel void outputKernel(texture2d<float, access::read>  src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 s = src.read(gid);
    dst.write(float4(grSRGBEncode(s.rgb), 1.0f), gid);
}

kernel void displayOutputKernel(texture2d<float, access::read>  src [[texture(0)]],
                                texture2d<float, access::write> dst [[texture(1)]],
                                constant float &displayWhite      [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 s = src.read(gid);
    dst.write(float4(clamp(s.rgb, 0.0f, displayWhite), 1.0f), gid);
}
