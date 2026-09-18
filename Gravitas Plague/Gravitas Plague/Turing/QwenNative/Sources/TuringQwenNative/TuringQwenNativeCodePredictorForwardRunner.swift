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
    let smallToMTPProjectionWeight: TuringQwenNativeLinearWeight
    let smallToMTPProjectionBias: MLXArray

    init(resolver: TuringQwenNativeWeightResolver) throws {
        self.smallToMTPProjectionWeight = try resolver.linear(
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
    let lmHeadWeights: [TuringQwenNativeLinearWeight]
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
            try resolver.linear("talker.code_predictor.lm_head.\($0).weight")
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
    let qProjWeight: TuringQwenNativeLinearWeight
    let kProjWeight: TuringQwenNativeLinearWeight
    let vProjWeight: TuringQwenNativeLinearWeight
    let oProjWeight: TuringQwenNativeLinearWeight
    let gateProjWeight: TuringQwenNativeLinearWeight
    let upProjWeight: TuringQwenNativeLinearWeight
    let downProjWeight: TuringQwenNativeLinearWeight

    init(
        resolver: TuringQwenNativeWeightResolver,
        layerIndex: Int
    ) throws {
        let prefix = "talker.code_predictor.model.layers.\(layerIndex)"
        self.inputLayerNormWeight = try resolver.tensor("\(prefix).input_layernorm.weight")
        self.postAttentionLayerNormWeight = try resolver.tensor("\(prefix).post_attention_layernorm.weight")
        self.qNormWeight = try resolver.tensor("\(prefix).self_attn.q_norm.weight")
        self.kNormWeight = try resolver.tensor("\(prefix).self_attn.k_norm.weight")
        self.qProjWeight = try resolver.linear("\(prefix).self_attn.q_proj.weight")
        self.kProjWeight = try resolver.linear("\(prefix).self_attn.k_proj.weight")
        self.vProjWeight = try resolver.linear("\(prefix).self_attn.v_proj.weight")
        self.oProjWeight = try resolver.linear("\(prefix).self_attn.o_proj.weight")
        self.gateProjWeight = try resolver.linear("\(prefix).mlp.gate_proj.weight")
        self.upProjWeight = try resolver.linear("\(prefix).mlp.up_proj.weight")
        self.downProjWeight = try resolver.linear("\(prefix).mlp.down_proj.weight")
    }
}

private struct TuringQwenNativeCodePredictorLayerForwardResult {
    let hiddenStates: MLXArray
    let cacheLayer: TuringQwenNativeCodePredictorKVCache.Layer
}

enum TuringQwenNativeCodePredictorForwardRunner {
    private typealias Arithmetic = TuringQwenNativeGenerationArithmetic

    static func prefill(
        inputEmbeddings: MLXArray,
        attentionMask: MLXArray?,
        config: TuringQwenNativeConfig,
        weights: TuringQwenNativeWeightsStore,
        resolvedWeights: TuringQwenNativeCodePredictorResolvedWeights? = nil,
        segmentCache: TuringQwenNativeSegmentRuntimeCache? = nil,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeCodePredictorPrefillOutput {
        let resolved = try resolvedWeights ?? TuringQwenNativeCodePredictorResolvedWeights(
            config: config,
            weightsStore: weights
        )
        let resolvedConfig = resolved.config
        let sequenceLength = inputEmbeddings.dim(1)
        var hidden = Arithmetic.activation(inputEmbeddings)
        var cacheLayers: [TuringQwenNativeCodePredictorKVCache.Layer] = []
        cacheLayers.reserveCapacity(resolvedConfig.numHiddenLayers)

        for layerIndex in 0..<resolvedConfig.numHiddenLayers {
            let result = try runDecoderLayer(
                hiddenStates: hidden,
                weights: resolved.layerWeights[layerIndex],
                config: resolvedConfig,
                sequenceLength: sequenceLength,
                layerIndex: layerIndex,
                segmentCache: segmentCache,
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
            eps: Float(resolvedConfig.rmsNormEps),
            performanceMode: performanceMode
        )
        let lastHidden = normalized[(sequenceLength - 1)..<sequenceLength, axis: 1]
        let logits = linear(Arithmetic.logitInput(lastHidden), weight: resolved.lmHeadWeights[0])
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
                generatedResidualTokenCount: 0
            )
        )
    }

    static func forwardOneStep(
        inputEmbedding: MLXArray,
        previousState: TuringQwenNativeCodePredictorGenerationState,
        config: TuringQwenNativeConfig,
        weights: TuringQwenNativeWeightsStore,
        resolvedWeights: TuringQwenNativeCodePredictorResolvedWeights? = nil,
        segmentCache: TuringQwenNativeSegmentRuntimeCache? = nil,
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

        var hidden = Arithmetic.activation(inputEmbedding)
        var nextCacheLayers: [TuringQwenNativeCodePredictorKVCache.Layer] = []
        nextCacheLayers.reserveCapacity(resolvedConfig.numHiddenLayers)
        let oneStepRope = segmentCache?.codePredictorRope(position: previousState.position) ??
            rotaryEmbeddings(
                positions: [previousState.position],
                headDim: resolvedConfig.headDim,
                theta: resolvedConfig.ropeTheta
            )

        for layerIndex in 0..<resolvedConfig.numHiddenLayers {
            let result = try runDecoderLayerOneStep(
                hiddenStates: hidden,
                previousCacheLayer: previousState.kvCache.layers[layerIndex],
                weights: resolved.layerWeights[layerIndex],
                config: resolvedConfig,
                layerIndex: layerIndex,
                position: previousState.position,
                rope: oneStepRope,
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
            eps: Float(resolvedConfig.rmsNormEps),
            performanceMode: performanceMode
        )
        let lmHeadIndex = previousState.generatedResidualTokenCount
        let logits = linear(Arithmetic.logitInput(lastHidden), weight: resolved.lmHeadWeights[lmHeadIndex])
        if performanceMode.shouldForceEveryEval {
            eval(logits)
        }

        let nextState = TuringQwenNativeCodePredictorGenerationState(
            kvCache: TuringQwenNativeCodePredictorKVCache(layers: nextCacheLayers),
            position: previousState.position + 1,
            lastHiddenState: lastHidden,
            generatedResidualTokenCount: previousState.generatedResidualTokenCount
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
        segmentCache: TuringQwenNativeSegmentRuntimeCache?,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeCodePredictorLayerForwardResult {
        let residual = Arithmetic.activation(hiddenStates)
        let normalized = rmsNorm(
            residual,
            weight: weights.inputLayerNormWeight,
            eps: Float(config.rmsNormEps),
            performanceMode: performanceMode
        )
        let attentionResult = try selfAttention(
            hiddenStates: normalized,
            weights: weights,
            config: config,
            sequenceLength: sequenceLength,
            layerIndex: layerIndex,
            segmentCache: segmentCache,
            performanceMode: performanceMode
        )
        let afterAttention = Arithmetic.activation(residual + attentionResult.hiddenStates)
        let mlpResidual = afterAttention
        let mlpInput = rmsNorm(
            afterAttention,
            weight: weights.postAttentionLayerNormWeight,
            eps: Float(config.rmsNormEps),
            performanceMode: performanceMode
        )
        let mlpOutput = mlp(mlpInput, weights: weights)

        return TuringQwenNativeCodePredictorLayerForwardResult(
            hiddenStates: Arithmetic.activation(mlpResidual + mlpOutput),
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
        rope: (cos: MLXArray, sin: MLXArray),
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeCodePredictorLayerForwardResult {
        let residual = Arithmetic.activation(hiddenStates)
        let normalized = rmsNorm(
            residual,
            weight: weights.inputLayerNormWeight,
            eps: Float(config.rmsNormEps),
            performanceMode: performanceMode
        )
        let attentionResult = try selfAttentionOneStep(
            hiddenStates: normalized,
            previousCacheLayer: previousCacheLayer,
            weights: weights,
            config: config,
            layerIndex: layerIndex,
            position: position,
            rope: rope,
            performanceMode: performanceMode
        )
        let afterAttention = Arithmetic.activation(residual + attentionResult.hiddenStates)
        let mlpResidual = afterAttention
        let mlpInput = rmsNorm(
            afterAttention,
            weight: weights.postAttentionLayerNormWeight,
            eps: Float(config.rmsNormEps),
            performanceMode: performanceMode
        )
        let mlpOutput = mlp(mlpInput, weights: weights)

        return TuringQwenNativeCodePredictorLayerForwardResult(
            hiddenStates: Arithmetic.activation(mlpResidual + mlpOutput),
            cacheLayer: attentionResult.cacheLayer
        )
    }

    private static func selfAttention(
        hiddenStates: MLXArray,
        weights: TuringQwenNativeCodePredictorLayerWeights,
        config: TuringQwenNativeCodePredictorResolvedConfig,
        sequenceLength: Int,
        layerIndex: Int,
        segmentCache: TuringQwenNativeSegmentRuntimeCache?,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeCodePredictorLayerForwardResult {
        let query = Arithmetic.activation(linear(hiddenStates, weight: weights.qProjWeight))
            .reshaped([1, sequenceLength, config.numAttentionHeads, config.headDim])
        let key = Arithmetic.activation(linear(hiddenStates, weight: weights.kProjWeight))
            .reshaped([1, sequenceLength, config.numKeyValueHeads, config.headDim])
        let value = Arithmetic.activation(linear(hiddenStates, weight: weights.vProjWeight))
            .reshaped([1, sequenceLength, config.numKeyValueHeads, config.headDim])
        if layerIndex == 0 {
            TuringQwenNativePhaseDiagnostics.tensor("predictor.prefill.qProjection", query)
            TuringQwenNativePhaseDiagnostics.tensor("predictor.prefill.kProjection", key)
            TuringQwenNativePhaseDiagnostics.tensor("predictor.prefill.vProjection", value)
        }
        var queryStates = rmsNorm(
            query,
            weight: weights.qNormWeight,
            eps: Float(config.rmsNormEps),
            performanceMode: performanceMode
        ).transposed(0, 2, 1, 3)
        var keyStates = rmsNorm(
            key,
            weight: weights.kNormWeight,
            eps: Float(config.rmsNormEps),
            performanceMode: performanceMode
        ).transposed(0, 2, 1, 3)
        var valueStates = value.transposed(0, 2, 1, 3)

        let rope: (cos: MLXArray, sin: MLXArray)
        if sequenceLength == 2,
           segmentCache?.matchesCurrentArithmetic == true,
           let cached = segmentCache?.codePredictorPrefillRope {
            rope = (cached.cos, cached.sin)
        } else {
            rope = rotaryEmbeddings(
                sequenceLength: sequenceLength,
                headDim: config.headDim,
                theta: config.ropeTheta
            )
        }
        queryStates = applyRotary(queryStates, cos: rope.cos, sin: rope.sin)
        keyStates = applyRotary(keyStates, cos: rope.cos, sin: rope.sin)

        if layerIndex == 0 {
            TuringQwenNativePhaseDiagnostics.tensor("predictor.prefill.postRopeQ", queryStates)
            TuringQwenNativePhaseDiagnostics.tensor("predictor.prefill.postRopeK", keyStates)
        }

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
        let attentionMask = sequenceLength == 2 && segmentCache?.matchesCurrentArithmetic == true
            ? (segmentCache?.codePredictorPrefillMask ?? causalMask(sequenceLength: sequenceLength))
            : causalMask(sequenceLength: sequenceLength)
        let scores = attentionScores(query: queryStates, key: keyStates, scale: scale) + attentionMask
        let probabilities = Arithmetic.attentionProbabilities(
            scores,
            legacyPrecise: performanceMode.shouldUsePreciseAttentionSoftmax
        )
        let attended = Arithmetic.activation(matmul(probabilities, valueStates))
            .transposed(0, 2, 1, 3)
            .reshaped([1, sequenceLength, config.attentionOutputSize])
        if layerIndex == 0 {
            TuringQwenNativePhaseDiagnostics.tensor("predictor.prefill.attentionOutput", attended)
        }

        return TuringQwenNativeCodePredictorLayerForwardResult(
            hiddenStates: Arithmetic.activation(linear(attended, weight: weights.oProjWeight)),
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
        rope: (cos: MLXArray, sin: MLXArray),
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeCodePredictorLayerForwardResult {
        let query = Arithmetic.activation(linear(hiddenStates, weight: weights.qProjWeight))
            .reshaped([1, 1, config.numAttentionHeads, config.headDim])
        let key = Arithmetic.activation(linear(hiddenStates, weight: weights.kProjWeight))
            .reshaped([1, 1, config.numKeyValueHeads, config.headDim])
        let value = Arithmetic.activation(linear(hiddenStates, weight: weights.vProjWeight))
            .reshaped([1, 1, config.numKeyValueHeads, config.headDim])
        if layerIndex == 0 {
            TuringQwenNativePhaseDiagnostics.tensor("predictor.step.qProjection", query)
            TuringQwenNativePhaseDiagnostics.tensor("predictor.step.kProjection", key)
            TuringQwenNativePhaseDiagnostics.tensor("predictor.step.vProjection", value)
        }
        var queryStates = rmsNorm(
            query,
            weight: weights.qNormWeight,
            eps: Float(config.rmsNormEps),
            performanceMode: performanceMode
        ).transposed(0, 2, 1, 3)
        var keyStates = rmsNorm(
            key,
            weight: weights.kNormWeight,
            eps: Float(config.rmsNormEps),
            performanceMode: performanceMode
        ).transposed(0, 2, 1, 3)
        let valueStates = value.transposed(0, 2, 1, 3)

        queryStates = applyRotary(queryStates, cos: rope.cos, sin: rope.sin)
        keyStates = applyRotary(keyStates, cos: rope.cos, sin: rope.sin)

        if layerIndex == 0 {
            TuringQwenNativePhaseDiagnostics.tensor("predictor.step.postRopeQ", queryStates)
            TuringQwenNativePhaseDiagnostics.tensor("predictor.step.postRopeK", keyStates)
        }

        let updatedCacheLayer = try TuringQwenNativeCodePredictorKVCacheStore.appendOneStep(
            layer: previousCacheLayer,
            newKey: keyStates,
            newValue: valueStates,
            layerIndex: layerIndex,
            performanceMode: performanceMode
        )

        let scale = Float(1.0 / sqrt(Double(config.headDim)))
        let attendedHeads: MLXArray
        if performanceMode.shouldUseFastGroupedQueryAttention {
            attendedHeads = MLXFast.scaledDotProductAttention(
                queries: queryStates,
                keys: updatedCacheLayer.activeKeys,
                values: updatedCacheLayer.activeValues,
                scale: scale,
                mask: .none
            )
        } else {
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
            let scores = attentionScores(query: queryStates, key: repeatedKeyStates, scale: scale)
            let probabilities = Arithmetic.attentionProbabilities(
                scores,
                legacyPrecise: performanceMode.shouldUsePreciseAttentionSoftmax
            )
            attendedHeads = matmul(probabilities, repeatedValueStates)
        }

        let attended = Arithmetic.activation(attendedHeads)
            .transposed(0, 2, 1, 3)
            .reshaped([1, 1, config.attentionOutputSize])
        if layerIndex == 0 {
            TuringQwenNativePhaseDiagnostics.tensor("predictor.step.attentionOutput", attended)
            TuringQwenNativePhaseDiagnostics.tensor("predictor.step.cacheK", updatedCacheLayer.key)
            TuringQwenNativePhaseDiagnostics.tensor("predictor.step.cacheV", updatedCacheLayer.value)
        }

        return TuringQwenNativeCodePredictorLayerForwardResult(
            hiddenStates: Arithmetic.activation(linear(attended, weight: weights.oProjWeight)),
            cacheLayer: updatedCacheLayer
        )
    }

    static func projectedInput(
        codeHidden: MLXArray,
        projectionWeights: TuringQwenNativeCodePredictorProjectionWeights
    ) -> MLXArray {
        Arithmetic.activation(linear(
            Arithmetic.activation(codeHidden),
            weight: projectionWeights.smallToMTPProjectionWeight,
            bias: Arithmetic.activation(projectionWeights.smallToMTPProjectionBias)
        ))
    }

    static func logits(
        lastHidden: MLXArray,
        lmHeadIndex: Int,
        weights: TuringQwenNativeWeightsStore
    ) throws -> MLXArray {
        let resolver = TuringQwenNativeWeightResolver(store: weights)
        let lmHeadWeight = try resolver.linear("talker.code_predictor.lm_head.\(lmHeadIndex).weight")
        return linear(Arithmetic.logitInput(lastHidden), weight: lmHeadWeight)
    }

    private static func mlp(
        _ hiddenStates: MLXArray,
        weights: TuringQwenNativeCodePredictorLayerWeights
    ) -> MLXArray {
        let gate = Arithmetic.activation(linear(hiddenStates, weight: weights.gateProjWeight))
        let up = Arithmetic.activation(linear(hiddenStates, weight: weights.upProjWeight))
        let activated = Arithmetic.activation(gate * sigmoid(gate))
        return Arithmetic.activation(linear(Arithmetic.activation(activated * up), weight: weights.downProjWeight))
    }

    private static func rmsNorm(
        _ value: MLXArray,
        weight: MLXArray,
        eps: Float,
        performanceMode: TuringQwenNativePerformanceMode
    ) -> MLXArray {
        Arithmetic.rmsNorm(
            value,
            weight: weight,
            epsilon: eps,
            forceManual: performanceMode != .performance
        )
    }

    private static func attentionScores(
        query: MLXArray,
        key: MLXArray,
        scale: Float
    ) -> MLXArray {
        // BF16 cache/activation storage does not lower score arithmetic.
        let scoreQuery = Arithmetic.isBF16 ? query.asType(.float32) : query
        let scoreKey = Arithmetic.isBF16 ? key.asType(.float32) : key
        return matmul(scoreQuery, scoreKey.transposed(0, 1, 3, 2)) * scale
    }

    private static func linear(
        _ value: MLXArray,
        weight: TuringQwenNativeLinearWeight
    ) -> MLXArray {
        weight.apply(value)
    }

    private static func linear(
        _ value: MLXArray,
        weight: TuringQwenNativeLinearWeight,
        bias: MLXArray
    ) -> MLXArray {
        weight.apply(value) + bias
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
            Arithmetic.activation(MLXArray(cosValues, [1, 1, positions.count, headDim])),
            Arithmetic.activation(MLXArray(sinValues, [1, 1, positions.count, headDim]))
        )
    }

    private static func applyRotary(
        _ value: MLXArray,
        cos: MLXArray,
        sin: MLXArray
    ) -> MLXArray {
        Arithmetic.activation(
            value * Arithmetic.activation(cos) + rotateHalf(value) * Arithmetic.activation(sin)
        )
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
