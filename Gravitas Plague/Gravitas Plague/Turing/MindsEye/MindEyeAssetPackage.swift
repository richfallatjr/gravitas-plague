import Foundation
import Metal

nonisolated struct MindEyeEyeTextures: Sendable {
    let open: [MindEyeGPUTexture]
    let closed: [MindEyeGPUTexture]
}

nonisolated struct MindEyeMouthTextures: Sendable {
    let rest: [MindEyeGPUTexture]
    let small: [MindEyeGPUTexture]
    let wide: [MindEyeGPUTexture]
    let round: [MindEyeGPUTexture]
    let teeth: [MindEyeGPUTexture]

    func textures(for pose: MindEyeMouthPose) -> [MindEyeGPUTexture] {
        switch pose {
        case .rest: rest
        case .small: small
        case .wide: wide
        case .round: round
        case .teeth: teeth
        }
    }

    var allTextures: [MindEyeGPUTexture] {
        MindEyeMouthPose.allCases.flatMap(textures(for:))
    }
}

nonisolated final class MindEyeAssetPackage: @unchecked Sendable {
    let characterID: TuringConversationCharacterID
    let vignetteID: String
    let manifest: MindEyeVignetteManifest
    let background: MindEyeGPUTexture
    let characterBase: MindEyeGPUTexture
    let featherMask: MindEyeGPUTexture
    let eyes: MindEyeEyeTextures
    let mouths: MindEyeMouthTextures
    let estimatedResidentSourceBytes: UInt64

    init(
        characterID: TuringConversationCharacterID,
        vignetteID: String,
        manifest: MindEyeVignetteManifest,
        background: MindEyeGPUTexture,
        characterBase: MindEyeGPUTexture,
        featherMask: MindEyeGPUTexture,
        eyes: MindEyeEyeTextures,
        mouths: MindEyeMouthTextures
    ) throws {
        guard manifest.characterID == characterID,
              manifest.vignetteID == vignetteID,
              !eyes.open.isEmpty,
              !eyes.closed.isEmpty,
              MindEyeMouthPose.allCases.allSatisfy({
                  !mouths.textures(for: $0).isEmpty
              }) else {
            throw MindEyeFailure(
                code: .packageConstructionFailed,
                characterID: characterID,
                vignetteID: vignetteID,
                resourcePath: nil,
                message: "Mind's Eye package is missing a required texture family."
            )
        }
        guard background.metadata.role == .background,
              characterBase.metadata.role == .characterBase,
              featherMask.metadata.role == .featherMask else {
            throw MindEyeFailure(
                code: .packageConstructionFailed,
                characterID: characterID,
                vignetteID: vignetteID,
                resourcePath: nil,
                message: "Mind's Eye package has mismatched core texture roles."
            )
        }

        let textures = [background, characterBase, featherMask] +
            eyes.open + eyes.closed + mouths.allTextures
        var total: UInt64 = 0
        for item in textures {
            let width = UInt64(item.texture.width)
            let height = UInt64(item.texture.height)
            let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
            let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
            guard !pixelOverflow, !byteOverflow else {
                throw MindEyeFailure(
                    code: .packageConstructionFailed,
                    characterID: characterID,
                    vignetteID: vignetteID,
                    resourcePath: item.metadata.resourcePath,
                    message: "Mind's Eye texture byte estimate overflowed."
                )
            }
            let (next, totalOverflow) = total.addingReportingOverflow(bytes)
            guard !totalOverflow else {
                throw MindEyeFailure(
                    code: .packageConstructionFailed,
                    characterID: characterID,
                    vignetteID: vignetteID,
                    resourcePath: item.metadata.resourcePath,
                    message: "Mind's Eye package byte estimate overflowed."
                )
            }
            total = next
        }

        self.characterID = characterID
        self.vignetteID = vignetteID
        self.manifest = manifest
        self.background = background
        self.characterBase = characterBase
        self.featherMask = featherMask
        self.eyes = eyes
        self.mouths = mouths
        estimatedResidentSourceBytes = total
    }

    var allSourceTextures: [MindEyeGPUTexture] {
        [background, characterBase, featherMask] +
            eyes.open + eyes.closed + mouths.allTextures
    }
}

nonisolated struct MindEyePreparedPackageMetadata:
    Sendable,
    Equatable
{
    let resolvedVignette: MindEyeResolvedVignette
    let manifest: MindEyeVignetteManifest
    let background: MindEyeImageMetadata
    let characterBase: MindEyeImageMetadata
    let featherMask: MindEyeImageMetadata
    let eyeOpen: [MindEyeImageMetadata]
    let eyeClosed: [MindEyeImageMetadata]
    let mouths: [MindEyeMouthPose: [MindEyeImageMetadata]]

    var orderedTextureRequests: [MindEyeTextureLoadRequest] {
        var requests = [
            MindEyeTextureLoadRequest(
                metadata: background,
                colorInterpretation: .sRGBColor
            ),
            MindEyeTextureLoadRequest(
                metadata: characterBase,
                colorInterpretation: .sRGBColor
            ),
            MindEyeTextureLoadRequest(
                metadata: featherMask,
                colorInterpretation: .linearMask
            )
        ]
        requests += eyeOpen.map {
            MindEyeTextureLoadRequest(metadata: $0, colorInterpretation: .sRGBColor)
        }
        requests += eyeClosed.map {
            MindEyeTextureLoadRequest(metadata: $0, colorInterpretation: .sRGBColor)
        }
        for pose in MindEyeMouthPose.allCases {
            requests += (mouths[pose] ?? []).map {
                MindEyeTextureLoadRequest(metadata: $0, colorInterpretation: .sRGBColor)
            }
        }
        return requests
    }
}
