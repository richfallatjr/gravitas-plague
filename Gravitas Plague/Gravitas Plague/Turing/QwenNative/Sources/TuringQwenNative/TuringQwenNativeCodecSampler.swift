import Foundation
import MLX

struct TuringQwenNativeFirstCodecToken:
  Sendable
{
  let tokenID: Int
  let expectedFixtureTokenID: Int

  var matchesFixture: Bool {
    tokenID == expectedFixtureTokenID
  }
}

enum TuringQwenNativeCodecSampler {
  static let expectedFirstFixtureTokenID =
    1221

  /// Compatibility/fixture path. Production character generation uses the
  /// policy-aware overload below.
  static func selectFirstCodecToken(
    logits: MLXArray,
    sequenceLength: Int,
    vocabSize: Int
  ) throws -> TuringQwenNativeFirstCodecToken {
    var context =
      TuringQwenNativeSamplingContext(
        seed:
          0x9E37_79B9_7F4A_7C15
      )

    return try selectFirstCodecToken(
      logits: logits,
      sequenceLength:
        sequenceLength,
      vocabSize: vocabSize,
      samplingConfiguration:
        .greedy,
      samplingContext: &context
    )
  }

  static func selectFirstCodecToken(
    logits: MLXArray,
    sequenceLength: Int,
    vocabSize: Int,
    samplingConfiguration:
      TuringQwenNativeTokenSamplerConfiguration,
    samplingContext:
      inout TuringQwenNativeSamplingContext
  ) throws -> TuringQwenNativeFirstCodecToken {
    _ = sequenceLength

    guard logits.shape == [1, 1, vocabSize] else {
      throw
        TuringQwenNativeError
        .invalidConfig(
          "Expected final-position talker logits shape [1, 1, \(vocabSize)], got \(logits.shape)."
        )
    }

    let sampled =
      try samplingContext
      .selectTalkerToken(
        logits: logits,
        configuration:
          samplingConfiguration,
        vocabSize: vocabSize
      )

    guard
      let tokenID =
        sampled
        .tokenIDForStopCheck
    else {
      throw
        TuringQwenNativeError
        .invalidConfig(
          "Talker token sampling did not materialize an EOS-checkable token ID."
        )
    }

    print(
      """
      [TuringQwenNativeSampler] talker token selected
        tokenID: \(tokenID)
        mode: \(samplingConfiguration.mode.rawValue)
        backend: \(samplingConfiguration.backend.rawValue)
        candidateCount: \(sampled.candidateCount)
        materializationSeconds: \(String(format: "%.6f", sampled.materializationSeconds))
        hostSelectionSeconds: \(String(format: "%.6f", sampled.hostSelectionSeconds))
      """)

    return TuringQwenNativeFirstCodecToken(
      tokenID: tokenID,
      expectedFixtureTokenID:
        expectedFirstFixtureTokenID
    )
  }

  static func selectCodecToken(
    logits: MLXArray,
    sequenceLength: Int,
    vocabSize: Int
  ) throws -> Int {
    try selectFirstCodecToken(
      logits: logits,
      sequenceLength:
        sequenceLength,
      vocabSize: vocabSize
    ).tokenID
  }
}
