import Foundation
import MLX

struct TuringQwenNativeCodePredictorResolvedConfig {
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

struct TuringQwenNativeCodePredictorProjectionWeights {
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

struct TuringQwenNativeCodePredictorResolvedWeights {
    let config: TuringQwenNativeCodePredictorResolvedConfig
    let projectionWeights: TuringQwenNativeCodePredictorProjectionWeights
    let layerWeights: [TuringQwenNativeCodePredictorLayerWeights]
    let normWeight: MLXArray
    let lmHeadWeights: [MLXArray]
    let talkerCodecEmbeddingWeight: MLXArray
    let codePredictorCodecEmbeddingWeights: [MLXArray]

    init(
        config rootConfig: TuringQwenNativeConfig,
        weightsStore: TuringQwenNativeWeightsStore
    ) throws {
        let resolver = TuringQwenNativeWeightResolver(store: weightsStore)
        let resolvedConfig = try TuringQwenNativeCodePredictorResolvedConfig(
            rootConfig.talkerConfig.codePredictorConfig
        )
        self.config = resolvedConfig
        self.projectionWeights = try TuringQwenNativeCodePredictorProjectionWeights(
            resolver: resolver
        )
        self.layerWeights = try (0..<resolvedConfig.numHiddenLayers).map {
            try TuringQwenNativeCodePredictorLayerWeights(
                resolver: resolver,
                layerIndex: $0
            )
        }
        self.normWeight = try resolver.tensor("talker.code_predictor.model.norm.weight")
        self.lmHeadWeights = try (0..<(resolvedConfig.numCodeGroups - 1)).map {
            try resolver.tensor("talker.code_predictor.lm_head.\($0).weight")
        }
        self.talkerCodecEmbeddingWeight = try resolver.tensor(
            "talker.model.codec_embedding.weight"
        )
        self.codePredictorCodecEmbeddingWeights = try (0..<(resolvedConfig.numCodeGroups - 1)).map {
            try resolver.tensor("talker.code_predictor.model.codec_embedding.\($0).weight")
        }
    }

    func talkerCodecEmbedding(
        tokenID: Int
    ) throws -> MLXArray {
        try row(
            talkerCodecEmbeddingWeight,
            tokenID: tokenID,
            label: "talker.model.codec_embedding.weight"
        )
        .reshaped([1, 1, 2048])
    }

    func talkerCodecEmbedding(
        tokenIndex: MLXArray
    ) -> MLXArray {
        row(
            talkerCodecEmbeddingWeight,
            tokenIndex: tokenIndex
        )
        .reshaped([1, 1, 2048])
    }

    func codePredictorCodecEmbedding(
        embeddingIndex: Int,
        tokenID: Int
    ) throws -> MLXArray {
        guard codePredictorCodecEmbeddingWeights.indices.contains(embeddingIndex) else {
            throw TuringQwenNativeError.invalidConfig(
                "Missing code predictor codec embedding \(embeddingIndex)."
            )
        }

        return try row(
            codePredictorCodecEmbeddingWeights[embeddingIndex],
            tokenID: tokenID,
            label: "talker.code_predictor.model.codec_embedding.\(embeddingIndex).weight"
        )
        .reshaped([1, 1, 2048])
    }

    func codePredictorCodecEmbedding(
        embeddingIndex: Int,
        tokenIndex: MLXArray
    ) throws -> MLXArray {
        guard codePredictorCodecEmbeddingWeights.indices.contains(embeddingIndex) else {
            throw TuringQwenNativeError.invalidConfig(
                "Missing code predictor codec embedding \(embeddingIndex)."
            )
        }

        return row(
            codePredictorCodecEmbeddingWeights[embeddingIndex],
            tokenIndex: tokenIndex
        )
        .reshaped([1, 1, 2048])
    }

    private func row(
        _ source: MLXArray,
        tokenID: Int,
        label: String
    ) throws -> MLXArray {
        guard source.shape.count == 2 else {
            throw TuringQwenNativeError.invalidSafetensors(
                "Row slicing requires rank-2 tensor \(label), got shape \(source.shape)."
            )
        }
        guard tokenID >= 0, tokenID < source.dim(0) else {
            throw TuringQwenNativeError.invalidSafetensors(
                "Row \(tokenID) is out of bounds for tensor \(label) with \(source.dim(0)) rows."
            )
        }
        return source.take(MLXArray([tokenID]), axis: 0)
    }

    private func row(
        _ source: MLXArray,
        tokenIndex: MLXArray
    ) -> MLXArray {
        source.take(tokenIndex, axis: 0)
    }
}

struct TuringQwenNativeCodePredictorLayerWeights {
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

private struct TuringQwenNativeCodePredictorLayerForwardResult {
    let hiddenStates: MLXArray
    let cacheLayer: TuringQwenNativeCodePredictorKVCache.Layer
}

enum TuringQwenNativeCodePredictorForwardRunner {
    static func prefill(
        inputEmbeddings: MLXArray,
        attentionMask: MLXArray?,
        config: TuringQwenNativeConfig,
        weights: TuringQwenNativeWeightsStore,
        resolvedWeights: TuringQwenNativeCodePredictorResolvedWeights? = nil,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeCodePredictorPrefillOutput {
        let resolved = try resolvedWeights ?? TuringQwenNativeCodePredictorResolvedWeights(
            config: config,
            weightsStore: weights
        )
        let resolvedConfig = resolved.config
        let sequenceLength = inputEmbeddings.dim(1)
        var hidden = inputEmbeddings
        var cacheLayers: [TuringQwenNativeCodePredictorKVCache.Layer] = []
        cacheLayers.reserveCapacity(resolvedConfig.numHiddenLayers)

        for layerIndex in 0..<resolvedConfig.numHiddenLayers {
            let result = try runDecoderLayer(
                hiddenStates: hidden,
                weights: resolved.layerWeights[layerIndex],
                config: resolvedConfig,
                sequenceLength: sequenceLength,
                layerIndex: layerIndex,
                performanceMode: performanceMode
            )
            hidden = result.hiddenStates
            cacheLayers.append(result.cacheLayer)
            if performanceMode.shouldForceEveryEval {
                eval(hidden)
            }
        }

        let normalized = rmsNorm(
            hidden,
            weight: resolved.normWeight,
            eps: Float(resolvedConfig.rmsNormEps)
        )
        let lastHidden = normalized[(sequenceLength - 1)..<sequenceLength, axis: 1]
        let logits = linear(lastHidden, weight: resolved.lmHeadWeights[0])
        if performanceMode.shouldForceEveryEval {
            eval(logits)
        }

        return TuringQwenNativeCodePredictorPrefillOutput(
            logits: logits,
            lastHiddenState: lastHidden,
            state: TuringQwenNativeCodePredictorGenerationState(
                kvCache: TuringQwenNativeCodePredictorKVCache(layers: cacheLayers),
                position: sequenceLength,
                lastHiddenState: lastHidden,
                generatedResidualTokens: []
            )
        )
    }

    static func forwardOneStep(
        inputEmbedding: MLXArray,
        previousState: TuringQwenNativeCodePredictorGenerationState,
        config: TuringQwenNativeConfig,
        weights: TuringQwenNativeWeightsStore,
        resolvedWeights: TuringQwenNativeCodePredictorResolvedWeights? = nil,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeCodePredictorStepOutput {
        let resolved = try resolvedWeights ?? TuringQwenNativeCodePredictorResolvedWeights(
            config: config,
            weightsStore: weights
        )
        let resolvedConfig = resolved.config
        guard inputEmbedding.shape == [1, 1, resolvedConfig.hiddenSize] else {
            throw TuringQwenNativeError.invalidConfig(
                "Expected code predictor one-step input [1, 1, \(resolvedConfig.hiddenSize)], got \(inputEmbedding.shape)."
            )
        }
        guard previousState.kvCache.layers.count == resolvedConfig.numHiddenLayers else {
            throw TuringQwenNativeError.invalidConfig(
                "Code predictor KV cache layer count \(previousState.kvCache.layers.count) does not match \(resolvedConfig.numHiddenLayers)."
            )
        }

        var hidden = inputEmbedding
        var nextCacheLayers: [TuringQwenNativeCodePredictorKVCache.Layer] = []
        nextCacheLayers.reserveCapacity(resolvedConfig.numHiddenLayers)

        for layerIndex in 0..<resolvedConfig.numHiddenLayers {
            let result = try runDecoderLayerOneStep(
                hiddenStates: hidden,
                previousCacheLayer: previousState.kvCache.layers[layerIndex],
                weights: resolved.layerWeights[layerIndex],
                config: resolvedConfig,
                layerIndex: layerIndex,
                position: previousState.position,
                performanceMode: performanceMode
            )
            hidden = result.hiddenStates
            nextCacheLayers.append(result.cacheLayer)
            if performanceMode.shouldForceEveryEval {
                eval(hidden)
            }
        }

        let lastHidden = rmsNorm(
            hidden,
            weight: resolved.normWeight,
            eps: Float(resolvedConfig.rmsNormEps)
        )
        let lmHeadIndex = previousState.generatedResidualTokens.count
        let logits = linear(lastHidden, weight: resolved.lmHeadWeights[lmHeadIndex])
        if performanceMode.shouldForceEveryEval {
            eval(logits)
        }

        let nextState = TuringQwenNativeCodePredictorGenerationState(
            kvCache: TuringQwenNativeCodePredictorKVCache(layers: nextCacheLayers),
            position: previousState.position + 1,
            lastHiddenState: lastHidden,
            generatedResidualTokens: previousState.generatedResidualTokens
        )

        return TuringQwenNativeCodePredictorStepOutput(
            logits: logits,
            lastHiddenState: lastHidden,
            state: nextState
        )
    }

    private static func runDecoderLayer(
        hiddenStates: MLXArray,
        weights: TuringQwenNativeCodePredictorLayerWeights,
        config: TuringQwenNativeCodePredictorResolvedConfig,
        sequenceLength: Int,
        layerIndex: Int,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeCodePredictorLayerForwardResult {
        let residual = hiddenStates
        let normalized = rmsNorm(
            hiddenStates,
            weight: weights.inputLayerNormWeight,
            eps: Float(config.rmsNormEps)
        )
        let attentionResult = try selfAttention(
            hiddenStates: normalized,
            weights: weights,
            config: config,
            sequenceLength: sequenceLength,
            layerIndex: layerIndex,
            performanceMode: performanceMode
        )
        let afterAttention = residual + attentionResult.hiddenStates
        let mlpResidual = afterAttention
        let mlpInput = rmsNorm(
            afterAttention,
            weight: weights.postAttentionLayerNormWeight,
            eps: Float(config.rmsNormEps)
        )
        let mlpOutput = mlp(mlpInput, weights: weights)

        return TuringQwenNativeCodePredictorLayerForwardResult(
            hiddenStates: mlpResidual + mlpOutput,
            cacheLayer: attentionResult.cacheLayer
        )
    }

    private static func runDecoderLayerOneStep(
        hiddenStates: MLXArray,
        previousCacheLayer: TuringQwenNativeCodePredictorKVCache.Layer,
        weights: TuringQwenNativeCodePredictorLayerWeights,
        config: TuringQwenNativeCodePredictorResolvedConfig,
        layerIndex: Int,
        position: Int,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeCodePredictorLayerForwardResult {
        let residual = hiddenStates
        let normalized = rmsNorm(
            hiddenStates,
            weight: weights.inputLayerNormWeight,
            eps: Float(config.rmsNormEps)
        )
        let attentionResult = try selfAttentionOneStep(
            hiddenStates: normalized,
            previousCacheLayer: previousCacheLayer,
            weights: weights,
            config: config,
            layerIndex: layerIndex,
            position: position,
            performanceMode: performanceMode
        )
        let afterAttention = residual + attentionResult.hiddenStates
        let mlpResidual = afterAttention
        let mlpInput = rmsNorm(
            afterAttention,
            weight: weights.postAttentionLayerNormWeight,
            eps: Float(config.rmsNormEps)
        )
        let mlpOutput = mlp(mlpInput, weights: weights)

        return TuringQwenNativeCodePredictorLayerForwardResult(
            hiddenStates: mlpResidual + mlpOutput,
            cacheLayer: attentionResult.cacheLayer
        )
    }

    private static func selfAttention(
        hiddenStates: MLXArray,
        weights: TuringQwenNativeCodePredictorLayerWeights,
        config: TuringQwenNativeCodePredictorResolvedConfig,
        sequenceLength: Int,
        layerIndex: Int,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeCodePredictorLayerForwardResult {
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

        let cacheLayer = try TuringQwenNativeCodePredictorKVCacheStore.prefillLayer(
            keyStates: keyStates,
            valueStates: valueStates,
            layerIndex: layerIndex,
            performanceMode: performanceMode
        )
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

        return TuringQwenNativeCodePredictorLayerForwardResult(
            hiddenStates: linear(attended, weight: weights.oProjWeight),
            cacheLayer: cacheLayer
        )
    }

    private static func selfAttentionOneStep(
        hiddenStates: MLXArray,
        previousCacheLayer: TuringQwenNativeCodePredictorKVCache.Layer,
        weights: TuringQwenNativeCodePredictorLayerWeights,
        config: TuringQwenNativeCodePredictorResolvedConfig,
        layerIndex: Int,
        position: Int,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeCodePredictorLayerForwardResult {
        let query = linear(hiddenStates, weight: weights.qProjWeight)
            .reshaped([1, 1, config.numAttentionHeads, config.headDim])
        let key = linear(hiddenStates, weight: weights.kProjWeight)
            .reshaped([1, 1, config.numKeyValueHeads, config.headDim])
        let value = linear(hiddenStates, weight: weights.vProjWeight)
            .reshaped([1, 1, config.numKeyValueHeads, config.headDim])
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
        let valueStates = value.transposed(0, 2, 1, 3)

        let rope = rotaryEmbeddings(
            positions: [position],
            headDim: config.headDim,
            theta: config.ropeTheta
        )
        queryStates = applyRotary(queryStates, cos: rope.cos, sin: rope.sin)
        keyStates = applyRotary(keyStates, cos: rope.cos, sin: rope.sin)

        let updatedCacheLayer = try TuringQwenNativeCodePredictorKVCacheStore.appendOneStep(
            layer: previousCacheLayer,
            newKey: keyStates,
            newValue: valueStates,
            layerIndex: layerIndex,
            performanceMode: performanceMode
        )
        let repeatedKeyStates = repeatKeyValueHeads(
            updatedCacheLayer.activeKeys,
            keyValueHeads: config.numKeyValueHeads,
            attentionHeads: config.numAttentionHeads
        )
        let repeatedValueStates = repeatKeyValueHeads(
            updatedCacheLayer.activeValues,
            keyValueHeads: config.numKeyValueHeads,
            attentionHeads: config.numAttentionHeads
        )

        let scale = Float(1.0 / sqrt(Double(config.headDim)))
        let scores = matmul(queryStates, repeatedKeyStates.transposed(0, 1, 3, 2)) * scale
        let probabilities = softmax(scores, axis: -1, precise: true)
        let attended = matmul(probabilities, repeatedValueStates)
            .transposed(0, 2, 1, 3)
            .reshaped([1, 1, config.attentionOutputSize])

        return TuringQwenNativeCodePredictorLayerForwardResult(
            hiddenStates: linear(attended, weight: weights.oProjWeight),
            cacheLayer: updatedCacheLayer
        )
    }

    static func projectedInput(
        codeHidden: MLXArray,
        projectionWeights: TuringQwenNativeCodePredictorProjectionWeights
    ) -> MLXArray {
        linear(
            codeHidden,
            weight: projectionWeights.smallToMTPProjectionWeight,
            bias: projectionWeights.smallToMTPProjectionBias
        )
    }

    static func logits(
        lastHidden: MLXArray,
        lmHeadIndex: Int,
        weights: TuringQwenNativeWeightsStore
    ) throws -> MLXArray {
        let resolver = TuringQwenNativeWeightResolver(store: weights)
        let lmHeadWeight = try resolver.tensor("talker.code_predictor.lm_head.\(lmHeadIndex).weight")
        return linear(lastHidden, weight: lmHeadWeight)
    }

    private static func mlp(
        _ hiddenStates: MLXArray,
        weights: TuringQwenNativeCodePredictorLayerWeights
    ) -> MLXArray {
        let gate = linear(hiddenStates, weight: weights.gateProjWeight)
        let up = linear(hiddenStates, weight: weights.upProjWeight)
        let activated = gate * sigmoid(gate)
        return linear(activated * up, weight: weights.downProjWeight)
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
        rotaryEmbeddings(
            positions: Array(0..<sequenceLength),
            headDim: headDim,
            theta: theta
        )
    }

    private static func rotaryEmbeddings(
        positions: [Int],
        headDim: Int,
        theta: Double
    ) -> (cos: MLXArray, sin: MLXArray) {
        let half = headDim / 2
        var cosValues: [Float] = []
        var sinValues: [Float] = []
        cosValues.reserveCapacity(positions.count * headDim)
        sinValues.reserveCapacity(positions.count * headDim)

        for position in positions {
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
            MLXArray(cosValues, [1, 1, positions.count, headDim]),
            MLXArray(sinValues, [1, 1, positions.count, headDim])
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
}
