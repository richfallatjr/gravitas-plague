import Foundation
import MLX

struct TuringQwenNativeTalkerLayerOutput {
    let hiddenStates: MLXArray
    let sequenceLength: Int
    let hiddenSize: Int
}

struct TuringQwenNativeTalkerForwardOutput {
    let finalLastHiddenState: MLXArray
    let sequenceLength: Int
    let hiddenSize: Int
    let kvCache: TuringQwenNativeKVCache
}

struct TuringQwenNativeTalkerResolvedWeights {
    let layers: [TuringQwenNativeTalkerLayerWeights]
    let finalNormWeight: MLXArray
    let codecHeadWeight: TuringQwenNativeLinearWeight

    init(
        config: TuringQwenNativeConfig,
        weightsStore: TuringQwenNativeWeightsStore
    ) throws {
        let resolver = TuringQwenNativeWeightResolver(store: weightsStore)
        self.layers = try (0..<config.talkerConfig.numHiddenLayers).map {
            try TuringQwenNativeTalkerLayerWeights(
                resolver: resolver,
                layerIndex: $0
            )
        }
        self.finalNormWeight = try resolver.tensor("talker.model.norm.weight")
        self.codecHeadWeight = try resolver.linear("talker.codec_head.weight")
    }
}

private struct TuringQwenNativeTalkerLayerForwardResult {
    let hiddenStates: MLXArray
    let cacheLayer: TuringQwenNativeKVCache.Layer
}

enum TuringQwenNativeTalkerForwardRunner {
    static func runLayer0(
        promptInputs: TuringQwenNativeTalkerPromptInputs,
        config: TuringQwenNativeConfig,
        weightsStore: TuringQwenNativeWeightsStore,
        maxNewRows: Int
    ) throws -> TuringQwenNativeTalkerLayerOutput {
        let weightsResolver = TuringQwenNativeWeightResolver(store: weightsStore)
        let weights = try TuringQwenNativeTalkerLayerWeights(
            resolver: weightsResolver,
            layerIndex: 0
        )

        let layerResult = try runDecoderLayer(
            hiddenStates: promptInputs.inputsEmbeds,
            weights: weights,
            config: config.talkerConfig,
            sequenceLength: promptInputs.sequenceLength,
            layerIndex: 0,
            maxNewRows: maxNewRows
        )
        let hidden = layerResult.hiddenStates
        eval(hidden)

        return TuringQwenNativeTalkerLayerOutput(
            hiddenStates: hidden,
            sequenceLength: promptInputs.sequenceLength,
            hiddenSize: config.talkerConfig.hiddenSize
        )
    }

    static func runFullForward(
        promptInputs: TuringQwenNativeTalkerPromptInputs,
        config: TuringQwenNativeConfig,
        weightsStore: TuringQwenNativeWeightsStore,
        maxNewRows: Int,
        resolvedWeights: TuringQwenNativeTalkerResolvedWeights? = nil,
        performanceMode: TuringQwenNativePerformanceMode = .diagnostic
    ) throws -> TuringQwenNativeTalkerForwardOutput {
        try runFullForward(
            inputsEmbeds: promptInputs.inputsEmbeds,
            sequenceLength: promptInputs.sequenceLength,
            hiddenSize: config.talkerConfig.hiddenSize,
            config: config,
            weightsStore: weightsStore,
            maxNewRows: maxNewRows,
            resolvedWeights: resolvedWeights,
            logLabel: "prompt",
            performanceMode: performanceMode
        )
    }

    static func runFullForward(
        inputsEmbeds: MLXArray,
        sequenceLength: Int,
        hiddenSize: Int,
        config: TuringQwenNativeConfig,
        weightsStore: TuringQwenNativeWeightsStore,
        maxNewRows: Int,
        resolvedWeights: TuringQwenNativeTalkerResolvedWeights? = nil,
        logLabel: String,
        performanceMode: TuringQwenNativePerformanceMode = .diagnostic
    ) throws -> TuringQwenNativeTalkerForwardOutput {
        let resolved = try resolvedWeights ?? TuringQwenNativeTalkerResolvedWeights(
            config: config,
            weightsStore: weightsStore
        )
        var hidden = inputsEmbeds
        var cacheLayers: [TuringQwenNativeKVCache.Layer] = []
        cacheLayers.reserveCapacity(config.talkerConfig.numHiddenLayers)
        let forwardStart = Date()

        guard inputsEmbeds.shape == [1, sequenceLength, hiddenSize] else {
            throw TuringQwenNativeError.invalidConfig(
                "Expected talker input embeds [1, \(sequenceLength), \(hiddenSize)] for \(logLabel), got \(inputsEmbeds.shape)."
            )
        }

        if performanceMode.shouldLogFullTokenRows {
            print("""
            [TuringQwenNative] talker all-layers eval starting
              label: \(logLabel)
              layerCount: \(config.talkerConfig.numHiddenLayers)
              sequenceLength: \(sequenceLength)
              hiddenSize: \(hiddenSize)
            """)
        } else {
            print("""
            [TuringQwenNativePerf] talker full forward started
              label: \(logLabel)
              layerCount: \(config.talkerConfig.numHiddenLayers)
              sequenceLength: \(sequenceLength)
            """)
        }

        for layerIndex in 0..<config.talkerConfig.numHiddenLayers {
            let layerStart = Date()

            let layerResult = try runDecoderLayer(
                hiddenStates: hidden,
                weights: resolved.layers[layerIndex],
                config: config.talkerConfig,
                sequenceLength: sequenceLength,
                layerIndex: layerIndex,
                maxNewRows: maxNewRows
            )
            hidden = layerResult.hiddenStates
            cacheLayers.append(layerResult.cacheLayer)
            if performanceMode.shouldForceEveryEval {
                eval(hidden)
            }
            if performanceMode.shouldClearMLXCacheEveryRow {
                TuringQwenNativeMemoryControl.clearCache(label: "talker.\(logLabel).layer.\(layerIndex)")
            }
            if performanceMode.shouldLogFullTokenRows {
                print("""
                [TuringQwenNative] talker layer completed
                  label: \(logLabel)
                  layerIndex: \(layerIndex)
                  layerSeconds: \(String(format: "%.3f", Date().timeIntervalSince(layerStart)))
                  cumulativeSeconds: \(String(format: "%.3f", Date().timeIntervalSince(forwardStart)))
                """)
            }
        }

        let finalNormStart = Date()
        let finalHidden = rmsNorm(
            hidden,
            weight: resolved.finalNormWeight,
            eps: Float(config.talkerConfig.rmsNormEps)
        )
        if performanceMode.shouldForceEveryEval {
            eval(finalHidden)
        }
        let finalLastHidden = finalHidden[
            (sequenceLength - 1)..<sequenceLength,
            axis: 1
        ]
        if performanceMode.shouldForceEveryEval {
            eval(finalLastHidden)
        }
        if performanceMode.shouldClearMLXCacheEveryRow {
            TuringQwenNativeMemoryControl.clearCache(label: "talker.\(logLabel).finalNorm")
        }
        if performanceMode.shouldLogFullTokenRows {
            print("""
            [TuringQwenNative] talker final norm completed
              label: \(logLabel)
              seconds: \(String(format: "%.3f", Date().timeIntervalSince(finalNormStart)))
              cumulativeSeconds: \(String(format: "%.3f", Date().timeIntervalSince(forwardStart)))
            """)
        } else {
            print("""
            [TuringQwenNativePerf] talker full forward finished
              label: \(logLabel)
              seconds: \(String(format: "%.3f", Date().timeIntervalSince(forwardStart)))
            """)
        }

        return TuringQwenNativeTalkerForwardOutput(
            finalLastHiddenState: finalLastHidden,
            sequenceLength: sequenceLength,
            hiddenSize: hiddenSize,
            kvCache: TuringQwenNativeKVCache(
                layers: cacheLayers,
                usesMaterializedLayerState: true,
                maxNewRows: maxNewRows
            )
        )
    }

    static func codecHeadLogits(
        finalLastHiddenState: MLXArray,
        weightsStore: TuringQwenNativeWeightsStore,
        performanceMode: TuringQwenNativePerformanceMode = .diagnostic
    ) throws -> MLXArray {
        let codecHeadWeight = try TuringQwenNativeWeightResolver(
            store: weightsStore
        ).linear("talker.codec_head.weight")
        return codecHeadLogits(
            finalLastHiddenState: finalLastHiddenState,
            codecHeadWeight: codecHeadWeight,
            performanceMode: performanceMode
        )
    }

    static func codecHeadLogits(
        finalLastHiddenState: MLXArray,
        codecHeadWeight: TuringQwenNativeLinearWeight,
        performanceMode: TuringQwenNativePerformanceMode = .diagnostic
    ) -> MLXArray {
        let start = Date()
        let logits = linear(finalLastHiddenState, weight: codecHeadWeight)
        if performanceMode.shouldForceEveryEval {
            eval(logits)
        }
        if performanceMode.shouldClearMLXCacheEveryRow {
            TuringQwenNativeMemoryControl.clearCache(label: "talker.codecHead")
        }
        if performanceMode.shouldLogFullTokenRows {
            print("""
            [TuringQwenNative] talker codec head completed
              seconds: \(String(format: "%.3f", Date().timeIntervalSince(start)))
            """)
        }
        return logits
    }

    static func forwardOneStep(
        inputEmbedding: MLXArray,
        previousState: TuringQwenNativeTalkerGenerationState,
        config: TuringQwenNativeConfig,
        weightsStore: TuringQwenNativeWeightsStore,
        resolvedWeights: TuringQwenNativeTalkerResolvedWeights? = nil,
        codePredictorWeights: TuringQwenNativeCodePredictorResolvedWeights? = nil,
        performanceMode: TuringQwenNativePerformanceMode = .diagnostic
    ) throws -> TuringQwenNativeGeneratedStepOutput {
        let stepStart = Date()
        guard inputEmbedding.shape == [1, 1, config.talkerConfig.hiddenSize] else {
            throw TuringQwenNativeError.invalidConfig(
                "Expected one-step talker input embedding [1, 1, \(config.talkerConfig.hiddenSize)], got \(inputEmbedding.shape)."
            )
        }

        if performanceMode.shouldLogFullTokenRows {
            print("""
            [TuringQwenNative] forwardOneStep started
              position: \(previousState.position)
              kvCacheLayers: \(previousState.kvCache.layers.count)
              kvCacheMaterialized: \(previousState.kvCache.usesMaterializedLayerState)
            """)
        }

        guard previousState.kvCache.layers.count == config.talkerConfig.numHiddenLayers,
              previousState.kvCache.usesMaterializedLayerState else {
            throw TuringQwenNativeError.invalidConfig(
                "One-step talker forward requires materialized K/V cache from the initial prompt forward."
            )
        }

        let resolved = try resolvedWeights ?? TuringQwenNativeTalkerResolvedWeights(
            config: config,
            weightsStore: weightsStore
        )
        var hidden = inputEmbedding
        var nextCacheLayers: [TuringQwenNativeKVCache.Layer] = []
        nextCacheLayers.reserveCapacity(config.talkerConfig.numHiddenLayers)

        for layerIndex in 0..<config.talkerConfig.numHiddenLayers {
            let layerResult = try runDecoderLayerOneStep(
                hiddenStates: hidden,
                previousCacheLayer: previousState.kvCache.layers[layerIndex],
                weights: resolved.layers[layerIndex],
                config: config.talkerConfig,
                layerIndex: layerIndex,
                position: previousState.position,
                performanceMode: performanceMode
            )
            hidden = layerResult.hiddenStates
            nextCacheLayers.append(layerResult.cacheLayer)
            if performanceMode.shouldForceEveryEval {
                eval(hidden)
            }
            if performanceMode.shouldClearMLXCacheEveryRow {
                TuringQwenNativeMemoryControl.clearCache(
                    label: "talker.generatedStep.\(previousState.position).layer.\(layerIndex)"
                )
            }
        }

        let finalLastHiddenState = rmsNorm(
            hidden,
            weight: resolved.finalNormWeight,
            eps: Float(config.talkerConfig.rmsNormEps)
        )
        if performanceMode.shouldForceEveryEval {
            eval(finalLastHiddenState)
        }
        let logits = codecHeadLogits(
            finalLastHiddenState: finalLastHiddenState,
            codecHeadWeight: resolved.codecHeadWeight,
            performanceMode: performanceMode
        )
        let firstCodecToken = try TuringQwenNativeCodecSampler.selectFirstCodecToken(
            logits: logits,
            sequenceLength: 1,
            vocabSize: config.talkerConfig.vocabSize
        ).tokenID
        let codePredictorStart = Date()
        let codeGroup = try TuringQwenNativeCodePredictor.generateCodeGroup(
            firstCodecToken: firstCodecToken,
            talkerLastHiddenState: finalLastHiddenState,
            config: config,
            weightsStore: weightsStore,
            expectedFixtureRowIndex: nil,
            resolvedWeights: codePredictorWeights,
            performanceMode: performanceMode
        )
        let codePredictorSeconds = Date().timeIntervalSince(codePredictorStart)
        let nextPosition = previousState.position + 1
        let attentionMask = MLXArray(
            int64: Array(repeating: 1, count: nextPosition),
            [1, nextPosition]
        )
        let nextState = TuringQwenNativeTalkerGenerationState(
            kvCache: TuringQwenNativeKVCache(
                layers: nextCacheLayers,
                usesMaterializedLayerState: true,
                maxNewRows: previousState.kvCache.maxNewRows
            ),
            position: nextPosition,
            attentionMask: attentionMask
        )

        if performanceMode.shouldLogFullTokenRows {
            print("""
            [TuringQwenNative] forwardOneStep finished
              position: \(nextPosition)
              firstCodecToken: \(firstCodecToken)
              tokenIDs: \(codeGroup.tokenIDs)
            """)
        } else if nextPosition % performanceMode.rowCheckpointStride == 0 {
            print("""
            [TuringQwenNativePerf] forwardOneStep checkpoint
              position: \(nextPosition)
              firstCodecToken: \(firstCodecToken)
            codePredictorKVCache: oneStep
            """)
        }
        let totalStepSeconds = Date().timeIntervalSince(stepStart)

        return TuringQwenNativeGeneratedStepOutput(
            step: nextPosition,
            firstCodecToken: firstCodecToken,
            codeGroup: codeGroup.tokenIDs,
            talkerLastHiddenState: finalLastHiddenState,
            talkerStepSeconds: max(0, totalStepSeconds - codePredictorSeconds),
            codePredictorSeconds: codePredictorSeconds,
            stop: false,
            state: nextState
        )
    }

    private static func runDecoderLayer(
        hiddenStates: MLXArray,
        weights: TuringQwenNativeTalkerLayerWeights,
        config: TuringQwenNativeConfig.TalkerConfig,
        sequenceLength: Int,
        layerIndex: Int,
        maxNewRows: Int
    ) throws -> TuringQwenNativeTalkerLayerForwardResult {
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
            maxNewRows: maxNewRows
        )
        let afterAttention = residual + attentionResult.hiddenStates

        let mlpResidual = afterAttention
        let mlpInput = rmsNorm(
            afterAttention,
            weight: weights.postAttentionLayerNormWeight,
            eps: Float(config.rmsNormEps)
        )
        let mlpOutput = mlp(mlpInput, weights: weights)

        return TuringQwenNativeTalkerLayerForwardResult(
            hiddenStates: mlpResidual + mlpOutput,
            cacheLayer: attentionResult.cacheLayer
        )
    }

    private static func runDecoderLayerOneStep(
        hiddenStates: MLXArray,
        previousCacheLayer: TuringQwenNativeKVCache.Layer,
        weights: TuringQwenNativeTalkerLayerWeights,
        config: TuringQwenNativeConfig.TalkerConfig,
        layerIndex: Int,
        position: Int,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeTalkerLayerForwardResult {
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

        return TuringQwenNativeTalkerLayerForwardResult(
            hiddenStates: mlpResidual + mlpOutput,
            cacheLayer: attentionResult.cacheLayer
        )
    }

    private static func selfAttention(
        hiddenStates: MLXArray,
        weights: TuringQwenNativeTalkerLayerWeights,
        config: TuringQwenNativeConfig.TalkerConfig,
        sequenceLength: Int,
        layerIndex: Int,
        maxNewRows: Int
    ) throws -> TuringQwenNativeTalkerLayerForwardResult {
        let hiddenSize = config.hiddenSize
        let headDim = config.headDim
        let attentionHeads = config.numAttentionHeads
        let keyValueHeads = config.numKeyValueHeads

        let query = linear(hiddenStates, weight: weights.qProjWeight)
            .reshaped([1, sequenceLength, attentionHeads, headDim])
        let key = linear(hiddenStates, weight: weights.kProjWeight)
            .reshaped([1, sequenceLength, keyValueHeads, headDim])
        let value = linear(hiddenStates, weight: weights.vProjWeight)
            .reshaped([1, sequenceLength, keyValueHeads, headDim])

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
            headDim: headDim,
            theta: config.ropeTheta
        )
        queryStates = applyRotary(queryStates, cos: rope.cos, sin: rope.sin)
        keyStates = applyRotary(keyStates, cos: rope.cos, sin: rope.sin)

        let cacheLayer = try TuringQwenNativeKVCacheStore.promptLayer(
            keyStates: keyStates,
            valueStates: valueStates,
            maxNewRows: maxNewRows,
            layerIndex: layerIndex
        )

        keyStates = repeatKeyValueHeads(
            keyStates,
            keyValueHeads: keyValueHeads,
            attentionHeads: attentionHeads
        )
        valueStates = repeatKeyValueHeads(
            valueStates,
            keyValueHeads: keyValueHeads,
            attentionHeads: attentionHeads
        )

        let scale = Float(1.0 / sqrt(Double(headDim)))
        let attentionMask = causalMask(sequenceLength: sequenceLength)
        let scores = matmul(queryStates, keyStates.transposed(0, 1, 3, 2)) * scale + attentionMask
        let probabilities = softmax(scores, axis: -1, precise: true)
        let attended = matmul(probabilities, valueStates)
            .transposed(0, 2, 1, 3)
            .reshaped([1, sequenceLength, hiddenSize])

        return TuringQwenNativeTalkerLayerForwardResult(
            hiddenStates: linear(attended, weight: weights.oProjWeight),
            cacheLayer: cacheLayer
        )
    }

    private static func selfAttentionOneStep(
        hiddenStates: MLXArray,
        previousCacheLayer: TuringQwenNativeKVCache.Layer,
        weights: TuringQwenNativeTalkerLayerWeights,
        config: TuringQwenNativeConfig.TalkerConfig,
        layerIndex: Int,
        position: Int,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> TuringQwenNativeTalkerLayerForwardResult {
        let hiddenSize = config.hiddenSize
        let headDim = config.headDim
        let attentionHeads = config.numAttentionHeads
        let keyValueHeads = config.numKeyValueHeads

        let query = linear(hiddenStates, weight: weights.qProjWeight)
            .reshaped([1, 1, attentionHeads, headDim])
        let key = linear(hiddenStates, weight: weights.kProjWeight)
            .reshaped([1, 1, keyValueHeads, headDim])
        let value = linear(hiddenStates, weight: weights.vProjWeight)
            .reshaped([1, 1, keyValueHeads, headDim])

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
            headDim: headDim,
            theta: config.ropeTheta
        )
        queryStates = applyRotary(queryStates, cos: rope.cos, sin: rope.sin)
        keyStates = applyRotary(keyStates, cos: rope.cos, sin: rope.sin)

        let updatedCacheLayer = try TuringQwenNativeKVCacheStore.appendOneStep(
            layer: previousCacheLayer,
            newKeys: keyStates,
            newValues: valueStates,
            layerIndex: layerIndex,
            performanceMode: performanceMode
        )
        let repeatedKeyStates = repeatKeyValueHeads(
            updatedCacheLayer.activeKeys,
            keyValueHeads: keyValueHeads,
            attentionHeads: attentionHeads
        )
        let repeatedValueStates = repeatKeyValueHeads(
            updatedCacheLayer.activeValues,
            keyValueHeads: keyValueHeads,
            attentionHeads: attentionHeads
        )

        let scale = Float(1.0 / sqrt(Double(headDim)))
        let scores = matmul(queryStates, repeatedKeyStates.transposed(0, 1, 3, 2)) * scale
        let probabilities = softmax(scores, axis: -1, precise: true)
        let attended = matmul(probabilities, repeatedValueStates)
            .transposed(0, 2, 1, 3)
            .reshaped([1, 1, hiddenSize])

        return TuringQwenNativeTalkerLayerForwardResult(
            hiddenStates: linear(attended, weight: weights.oProjWeight),
            cacheLayer: updatedCacheLayer
        )
    }

    private static func mlp(
        _ hiddenStates: MLXArray,
        weights: TuringQwenNativeTalkerLayerWeights
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
        weight: TuringQwenNativeLinearWeight
    ) -> MLXArray {
        weight.apply(value)
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

struct TuringQwenNativeTalkerLayerWeights {
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
        let prefix = "talker.model.layers.\(layerIndex)"
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
