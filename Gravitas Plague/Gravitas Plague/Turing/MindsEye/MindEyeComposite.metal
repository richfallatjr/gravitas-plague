#include <metal_stdlib>

using namespace metal;

struct MindEyeCompositeUniforms {
    uint4 dimensions;
    uint4 cropAndFlags;
    float4 backgroundTransform;
    float4 characterTransform;
};

constant uint mindEyeMaskArtistRGB = 0;
constant uint mindEyeMaskHardRectangle = 1;
constant uint mindEyeMaskPreview = 2;
constant uint mindEyeFinalAlphaPreview = 3;

constexpr sampler mindEyeColorSampler(
    coord::normalized,
    address::clamp_to_edge,
    filter::linear
);

inline float2 mindEyeInverseTransform(float2 logicalYUp, float4 transform) {
    float safeScale = max(transform.w, 0.0001);
    float2 local = logicalYUp - transform.xy;
    float angle = -transform.z;
    float cosine = cos(angle);
    float sine = sin(angle);
    local = float2(
        cosine * local.x - sine * local.y,
        sine * local.x + cosine * local.y
    );
    return local / safeScale;
}

inline float2 mindEyeSourcePixel(
    uint2 gid,
    uint4 dimensions,
    uint4 cropAndFlags,
    float4 transform
) {
    float2 outputSize = float2(dimensions.z, dimensions.w);
    float2 outputPixelCenter = float2(gid) + 0.5;
    float2 logicalYUp = float2(
        outputPixelCenter.x - outputSize.x * 0.5,
        outputSize.y * 0.5 - outputPixelCenter.y
    );
    float2 local = mindEyeInverseTransform(logicalYUp, transform);
    float2 sourceViewportCenter = float2(
        float(cropAndFlags.x) + outputSize.x * 0.5,
        float(cropAndFlags.y) + outputSize.y * 0.5
    );
    return float2(
        sourceViewportCenter.x + local.x,
        sourceViewportCenter.y - local.y
    );
}

inline bool mindEyeSourcePixelIsSafe(float2 sourcePixel, float2 sourceSize) {
    return sourcePixel.x >= 0.5 &&
        sourcePixel.y >= 0.5 &&
        sourcePixel.x <= sourceSize.x - 0.5 &&
        sourcePixel.y <= sourceSize.y - 0.5;
}

inline half4 mindEyeSampleStraight(
    texture2d<half, access::sample> texture,
    float2 sourcePixel,
    float2 sourceSize
) {
    if (!mindEyeSourcePixelIsSafe(sourcePixel, sourceSize)) {
        return half4(0.0h);
    }
    return texture.sample(mindEyeColorSampler, sourcePixel / sourceSize);
}

inline half4 mindEyePremultiply(half4 straightColor) {
    half alpha = clamp(straightColor.a, half(0.0), half(1.0));
    return half4(straightColor.rgb * alpha, alpha);
}

inline half4 mindEyeSourceOverPremultiplied(
    half4 underColor,
    half4 overColor
) {
    half oneMinusOver = half(1.0) - overColor.a;
    return half4(
        overColor.rgb + underColor.rgb * oneMinusOver,
        overColor.a + underColor.a * oneMinusOver
    );
}

inline half mindEyeMaskLuminance(half3 rgb) {
    half luminance = clamp(
        dot(rgb, half3(0.2126h, 0.7152h, 0.0722h)),
        half(0.0),
        half(1.0)
    );
    // The artist mask's outermost pixels reach 21/255 rather than true black.
    // Establish a measured black point so the card boundary is guaranteed to
    // become fully transparent while preserving the authored feather ramp.
    constexpr half blackPoint = half(22.0 / 255.0);
    return clamp(
        (luminance - blackPoint) / (half(1.0) - blackPoint),
        half(0.0),
        half(1.0)
    );
}

kernel void mindEyeCompositeFrame(
    texture2d<half, access::sample> background [[texture(0)]],
    texture2d<half, access::sample> characterBase [[texture(1)]],
    texture2d<half, access::sample> selectedEyes [[texture(2)]],
    texture2d<half, access::sample> selectedMouth [[texture(3)]],
    texture2d<half, access::read> featherMask [[texture(4)]],
    texture2d<half, access::write> output [[texture(5)]],
    constant MindEyeCompositeUniforms &uniforms [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint outputWidth = uniforms.dimensions.z;
    uint outputHeight = uniforms.dimensions.w;
    if (gid.x >= outputWidth || gid.y >= outputHeight) {
        return;
    }

    float2 sourceSize = float2(uniforms.dimensions.x, uniforms.dimensions.y);
    float2 backgroundPixel = mindEyeSourcePixel(
        gid,
        uniforms.dimensions,
        uniforms.cropAndFlags,
        uniforms.backgroundTransform
    );
    float2 characterPixel = mindEyeSourcePixel(
        gid,
        uniforms.dimensions,
        uniforms.cropAndFlags,
        uniforms.characterTransform
    );

    half4 composed = mindEyePremultiply(
        mindEyeSampleStraight(background, backgroundPixel, sourceSize)
    );
    composed = mindEyeSourceOverPremultiplied(
        composed,
        mindEyePremultiply(
            mindEyeSampleStraight(characterBase, characterPixel, sourceSize)
        )
    );
    composed = mindEyeSourceOverPremultiplied(
        composed,
        mindEyePremultiply(
            mindEyeSampleStraight(selectedEyes, characterPixel, sourceSize)
        )
    );
    composed = mindEyeSourceOverPremultiplied(
        composed,
        mindEyePremultiply(
            mindEyeSampleStraight(selectedMouth, characterPixel, sourceSize)
        )
    );

    half maskAlpha = half(1.0);
    uint maskMode = uniforms.cropAndFlags.z;
    if (maskMode != mindEyeMaskHardRectangle) {
        maskAlpha = mindEyeMaskLuminance(featherMask.read(gid).rgb);
    }
    half sourceAlpha = composed.a;
    half finalAlpha = sourceAlpha * maskAlpha;

    if (maskMode == mindEyeMaskPreview) {
        output.write(half4(maskAlpha, maskAlpha, maskAlpha, half(1.0)), gid);
        return;
    }
    if (maskMode == mindEyeFinalAlphaPreview) {
        half alpha = finalAlpha;
        output.write(half4(alpha, alpha, alpha, half(1.0)), gid);
        return;
    }
    half3 straightRGB = sourceAlpha > half(0.0000152588)
        ? composed.rgb / sourceAlpha
        : half3(0.0h);
    output.write(
        clamp(half4(straightRGB, finalAlpha), half4(0.0h), half4(1.0h)),
        gid
    );
}
