import Foundation
import Metal

nonisolated struct MindEyeResolvedCompositeLayers: @unchecked Sendable {
    let background: any MTLTexture
    let characterBase: any MTLTexture
    let selectedEyes: any MTLTexture
    let selectedMouth: any MTLTexture
    let featherMask: any MTLTexture
}

nonisolated enum MindEyeCompositeLayerResolver {
    static func resolve(
        package: MindEyeAssetPackage,
        frame: MindEyeCompositeFrameState
    ) -> Result<MindEyeResolvedCompositeLayers, MindEyeFailure> {
        if let failure = MindEyeCompositeFrameStateValidator.validateBasic(frame) {
            return .failure(failure)
        }

        let eyeTexture: MindEyeGPUTexture?
        switch frame.eyeSelection {
        case .open(let index):
            eyeTexture = package.eyes.open[safe: index]
        case .closed(let index):
            eyeTexture = package.eyes.closed[safe: index]
        }
        let mouthTexture = package.mouths
            .textures(for: frame.mouthSelection.pose)[safe: frame.mouthSelection.variantIndex]

        guard let eyeTexture, let mouthTexture else {
            return .failure(failure(
                package: package,
                "Composite frame selected an unavailable eye or mouth variant."
            ))
        }

        let colors = [
            package.background.texture,
            package.characterBase.texture,
            eyeTexture.texture,
            mouthTexture.texture
        ]
        guard colors.allSatisfy({ $0.width == 2_304 && $0.height == 1_296 }),
              package.featherMask.texture.width == 1_920,
              package.featherMask.texture.height == 1_080 else {
            return .failure(failure(
                package: package,
                "Composite input texture dimensions violate the source contract."
            ))
        }

        return .success(MindEyeResolvedCompositeLayers(
            background: colors[0],
            characterBase: colors[1],
            selectedEyes: colors[2],
            selectedMouth: colors[3],
            featherMask: package.featherMask.texture
        ))
    }

    private static func failure(
        package: MindEyeAssetPackage,
        _ message: String
    ) -> MindEyeFailure {
        MindEyeFailure(
            code: .invalidCompositeSelection,
            characterID: package.characterID,
            vignetteID: package.vignetteID,
            resourcePath: nil,
            message: message
        )
    }
}

private extension Collection where Index == Int {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
