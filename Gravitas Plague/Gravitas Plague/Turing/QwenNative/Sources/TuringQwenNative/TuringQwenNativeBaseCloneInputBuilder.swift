import Foundation
import MLX

struct TuringQwenNativeBaseClonePromptRequest: Sendable {
    let targetText: String
    let targetLanguage: String
    let cloneArtifacts: TuringQwenNativeCloneArtifacts
}

struct TuringQwenNativePreparedBaseClonePrompt: Sendable {
    let layout: String
    let targetInputIDs: [Int]
    let refTextTokens: [Int32]
    let referenceCodes: [[Int32]]
    let speakerEmbedding: [Float]
    let referenceRowCount: Int
    let languageCodecID: Int
    let xVectorOnlyMode: Bool

    var speakerEmbeddingArray: MLXArray {
        MLXArray(speakerEmbedding, [1, speakerEmbedding.count])
    }
}

enum TuringQwenNativeBaseCloneInputBuilder {
    static func build(
        request: TuringQwenNativeBaseClonePromptRequest,
        config: TuringQwenNativeConfig,
        tokenizer: TuringQwenNativeTokenizer
    ) throws -> TuringQwenNativePreparedBaseClonePrompt {
        try config.validateBaseCloneRuntime()
        guard request.cloneArtifacts.xVectorOnlyMode == false else {
            throw TuringQwenNativeError.invalidConfig(
                "Base clone runtime requires ICL artifacts with xVectorOnlyMode false."
            )
        }
        guard let languageCodecID = config.talkerConfig.codecLanguageID[
            request.targetLanguage.lowercased()
        ] ?? config.talkerConfig.codecLanguageID["english"] else {
            throw TuringQwenNativeError.invalidConfig(
                "Missing codec language ID for \(request.targetLanguage)."
            )
        }

        let targetPrompt = """
        <|im_start|>assistant
        \(request.targetText)<|im_end|>
        <|im_start|>assistant
        """
        let targetInputIDs = try tokenizer.encode(targetPrompt)
        guard targetInputIDs.count >= 3 else {
            throw TuringQwenNativeError.tokenizer(
                "Base clone target prompt did not produce assistant role tokens."
            )
        }

        return TuringQwenNativePreparedBaseClonePrompt(
            layout: "officialBaseICL",
            targetInputIDs: targetInputIDs,
            refTextTokens: request.cloneArtifacts.refTextTokens,
            referenceCodes: request.cloneArtifacts.referenceCodes,
            speakerEmbedding: request.cloneArtifacts.speakerEmbedding,
            referenceRowCount: request.cloneArtifacts.referenceRowCount,
            languageCodecID: languageCodecID,
            xVectorOnlyMode: request.cloneArtifacts.xVectorOnlyMode
        )
    }
}
