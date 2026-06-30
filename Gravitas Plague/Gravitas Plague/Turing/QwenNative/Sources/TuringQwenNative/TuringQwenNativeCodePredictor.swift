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
    static let expectedFirstFixtureGroup = [
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
    ]

    static func generateFirstCodeGroup(
        firstCodecToken: Int,
        talkerLastHiddenState: MLXArray,
        config: TuringQwenNativeConfig,
        tensorIndex: TuringQwenNativeSafetensorsIndex
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

        let start = Date()
        let reader = TuringQwenNativeSafetensorsReader(index: tensorIndex)
        let weights = try ProjectionWeights(reader: reader)

        guard talkerLastHiddenState.shape == [1, 1, 2048] else {
            throw TuringQwenNativeError.invalidConfig(
                "Expected talker last hidden shape [1, 1, 2048], got \(talkerLastHiddenState.shape)."
            )
        }

        var codeHiddens = [
            talkerLastHiddenState,
            try talkerCodecEmbedding(
                tokenID: firstCodecToken,
                reader: reader
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
                reader: reader
            )
            let lastHidden = hidden[(codeHiddens.count - 1)..<codeHiddens.count, axis: 1]
            let lmHeadWeight = try reader.loadTensorFloat32(
                name: "talker.code_predictor.lm_head.\(headIndex).weight"
            ).mlxArray()
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
                        reader: reader
                    )
                )
            }
        }

        print("""
        [TuringQwenNative] code predictor first group completed
          tokenCount: \(tokens.count)
          seconds: \(String(format: "%.3f", Date().timeIntervalSince(start)))
        """)

        return TuringQwenNativeFirstCodeGroup(
            tokenIDs: tokens,
            expectedFixtureTokenIDs: expectedFirstFixtureGroup
        )
    }

    private static func runNoCacheForward(
        projectedInputs: MLXArray,
        sequenceLength: Int,
        config: ResolvedConfig,
        reader: TuringQwenNativeSafetensorsReader
    ) throws -> MLXArray {
        var hidden = projectedInputs

        for layerIndex in 0..<config.numHiddenLayers {
            let weights = try LayerWeights(
                reader: reader,
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

        let normWeight = try reader.loadTensorFloat32(
            name: "talker.code_predictor.model.norm.weight"
        ).mlxArray()
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
        reader: TuringQwenNativeSafetensorsReader
    ) throws -> MLXArray {
        try reader.loadRowsFloat32(
            name: "talker.model.codec_embedding.weight",
            rows: [tokenID]
        )
        .mlxArray()
        .reshaped([1, 1, 2048])
    }

    private static func codePredictorCodecEmbedding(
        embeddingIndex: Int,
        tokenID: Int,
        reader: TuringQwenNativeSafetensorsReader
    ) throws -> MLXArray {
        try reader.loadRowsFloat32(
            name: "talker.code_predictor.model.codec_embedding.\(embeddingIndex).weight",
            rows: [tokenID]
        )
        .mlxArray()
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

        init(reader: TuringQwenNativeSafetensorsReader) throws {
            self.smallToMTPProjectionWeight = try reader.loadTensorFloat32(
                name: "talker.code_predictor.small_to_mtp_projection.weight"
            ).mlxArray()
            self.smallToMTPProjectionBias = try reader.loadTensorFloat32(
                name: "talker.code_predictor.small_to_mtp_projection.bias"
            ).mlxArray()
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
            reader: TuringQwenNativeSafetensorsReader,
            layerIndex: Int
        ) throws {
            let prefix = "talker.code_predictor.model.layers.\(layerIndex)"
            self.inputLayerNormWeight = try reader.loadTensorFloat32(
                name: "\(prefix).input_layernorm.weight"
            ).mlxArray()
            self.postAttentionLayerNormWeight = try reader.loadTensorFloat32(
                name: "\(prefix).post_attention_layernorm.weight"
            ).mlxArray()
            self.qNormWeight = try reader.loadTensorFloat32(
                name: "\(prefix).self_attn.q_norm.weight"
            ).mlxArray()
            self.kNormWeight = try reader.loadTensorFloat32(
                name: "\(prefix).self_attn.k_norm.weight"
            ).mlxArray()
            self.qProjWeight = try reader.loadTensorFloat32(
                name: "\(prefix).self_attn.q_proj.weight"
            ).mlxArray()
            self.kProjWeight = try reader.loadTensorFloat32(
                name: "\(prefix).self_attn.k_proj.weight"
            ).mlxArray()
            self.vProjWeight = try reader.loadTensorFloat32(
                name: "\(prefix).self_attn.v_proj.weight"
            ).mlxArray()
            self.oProjWeight = try reader.loadTensorFloat32(
                name: "\(prefix).self_attn.o_proj.weight"
            ).mlxArray()
            self.gateProjWeight = try reader.loadTensorFloat32(
                name: "\(prefix).mlp.gate_proj.weight"
            ).mlxArray()
            self.upProjWeight = try reader.loadTensorFloat32(
                name: "\(prefix).mlp.up_proj.weight"
            ).mlxArray()
            self.downProjWeight = try reader.loadTensorFloat32(
                name: "\(prefix).mlp.down_proj.weight"
            ).mlxArray()
        }
    }
}
