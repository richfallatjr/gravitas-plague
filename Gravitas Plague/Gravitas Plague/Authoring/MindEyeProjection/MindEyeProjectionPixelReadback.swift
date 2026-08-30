#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import Foundation
import Metal

nonisolated struct MindEyeProjectionPixelBuffer: Sendable {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bgra8: Data
}

nonisolated enum MindEyeProjectionPixelReadback {
    static func read(texture: any MTLTexture, device: any MTLDevice) async throws
        -> MindEyeProjectionPixelBuffer {
        let tightBytesPerRow = texture.width * 4
        let bytesPerRow = ((tightBytesPerRow + 255) / 256) * 256
        let length = bytesPerRow * texture.height
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared),
              let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else {
            throw MindEyeProjectionError.renderFailed("could not allocate readback staging")
        }
        blit.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: texture.width, height: texture.height, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: length
        )
        blit.endEncoding()
        let completed = await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { value in
                continuation.resume(returning: value.status == .completed)
            }
            commandBuffer.commit()
        }
        guard completed else {
            throw MindEyeProjectionError.renderFailed("GPU readback failed")
        }
        return MindEyeProjectionPixelBuffer(
            width: texture.width,
            height: texture.height,
            bytesPerRow: bytesPerRow,
            bgra8: Data(bytes: buffer.contents(), count: length)
        )
    }
}
#endif
