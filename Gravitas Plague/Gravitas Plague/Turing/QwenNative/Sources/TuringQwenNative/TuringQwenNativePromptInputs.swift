import Foundation
import MLX

struct TuringQwenNativeTalkerPromptInputs {
    let inputsEmbeds: MLXArray
    let attentionMask: MLXArray
    let trailingTextHidden: MLXArray
    let ttsPadEmbed: MLXArray
    let sequenceLength: Int
    let hiddenSize: Int
}

enum TuringQwenNativeTalkerPromptInputBuilder {
    static func build(
        prompt: TuringQwenNativeVoiceDesignPrompt,
        config: TuringQwenNativeConfig,
        tensorIndex: TuringQwenNativeSafetensorsIndex
    ) throws -> TuringQwenNativeTalkerPromptInputs {
        let weights = try TuringQwenNativeTalkerPromptWeights(
            reader: TuringQwenNativeSafetensorsReader(index: tensorIndex),
            hiddenSize: config.talkerConfig.hiddenSize,
            textHiddenSize: config.talkerConfig.textHiddenSize
        )

        let roleIDs = try prefix(prompt.assistantInputIDs, count: 3, label: "assistant role IDs")
        let bodyIDs = try assistantBodyIDs(prompt.assistantInputIDs)
        let languageID = try englishLanguageID(config)

        let instructEmbed = try weights.projectTextEmbedding(ids: prompt.instructInputIDs)
        let ttsBosEmbed = try weights.projectTextEmbedding(ids: [config.ttsBosTokenID])
        let ttsEosEmbed = try weights.projectTextEmbedding(ids: [config.ttsEosTokenID])
        let ttsPadEmbed = try weights.projectTextEmbedding(ids: [config.ttsPadTokenID])

        let codecThinkPrefill = try weights.codecEmbedding(ids: [
            config.talkerConfig.codecThinkID,
            config.talkerConfig.codecThinkBosID,
            languageID,
            config.talkerConfig.codecThinkEosID
        ])
        let codecPadEmbed = try weights.codecEmbedding(ids: [config.talkerConfig.codecPadID])
        let codecBosEmbed = try weights.codecEmbedding(ids: [config.talkerConfig.codecBosID])

        let roleEmbed = try weights.projectTextEmbedding(ids: roleIDs)
        let padPrefix = repeatSequence(ttsPadEmbed, count: 4)
        let codecMinusLast = concatenated([codecThinkPrefill, codecPadEmbed], axis: 1)
        let codecTagAndSpeaker = concatenated([padPrefix, ttsBosEmbed], axis: 1) + codecMinusLast

        let textBodyEmbed = try weights.projectTextEmbedding(ids: bodyIDs)
        let codecPadForBody = repeatSequence(codecPadEmbed, count: bodyIDs.count + 1)
        let textBodyAndEos = concatenated([textBodyEmbed, ttsEosEmbed], axis: 1) + codecPadForBody
        let finalCodecBos = ttsPadEmbed + codecBosEmbed

        let speechPromptEmbed = concatenated([
            roleEmbed,
            codecTagAndSpeaker,
            textBodyAndEos,
            finalCodecBos
        ], axis: 1)

        let inputsEmbeds = concatenated([instructEmbed, speechPromptEmbed], axis: 1)
        let sequenceLength = prompt.instructInputIDs.count + 3 + 5 + bodyIDs.count + 1 + 1
        let attentionMask = MLXArray(
            int64: Array(repeating: 1, count: sequenceLength),
            [1, sequenceLength]
        )

        eval(inputsEmbeds, attentionMask, ttsPadEmbed)

        return TuringQwenNativeTalkerPromptInputs(
            inputsEmbeds: inputsEmbeds,
            attentionMask: attentionMask,
            trailingTextHidden: ttsPadEmbed,
            ttsPadEmbed: ttsPadEmbed,
            sequenceLength: sequenceLength,
            hiddenSize: config.talkerConfig.hiddenSize
        )
    }

    private static func assistantBodyIDs(
        _ ids: [Int]
    ) throws -> [Int] {
        guard ids.count > 8 else {
            throw TuringQwenNativeError.invalidConfig(
                "Assistant prompt is too short for official non-streaming VoiceDesign layout."
            )
        }

        let bodyStart = 3
        let bodyEnd = ids.count - 5
        guard bodyStart < bodyEnd else {
            throw TuringQwenNativeError.invalidConfig(
                "Assistant prompt has no spoken body tokens."
            )
        }

        return Array(ids[bodyStart..<bodyEnd])
    }

    private static func prefix(
        _ ids: [Int],
        count: Int,
        label: String
    ) throws -> [Int] {
        guard ids.count >= count else {
            throw TuringQwenNativeError.invalidConfig(
                "Missing \(label). Required \(count), got \(ids.count)."
            )
        }

        return Array(ids.prefix(count))
    }

    private static func englishLanguageID(
        _ config: TuringQwenNativeConfig
    ) throws -> Int {
        guard let languageID = config.talkerConfig.codecLanguageID["english"] else {
            throw TuringQwenNativeError.invalidConfig(
                "Missing english codec language ID."
            )
        }

        return languageID
    }

    private static func repeatSequence(
        _ value: MLXArray,
        count: Int
    ) -> MLXArray {
        precondition(count > 0, "Cannot repeat an empty sequence.")
        return concatenated(
            (0..<count).map { _ in value },
            axis: 1
        )
    }
}

private struct TuringQwenNativeTalkerPromptWeights {
    private let reader: TuringQwenNativeSafetensorsReader
    private let hiddenSize: Int
    private let textHiddenSize: Int
    private let fc1Weight: MLXArray
    private let fc1Bias: MLXArray
    private let fc2Weight: MLXArray
    private let fc2Bias: MLXArray

    init(
        reader: TuringQwenNativeSafetensorsReader,
        hiddenSize: Int,
        textHiddenSize: Int
    ) throws {
        self.reader = reader
        self.hiddenSize = hiddenSize
        self.textHiddenSize = textHiddenSize

        self.fc1Weight = try reader.loadTensorFloat32(
            name: "talker.text_projection.linear_fc1.weight"
        ).mlxArray()
        self.fc1Bias = try reader.loadTensorFloat32(
            name: "talker.text_projection.linear_fc1.bias"
        ).mlxArray()
        self.fc2Weight = try reader.loadTensorFloat32(
            name: "talker.text_projection.linear_fc2.weight"
        ).mlxArray()
        self.fc2Bias = try reader.loadTensorFloat32(
            name: "talker.text_projection.linear_fc2.bias"
        ).mlxArray()
    }

    func projectTextEmbedding(
        ids: [Int]
    ) throws -> MLXArray {
        let rows = try reader.loadRowsFloat32(
            name: "talker.model.text_embedding.weight",
            rows: ids
        )
        guard rows.shape == [ids.count, textHiddenSize] else {
            throw TuringQwenNativeError.invalidSafetensors(
                "Unexpected text embedding row shape \(rows.shape)."
            )
        }

        let embeddings = rows.mlxArray().reshaped([1, ids.count, textHiddenSize])
        return projectTextHidden(embeddings)
    }

    func codecEmbedding(
        ids: [Int]
    ) throws -> MLXArray {
        let rows = try reader.loadRowsFloat32(
            name: "talker.model.codec_embedding.weight",
            rows: ids
        )
        guard rows.shape == [ids.count, hiddenSize] else {
            throw TuringQwenNativeError.invalidSafetensors(
                "Unexpected codec embedding row shape \(rows.shape)."
            )
        }

        return rows.mlxArray().reshaped([1, ids.count, hiddenSize])
    }

    private func projectTextHidden(
        _ hidden: MLXArray
    ) -> MLXArray {
        let fc1 = matmul(hidden, fc1Weight.T) + fc1Bias
        let activated = fc1 * sigmoid(fc1)
        return matmul(activated, fc2Weight.T) + fc2Bias
    }
}
