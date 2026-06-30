import Foundation
import MLX

struct TuringQwenNativeBaseClonePromptRequest: Sendable {
    let targetText: String
    let targetLanguage: String
    let cloneArtifacts: TuringQwenNativeCloneArtifacts
    let referenceRowLimit: Int?
    let referenceWindowStrategy: TuringQwenNativeReferenceWindowStrategy
}

struct TuringQwenNativePreparedBaseClonePrompt: Sendable {
    let layout: String
    let targetInputIDs: [Int]
    let refTextTokens: [Int32]
    let referenceCodes: [[Int32]]
    let speakerEmbedding: [Float]
    let referenceRowCount: Int
    let originalReferenceRowCount: Int
    let referenceWindowStrategy: TuringQwenNativeReferenceWindowStrategy
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

        let compactedReference = try compactReference(
            refTextTokens: request.cloneArtifacts.refTextTokens,
            referenceCodes: request.cloneArtifacts.referenceCodes,
            rowLimit: request.referenceRowLimit,
            strategy: request.referenceWindowStrategy
        )

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
            refTextTokens: compactedReference.refTextTokens,
            referenceCodes: compactedReference.referenceCodes,
            speakerEmbedding: request.cloneArtifacts.speakerEmbedding,
            referenceRowCount: compactedReference.referenceCodes.count,
            originalReferenceRowCount: request.cloneArtifacts.referenceRowCount,
            referenceWindowStrategy: compactedReference.strategy,
            languageCodecID: languageCodecID,
            xVectorOnlyMode: request.cloneArtifacts.xVectorOnlyMode
        )
    }

    private static func compactReference(
        refTextTokens: [Int32],
        referenceCodes: [[Int32]],
        rowLimit: Int?,
        strategy: TuringQwenNativeReferenceWindowStrategy
    ) throws -> (
        refTextTokens: [Int32],
        referenceCodes: [[Int32]],
        strategy: TuringQwenNativeReferenceWindowStrategy
    ) {
        guard let rowLimit,
              strategy != .full,
              rowLimit < referenceCodes.count else {
            return (refTextTokens, referenceCodes, .full)
        }

        guard rowLimit > 0 else {
            throw TuringQwenNativeError.invalidConfig(
                "referenceRowLimit must be greater than zero."
            )
        }

        let selectedCodes: [[Int32]]
        switch strategy {
        case .full:
            selectedCodes = referenceCodes
        case .prefix:
            selectedCodes = Array(referenceCodes.prefix(rowLimit))
        case .suffix:
            selectedCodes = Array(referenceCodes.suffix(rowLimit))
        }

        let selectedRefTextTokens = try compactReferenceTextTokens(
            refTextTokens,
            originalReferenceRowCount: referenceCodes.count,
            selectedReferenceRowCount: selectedCodes.count,
            strategy: strategy
        )

        print("""
        [TuringQwenNativeBaseClone] reference context compacted
          strategy: \(strategy.rawValue)
          originalReferenceRows: \(referenceCodes.count)
          effectiveReferenceRows: \(selectedCodes.count)
          originalRefTextTokens: \(refTextTokens.count)
          effectiveRefTextTokens: \(selectedRefTextTokens.count)
        """)

        return (selectedRefTextTokens, selectedCodes, strategy)
    }

    private static func compactReferenceTextTokens(
        _ tokens: [Int32],
        originalReferenceRowCount: Int,
        selectedReferenceRowCount: Int,
        strategy: TuringQwenNativeReferenceWindowStrategy
    ) throws -> [Int32] {
        guard tokens.count > 5,
              originalReferenceRowCount > 0,
              selectedReferenceRowCount < originalReferenceRowCount else {
            return tokens
        }

        let prefix = Array(tokens.prefix(3))
        let suffix = Array(tokens.suffix(2))
        let body = Array(tokens.dropFirst(3).dropLast(2))
        guard body.isEmpty == false else {
            return tokens
        }

        let proportionalBodyCount = Int(ceil(
            Double(body.count) *
            Double(selectedReferenceRowCount) /
            Double(originalReferenceRowCount)
        ))
        let bodyLimit = min(
            body.count,
            max(8, proportionalBodyCount)
        )

        let selectedBody: [Int32]
        switch strategy {
        case .full:
            selectedBody = body
        case .prefix:
            selectedBody = Array(body.prefix(bodyLimit))
        case .suffix:
            selectedBody = Array(body.suffix(bodyLimit))
        }

        return prefix + selectedBody + suffix
    }
}

enum TuringQwenNativeBaseClonePromptInputBuilder {
    static func build(
        prepared: TuringQwenNativePreparedBaseClonePrompt,
        config: TuringQwenNativeConfig,
        weightsStore: TuringQwenNativeWeightsStore,
        codePredictorWeights: TuringQwenNativeCodePredictorResolvedWeights
    ) throws -> TuringQwenNativeTalkerPromptInputs {
        let weights = try BaseClonePromptWeights(
            config: config,
            weightsStore: weightsStore
        )
        let roleIDs = try slice(
            prepared.targetInputIDs,
            start: 0,
            end: 3,
            label: "target assistant role IDs"
        )
        let targetBodyIDs = try slice(
            prepared.targetInputIDs,
            start: 3,
            end: prepared.targetInputIDs.count - 5,
            label: "target body IDs"
        )
        let refIDs = prepared.refTextTokens.map(Int.init)
        let refBodyIDs = try slice(
            refIDs,
            start: 3,
            end: refIDs.count - 2,
            label: "reference body IDs"
        )

        let ttsBosEmbed = try weights.projectTextEmbedding(ids: [config.ttsBosTokenID])
        let ttsEosEmbed = try weights.projectTextEmbedding(ids: [config.ttsEosTokenID])
        let ttsPadEmbed = try weights.projectTextEmbedding(ids: [config.ttsPadTokenID])

        let codecPrefill = try weights.codecEmbedding(ids: [
            config.talkerConfig.codecThinkID,
            config.talkerConfig.codecThinkBosID,
            prepared.languageCodecID,
            config.talkerConfig.codecThinkEosID
        ])
        let codecPadAndBos = try weights.codecEmbedding(ids: [
            config.talkerConfig.codecPadID,
            config.talkerConfig.codecBosID
        ])
        let speakerEmbed = prepared.speakerEmbeddingArray.reshaped([
            1,
            1,
            config.talkerConfig.hiddenSize
        ])
        let codecPrompt = concatenated([
            codecPrefill,
            speakerEmbed,
            codecPadAndBos
        ], axis: 1)

        let roleEmbed = try weights.projectTextEmbedding(ids: roleIDs)
        let padPrefix = repeatSequence(
            ttsPadEmbed,
            count: max(1, codecPrompt.dim(1) - 2)
        )
        let tagAndSpeaker = concatenated([padPrefix, ttsBosEmbed], axis: 1)
            + codecPrompt[0..<(codecPrompt.dim(1) - 1), axis: 1]

        let refAndTargetTextEmbed = try weights.projectTextEmbedding(
            ids: refBodyIDs + targetBodyIDs
        )
        let textWithEos = concatenated([refAndTargetTextEmbed, ttsEosEmbed], axis: 1)

        let referenceCodeEmbeds = try prepared.referenceCodes.map { row -> MLXArray in
            try TuringQwenNativeCodePredictor.talkerInputEmbedding(
                forCodeGroup: row.map(Int.init),
                config: config,
                resolvedWeights: codePredictorWeights
            )
        }
        let referenceCodecEmbed = concatenated(
            [
                try weights.codecEmbedding(ids: [config.talkerConfig.codecBosID])
            ] + referenceCodeEmbeds,
            axis: 1
        )

        let iclEmbed: MLXArray
        let trailingTextHidden: MLXArray
        if textWithEos.dim(1) > referenceCodecEmbed.dim(1) {
            iclEmbed = textWithEos[0..<referenceCodecEmbed.dim(1), axis: 1]
                + referenceCodecEmbed
            trailingTextHidden = textWithEos[
                referenceCodecEmbed.dim(1)..<textWithEos.dim(1),
                axis: 1
            ]
        } else {
            let padCount = referenceCodecEmbed.dim(1) - textWithEos.dim(1)
            let paddedText = padCount > 0
                ? concatenated([
                    textWithEos,
                    repeatSequence(ttsPadEmbed, count: padCount)
                ], axis: 1)
                : textWithEos
            iclEmbed = paddedText + referenceCodecEmbed
            trailingTextHidden = ttsPadEmbed
        }

        let inputsEmbeds = concatenated([
            roleEmbed,
            tagAndSpeaker,
            iclEmbed
        ], axis: 1)
        let sequenceLength = inputsEmbeds.dim(1)
        let attentionMask = MLXArray(
            int64: Array(repeating: 1, count: sequenceLength),
            [1, sequenceLength]
        )

        eval(inputsEmbeds, attentionMask, trailingTextHidden, ttsPadEmbed)

        return TuringQwenNativeTalkerPromptInputs(
            inputsEmbeds: inputsEmbeds,
            attentionMask: attentionMask,
            trailingTextHidden: trailingTextHidden,
            ttsPadEmbed: ttsPadEmbed,
            sequenceLength: sequenceLength,
            hiddenSize: config.talkerConfig.hiddenSize
        )
    }

    private static func slice<T>(
        _ values: [T],
        start: Int,
        end: Int,
        label: String
    ) throws -> [T] {
        guard start >= 0,
              end <= values.count,
              start < end else {
            throw TuringQwenNativeError.invalidConfig(
                "Invalid \(label) slice \(start)..<\(end) for count \(values.count)."
            )
        }
        return Array(values[start..<end])
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

private struct BaseClonePromptWeights {
    private let resolver: TuringQwenNativeWeightResolver
    private let textHiddenSize: Int
    private let hiddenSize: Int
    private let fc1Weight: TuringQwenNativeLinearWeight
    private let fc1Bias: MLXArray
    private let fc2Weight: TuringQwenNativeLinearWeight
    private let fc2Bias: MLXArray

    init(
        config: TuringQwenNativeConfig,
        weightsStore: TuringQwenNativeWeightsStore
    ) throws {
        self.resolver = TuringQwenNativeWeightResolver(store: weightsStore)
        self.textHiddenSize = config.talkerConfig.textHiddenSize
        self.hiddenSize = config.talkerConfig.hiddenSize
        self.fc1Weight = try resolver.linear("talker.text_projection.linear_fc1.weight")
        self.fc1Bias = try resolver.tensor("talker.text_projection.linear_fc1.bias")
        self.fc2Weight = try resolver.linear("talker.text_projection.linear_fc2.weight")
        self.fc2Bias = try resolver.tensor("talker.text_projection.linear_fc2.bias")
    }

    func projectTextEmbedding(
        ids: [Int]
    ) throws -> MLXArray {
        let rows = try resolver.rows(
            "talker.model.text_embedding.weight",
            rows: ids
        )
        guard rows.shape == [ids.count, textHiddenSize] else {
            throw TuringQwenNativeError.invalidSafetensors(
                "Unexpected text embedding row shape \(rows.shape)."
            )
        }

        return projectTextHidden(rows.reshaped([1, ids.count, textHiddenSize]))
    }

    func codecEmbedding(
        ids: [Int]
    ) throws -> MLXArray {
        let rows = try resolver.rows(
            "talker.model.codec_embedding.weight",
            rows: ids
        )
        guard rows.shape == [ids.count, hiddenSize] else {
            throw TuringQwenNativeError.invalidSafetensors(
                "Unexpected codec embedding row shape \(rows.shape)."
            )
        }

        return rows.reshaped([1, ids.count, hiddenSize])
    }

    private func projectTextHidden(
        _ hidden: MLXArray
    ) -> MLXArray {
        let fc1 = fc1Weight.apply(hidden) + fc1Bias
        let activated = fc1 * sigmoid(fc1)
        return fc2Weight.apply(activated) + fc2Bias
    }
}
