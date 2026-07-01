import Foundation
import MLX

struct TuringQwenNativeRotaryCachePair: @unchecked Sendable {
    let cos: MLXArray
    let sin: MLXArray
}

struct TuringQwenNativeSegmentRuntimeCache: @unchecked Sendable {
    let talkerOneStepRopes: [Int: TuringQwenNativeRotaryCachePair]
    let codePredictorPrefillRope: TuringQwenNativeRotaryCachePair
    let codePredictorPrefillMask: MLXArray
    let codePredictorOneStepRopes: [Int: TuringQwenNativeRotaryCachePair]
    let talkerTrailingTextEmbeds: [MLXArray]

    init(
        config: TuringQwenNativeConfig,
        promptSequenceLength: Int,
        maxNewRows: Int,
        trailingTextHidden: MLXArray,
        ttsPadEmbed: MLXArray
    ) {
        let rowBudget = max(maxNewRows, 1)
        let talkerPositions = Array(promptSequenceLength..<(promptSequenceLength + rowBudget))
        self.talkerOneStepRopes = Dictionary(
            uniqueKeysWithValues: talkerPositions.map { position in
                (
                    position,
                    Self.rotaryPair(
                        positions: [position],
                        headDim: config.talkerConfig.headDim,
                        theta: config.talkerConfig.ropeTheta
                    )
                )
            }
        )
        self.talkerTrailingTextEmbeds = (0..<rowBudget).map { generationStep in
            if generationStep < trailingTextHidden.dim(1) {
                return trailingTextHidden[
                    generationStep..<(generationStep + 1),
                    axis: 1
                ]
            }
            return ttsPadEmbed
        }

        let codePredictorConfig = config.talkerConfig.codePredictorConfig
        let codePredictorHeadDim = codePredictorConfig.headDim ?? 128
        let codePredictorTheta = codePredictorConfig.ropeTheta ?? config.talkerConfig.ropeTheta
        let codePredictorGroups = codePredictorConfig.numCodeGroups ?? config.talkerConfig.numCodeGroups

        self.codePredictorPrefillRope = Self.rotaryPair(
            positions: [0, 1],
            headDim: codePredictorHeadDim,
            theta: codePredictorTheta
        )
        self.codePredictorPrefillMask = Self.causalMask(sequenceLength: 2)
        self.codePredictorOneStepRopes = Dictionary(
            uniqueKeysWithValues: Array(2..<max(codePredictorGroups, 2)).map { position in
                (
                    position,
                    Self.rotaryPair(
                        positions: [position],
                        headDim: codePredictorHeadDim,
                        theta: codePredictorTheta
                    )
                )
            }
        )
    }

    func talkerRope(position: Int) -> (cos: MLXArray, sin: MLXArray)? {
        guard let pair = talkerOneStepRopes[position] else {
            return nil
        }
        return (pair.cos, pair.sin)
    }

    func codePredictorRope(position: Int) -> (cos: MLXArray, sin: MLXArray)? {
        guard let pair = codePredictorOneStepRopes[position] else {
            return nil
        }
        return (pair.cos, pair.sin)
    }

    func talkerTrailingTextEmbed(generationStep: Int) -> MLXArray? {
        guard talkerTrailingTextEmbeds.indices.contains(generationStep) else {
            return nil
        }
        return talkerTrailingTextEmbeds[generationStep]
    }

    private static func rotaryPair(
        positions: [Int],
        headDim: Int,
        theta: Double
    ) -> TuringQwenNativeRotaryCachePair {
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

        return TuringQwenNativeRotaryCachePair(
            cos: MLXArray(cosValues, [1, 1, positions.count, headDim]),
            sin: MLXArray(sinValues, [1, 1, positions.count, headDim])
        )
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
}
