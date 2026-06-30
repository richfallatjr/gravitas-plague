import Foundation
import MLX

struct TuringQwenNativeFirstCodeGroup: Sendable {
    let tokenIDs: [Int]
    let expectedFixtureTokenIDs: [Int]

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
        let codePredictorConfig = try ResolvedConfig(config.talkerConfig.codePredictorConfig)
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
            expectedFixtureRowIndex: 0
        )
    }

    static func generateCodeGroup(
        firstCodecToken: Int,
        talkerLastHiddenState: MLXArray,
        config: TuringQwenNativeConfig,
        weightsStore: TuringQwenNativeWeightsStore,
        expectedFixtureRowIndex: Int? = nil
    ) throws -> TuringQwenNativeFirstCodeGroup {
        let codePredictorConfig = try ResolvedConfig(config.talkerConfig.codePredictorConfig)
        let start = Date()
        let resolver = TuringQwenNativeWeightResolver(store: weightsStore)
        let weights = try ProjectionWeights(resolver: resolver)
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

        var codeHiddens = [
            talkerLastHiddenState,
            try talkerCodecEmbedding(
                tokenID: firstCodecToken,
                resolver: resolver
            )
        ]

        var tokens = [firstCodecToken]
        for headIndex in 0..<(codePredictorConfig.numCodeGroups - 1) {
            let sequence = concatenated(codeHiddens, axis: 1)
            let projected = linear(
                sequence,
                weight: weights.smallToMTPProjectionWeight,
                bias: weights.smallToMTPProjectionBias
            )

            let hidden = try runNoCacheForward(
                projectedInputs: projected,
                sequenceLength: codeHiddens.count,
                config: codePredictorConfig,
                resolver: resolver
            )
            let lastHidden = hidden[(codeHiddens.count - 1)..<codeHiddens.count, axis: 1]
            let lmHeadWeight = try resolver.tensor("talker.code_predictor.lm_head.\(headIndex).weight")
            let logits = linear(lastHidden, weight: lmHeadWeight)
            let nextToken = logits
                .argMax()
                .item(Int.self)
            TuringQwenNativeMemoryControl.clearCache(label: "codePredictor.head.\(headIndex)")
            tokens.append(nextToken)

            if headIndex < codePredictorConfig.numCodeGroups - 2 {
                codeHiddens.append(
                    try codePredictorCodecEmbedding(
                        embeddingIndex: headIndex,
                        tokenID: nextToken,
                        resolver: resolver
                    )
                )
            }
        }

        print("""
        [TuringQwenNative] code predictor group completed
          fixtureRowIndex: \(expectedFixtureRowIndex.map(String.init) ?? "none")
          tokenCount: \(tokens.count)
          seconds: \(String(format: "%.3f", Date().timeIntervalSince(start)))
        """)

        return TuringQwenNativeFirstCodeGroup(
            tokenIDs: tokens,
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

    private static func runNoCacheForward(
        projectedInputs: MLXArray,
        sequenceLength: Int,
        config: ResolvedConfig,
        resolver: TuringQwenNativeWeightResolver
    ) throws -> MLXArray {
        var hidden = projectedInputs

        for layerIndex in 0..<config.numHiddenLayers {
            let weights = try LayerWeights(
                resolver: resolver,
                layerIndex: layerIndex
            )
            hidden = try runDecoderLayer(
                hiddenStates: hidden,
                weights: weights,
                config: config,
                sequenceLength: sequenceLength
            )
            eval(hidden)
            TuringQwenNativeMemoryControl.clearCache(
                label: "codePredictor.sequence.\(sequenceLength).layer.\(layerIndex)"
            )
        }

        let normWeight = try resolver.tensor("talker.code_predictor.model.norm.weight")
        let normalized = rmsNorm(
            hidden,
            weight: normWeight,
            eps: Float(config.rmsNormEps)
        )
        eval(normalized)
        TuringQwenNativeMemoryControl.clearCache(label: "codePredictor.forward.sequenceLength.\(sequenceLength)")
        return normalized
    }

    private static func runDecoderLayer(
        hiddenStates: MLXArray,
        weights: LayerWeights,
        config: ResolvedConfig,
        sequenceLength: Int
    ) throws -> MLXArray {
        let residual = hiddenStates
        let normalized = rmsNorm(
            hiddenStates,
            weight: weights.inputLayerNormWeight,
            eps: Float(config.rmsNormEps)
        )

        let attentionOutput = try selfAttention(
            hiddenStates: normalized,
            weights: weights,
            config: config,
            sequenceLength: sequenceLength
        )
        let afterAttention = residual + attentionOutput

        let mlpResidual = afterAttention
        let mlpInput = rmsNorm(
            afterAttention,
            weight: weights.postAttentionLayerNormWeight,
            eps: Float(config.rmsNormEps)
        )
        let mlpOutput = mlp(mlpInput, weights: weights)

        return mlpResidual + mlpOutput
    }

    private static func selfAttention(
        hiddenStates: MLXArray,
        weights: LayerWeights,
        config: ResolvedConfig,
        sequenceLength: Int
    ) throws -> MLXArray {
        let query = linear(hiddenStates, weight: weights.qProjWeight)
            .reshaped([1, sequenceLength, config.numAttentionHeads, config.headDim])
        let key = linear(hiddenStates, weight: weights.kProjWeight)
            .reshaped([1, sequenceLength, config.numKeyValueHeads, config.headDim])
        let value = linear(hiddenStates, weight: weights.vProjWeight)
            .reshaped([1, sequenceLength, config.numKeyValueHeads, config.headDim])

        var queryStates = rmsNorm(
            query,
            weight: weights.qNormWeight,
            eps: Float(config.rmsNormEps)
        ).transposed(0, 2, 1, 3)
        var keyStates = rmsNorm(
            key,
            weight: weights.kNormWeight,
            eps: Float(config.rmsNormEps)
        ).transposed(0, 2, 1, 3)
        var valueStates = value.transposed(0, 2, 1, 3)

        let rope = rotaryEmbeddings(
            sequenceLength: sequenceLength,
            headDim: config.headDim,
            theta: config.ropeTheta
        )
        queryStates = applyRotary(queryStates, cos: rope.cos, sin: rope.sin)
        keyStates = applyRotary(keyStates, cos: rope.cos, sin: rope.sin)

        keyStates = repeatKeyValueHeads(
            keyStates,
            keyValueHeads: config.numKeyValueHeads,
            attentionHeads: config.numAttentionHeads
        )
        valueStates = repeatKeyValueHeads(
            valueStates,
            keyValueHeads: config.numKeyValueHeads,
            attentionHeads: config.numAttentionHeads
        )

        let scale = Float(1.0 / sqrt(Double(config.headDim)))
        let attentionMask = causalMask(sequenceLength: sequenceLength)
        let scores = matmul(queryStates, keyStates.transposed(0, 1, 3, 2)) * scale + attentionMask
        let probabilities = softmax(scores, axis: -1, precise: true)
        let attended = matmul(probabilities, valueStates)
            .transposed(0, 2, 1, 3)
            .reshaped([1, sequenceLength, config.attentionOutputSize])

        return linear(attended, weight: weights.oProjWeight)
    }

    private static func mlp(
        _ hiddenStates: MLXArray,
        weights: LayerWeights
    ) -> MLXArray {
        let gate = linear(hiddenStates, weight: weights.gateProjWeight)
        let up = linear(hiddenStates, weight: weights.upProjWeight)
        let activated = gate * sigmoid(gate)
        return linear(activated * up, weight: weights.downProjWeight)
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

    private static func rmsNorm(
        _ value: MLXArray,
        weight: MLXArray,
        eps: Float
    ) -> MLXArray {
        let variance = (value * value).mean(axis: -1, keepDims: true)
        return value / sqrt(variance + eps) * weight
    }

    private static func linear(
        _ value: MLXArray,
        weight: MLXArray
    ) -> MLXArray {
        matmul(value, weight.T)
    }

    private static func linear(
        _ value: MLXArray,
        weight: MLXArray,
        bias: MLXArray
    ) -> MLXArray {
        matmul(value, weight.T) + bias
    }

    private static func causalMask(
        sequenceLength: Int
    ) -> MLXArray {
        var values = Array(
            repeating: Float(0),
            count: sequenceLength * sequenceLength
        )

        for row in 0..<sequenceLength {
            for column in (row + 1)..<sequenceLength {
                values[row * sequenceLength + column] = -1_000_000_000
            }
        }

        return MLXArray(values, [1, 1, sequenceLength, sequenceLength])
    }

    private static func rotaryEmbeddings(
        sequenceLength: Int,
        headDim: Int,
        theta: Double
    ) -> (cos: MLXArray, sin: MLXArray) {
        let half = headDim / 2
        var cosValues: [Float] = []
        var sinValues: [Float] = []
        cosValues.reserveCapacity(sequenceLength * headDim)
        sinValues.reserveCapacity(sequenceLength * headDim)

        for position in 0..<sequenceLength {
            var freqs: [Double] = []
            freqs.reserveCapacity(half)

            for index in 0..<half {
                let exponent = Double(index * 2) / Double(headDim)
                let invFreq = 1.0 / pow(theta, exponent)
                freqs.append(Double(position) * invFreq)
            }

            for freq in freqs {
                cosValues.append(Float(cos(freq)))
                sinValues.append(Float(sin(freq)))
            }
            for freq in freqs {
                cosValues.append(Float(cos(freq)))
                sinValues.append(Float(sin(freq)))
            }
        }

        return (
            MLXArray(cosValues, [1, 1, sequenceLength, headDim]),
            MLXArray(sinValues, [1, 1, sequenceLength, headDim])
        )
    }

    private static func applyRotary(
        _ value: MLXArray,
        cos: MLXArray,
        sin: MLXArray
    ) -> MLXArray {
        value * cos + rotateHalf(value) * sin
    }

    private static func rotateHalf(
        _ value: MLXArray
    ) -> MLXArray {
        let half = value.dim(-1) / 2
        let first = value[..<half, axis: -1]
        let second = value[half..., axis: -1]
        return concatenated([-second, first], axis: -1)
    }

    private static func repeatKeyValueHeads(
        _ value: MLXArray,
        keyValueHeads: Int,
        attentionHeads: Int
    ) -> MLXArray {
        guard keyValueHeads != attentionHeads else {
            return value
        }

        let repeatCount = attentionHeads / keyValueHeads
        let indices = (0..<keyValueHeads).flatMap { head in
            Array(repeating: head, count: repeatCount)
        }
        return value.take(MLXArray(indices), axis: 1)
    }

    private struct ResolvedConfig {
        let hiddenSize: Int
        let vocabSize: Int
        let numHiddenLayers: Int
        let numAttentionHeads: Int
        let numKeyValueHeads: Int
        let headDim: Int
        let intermediateSize: Int
        let rmsNormEps: Double
        let ropeTheta: Double
        let numCodeGroups: Int

        var attentionOutputSize: Int {
            numAttentionHeads * headDim
        }

        init(_ config: TuringQwenNativeConfig.CodePredictorConfig) throws {
            guard let hiddenSize = config.hiddenSize,
                  let vocabSize = config.vocabSize,
                  let numHiddenLayers = config.numHiddenLayers,
                  let numAttentionHeads = config.numAttentionHeads,
                  let numKeyValueHeads = config.numKeyValueHeads,
                  let headDim = config.headDim,
                  let intermediateSize = config.intermediateSize,
                  let rmsNormEps = config.rmsNormEps,
                  let ropeTheta = config.ropeTheta,
                  let numCodeGroups = config.numCodeGroups else {
                throw TuringQwenNativeError.invalidConfig(
                    "Code predictor config is missing required fields."
                )
            }

            self.hiddenSize = hiddenSize
            self.vocabSize = vocabSize
            self.numHiddenLayers = numHiddenLayers
            self.numAttentionHeads = numAttentionHeads
            self.numKeyValueHeads = numKeyValueHeads
            self.headDim = headDim
            self.intermediateSize = intermediateSize
            self.rmsNormEps = rmsNormEps
            self.ropeTheta = ropeTheta
            self.numCodeGroups = numCodeGroups
        }
    }

    private struct ProjectionWeights {
        let smallToMTPProjectionWeight: MLXArray
        let smallToMTPProjectionBias: MLXArray

        init(resolver: TuringQwenNativeWeightResolver) throws {
            self.smallToMTPProjectionWeight = try resolver.tensor(
                "talker.code_predictor.small_to_mtp_projection.weight"
            )
            self.smallToMTPProjectionBias = try resolver.tensor(
                "talker.code_predictor.small_to_mtp_projection.bias"
            )
        }
    }

    private struct LayerWeights {
        let inputLayerNormWeight: MLXArray
        let postAttentionLayerNormWeight: MLXArray
        let qNormWeight: MLXArray
        let kNormWeight: MLXArray
        let qProjWeight: MLXArray
        let kProjWeight: MLXArray
        let vProjWeight: MLXArray
        let oProjWeight: MLXArray
        let gateProjWeight: MLXArray
        let upProjWeight: MLXArray
        let downProjWeight: MLXArray

        init(
            resolver: TuringQwenNativeWeightResolver,
            layerIndex: Int
        ) throws {
            let prefix = "talker.code_predictor.model.layers.\(layerIndex)"
            self.inputLayerNormWeight = try resolver.tensor("\(prefix).input_layernorm.weight")
            self.postAttentionLayerNormWeight = try resolver.tensor("\(prefix).post_attention_layernorm.weight")
            self.qNormWeight = try resolver.tensor("\(prefix).self_attn.q_norm.weight")
            self.kNormWeight = try resolver.tensor("\(prefix).self_attn.k_norm.weight")
            self.qProjWeight = try resolver.tensor("\(prefix).self_attn.q_proj.weight")
            self.kProjWeight = try resolver.tensor("\(prefix).self_attn.k_proj.weight")
            self.vProjWeight = try resolver.tensor("\(prefix).self_attn.v_proj.weight")
            self.oProjWeight = try resolver.tensor("\(prefix).self_attn.o_proj.weight")
            self.gateProjWeight = try resolver.tensor("\(prefix).mlp.gate_proj.weight")
            self.upProjWeight = try resolver.tensor("\(prefix).mlp.up_proj.weight")
            self.downProjWeight = try resolver.tensor("\(prefix).mlp.down_proj.weight")
        }
    }
}
