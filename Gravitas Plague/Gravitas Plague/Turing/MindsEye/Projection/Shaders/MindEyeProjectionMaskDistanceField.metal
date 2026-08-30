#include <metal_stdlib>

using namespace metal;

inline float mindEyeMaskSmootherstep(float edge0, float edge1, float value) {
    float u = saturate((value - edge0) / max(edge1 - edge0, 0.000001f));
    return u * u * u * (u * (u * 6.0f - 15.0f) + 10.0f);
}

kernel void mindEyeProjectionApplySignedDistance(
    texture2d<float, access::read> signedDistance [[texture(0)]],
    texture2d<half, access::write> output [[texture(1)]],
    constant float2 &insetAndFeather [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
    float distance = signedDistance.read(gid).r;
    float coverage = mindEyeMaskSmootherstep(-insetAndFeather.y, insetAndFeather.x, distance);
    output.write(half4(half(coverage), half(coverage), half(coverage), half(1)), gid);
}
