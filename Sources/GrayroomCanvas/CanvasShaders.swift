import Foundation

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
/// The image texture arrives with a mip pyramid (`Pipeline.render`'s
/// `generateDisplayMipmaps`) and is sampled at an **explicit** level, computed
/// on the CPU by `CanvasTransform.displayLOD`. It has to be explicit: the uv is
/// hand-computed and used inside a branch, so the implicit derivatives a sampler
/// would pick its own level from are undefined. Without it a 24 MP frame fitted
/// to a laptop window is point-sampled through a bilinear filter — roughly every
/// fourth pixel of the render — with all the aliasing that implies.
///
/// ## Everything here is linear light
///
/// The image texture holds **display-linear** values (`Pipeline.OutputMode`
/// `.display`, clamped to `[0, W]`) and the drawable is an `rgba16Float` whose
/// layer is tagged **extended linear sRGB** with EDR enabled
/// (`CanvasNSView.init`), so the window server applies the display's transfer
/// function itself and anything above 1.0 lands in the panel's headroom. The
/// shader therefore encodes nothing and dithers nothing: a float16 drawable has
/// no 8-bit quantisation step to dither at. Every constant it composites comes
/// from `CanvasColors`, sRGB-decoded, so the letterbox and the overlay look
/// unchanged.
enum CanvasShaders {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

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
        float  lod;           // explicit mip level for the image sample
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
                                        mip_filter::linear, address::clamp_to_edge);
        constexpr sampler nearestSampler(coord::normalized, filter::nearest,
                                         address::clamp_to_edge);

        // [[position]] is in render-target pixels with the origin top-left,
        // which is the same space CanvasTransform works in.
        float2 v = in.position.xy;
        float2 img = (v - u.viewSize * 0.5) / max(u.zoom, 1e-6) + u.center;

        // Backdrop outside the image: sRGB 0.09/0.09/0.10, decoded.
        float3 rgb = \(CanvasColors.msl(CanvasColors.backdropLinear));

        if (img.x >= 0.0 && img.y >= 0.0 && img.x < u.imageSize.x && img.y < u.imageSize.y) {
            float2 uv = img / u.imageSize;
            // Explicit level: the uv here is hand-computed inside a branch, so
            // the sampler has no derivatives to work from. u.lod is 0 whenever
            // the image is magnified, and grows as it is minified.
            rgb = (u.nearest > 0.5) ? image.sample(nearestSampler, uv, level(0.0)).rgb
                                    : image.sample(linearSampler, uv, level(u.lod)).rgb;
            if (u.overlay > 0.5) {
                // The coverage map is soft and never mipmapped; level 0 always.
                float cov = clamp(coverage.sample(linearSampler, uv, level(0.0)).r, 0.0, 1.0);
                rgb = mix(rgb, \(CanvasColors.msl(CanvasColors.overlayLinear)), 0.5 * cov);
            }
        }

        // Brush cursor: an outer ring at the stamp radius and a fainter inner
        // ring where the falloff starts, drawn as a dark/light pair so it stays
        // visible on both black and white. Black and white are the same numbers
        // in linear light, so only the blend happens in a different space.
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

        // Straight through: the drawable is extended-linear-sRGB float16, so
        // there is nothing to encode and no quantisation step to dither at.
        return float4(rgb, 1.0);
    }
    """
}
