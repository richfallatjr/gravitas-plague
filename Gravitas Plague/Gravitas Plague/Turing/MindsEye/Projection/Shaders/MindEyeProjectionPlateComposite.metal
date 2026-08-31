#include <metal_stdlib>

using namespace metal;

struct MindEyeProjectionCompositeUniforms {
    uint4 sourceAndOutputDimensions;
    uint2 cropOrigin;
    uint2 reserved;
};

constexpr sampler mindEyeProjectionPlateSampler(
    coord::normalized,
    address::clamp_to_edge,
    filter::linear
);

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
    texture2d<half, access::sample> projectionBase [[texture(0)]],
    texture2d<half, access::sample> selectedEyes [[texture(1)]],
    texture2d<half, access::sample> selectedMouth [[texture(2)]],
    texture2d<half, access::read> projectionMask [[texture(3)]],
    texture2d<half, access::write> output [[texture(4)]],
    constant MindEyeProjectionCompositeUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint outputWidth = uniforms.sourceAndOutputDimensions.z;
    uint outputHeight = uniforms.sourceAndOutputDimensions.w;
    if (gid.x >= outputWidth || gid.y >= outputHeight) {
        return;
    }
    float2 sourceSize = float2(
        uniforms.sourceAndOutputDimensions.x,
        uniforms.sourceAndOutputDimensions.y
    );
    float2 sourcePixel = float2(uniforms.cropOrigin + gid) + 0.5;
    float2 sourceUV = sourcePixel / sourceSize;

    half4 composed = mindEyeProjectionPremultiply(
        projectionBase.sample(mindEyeProjectionPlateSampler, sourceUV)
    );
    composed = mindEyeProjectionSourceOver(
        composed,
        mindEyeProjectionPremultiply(
            selectedEyes.sample(mindEyeProjectionPlateSampler, sourceUV)
        )
    );
    composed = mindEyeProjectionSourceOver(
        composed,
        mindEyeProjectionPremultiply(
            selectedMouth.sample(mindEyeProjectionPlateSampler, sourceUV)
        )
    );

    half mask = clamp(projectionMask.read(gid).r, half(0.0), half(1.0));
    half3 straightRGB = composed.a > half(0.0000152588)
        ? composed.rgb / composed.a
        : half3(0.0);
    output.write(
        clamp(half4(straightRGB, composed.a * mask), half4(0.0), half4(1.0)),
        gid
    );
}
