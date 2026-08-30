#include <metal_stdlib>

using namespace metal;

kernel void mindEyeProjectionBinaryMask(
    texture2d<half, access::read> source [[texture(0)]],
    texture2d<half, access::write> output [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
    half4 color = source.read(gid);
    half value = max(max(color.r, color.g), max(color.b, color.a)) > half(0.5) ? half(1) : half(0);
    output.write(half4(value, value, value, half(1)), gid);
}
