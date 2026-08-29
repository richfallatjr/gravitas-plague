import Foundation

nonisolated struct MindEyePackedLayerTexture: @unchecked Sendable {
    let layer: MindEyeLayerTexture
    let alphaBounds: MindEyeAlphaBounds
    let sourceAllocatedBytes: UInt64
    let retainedAllocatedBytes: UInt64

    var savedAllocatedBytes: UInt64 {
        sourceAllocatedBytes > retainedAllocatedBytes
            ? sourceAllocatedBytes - retainedAllocatedBytes
            : 0
    }
}
