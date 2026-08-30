import Foundation
import Metal
import RealityKit

@MainActor
final class MindEyeProjectionTextureSource {
    let lowLevelTexture: LowLevelTexture
    let textureResource: TextureResource

    private init(lowLevelTexture: LowLevelTexture, textureResource: TextureResource) {
        self.lowLevelTexture = lowLevelTexture
        self.textureResource = textureResource
    }

    static func make() async throws -> MindEyeProjectionTextureSource {
        let descriptor = LowLevelTexture.Descriptor(
            textureType: .type2D,
            pixelFormat: .bgra8Unorm_srgb,
            width: 1_440,
            height: 1_440,
            depth: 1,
            mipmapLevelCount: 1,
            arrayLength: 1,
            textureUsage: [.shaderRead, .shaderWrite],
            swizzle: .init(red: .red, green: .green, blue: .blue, alpha: .alpha)
        )
        let lowLevelTexture = try LowLevelTexture(descriptor: descriptor)
        let textureResource = try await TextureResource(from: lowLevelTexture)
        return MindEyeProjectionTextureSource(
            lowLevelTexture: lowLevelTexture,
            textureResource: textureResource
        )
    }
}
