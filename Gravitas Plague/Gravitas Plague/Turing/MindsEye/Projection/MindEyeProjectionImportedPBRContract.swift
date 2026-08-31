import CoreGraphics
import Foundation
import Metal
import RealityKit

nonisolated struct MindEyeProjectionImportedPBRContract: Codable, Sendable, Equatable {
    enum TextureSemantic: String, Codable, Sendable, Equatable {
        case color
        case rawData
        case tangentSpaceNormal
    }

    enum ScalarChannel: String, Codable, Sendable, Equatable {
        case red
        case green
        case blue
        case alpha
    }

    struct TextureBinding: Codable, Sendable, Equatable {
        let role: String
        let sourceAssetPath: String
        let sourceAssetSHA256: String
        let UVSetName: String
        let UVSetIndex: Int
        let semantic: TextureSemantic
        let scalarChannel: ScalarChannel?
        let noFlipV: Bool
        let wrapS: String
        let wrapT: String
        let transformScale: [Float]
        let transformTranslation: [Float]
        let transformRotationDegrees: Float
        let scale: [Float]
        let bias: [Float]

        var isIdentityUVTransform: Bool {
            transformScale == [1, 1] &&
                transformTranslation == [0, 0] &&
                transformRotationDegrees == 0
        }
    }

    let schemaVersion: Int
    let contractID: String
    let graphVersion: String
    let subjectAssetName: String
    let subjectAssetSHA256: String
    let targetEntityPath: String
    let materialIndex: Int
    let materialNetworkType: String
    let surfaceShaderID: String
    let baseColor: TextureBinding
    let metallic: TextureBinding
    let roughness: TextureBinding
    let normal: TextureBinding
    let emission: TextureBinding
    let expectedOpacityMode: String
    let expectedFaceCulling: String
    let unsupportedNondefaultFeatures: [String]

    func validate(
        profile: MindEyeProjectionProfile,
        target: MindEyeProjectionTargetDescriptor
    ) throws {
        guard schemaVersion == 1,
              contractID == "angel_head_v1.pbr-binding",
              graphVersion == "angel-camera-projector-uv-receiver/2",
              subjectAssetName == profile.subjectAssetName,
              Self.validSHA(subjectAssetSHA256),
              targetEntityPath == target.targetEntityPath,
              materialIndex == 0,
              materialNetworkType == "UsdPreviewSurface",
              surfaceShaderID == "UsdPreviewSurface",
              expectedOpacityMode == "opaque",
              unsupportedNondefaultFeatures.isEmpty else {
            throw MindEyeProjectionError.unsupportedImportedPBR(
                unsupportedNondefaultFeatures.joined(separator: ",")
            )
        }
        for binding in [baseColor, metallic, roughness, normal, emission] {
            guard binding.UVSetName == "primvars:st",
                  binding.UVSetIndex == 0,
                  Self.validSHA(binding.sourceAssetSHA256),
                  binding.transformScale.count == 2,
                  binding.transformTranslation.count == 2,
                  binding.scale.count == 4,
                  binding.bias.count == 4,
                  ["repeat", "clamp", "mirror", "black"].contains(binding.wrapS),
                  ["repeat", "clamp", "mirror", "black"].contains(binding.wrapT) else {
                throw MindEyeProjectionError.unsupportedImportedPBR(
                    "invalid imported texture contract for \(binding.role)"
                )
            }
        }
        guard baseColor.role == "baseColor",
              metallic.role == "metallic",
              roughness.role == "roughness",
              normal.role == "normal",
              emission.role == "emission",
              baseColor.semantic == .color,
              metallic.semantic == .rawData,
              roughness.semantic == .rawData,
              normal.semantic == .tangentSpaceNormal,
              emission.semantic == .color else {
            throw MindEyeProjectionError.unsupportedImportedPBR(
                "imported texture semantics do not match the production graph"
            )
        }
        guard baseColor.scale == [1, 1, 1, 1],
              baseColor.bias == [0, 0, 0, 0],
              emission.scale == [1, 1, 1, 1],
              emission.bias == [0, 0, 0, 0],
              metallic.scalarChannel != nil,
              roughness.scalarChannel != nil else {
            throw MindEyeProjectionError.unsupportedImportedPBR(
                "the current graph cannot preserve a nonidentity color-map scale/bias"
            )
        }
    }

    private static func validSHA(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }
}

nonisolated final class MindEyeProjectionImportedPBRSnapshot: @unchecked Sendable {
    let originalMaterial: PhysicallyBasedMaterial
    let baseTexture: MaterialParameters.Texture
    let metallicTexture: MaterialParameters.Texture
    let roughnessTexture: MaterialParameters.Texture
    let normalTexture: MaterialParameters.Texture
    let emissionTexture: MaterialParameters.Texture
    let baseTint: CGColor
    let emissionTint: CGColor
    let metallicScale: Float
    let roughnessScale: Float
    let specularScale: Float
    let emissionIntensity: Float
    let faceCulling: PhysicallyBasedMaterial.FaceCulling

    init(
        PBR: PhysicallyBasedMaterial,
        contract: MindEyeProjectionImportedPBRContract,
        entityPath: String
    ) throws {
        guard let base = PBR.baseColor.texture,
              let metallic = PBR.metallic.texture,
              let roughness = PBR.roughness.texture,
              let normal = PBR.normal.texture,
              let emission = PBR.emissiveColor.texture else {
            throw MindEyeProjectionError.unsupportedImportedPBR(
                "required texture map missing at \(entityPath)"
            )
        }
        guard contract.unsupportedNondefaultFeatures.isEmpty else {
            throw MindEyeProjectionError.unsupportedImportedPBR(
                contract.unsupportedNondefaultFeatures.joined(separator: ",")
            )
        }
        originalMaterial = PBR
        baseTexture = base
        metallicTexture = metallic
        roughnessTexture = roughness
        normalTexture = normal
        emissionTexture = emission
        baseTint = PBR.baseColor.__tint
        // This production USD network connects UsdUVTexture directly to
        // UsdPreviewSurface.emissiveColor. RealityKit retains the imported
        // texture but exposes the API's default black color alongside it; that
        // stored default is not the multiplier used by the imported network.
        // Reconstruct the USD graph with its neutral scale/bias multiplier.
        emissionTint = CGColor(gray: 1, alpha: 1)
        metallicScale = PBR.metallic.scale
        roughnessScale = PBR.roughness.scale
        specularScale = PBR.specular.scale
        emissionIntensity = PBR.emissiveIntensity
        faceCulling = PBR.faceCulling
#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
        func samplerDescription(_ texture: MaterialParameters.Texture) -> String {
            texture.sampler.access { descriptor in
                "min=\(descriptor.minFilter.rawValue) " +
                    "mag=\(descriptor.magFilter.rawValue) " +
                    "mip=\(descriptor.mipFilter.rawValue) " +
                    "s=\(descriptor.sAddressMode.rawValue) " +
                    "t=\(descriptor.tAddressMode.rawValue) " +
                    "aniso=\(descriptor.maxAnisotropy) " +
                    "lod=\(descriptor.lodMinClamp)...\(descriptor.lodMaxClamp)"
            }
        }
        print(
            "[MindEyeProjectionPBR] captured entity=\(entityPath) " +
                "baseTint=\(String(describing: baseTint.components)) " +
                "emissionTint=\(String(describing: emissionTint.components)) " +
                "metallicScale=\(metallicScale) roughnessScale=\(roughnessScale) " +
                "specularScale=\(specularScale) emissionIntensity=\(emissionIntensity) " +
                "faceCulling=\(String(describing: faceCulling))"
        )
        print(
            "[MindEyeProjectionPBR] samplers " +
                "base{\(samplerDescription(base))} " +
                "metallic{\(samplerDescription(metallic))} " +
                "roughness{\(samplerDescription(roughness))} " +
                "normal{\(samplerDescription(normal))} " +
                "emission{\(samplerDescription(emission))}"
        )
#endif
    }
}
