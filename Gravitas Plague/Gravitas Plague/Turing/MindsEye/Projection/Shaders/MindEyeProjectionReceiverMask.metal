#include <metal_stdlib>

using namespace metal;

kernel void mindEyeNormalizeReceiverMask(
    texture2d<half, access::read> source [[texture(0)]],
    texture2d<half, access::write> destination [[texture(1)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
        return;
    }
    half value = clamp(source.read(gid).r, half(0.0), half(1.0));
    destination.write(half4(value, value, value, half(1.0)), gid);
}

kernel void mindEyeProjectionDiagnosticChecker(
    texture2d<half, access::write> destination [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= destination.get_width() || gid.y >= destination.get_height()) {
        return;
    }
    const uint cell = 120;
    const uint column = gid.x / cell;
    const uint row = gid.y / cell;
    const bool checker = ((column + row) & 1u) == 0u;
    half3 color = checker ? half3(0.92h) : half3(0.05h);

    // Asymmetric axes make U/V swaps and vertical inversion immediately clear.
    if ((gid.y % cell) < 10u) { color = half3(1.0h, 0.05h, 0.05h); }
    if ((gid.x % cell) < 10u) { color = half3(0.05h, 0.05h, 1.0h); }
    const uint centerX = destination.get_width() / 2u;
    const uint centerY = destination.get_height() / 2u;
    if (abs(int(gid.x) - int(centerX)) < 16 ||
        abs(int(gid.y) - int(centerY)) < 16) {
        color = half3(0.0h, 1.0h, 0.0h);
    }
    // Four unique corner colors stand in for labels 1–4 at this render size.
    if (gid.x < cell && gid.y < cell) color = half3(1.0h, 0.2h, 0.2h);
    if (gid.x >= destination.get_width() - cell && gid.y < cell)
        color = half3(0.2h, 1.0h, 0.2h);
    if (gid.x < cell && gid.y >= destination.get_height() - cell)
        color = half3(0.2h, 0.2h, 1.0h);
    if (gid.x >= destination.get_width() - cell &&
        gid.y >= destination.get_height() - cell)
        color = half3(1.0h, 0.2h, 1.0h);
    destination.write(half4(color, 1.0h), gid);
}
