#include <metal_stdlib>

using namespace metal;

struct MindEyeProjectionCompositeUniforms {
    uint4 sourceAndOutputDimensions;
    uint2 cropOrigin;
    uint2 reserved;
};

inline half4 mindEyeProjectionPremultiply(half4 straightColor) {
    half alpha = clamp(straightColor.a, half(0.0), half(1.0));
    return half4(straightColor.rgb * alpha, alpha);
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

    half4 composed = mindEyeProjectionPremultiply(
        projectionBase.read(sourcePixel)
    );
    composed = mindEyeProjectionSourceOver(
        composed,
        mindEyeProjectionPremultiply(
            selectedEyes.read(sourcePixel)
        )
    );
    composed = mindEyeProjectionSourceOver(
        composed,
        mindEyeProjectionPremultiply(
            selectedMouth.read(sourcePixel)
        )
    );

    half3 straightRGB = composed.a > half(0.0000152588)
        ? composed.rgb / composed.a
        : half3(0.0);
    output.write(
        clamp(half4(straightRGB, composed.a), half4(0.0), half4(1.0)),
        gid
    );
}
