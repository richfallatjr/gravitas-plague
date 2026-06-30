import Foundation
import MLX

struct TuringQwenNativeFirstCodecToken: Sendable {
    let tokenID: Int
    let expectedFixtureTokenID: Int

    var matchesFixture: Bool {
        tokenID == expectedFixtureTokenID
    }
}

enum TuringQwenNativeCodecSampler {
    static let expectedFirstFixtureTokenID = 1221

    static func selectFirstCodecToken(
        logits: MLXArray,
        sequenceLength: Int,
        vocabSize: Int
    ) throws -> TuringQwenNativeFirstCodecToken {
        return TuringQwenNativeFirstCodecToken(
            tokenID: try selectCodecToken(
                logits: logits,
                sequenceLength: sequenceLength,
                vocabSize: vocabSize
            ),
            expectedFixtureTokenID: expectedFirstFixtureTokenID
        )
    }

    static func selectCodecToken(
        logits: MLXArray,
        sequenceLength: Int,
        vocabSize: Int
    ) throws -> Int {
        _ = sequenceLength

        guard logits.shape == [1, 1, vocabSize] else {
            throw TuringQwenNativeError.invalidConfig(
                "Expected final-position talker logits shape [1, 1, \(vocabSize)], got \(logits.shape)."
            )
        }

        return logits[0, 0]
            .argMax()
            .item(Int.self)
    }
}
