import Foundation
import GrayroomCore

/// The canvas display shader.
///
/// It lives here as a string rather than as a bundled `.metal` resource (the
/// convention in `GrayroomCore`) for one reason: this is *display* code, not
/// imaging code — nothing in the headless core or the golden tests can see it —
/// and keeping it inline means the executable needs no resource bundle at all,
/// which is one less thing that can go wrong when the app is launched as a bare
/// binary by `swift run`.
///
/// What it does: one full-screen triangle strip; the fragment shader inverts the
/// canvas transform per pixel to find the image texel, so zoom and pan cost
/// nothing and the drawable is always exactly window-sized.
///
/// The image texture holds **output-referred, sRGB-encoded** values (the
/// pipeline's `output` stage did that) and the drawable is a `bgra8Unorm` whose
/// layer is tagged **sRGB** (`CanvasNSView.init`), so the window server colour-
/// matches it to the display profile — what you see is what `ImageWriter` would
/// put in a PNG, on a wide-gamut display too. The fragment shader dithers to
/// 8 bits with exactly the same rule the exporter uses, so smooth gradients do
/// not band on screen either.
enum CanvasShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    \(Dither.metalSource)

    struct CanvasUniforms {
        float2 viewSize;      // device pixels
        float2 imageSize;     // image pixels
        float2 center;        // image point under the centre of the view
        float2 cursor;        // device pixels
        float  zoom;          // device pixels per image pixel
        float  overlay;       // 1 = composite the mask coverage
        float  cursorRadius;  // device pixels; <= 0 hides the brush cursor
        float  cursorInner;   // full-opacity radius (the feather ring)
        float  nearest;       // 1 = nearest sampling (pixel peeping)
    };

    struct Varyings {
        float4 position [[position]];
    };

    vertex Varyings canvasVertex(uint vid [[vertex_id]]) {
        // Triangle strip covering clip space.
        const float2 corners[4] = {
            float2(-1.0, -1.0), float2(1.0, -1.0),
            float2(-1.0,  1.0), float2(1.0,  1.0)
        };
        Varyings out;
        out.position = float4(corners[vid], 0.0, 1.0);
        return out;
    }

    fragment float4 canvasFragment(Varyings in [[stage_in]],
                                   texture2d<float> image    [[texture(0)]],
                                   texture2d<float> coverage [[texture(1)]],
                                   constant CanvasUniforms &u [[buffer(0)]])
    {
        constexpr sampler linearSampler(coord::normalized, filter::linear,
                                        address::clamp_to_edge);
        constexpr sampler nearestSampler(coord::normalized, filter::nearest,
                                         address::clamp_to_edge);

        // [[position]] is in render-target pixels with the origin top-left,
        // which is the same space CanvasTransform works in.
        float2 v = in.position.xy;
        float2 img = (v - u.viewSize * 0.5) / max(u.zoom, 1e-6) + u.center;

        float3 rgb = float3(0.09, 0.09, 0.10);   // backdrop outside the image

        if (img.x >= 0.0 && img.y >= 0.0 && img.x < u.imageSize.x && img.y < u.imageSize.y) {
            float2 uv = img / u.imageSize;
            rgb = (u.nearest > 0.5) ? image.sample(nearestSampler, uv).rgb
                                    : image.sample(linearSampler, uv).rgb;
            if (u.overlay > 0.5) {
                float cov = clamp(coverage.sample(linearSampler, uv).r, 0.0, 1.0);
                rgb = mix(rgb, float3(1.0, 0.15, 0.15), 0.5 * cov);
            }
        }

        // Brush cursor: an outer ring at the stamp radius and a fainter inner
        // ring where the falloff starts, drawn as a dark/light pair so it stays
        // visible on both black and white.
        if (u.cursorRadius > 0.0) {
            float d = distance(v, u.cursor);
            float outer = 1.0 - smoothstep(0.6, 1.8, abs(d - u.cursorRadius));
            rgb = mix(rgb, float3(0.0), 0.55 * (1.0 - smoothstep(1.4, 3.0, abs(d - u.cursorRadius))));
            rgb = mix(rgb, float3(1.0), 0.9 * outer);
            if (u.cursorInner > 1.0) {
                float inner = 1.0 - smoothstep(0.6, 1.8, abs(d - u.cursorInner));
                rgb = mix(rgb, float3(1.0), 0.45 * inner);
            }
        }

        // Dither at the 8-bit drawable's quantisation step, per channel, keyed
        // on the device pixel — the same rule ImageWriter applies on export.
        uint2 p = uint2(v);
        rgb = float3(grDither8(rgb.r, p.x, p.y, 0u),
                     grDither8(rgb.g, p.x, p.y, 1u),
                     grDither8(rgb.b, p.x, p.y, 2u));
        return float4(rgb, 1.0);
    }
    """
}
