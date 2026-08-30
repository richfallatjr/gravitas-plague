#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import Metal

nonisolated final class MindEyeProjectionRenderTarget: @unchecked Sendable {
    let texture: any MTLTexture
    let pixelFormat: MTLPixelFormat

    init(device: any MTLDevice, width: Int = 1_728, height: Int = 1_728,
         pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb) throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MindEyeProjectionError.rendererUnavailable("could not allocate render target")
        }
        texture.label = "MindEyeProjectionAuthoringTarget"
        self.texture = texture
        self.pixelFormat = pixelFormat
    }
}
#endif
