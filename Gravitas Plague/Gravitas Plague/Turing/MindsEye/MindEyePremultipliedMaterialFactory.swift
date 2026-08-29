import RealityKit

@MainActor
enum MindEyePremultipliedMaterialFactory {
    static func make(
        textureResource: TextureResource
    ) async -> Result<UnlitMaterial, MindEyeFailure> {
        var material = UnlitMaterial(texture: textureResource)
        material.blending = .transparent(opacity: 1.0)
        material.faceCulling = .none
        material.readsDepth = true
        material.writesDepth = false
        return .success(material)
    }
}
