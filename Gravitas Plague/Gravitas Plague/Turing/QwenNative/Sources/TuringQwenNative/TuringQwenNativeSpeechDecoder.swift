import Foundation
import MLX

struct TuringQwenNativeSpeechTokenizerConfig: Decodable, Sendable {
    let decoderConfig: DecoderConfig
    let decodeUpsampleRate: Int
    let outputSampleRate: Int
    let encoderValidNumQuantizers: Int

    enum CodingKeys: String, CodingKey {
        case decoderConfig = "decoder_config"
        case decodeUpsampleRate = "decode_upsample_rate"
        case outputSampleRate = "output_sample_rate"
        case encoderValidNumQuantizers = "encoder_valid_num_quantizers"
    }

    struct DecoderConfig: Decodable, Sendable {
        let codebookSize: Int
        let hiddenSize: Int
        let latentDim: Int
        let maxPositionEmbeddings: Int
        let ropeTheta: Double
        let numAttentionHeads: Int
        let numKeyValueHeads: Int
        let attentionBias: Bool
        let slidingWindow: Int
        let intermediateSize: Int
        let hiddenAct: String
        let layerScaleInitialScale: Double
        let rmsNormEps: Double
        let numHiddenLayers: Int
        let numQuantizers: Int
        let upsampleRates: [Int]
        let upsamplingRatios: [Int]
        let decoderDim: Int
        let attentionDropout: Double
        let headDim: Int
        let codebookDim: Int

        enum CodingKeys: String, CodingKey {
            case codebookSize = "codebook_size"
            case hiddenSize = "hidden_size"
            case latentDim = "latent_dim"
            case maxPositionEmbeddings = "max_position_embeddings"
            case ropeTheta = "rope_theta"
            case numAttentionHeads = "num_attention_heads"
            case numKeyValueHeads = "num_key_value_heads"
            case attentionBias = "attention_bias"
            case slidingWindow = "sliding_window"
            case intermediateSize = "intermediate_size"
            case hiddenAct = "hidden_act"
            case layerScaleInitialScale = "layer_scale_initial_scale"
            case rmsNormEps = "rms_norm_eps"
            case numHiddenLayers = "num_hidden_layers"
            case numQuantizers = "num_quantizers"
            case upsampleRates = "upsample_rates"
            case upsamplingRatios = "upsampling_ratios"
            case decoderDim = "decoder_dim"
            case attentionDropout = "attention_dropout"
            case headDim = "head_dim"
            case codebookDim = "codebook_dim"
        }
    }

    static func load(from modelRoot: URL) throws -> TuringQwenNativeSpeechTokenizerConfig {
        let url = modelRoot
            .appendingPathComponent("speech_tokenizer")
            .appendingPathComponent("config.json")
        let config = try JSONDecoder().decode(
            TuringQwenNativeSpeechTokenizerConfig.self,
            from: try Data(contentsOf: url)
        )

        guard config.decoderConfig.numQuantizers == 16 else {
            throw TuringQwenNativeError.invalidConfig(
                "Expected 16 speech tokenizer quantizers, got \(config.decoderConfig.numQuantizers)."
            )
        }
        guard config.outputSampleRate == 24_000 else {
            throw TuringQwenNativeError.invalidConfig(
                "Expected 24 kHz speech tokenizer output, got \(config.outputSampleRate)."
            )
        }

        return config
    }
}

enum TuringQwenNativeSpeechDecoder {
    static func decode(
        codebookRows: [[Int]],
        modelRoot: URL,
        performanceMode: TuringQwenNativePerformanceMode = .diagnostic
    ) throws -> TuringQwenNativeAudio {
        let config = try TuringQwenNativeSpeechTokenizerConfig.load(from: modelRoot)
        let tensorIndex = try TuringQwenNativeSafetensorsIndex.load(
            from: modelRoot
                .appendingPathComponent("speech_tokenizer")
                .appendingPathComponent("model.safetensors")
        )
        let reader = TuringQwenNativeSafetensorsReader(index: tensorIndex)

        guard codebookRows.isEmpty == false else {
            throw TuringQwenNativeError.emptyAudio
        }
        guard codebookRows.allSatisfy({ $0.count == config.decoderConfig.numQuantizers }) else {
            throw TuringQwenNativeError.invalidConfig(
                "Speech decoder expected [T, \(config.decoderConfig.numQuantizers)] codebook rows, got \(codebookRows.map { $0.count })."
            )
        }

        let start = Date()
        var hidden = try quantizerDecode(
            codebookRows: codebookRows,
            config: config.decoderConfig,
            reader: reader
        )
        materializeIfNeeded(hidden, label: "speechDecoder.quantizerDecode", performanceMode: performanceMode)

        hidden = try causalConv1d(
            hidden,
            weightName: "decoder.pre_conv.conv.weight",
            biasName: "decoder.pre_conv.conv.bias",
            kernelSize: 3,
            reader: reader
        )
        materializeIfNeeded(hidden, label: "speechDecoder.preConv", performanceMode: performanceMode)

        hidden = try runPreTransformer(
            hidden,
            config: config.decoderConfig,
            reader: reader,
            performanceMode: performanceMode
        )
        materializeIfNeeded(hidden, label: "speechDecoder.preTransformer", performanceMode: performanceMode)

        for upsampleIndex in 0..<config.decoderConfig.upsamplingRatios.count {
            let ratio = config.decoderConfig.upsamplingRatios[upsampleIndex]
            hidden = try causalTransposedConv1d(
                hidden,
                weightName: "decoder.upsample.\(upsampleIndex).0.conv.weight",
                biasName: "decoder.upsample.\(upsampleIndex).0.conv.bias",
                kernelSize: ratio,
                stride: ratio,
                rightCrop: ratio - ratio,
                reader: reader
            )
            hidden = try convNeXtBlock(
                hidden,
                prefix: "decoder.upsample.\(upsampleIndex).1",
                reader: reader
            )
            materializeIfNeeded(hidden, label: "speechDecoder.upsample.\(upsampleIndex)", performanceMode: performanceMode)
        }

        hidden = try causalConv1d(
            hidden,
            weightName: "decoder.decoder.0.conv.weight",
            biasName: "decoder.decoder.0.conv.bias",
            kernelSize: 7,
            reader: reader
        )
        materializeIfNeeded(hidden, label: "speechDecoder.decoder.0", performanceMode: performanceMode)

        for blockIndex in 0..<config.decoderConfig.upsampleRates.count {
            hidden = try decoderBlock(
                hidden,
                blockIndex: blockIndex + 1,
                upsampleRate: config.decoderConfig.upsampleRates[blockIndex],
                reader: reader
            )
            materializeIfNeeded(hidden, label: "speechDecoder.decoder.\(blockIndex + 1)", performanceMode: performanceMode)
        }

        hidden = try snakeBeta(
            hidden,
            alphaName: "decoder.decoder.5.alpha",
            betaName: "decoder.decoder.5.beta",
            reader: reader
        )
        hidden = try causalConv1d(
            hidden,
            weightName: "decoder.decoder.6.conv.weight",
            biasName: "decoder.decoder.6.conv.bias",
            kernelSize: 7,
            reader: reader
        )
        let clipped = clip(hidden, min: -1.0, max: 1.0)
        eval(clipped)
        if performanceMode.shouldClearMLXCacheEveryRow {
            TuringQwenNativeMemoryControl.clearCache(label: "speechDecoder.output")
        }

        let expectedSampleCount = codebookRows.count * config.decodeUpsampleRate
        let samples = Array(
            clipped.reshaped([clipped.size]).asArray(Float.self)
                .prefix(expectedSampleCount)
        )

        print("""
        [TuringQwenNative] speech decoder completed
          codebookShape: [\(codebookRows.count), \(config.decoderConfig.numQuantizers)]
          sampleCount: \(samples.count)
          expectedSampleCount: \(expectedSampleCount)
          sampleRate: \(config.outputSampleRate)
          seconds: \(String(format: "%.3f", Date().timeIntervalSince(start)))
        """)

        guard samples.isEmpty == false else {
            throw TuringQwenNativeError.emptyAudio
        }

        return TuringQwenNativeAudio(
            samples: samples,
            sampleRate: config.outputSampleRate
        )
    }

    private static func quantizerDecode(
        codebookRows: [[Int]],
        config: TuringQwenNativeSpeechTokenizerConfig.DecoderConfig,
        reader: TuringQwenNativeSafetensorsReader
    ) throws -> MLXArray {
        let semantic = try residualQuantizerDecode(
            codebookRows: codebookRows,
            tokenOffset: 0,
            quantizerCount: 1,
            prefix: "decoder.quantizer.rvq_first",
            config: config,
            reader: reader
        )
        let acoustic = try residualQuantizerDecode(
            codebookRows: codebookRows,
            tokenOffset: 1,
            quantizerCount: config.numQuantizers - 1,
            prefix: "decoder.quantizer.rvq_rest",
            config: config,
            reader: reader
        )

        return semantic + acoustic
    }

    private static func residualQuantizerDecode(
        codebookRows: [[Int]],
        tokenOffset: Int,
        quantizerCount: Int,
        prefix: String,
        config: TuringQwenNativeSpeechTokenizerConfig.DecoderConfig,
        reader: TuringQwenNativeSafetensorsReader
    ) throws -> MLXArray {
        var quantized: MLXArray?
        for quantizerIndex in 0..<quantizerCount {
            let tokenIDs = codebookRows.map { $0[tokenOffset + quantizerIndex] }
            let embeddingSum = try reader.loadRowsFloat32(
                name: "\(prefix).vq.layers.\(quantizerIndex)._codebook.embedding_sum",
                rows: tokenIDs
            ).mlxArray()
            let clusterUsage = try reader.loadTensorFloat32(
                name: "\(prefix).vq.layers.\(quantizerIndex)._codebook.cluster_usage"
            )
            .mlxArray()
            .take(MLXArray(tokenIDs), axis: 0)
            .reshaped([tokenIDs.count, 1])
            let decoded = embeddingSum / maximum(clusterUsage, MLXArray(1e-5))
            quantized = quantized.map { $0 + decoded } ?? decoded
        }

        guard let quantized else {
            throw TuringQwenNativeError.invalidConfig("Residual quantizer \(prefix) produced no tensors.")
        }

        let outputProjection = try reader.loadTensorFloat32(
            name: "\(prefix).output_proj.weight"
        ).mlxArray()
        let projectionInput = quantized.reshaped([
            1,
            quantized.dim(0),
            quantized.dim(1)
        ])
        return conv1d(
            projectionInput,
            conv1dWeightFromPyTorch(outputProjection)
        )
    }

    private static func runPreTransformer(
        _ input: MLXArray,
        config: TuringQwenNativeSpeechTokenizerConfig.DecoderConfig,
        reader: TuringQwenNativeSafetensorsReader,
        performanceMode: TuringQwenNativePerformanceMode
    ) throws -> MLXArray {
        var hidden = linear(
            input,
            weight: try reader.loadTensorFloat32(
                name: "decoder.pre_transformer.input_proj.weight"
            ).mlxArray(),
            bias: try reader.loadTensorFloat32(
                name: "decoder.pre_transformer.input_proj.bias"
            ).mlxArray()
        )

        for layerIndex in 0..<config.numHiddenLayers {
            hidden = try runTransformerLayer(
                hidden,
                prefix: "decoder.pre_transformer.layers.\(layerIndex)",
                config: config,
                reader: reader
            )
            materializeIfNeeded(
                hidden,
                label: "speechDecoder.preTransformer.layer.\(layerIndex)",
                performanceMode: performanceMode
            )
        }

        hidden = rmsNorm(
            hidden,
            weight: try reader.loadTensorFloat32(
                name: "decoder.pre_transformer.norm.weight"
            ).mlxArray(),
            eps: Float(config.rmsNormEps)
        )

        return linear(
            hidden,
            weight: try reader.loadTensorFloat32(
                name: "decoder.pre_transformer.output_proj.weight"
            ).mlxArray(),
            bias: try reader.loadTensorFloat32(
                name: "decoder.pre_transformer.output_proj.bias"
            ).mlxArray()
        )
    }

    private static func materializeIfNeeded(
        _ value: MLXArray,
        label: String,
        performanceMode: TuringQwenNativePerformanceMode
    ) {
        guard performanceMode.shouldForceEveryEval else {
            return
        }
        eval(value)
        if performanceMode.shouldClearMLXCacheEveryRow {
            TuringQwenNativeMemoryControl.clearCache(label: label)
        }
    }

    private static func runTransformerLayer(
        _ hiddenStates: MLXArray,
        prefix: String,
        config: TuringQwenNativeSpeechTokenizerConfig.DecoderConfig,
        reader: TuringQwenNativeSafetensorsReader
    ) throws -> MLXArray {
        let residual = hiddenStates
        let normalized = rmsNorm(
            hiddenStates,
            weight: try reader.loadTensorFloat32(
                name: "\(prefix).input_layernorm.weight"
            ).mlxArray(),
            eps: Float(config.rmsNormEps)
        )
        let attention = try selfAttention(
            normalized,
            prefix: "\(prefix).self_attn",
            config: config,
            reader: reader
        )
        let attentionScale = try reader.loadTensorFloat32(
            name: "\(prefix).self_attn_layer_scale.scale"
        ).mlxArray()
        let afterAttention = residual + attention * attentionScale

        let mlpResidual = afterAttention
        let mlpInput = rmsNorm(
            afterAttention,
            weight: try reader.loadTensorFloat32(
                name: "\(prefix).post_attention_layernorm.weight"
            ).mlxArray(),
            eps: Float(config.rmsNormEps)
        )
        let gate = linear(
            mlpInput,
            weight: try reader.loadTensorFloat32(
                name: "\(prefix).mlp.gate_proj.weight"
            ).mlxArray()
        )
        let up = linear(
            mlpInput,
            weight: try reader.loadTensorFloat32(
                name: "\(prefix).mlp.up_proj.weight"
            ).mlxArray()
        )
        let mlp = linear(
            silu(gate) * up,
            weight: try reader.loadTensorFloat32(
                name: "\(prefix).mlp.down_proj.weight"
            ).mlxArray()
        )
        let mlpScale = try reader.loadTensorFloat32(
            name: "\(prefix).mlp_layer_scale.scale"
        ).mlxArray()

        return mlpResidual + mlp * mlpScale
    }

    private static func selfAttention(
        _ hiddenStates: MLXArray,
        prefix: String,
        config: TuringQwenNativeSpeechTokenizerConfig.DecoderConfig,
        reader: TuringQwenNativeSafetensorsReader
    ) throws -> MLXArray {
        let sequenceLength = hiddenStates.dim(1)
        let headDim = config.headDim
        let query = linear(
            hiddenStates,
            weight: try reader.loadTensorFloat32(name: "\(prefix).q_proj.weight").mlxArray()
        )
        .reshaped([1, sequenceLength, config.numAttentionHeads, headDim])
        let key = linear(
            hiddenStates,
            weight: try reader.loadTensorFloat32(name: "\(prefix).k_proj.weight").mlxArray()
        )
        .reshaped([1, sequenceLength, config.numKeyValueHeads, headDim])
        let value = linear(
            hiddenStates,
            weight: try reader.loadTensorFloat32(name: "\(prefix).v_proj.weight").mlxArray()
        )
        .reshaped([1, sequenceLength, config.numKeyValueHeads, headDim])

        var queryStates = query.transposed(0, 2, 1, 3)
        var keyStates = key.transposed(0, 2, 1, 3)
        let valueStates = value.transposed(0, 2, 1, 3)

        let rope = rotaryEmbeddings(
            sequenceLength: sequenceLength,
            headDim: headDim,
            theta: config.ropeTheta
        )
        queryStates = applyRotary(queryStates, cos: rope.cos, sin: rope.sin)
        keyStates = applyRotary(keyStates, cos: rope.cos, sin: rope.sin)

        let scale = Float(1.0 / sqrt(Double(headDim)))
        let attentionMask = causalMask(sequenceLength: sequenceLength)
        let scores = matmul(queryStates, keyStates.transposed(0, 1, 3, 2)) * scale + attentionMask
        let probabilities = softmax(scores, axis: -1, precise: true)
        let attended = matmul(probabilities, valueStates)
            .transposed(0, 2, 1, 3)
            .reshaped([1, sequenceLength, config.numAttentionHeads * headDim])

        return linear(
            attended,
            weight: try reader.loadTensorFloat32(name: "\(prefix).o_proj.weight").mlxArray()
        )
    }

    private static func convNeXtBlock(
        _ input: MLXArray,
        prefix: String,
        reader: TuringQwenNativeSafetensorsReader
    ) throws -> MLXArray {
        let residual = input
        var hidden = try depthwiseCausalConv1d(
            input,
            weightName: "\(prefix).dwconv.conv.weight",
            biasName: "\(prefix).dwconv.conv.bias",
            kernelSize: 7,
            reader: reader
        )
        hidden = layerNorm(
            hidden,
            weight: try reader.loadTensorFloat32(name: "\(prefix).norm.weight").mlxArray(),
            bias: try reader.loadTensorFloat32(name: "\(prefix).norm.bias").mlxArray(),
            eps: 1e-6
        )
        hidden = linear(
            hidden,
            weight: try reader.loadTensorFloat32(name: "\(prefix).pwconv1.weight").mlxArray(),
            bias: try reader.loadTensorFloat32(name: "\(prefix).pwconv1.bias").mlxArray()
        )
        hidden = geluExact(hidden)
        hidden = linear(
            hidden,
            weight: try reader.loadTensorFloat32(name: "\(prefix).pwconv2.weight").mlxArray(),
            bias: try reader.loadTensorFloat32(name: "\(prefix).pwconv2.bias").mlxArray()
        )
        let gamma = try reader.loadTensorFloat32(name: "\(prefix).gamma").mlxArray()
        hidden = hidden * gamma

        return residual + hidden
    }

    private static func decoderBlock(
        _ input: MLXArray,
        blockIndex: Int,
        upsampleRate: Int,
        reader: TuringQwenNativeSafetensorsReader
    ) throws -> MLXArray {
        var hidden = try snakeBeta(
            input,
            alphaName: "decoder.decoder.\(blockIndex).block.0.alpha",
            betaName: "decoder.decoder.\(blockIndex).block.0.beta",
            reader: reader
        )
        hidden = try causalTransposedConv1d(
            hidden,
            weightName: "decoder.decoder.\(blockIndex).block.1.conv.weight",
            biasName: "decoder.decoder.\(blockIndex).block.1.conv.bias",
            kernelSize: 2 * upsampleRate,
            stride: upsampleRate,
            rightCrop: upsampleRate,
            reader: reader
        )

        for residualUnit in 2...4 {
            hidden = try decoderResidualUnit(
                hidden,
                prefix: "decoder.decoder.\(blockIndex).block.\(residualUnit)",
                dilation: [1, 3, 9][residualUnit - 2],
                reader: reader
            )
        }

        return hidden
    }

    private static func decoderResidualUnit(
        _ input: MLXArray,
        prefix: String,
        dilation: Int,
        reader: TuringQwenNativeSafetensorsReader
    ) throws -> MLXArray {
        let residual = input
        var hidden = try snakeBeta(
            input,
            alphaName: "\(prefix).act1.alpha",
            betaName: "\(prefix).act1.beta",
            reader: reader
        )
        hidden = try causalConv1d(
            hidden,
            weightName: "\(prefix).conv1.conv.weight",
            biasName: "\(prefix).conv1.conv.bias",
            kernelSize: 7,
            dilation: dilation,
            reader: reader
        )
        hidden = try snakeBeta(
            hidden,
            alphaName: "\(prefix).act2.alpha",
            betaName: "\(prefix).act2.beta",
            reader: reader
        )
        hidden = try causalConv1d(
            hidden,
            weightName: "\(prefix).conv2.conv.weight",
            biasName: "\(prefix).conv2.conv.bias",
            kernelSize: 1,
            reader: reader
        )

        return residual + hidden
    }

    private static func snakeBeta(
        _ input: MLXArray,
        alphaName: String,
        betaName: String,
        reader: TuringQwenNativeSafetensorsReader
    ) throws -> MLXArray {
        let alpha = exp(
            try reader.loadTensorFloat32(name: alphaName).mlxArray()
        )
        .reshaped([1, 1, input.dim(-1)])
        let beta = exp(
            try reader.loadTensorFloat32(name: betaName).mlxArray()
        )
        .reshaped([1, 1, input.dim(-1)])
        let sine = sin(input * alpha)
        return input + (sine * sine) / (beta + 0.000000001)
    }

    private static func causalConv1d(
        _ input: MLXArray,
        weightName: String,
        biasName: String,
        kernelSize: Int,
        stride: Int = 1,
        dilation: Int = 1,
        reader: TuringQwenNativeSafetensorsReader
    ) throws -> MLXArray {
        let weight = conv1dWeightFromPyTorch(
            try reader.loadTensorFloat32(name: weightName).mlxArray()
        )
        let bias = try reader.loadTensorFloat32(name: biasName).mlxArray()
        let effectiveKernel = (kernelSize - 1) * dilation + 1
        let leftPadding = effectiveKernel - stride
        let paddedInput = padded(
            input,
            widths: [
                IntOrPair((0, 0)),
                IntOrPair((leftPadding, 0)),
                IntOrPair((0, 0))
            ]
        )
        return conv1d(
            paddedInput,
            weight,
            stride: stride,
            padding: 0,
            dilation: dilation
        ) + bias
    }

    private static func depthwiseCausalConv1d(
        _ input: MLXArray,
        weightName: String,
        biasName: String,
        kernelSize: Int,
        reader: TuringQwenNativeSafetensorsReader
    ) throws -> MLXArray {
        let weight = try reader.loadTensorFloat32(name: weightName).mlxArray()
        let bias = try reader.loadTensorFloat32(name: biasName).mlxArray()
        let paddedInput = padded(
            input,
            widths: [
                IntOrPair((0, 0)),
                IntOrPair((kernelSize - 1, 0)),
                IntOrPair((0, 0))
            ]
        )
        var output: MLXArray?
        for offset in 0..<kernelSize {
            let inputSlice = paddedInput[offset..<(offset + input.dim(1)), axis: 1]
            let kernelSlice = weight[
                offset..<(offset + 1),
                axis: 2
            ]
            .reshaped([1, 1, input.dim(-1)])
            output = output.map { $0 + inputSlice * kernelSlice } ?? inputSlice * kernelSlice
        }

        return (output ?? input) + bias.reshaped([1, 1, input.dim(-1)])
    }

    private static func causalTransposedConv1d(
        _ input: MLXArray,
        weightName: String,
        biasName: String,
        kernelSize: Int,
        stride: Int,
        rightCrop: Int,
        reader: TuringQwenNativeSafetensorsReader
    ) throws -> MLXArray {
        let weight = convTransposed1dWeightFromPyTorch(
            try reader.loadTensorFloat32(name: weightName).mlxArray()
        )
        let bias = try reader.loadTensorFloat32(name: biasName).mlxArray()
        var output = convTransposed1d(
            input,
            weight,
            stride: stride,
            padding: 0,
            dilation: 1,
            outputPadding: 0
        ) + bias

        if rightCrop > 0 {
            output = output[..<(output.dim(1) - rightCrop), axis: 1]
        }

        return output
    }

    private static func conv1dWeightFromPyTorch(
        _ weight: MLXArray
    ) -> MLXArray {
        weight.transposed(0, 2, 1)
    }

    private static func convTransposed1dWeightFromPyTorch(
        _ weight: MLXArray
    ) -> MLXArray {
        weight.transposed(1, 2, 0)
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

    private static func rmsNorm(
        _ value: MLXArray,
        weight: MLXArray,
        eps: Float
    ) -> MLXArray {
        let variance = (value * value).mean(axis: -1, keepDims: true)
        return value / sqrt(variance + eps) * weight
    }

    private static func layerNorm(
        _ value: MLXArray,
        weight: MLXArray,
        bias: MLXArray,
        eps: Float
    ) -> MLXArray {
        let mean = value.mean(axis: -1, keepDims: true)
        let variance = ((value - mean) * (value - mean)).mean(axis: -1, keepDims: true)
        return (value - mean) / sqrt(variance + eps) * weight + bias
    }

    private static func geluExact(
        _ value: MLXArray
    ) -> MLXArray {
        value * 0.5 * (1.0 + erf(value / Float(sqrt(2.0))))
    }

    private static func silu(
        _ value: MLXArray
    ) -> MLXArray {
        value * sigmoid(value)
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
}
