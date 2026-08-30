#include <metal_stdlib>

using namespace metal;

struct MindEyeFacialProjectionUniforms {
    float4x4 clipFromSubject;
    float4 controls; // emission, albedo suppression, specular suppression, frustum feather
    float4 anglesAndPadding; // full angle radians, zero angle radians, reserved, reserved
};

inline float mindEyeProjectionSmootherstep(float edge0, float edge1, float value) {
    float u = saturate((value - edge0) / max(edge1 - edge0, 0.000001f));
    return u * u * u * (u * (u * 6.0f - 15.0f) + 10.0f);
}

inline float mindEyeProjectionFacingFade(float angle, float fullAngle, float zeroAngle) {
    return 1.0f - mindEyeProjectionSmootherstep(fullAngle, zeroAngle, angle);
}

inline float mindEyeProjectionFrustumFade(float2 uv, float feather) {
    float2 edgeDistance = min(uv, 1.0f - uv);
    return mindEyeProjectionSmootherstep(0.0f, feather, min(edgeDistance.x, edgeDistance.y));
}

// Compile-time contract kernel. The production material consumes the same math
// through a visionOS-supported ShaderGraphMaterial program.
kernel void mindEyeProjectionMathContract(
    device const float4 *inputs [[buffer(0)]],
    device float4 *outputs [[buffer(1)]],
    constant MindEyeFacialProjectionUniforms &uniforms [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    float4 input = inputs[index]; // mask, alpha, angle, frustum fade
    float facing = mindEyeProjectionFacingFade(
        input.z,
        uniforms.anglesAndPadding.x,
        uniforms.anglesAndPadding.y
    );
    float coverage = saturate(input.x * input.y * facing * input.w);
    outputs[index] = float4(
        coverage,
        1.0f - coverage * uniforms.controls.y,
        1.0f - coverage * uniforms.controls.z,
        coverage * uniforms.controls.x
    );
}
