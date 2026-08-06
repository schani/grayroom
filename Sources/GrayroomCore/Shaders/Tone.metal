// Tone stage: exposure + contrast/highlights/shadows/whites/blacks.
//
// All the curve math happens on the CPU (ToneCurve.swift) and arrives here as a
// 1-D LUT texture (r32Float, size x 1) over log2(Y/0.18) in [minEV, maxEV].
// The kernel is a pure ratio-preserving remap: it looks up Y', then scales RGB
// by Y'/Y, so hue and saturation are untouched.

struct ToneUniforms {
    float minEV;
    float maxEV;
    float gainBelow;   // multiplicative gain below the LUT domain
    float gainAbove;   // multiplicative gain above the LUT domain
    uint  lutSize;
};

kernel void toneKernel(texture2d<float, access::read>  src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       texture2d<float, access::read>  lut [[texture(2)]],
                       constant ToneUniforms &u           [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;

    float4 s = src.read(gid);
    float3 rgb = max(s.rgb, 0.0f);
    float Y = grLuminance(rgb);

    float3 outRGB;
    if (Y <= 1e-9f) {
        outRGB = rgb * u.gainBelow;
    } else {
        float x = log2(Y / kPivot);
        float Yp;
        if (x <= u.minEV) {
            Yp = Y * u.gainBelow;
        } else if (x >= u.maxEV) {
            Yp = Y * u.gainAbove;
        } else {
            float t = (x - u.minEV) / (u.maxEV - u.minEV) * float(u.lutSize - 1u);
            uint i0 = uint(t);
            uint i1 = min(i0 + 1u, u.lutSize - 1u);
            float f = t - float(i0);
            float a = lut.read(uint2(i0, 0)).r;
            float b = lut.read(uint2(i1, 0)).r;
            Yp = mix(a, b, f);
        }
        outRGB = rgb * (Yp / Y);
    }

    dst.write(float4(outRGB, s.a), gid);
}
