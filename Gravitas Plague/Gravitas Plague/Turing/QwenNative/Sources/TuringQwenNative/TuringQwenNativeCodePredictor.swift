import Foundation
import MLX

struct TuringQwenNativeFirstCodeGroup: @unchecked Sendable {
    let tokenArray: MLXArray
    let materializedTokenIDs: [Int]?
    let expectedFixtureTokenIDs: [Int]

    var tokenIDs: [Int] {
        materializedTokenIDs ?? tokenArray.asArray(Int.self)
    }

    var matchesFixture: Bool {
        tokenIDs == expectedFixtureTokenIDs
    }
}

enum TuringQwenNativeCodePredictor {
    static let expectedFixtureRows = [
        [
            1221,
            1052,
            1512,
            159,
            790,
            1069,
            1701,
            832,
            1190,
            87,
            226,
            276,
            1363,
            844,
            215,
            783
        ],
        [
            1175,
            1423,
            357,
            1311,
            1628,
            504,
            15,
            122,
            1948,
            1693,
            1489,
            373,
            747,
            324,
            20,
            23
        ],
        [
            2026,
            289,
            171,
            1619,
            867,
            1793,
            472,
            1063,
            1937,
            767,
            535,
            1008,
            1743,
            282,
            653,
            1853
        ],
        [
            1119,
            1423,
            754,
            1350,
            1624,
            1247,
            837,
            818,
            137,
            1913,
            545,
            603,
            702,
            1160,
            773,
            705
        ],
        [
            1946,
            112,
            1525,
            597,
            595,
            964,
            1216,
            817,
            1010,
            867,
            346,
            315,
            1342,
            188,
            1336,
            708
        ],
        [
            46,
            660,
            1808,
            229,
            1624,
            310,
            787,
            533,
            1487,
            1068,
            650,
            523,
            506,
            626,
            2012,
            1201
        ],
        [
            681,
            884,
            82,
            1082,
            1767,
            1901,
            774,
            818,
            833,
            1701,
            157,
            1090,
            1206,
            486,
            1290,
            59
        ]
    ]

    static var expectedFirstFixtureGroup: [Int] {
        expectedFixtureRows[0]
    }

    static func generateFirstCodeGroup(
        firstCodecToken: Int,
        talkerLastHiddenState: MLXArray,
        config: TuringQwenNativeConfig,
        weightsStore: TuringQwenNativeWeightsStore
    ) throws -> TuringQwenNativeFirstCodeGroup {
        let codePredictorConfig = try TuringQwenNativeCodePredictorResolvedConfig(
            config.talkerConfig.codePredictorConfig
        )
        guard config.talkerConfig.numCodeGroups == codePredictorConfig.numCodeGroups else {
            throw TuringQwenNativeError.invalidConfig(
                "Talker num_code_groups \(config.talkerConfig.numCodeGroups) does not match code predictor \(codePredictorConfig.numCodeGroups)."
            )
        }
        guard expectedFirstFixtureGroup.first == firstCodecToken else {
            throw TuringQwenNativeError.invalidConfig(
                "First codec token \(firstCodecToken) does not match fixture \(expectedFirstFixtureGroup[0])."
            )
        }

        return try generateCodeGroup(
            firstCodecToken: firstCodecToken,
            talkerLastHiddenState: talkerLastHiddenState,
            config: config,
            weightsStore: weightsStore,
            expectedFixtureRowIndex: 0,
            performanceMode: .diagnostic
        )
    }

    static func generateCodeGroup(
        firstCodecToken: Int,
        talkerLastHiddenState: MLXArray,
        config: TuringQwenNativeConfig,
        weightsStore: TuringQwenNativeWeightsStore,
        expectedFixtureRowIndex: Int? = nil,
        resolvedWeights: TuringQwenNativeCodePredictorResolvedWeights? = nil,
        segmentCache: TuringQwenNativeSegmentRuntimeCache? = nil,
        performanceMode: TuringQwenNativePerformanceMode = .diagnostic
    ) throws -> TuringQwenNativeFirstCodeGroup {
        try generateCodeGroupCached(
            firstCodecToken: firstCodecToken,
            talkerLastHiddenState: talkerLastHiddenState,
            config: config,
            weightsStore: weightsStore,
            expectedFixtureRowIndex: expectedFixtureRowIndex,
            resolvedWeights: resolvedWeights,
            segmentCache: segmentCache,
            performanceMode: performanceMode
        )
    }

    static func generateCodeGroupCached(
        firstCodecToken: Int,
        talkerLastHiddenState: MLXArray,
        config: TuringQwenNativeConfig,
        weightsStore: TuringQwenNativeWeightsStore,
        expectedFixtureRowIndex: Int? = nil,
        resolvedWeights: TuringQwenNativeCodePredictorResolvedWeights? = nil,
        segmentCache: TuringQwenNativeSegmentRuntimeCache? = nil,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeFirstCodeGroup {
        let resolved = try resolvedWeights ?? TuringQwenNativeCodePredictorResolvedWeights(
            config: config,
            weightsStore: weightsStore
        )
        let codePredictorConfig = resolved.config
        let start = Date()
        let expectedFixtureTokens: [Int]
        if let expectedFixtureRowIndex {
            guard expectedFixtureRows.indices.contains(expectedFixtureRowIndex) else {
                throw TuringQwenNativeError.invalidConfig(
                    "Missing codebook fixture row \(expectedFixtureRowIndex)."
                )
            }

            expectedFixtureTokens = expectedFixtureRows[expectedFixtureRowIndex]
        } else {
            expectedFixtureTokens = []
        }

        if let expectedFirst = expectedFixtureTokens.first,
           expectedFirst != firstCodecToken {
            throw TuringQwenNativeError.invalidConfig(
                "First codec token \(firstCodecToken) does not match fixture row \(expectedFixtureRowIndex ?? -1) token \(expectedFirst)."
            )
        }

        guard talkerLastHiddenState.shape == [1, 1, 2048] else {
            throw TuringQwenNativeError.invalidConfig(
                "Expected talker last hidden shape [1, 1, 2048], got \(talkerLastHiddenState.shape)."
            )
        }

        let prefillCodeHiddens = concatenated([
            talkerLastHiddenState,
            try resolved.talkerCodecEmbedding(tokenID: firstCodecToken)
        ], axis: 1)
        let prefillInput = TuringQwenNativeCodePredictorForwardRunner.projectedInput(
            codeHidden: prefillCodeHiddens,
            projectionWeights: resolved.projectionWeights
        )
        let prefill = try TuringQwenNativeCodePredictorForwardRunner.prefill(
            inputEmbeddings: prefillInput,
            attentionMask: nil,
            config: config,
            weights: weightsStore,
            resolvedWeights: resolved,
            segmentCache: segmentCache,
            performanceMode: performanceMode
        )

        var tokenArrays = [MLXArray([firstCodecToken])]
        var state = prefill.state
        var logits = prefill.logits

        for residualIndex in 1..<codePredictorConfig.numCodeGroups {
            let headIndex = residualIndex - 1
            let nextTokenArray = try TuringQwenNativeSampler.greedyTokenArray(from: logits)
            tokenArrays.append(nextTokenArray)

            guard residualIndex < codePredictorConfig.numCodeGroups - 1 else {
                break
            }

            state.generatedResidualTokenCount += 1
            let residualEmbedding = try resolved.codePredictorCodecEmbedding(
                embeddingIndex: headIndex,
                tokenIndex: nextTokenArray
            )
            let projectedInput = TuringQwenNativeCodePredictorForwardRunner.projectedInput(
                codeHidden: residualEmbedding,
                projectionWeights: resolved.projectionWeights
            )
            let step = try TuringQwenNativeCodePredictorForwardRunner.forwardOneStep(
                inputEmbedding: projectedInput,
                previousState: state,
                config: config,
                weights: weightsStore,
                resolvedWeights: resolved,
                segmentCache: segmentCache,
                performanceMode: performanceMode
            )
            state = step.state
            logits = step.logits
        }
        let tokenArray = concatenated(tokenArrays, axis: 0)
        let shouldMaterializeTokens = performanceMode.shouldLogFullTokenRows ||
            expectedFixtureRowIndex != nil
        let tokens = shouldMaterializeTokens ? tokenArray.asArray(Int.self) : nil

        if performanceMode.shouldLogFullTokenRows {
            print("""
            [TuringQwenNative] code predictor group completed
              fixtureRowIndex: \(expectedFixtureRowIndex.map(String.init) ?? "none")
              tokenCount: \(tokens?.count ?? codePredictorConfig.numCodeGroups)
              seconds: \(String(format: "%.3f", Date().timeIntervalSince(start)))
              codePredictorKVCache: oneStep
              noCacheForwardCount: 0
              residualTokenSyncs: 1
            """)
        } else {
            print("""
            [TuringQwenNativePerf] code predictor group completed
              tokenCount: \(codePredictorConfig.numCodeGroups)
              seconds: \(String(format: "%.3f", Date().timeIntervalSince(start)))
              codePredictorKVCache: oneStep
              noCacheForwardCount: 0
              residualTokenSyncs: 0
            """)
        }

        return TuringQwenNativeFirstCodeGroup(
            tokenArray: tokenArray,
            materializedTokenIDs: tokens,
            expectedFixtureTokenIDs: expectedFixtureTokens
        )
    }

    static func talkerInputEmbedding(
        forCodeGroup tokenIDs: [Int],
        config: TuringQwenNativeConfig,
        weightsStore: TuringQwenNativeWeightsStore
    ) throws -> MLXArray {
        guard tokenIDs.count == config.talkerConfig.numCodeGroups else {
            throw TuringQwenNativeError.invalidConfig(
                "Expected \(config.talkerConfig.numCodeGroups) code group tokens, got \(tokenIDs.count)."
            )
        }

        let resolver = TuringQwenNativeWeightResolver(store: weightsStore)
        var embeddings: [MLXArray] = [
            try talkerCodecEmbedding(
                tokenID: tokenIDs[0],
                resolver: resolver
            )
        ]

        for (offset, tokenID) in tokenIDs.dropFirst().enumerated() {
            embeddings.append(
                try codePredictorCodecEmbedding(
                    embeddingIndex: offset,
                    tokenID: tokenID,
                    resolver: resolver
                )
            )
        }

        return concatenated(embeddings, axis: 1)
            .sum(axis: 1, keepDims: true)
    }

    static func talkerInputEmbedding(
        forCodeGroup tokenIDs: [Int],
        config: TuringQwenNativeConfig,
        resolvedWeights: TuringQwenNativeCodePredictorResolvedWeights
    ) throws -> MLXArray {
        guard tokenIDs.count == config.talkerConfig.numCodeGroups else {
            throw TuringQwenNativeError.invalidConfig(
                "Expected \(config.talkerConfig.numCodeGroups) code group tokens, got \(tokenIDs.count)."
            )
        }

        var embeddings: [MLXArray] = [
            try resolvedWeights.talkerCodecEmbedding(tokenID: tokenIDs[0])
        ]

        for (offset, tokenID) in tokenIDs.dropFirst().enumerated() {
            embeddings.append(
                try resolvedWeights.codePredictorCodecEmbedding(
                    embeddingIndex: offset,
                    tokenID: tokenID
                )
            )
        }

        return concatenated(embeddings, axis: 1)
            .sum(axis: 1, keepDims: true)
    }

    static func talkerInputEmbedding(
        forCodeGroupTokenArray tokenArray: MLXArray,
        config: TuringQwenNativeConfig,
        resolvedWeights: TuringQwenNativeCodePredictorResolvedWeights
    ) throws -> MLXArray {
        guard tokenArray.size == config.talkerConfig.numCodeGroups else {
            throw TuringQwenNativeError.invalidConfig(
                "Expected \(config.talkerConfig.numCodeGroups) code group tokens, got token array shape \(tokenArray.shape)."
            )
        }

        var embeddings: [MLXArray] = [
            resolvedWeights.talkerCodecEmbedding(tokenIndex: tokenArray[0..<1])
        ]

        for offset in 0..<(config.talkerConfig.numCodeGroups - 1) {
            embeddings.append(
                try resolvedWeights.codePredictorCodecEmbedding(
                    embeddingIndex: offset,
                    tokenIndex: tokenArray[(offset + 1)..<(offset + 2)]
                )
            )
        }

        return concatenated(embeddings, axis: 1)
            .sum(axis: 1, keepDims: true)
    }

    private static func talkerCodecEmbedding(
        tokenID: Int,
        resolver: TuringQwenNativeWeightResolver
    ) throws -> MLXArray {
        try resolver.rows(
            "talker.model.codec_embedding.weight",
            rows: [tokenID]
        )
        .reshaped([1, 1, 2048])
    }

    private static func codePredictorCodecEmbedding(
        embeddingIndex: Int,
        tokenID: Int,
        resolver: TuringQwenNativeWeightResolver
    ) throws -> MLXArray {
        try resolver.rows(
            "talker.code_predictor.model.codec_embedding.\(embeddingIndex).weight",
            rows: [tokenID]
        )
        .reshaped([1, 1, 2048])
    }
}
