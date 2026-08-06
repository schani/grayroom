// Output transform: linear (Rec.709 primaries) -> sRGB display encoding.

kernel void outputKernel(texture2d<float, access::read>  src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 s = src.read(gid);
    dst.write(float4(grSRGBEncode(s.rgb), 1.0f), gid);
}
