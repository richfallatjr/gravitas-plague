import Foundation

public final class TuringQwenNativeSharedCloneConditioning: @unchecked Sendable {
    public let identity: UUID
    public let voiceID: String
    public let variantID: String
    let conditioning: TuringQwenNativeBaseCloneConditioning

    init(
        profile: TuringQwenNativeCloneProfile,
        variantID: String,
        loader: TuringQwenNativeCloneArtifactsLoader = .init()
    ) throws {
        guard profile.defaultVariantID == variantID else {
            throw TuringQwenNativeError.invalidConfig(
                "Shared clone-conditioning variant mismatch."
            )
        }
        let loaded = try TuringQwenNativeBaseCloneConditioningBuilder(
            artifactsLoader: loader
        ).load(profile: profile)
        guard loaded.artifacts.voiceID == profile.voiceID,
              loaded.artifacts.variantID == variantID else {
            throw TuringQwenNativeError.invalidConfig(
                "Shared clone-conditioning identity mismatch."
            )
        }
        identity = UUID()
        voiceID = profile.voiceID
        self.variantID = variantID
        conditioning = loaded
    }
}
