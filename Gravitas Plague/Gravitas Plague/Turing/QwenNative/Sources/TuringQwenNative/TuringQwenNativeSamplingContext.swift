import Foundation
import MLX

public enum TuringQwenNativeSamplingSeed {
  public static func make(
    voiceID: String,
    runID: String,
    segmentIndex: Int
  ) -> UInt64 {
    let input =
      "\(voiceID)|\(runID)|\(segmentIndex)"

    var hash: UInt64 =
      14_695_981_039_346_656_037
    let prime: UInt64 =
      1_099_511_628_211

    for byte in input.utf8 {
      hash ^= UInt64(byte)
      hash &*= prime
    }

    return hash == 0
      ? 0x9E37_79B9_7F4A_7C15
      : hash
  }
}

struct TuringQwenNativeSplitMix64 {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func nextUInt64() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15

    var value = state
    value =
      (value ^ (value >> 30))
      &* 0xBF58_476D_1CE4_E5B9
    value =
      (value ^ (value >> 27))
      &* 0x94D0_49BB_1331_11EB
    return value ^ (value >> 31)
  }

  mutating func nextUnitInterval()
    -> Double
  {
    // The high 53 bits map exactly into a Double mantissa.
    Double(nextUInt64() >> 11)
      * (1.0 / 9_007_199_254_740_992.0)
  }
}

/// Request-local sampling state.
///
/// One instance exists per generated segment. It is never global, shared,
/// pooled, or sent across Fresh2 workers.
struct TuringQwenNativeSamplingContext {
  private var talkerRandom: TuringQwenNativeSplitMix64
  private var codePredictorRandom: TuringQwenNativeSplitMix64

  private(set) var firstCodecHistory: [Int] = []
  private var residualHistoryByCodebook: [Int: [Int]] = [:]

  init(seed: UInt64) {
    talkerRandom =
      TuringQwenNativeSplitMix64(
        seed:
          seed
          ^ 0xA076_1D64_78BD_642F
      )
    codePredictorRandom =
      TuringQwenNativeSplitMix64(
        seed:
          seed
          ^ 0xE703_7ED1_A0B4_28DB
      )
  }

  mutating func selectTalkerToken(
    logits: MLXArray,
    configuration:
      TuringQwenNativeTokenSamplerConfiguration,
    vocabSize: Int
  ) throws -> TuringQwenNativeSampledToken {
    let randomDraw: Double?

    switch configuration.mode {
    case .greedy:
      randomDraw = nil
    case .temperatureTopP:
      randomDraw =
        talkerRandom.nextUnitInterval()
    }

    let token =
      try TuringQwenNativeSampler.select(
        logits: logits,
        configuration:
          configuration,
        generatedTokenHistory:
          firstCodecHistory,
        randomDraw: randomDraw,
        needHostTokenID: true,
        vocabSize: vocabSize
      )

    if let tokenID =
      token.tokenIDForStopCheck
    {
      firstCodecHistory.append(tokenID)
    }

    return token
  }

  mutating func selectCodePredictorToken(
    logits: MLXArray,
    configuration:
      TuringQwenNativeTokenSamplerConfiguration,
    residualCodebookIndex: Int,
    vocabSize: Int
  ) throws -> TuringQwenNativeSampledToken {
    let history =
      residualHistoryByCodebook[
        residualCodebookIndex
      ] ?? []

    let randomDraw: Double?

    switch configuration.mode {
    case .greedy:
      randomDraw = nil
    case .temperatureTopP:
      randomDraw =
        codePredictorRandom
        .nextUnitInterval()
    }

    let token =
      try TuringQwenNativeSampler.select(
        logits: logits,
        configuration:
          configuration,
        generatedTokenHistory:
          history,
        randomDraw: randomDraw,
        // Greedy residual decoding keeps the existing no-host-sync
        // path. Sampled residual decoding necessarily returns a host
        // token because the host owns the random decision.
        needHostTokenID:
          configuration.mode != .greedy,
        vocabSize: vocabSize
      )

    if let tokenID =
      token.tokenIDForStopCheck
    {
      residualHistoryByCodebook[
        residualCodebookIndex,
        default: []
      ].append(tokenID)
    }

    return token
  }
}
