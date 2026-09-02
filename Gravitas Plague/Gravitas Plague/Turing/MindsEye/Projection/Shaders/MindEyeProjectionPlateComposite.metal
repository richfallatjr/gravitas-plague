#include <metal_stdlib>

using namespace metal;

struct MindEyeProjectionCompositeUniforms {
    uint4 sourceAndOutputDimensions;
    uint2 cropOrigin;
    uint2 reserved;
};

inline half4 mindEyeProjectionPremultiplyStraight(half4 color) {
    half alpha = clamp(color.a, half(0.0), half(1.0));
    return half4(color.rgb * alpha, alpha);
}

inline half4 mindEyeProjectionSourceOver(half4 under, half4 over) {
    half inverseAlpha = half(1.0) - over.a;
    return half4(
        over.rgb + under.rgb * inverseAlpha,
        over.a + under.a * inverseAlpha
    );
}

kernel void mindEyeCompositeProjectionFrame(
    texture2d<half, access::read> projectionBase [[texture(0)]],
    texture2d<half, access::read> selectedEyes [[texture(1)]],
    texture2d<half, access::read> selectedMouth [[texture(2)]],
    texture2d<half, access::write> output [[texture(3)]],
    constant MindEyeProjectionCompositeUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint outputWidth = uniforms.sourceAndOutputDimensions.z;
    uint outputHeight = uniforms.sourceAndOutputDimensions.w;
    if (gid.x >= outputWidth || gid.y >= outputHeight) {
        return;
    }
    // All authored plates share the same 1728-square pixel grid and the output
    // is its exact 1440-square center crop. Direct texel reads are both exact
    // and substantially cheaper than three bilinear samples (twelve filtered
    // fetches) for every output pixel on every viseme transition.
    uint2 sourcePixel = uniforms.cropOrigin + gid;

    // Base, eyes, and mouths are authored in the same 1728-square camera space.
    // Merge them without any per-layer transform so facial registration and key
    // direction remain identical. No later runtime stage mirrors the composite.
    // The authored PNG payload and MTKTextureLoader texture are straight RGBA.
    // Match a Nuke Premult -> Merge(over) graph exactly: premultiply each input
    // once, then evaluate A + B * (1 - A.alpha). Do not clamp straight RGB to
    // alpha and do not unpremultiply between layers.
    half4 composed = mindEyeProjectionPremultiplyStraight(
        projectionBase.read(sourcePixel)
    );
    composed = mindEyeProjectionSourceOver(
        composed,
        mindEyeProjectionPremultiplyStraight(
            selectedEyes.read(sourcePixel)
        )
    );
    composed = mindEyeProjectionSourceOver(
        composed,
        mindEyeProjectionPremultiplyStraight(
            selectedMouth.read(sourcePixel)
        )
    );

    // projection-base.png is contractually opaque, so the merged alpha is 1
    // and premultiplied RGB is numerically identical to straight RGB here.
    output.write(clamp(composed, half4(0.0), half4(1.0)), gid);
}
