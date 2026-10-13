import Foundation

/// Metal Shading Language source, compiled at runtime with
/// `MTLDevice.makeLibrary(source:options:)`.
///
/// Runtime compilation (a few ms, once per renderer) is deliberate: it keeps
/// the package buildable without the separately-downloaded Metal Toolchain,
/// and SwiftPM's `.metal`-resource path silently copies the source file
/// instead of producing a `default.metallib` on such installs.
enum ShaderSource {
    /// Vertices are packed as float4(x, y, u, v): position in source-image
    /// pixels, texture coordinates in [0, 1]. The uniform transform maps image
    /// pixels to NDC with aspect-fit and y-flip already folded in.
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct ArilsVertex {
        float4 position;
        float2 uv;
        float2 padding;
    };

    struct ArilsUniforms {
        float2 scale;
        float2 offset;
        float opacity;
        float cameraDistance;
        float depthRange;
        float zBias;
        float minimumCameraDenominator;
        float opaqueAlphaThreshold;
        float minimumVisibleAlpha;
    };

    struct ArilsVaryings {
        float4 position [[position]];
        float2 uv;
    };

    vertex ArilsVaryings arils_vertex(
        uint vertexID [[vertex_id]],
        const device ArilsVertex *vertices [[buffer(0)]],
        constant ArilsUniforms &uniforms [[buffer(1)]]
    ) {
        ArilsVertex packed = vertices[vertexID];
        ArilsVaryings out;
        float perspective = uniforms.cameraDistance / max(
            uniforms.minimumCameraDenominator,
            uniforms.cameraDistance - packed.position.z
        );
        float2 center = float2(-uniforms.offset.x / uniforms.scale.x, -uniforms.offset.y / uniforms.scale.y);
        float2 projected = center + (packed.position.xy - center) * perspective;
        float depth = clamp(0.5 - packed.position.z / uniforms.depthRange - uniforms.zBias, 0.0, 1.0);
        out.position = float4(projected * uniforms.scale + uniforms.offset, depth, 1.0);
        out.uv = packed.uv;
        return out;
    }

    fragment float4 arils_fragment(
        ArilsVaryings in [[stage_in]],
        texture2d<float> layerTexture [[texture(0)]],
        constant ArilsUniforms &uniforms [[buffer(1)]]
    ) {
        constexpr sampler linearSampler(
            mag_filter::linear,
            min_filter::linear,
            // The transparent side gutters make edge clamping safe during
            // yaw. Vertically, sampling outside the head must become zero;
            // repeating its feathered neck row produces a horizontal seam.
            s_address::clamp_to_edge,
            t_address::clamp_to_zero
        );
        // Textures are premultiplied; opacity scales all four channels so the
        // premultiplied blend (ONE, ONE_MINUS_SRC_ALPHA) stays consistent.
        return layerTexture.sample(linearSampler, in.uv) * uniforms.opacity;
    }


    fragment float4 arils_fragment_opaque(
        ArilsVaryings in [[stage_in]],
        texture2d<float> layerTexture [[texture(0)]],
        constant ArilsUniforms &uniforms [[buffer(1)]]) {
        constexpr sampler s(
            mag_filter::linear,
            min_filter::linear,
            s_address::clamp_to_edge,
            t_address::clamp_to_zero
        );
        float4 color = layerTexture.sample(s, in.uv) * uniforms.opacity;
        if (color.a < uniforms.opaqueAlphaThreshold) discard_fragment();
        return color;
    }

    fragment float4 arils_fragment_feather(
        ArilsVaryings in [[stage_in]],
        texture2d<float> layerTexture [[texture(0)]],
        constant ArilsUniforms &uniforms [[buffer(1)]]) {
        constexpr sampler s(
            mag_filter::linear,
            min_filter::linear,
            s_address::clamp_to_edge,
            t_address::clamp_to_zero
        );
        float4 color = layerTexture.sample(s, in.uv) * uniforms.opacity;
        if (color.a <= uniforms.minimumVisibleAlpha || color.a >= uniforms.opaqueAlphaThreshold) {
            discard_fragment();
        }
        return color;
    }
    """
}
