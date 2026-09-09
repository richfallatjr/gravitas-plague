#include <metal_stdlib>
using namespace metal;

/// RealityKit supplies Dad's imported positions as tightly packed float3 data.
/// The authored deltas are uploaded once as float4 values so their alignment is
/// explicit on both Swift and Metal. This pass runs before RealityKit skinning.
kernel void characterVocalApplyDenseOffsets(
    device const packed_float3 *inputPositions [[buffer(0)]],
    device packed_float3 *outputPositions [[buffer(1)]],
    device const float4 *offsets [[buffer(2)]],
    constant float &weight [[buffer(3)]],
    constant uint &vertexCount [[buffer(4)]],
    uint vertexIndex [[thread_position_in_grid]])
{
    if (vertexIndex >= vertexCount) {
        return;
    }

    const float3 position = float3(inputPositions[vertexIndex]);
    const float3 delta = offsets[vertexIndex].xyz * clamp(weight, 0.0f, 1.0f);
    outputPositions[vertexIndex] = packed_float3(position + delta);
}
