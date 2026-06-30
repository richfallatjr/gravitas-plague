import Foundation
import MLX

struct TuringQwenNativeTalkerLayerOutput {
    let hiddenStates: MLXArray
    let sequenceLength: Int
    let hiddenSize: Int
}

enum TuringQwenNativeTalkerLayer0Runner {
    static func run(
        promptInputs: TuringQwenNativeTalkerPromptInputs,
        config: TuringQwenNativeConfig,
        tensorIndex: TuringQwenNativeSafetensorsIndex
    ) throws -> TuringQwenNativeTalkerLayerOutput {
        let weights = try TuringQwenNativeTalkerLayerWeights(
            reader: TuringQwenNativeSafetensorsReader(index: tensorIndex),
            layerIndex: 0
        )

        let hidden = try runDecoderLayer(
            hiddenStates: promptInputs.inputsEmbeds,
            weights: weights,
            config: config.talkerConfig,
            sequenceLength: promptInputs.sequenceLength
        )
        eval(hidden)

        return TuringQwenNativeTalkerLayerOutput(
            hiddenStates: hidden,
            sequenceLength: promptInputs.sequenceLength,
            hiddenSize: config.talkerConfig.hiddenSize
        )
    }

    private static func runDecoderLayer(
        hiddenStates: MLXArray,
        weights: TuringQwenNativeTalkerLayerWeights,
        config: TuringQwenNativeConfig.TalkerConfig,
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
        weights: TuringQwenNativeTalkerLayerWeights,
        config: TuringQwenNativeConfig.TalkerConfig,
        sequenceLength: Int
    ) throws -> MLXArray {
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

        return linear(attended, weight: weights.oProjWeight)
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
        weight: MLXArray
    ) -> MLXArray {
        matmul(value, weight.T)
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
}

private struct TuringQwenNativeTalkerLayerWeights {
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
        let prefix = "talker.model.layers.\(layerIndex)"
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
