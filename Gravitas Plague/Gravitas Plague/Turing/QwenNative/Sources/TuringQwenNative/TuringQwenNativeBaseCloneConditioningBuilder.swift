import Foundation

struct TuringQwenNativeBaseCloneConditioning: Sendable {
    let artifacts: TuringQwenNativeCloneArtifacts
    let variant: TuringQwenNativeCloneProfile.Variant
}

struct TuringQwenNativeBaseCloneConditioningBuilder: Sendable {
    private let artifactsLoader: TuringQwenNativeCloneArtifactsLoader

    init(
        artifactsLoader: TuringQwenNativeCloneArtifactsLoader = TuringQwenNativeCloneArtifactsLoader()
    ) {
        self.artifactsLoader = artifactsLoader
    }

    func load(
        profile: TuringQwenNativeCloneProfile
    ) throws -> TuringQwenNativeBaseCloneConditioning {
        let variant = try profile.requireVariant(profile.defaultVariantID)
        let artifacts = try artifactsLoader.load(from: variant)

        guard artifacts.xVectorOnlyMode == false else {
            throw TuringQwenNativeError.invalidConfig(
                "Big Mike Base clone must use baseCloneICL artifacts, not xVectorOnlyMode."
            )
        }
        guard artifacts.referenceRowCount > 0,
              artifacts.codebookCount == 16 else {
            throw TuringQwenNativeError.invalidConfig(
                "Big Mike Base clone artifacts must include non-empty reference_codes rows_x_codebooks with 16 codebooks."
            )
        }

        return TuringQwenNativeBaseCloneConditioning(
            artifacts: artifacts,
            variant: variant
        )
    }
}
