import Foundation

public enum TuringQwenNativeTokenSamplingMode:
  String,
  Codable,
  Sendable,
  Hashable
{
  case greedy
  case temperatureTopP
}

public enum TuringQwenNativeSamplingBackend:
  String,
  Codable,
  Sendable,
  Hashable
{
  /// Materialize one logits vector, select a bounded top-k candidate set on
  /// the host, and sample with a request-local deterministic PRNG.
  ///
  /// This backend deliberately creates no MLX random graph and no
  /// full-vocabulary -infinity mask.
  case materializedHostTopK
}

public struct TuringQwenNativeTokenSamplerConfiguration:
  Codable,
  Sendable,
  Hashable
{
  public let mode: TuringQwenNativeTokenSamplingMode
  public let backend: TuringQwenNativeSamplingBackend
  public let temperature: Float
  public let topK: Int
  public let topP: Float
  public let repetitionPenalty: Float

  public init(
    mode: TuringQwenNativeTokenSamplingMode,
    backend: TuringQwenNativeSamplingBackend = .materializedHostTopK,
    temperature: Float,
    topK: Int,
    topP: Float,
    repetitionPenalty: Float
  ) {
    self.mode = mode
    self.backend = backend
    self.temperature = temperature
    self.topK = topK
    self.topP = topP
    self.repetitionPenalty = repetitionPenalty
  }

  public static let greedy =
    TuringQwenNativeTokenSamplerConfiguration(
      mode: .greedy,
      temperature: 1,
      topK: 1,
      topP: 1,
      repetitionPenalty: 1
    )

  public static let qwenDefaultTalker =
    TuringQwenNativeTokenSamplerConfiguration(
      mode: .temperatureTopP,
      temperature: 0.9,
      topK: 50,
      topP: 1,
      repetitionPenalty: 1.05
    )

  public static let qwenDefaultCodePredictor =
    TuringQwenNativeTokenSamplerConfiguration(
      mode: .temperatureTopP,
      temperature: 0.9,
      topK: 50,
      topP: 1,
      repetitionPenalty: 1
    )

  public func validate(
    stage: String
  ) throws {
    switch mode {
    case .greedy:
      return

    case .temperatureTopP:
      guard temperature.isFinite,
        temperature > 0
      else {
        throw
          TuringQwenNativeSamplingError
          .invalidConfiguration(
            "\(stage) temperature must be finite and greater than zero."
          )
      }

      // A bounded top-k is mandatory for sampled production decoding.
      // topK=0 would make the host transfer and candidate set unbounded.
      guard (1...256).contains(topK) else {
        throw
          TuringQwenNativeSamplingError
          .invalidConfiguration(
            "\(stage) topK must be in 1...256."
          )
      }

      guard topP.isFinite,
        topP > 0,
        topP <= 1
      else {
        throw
          TuringQwenNativeSamplingError
          .invalidConfiguration(
            "\(stage) topP must be in (0, 1]."
          )
      }

      guard repetitionPenalty.isFinite,
        repetitionPenalty >= 1
      else {
        throw
          TuringQwenNativeSamplingError
          .invalidConfiguration(
            "\(stage) repetitionPenalty must be at least 1."
          )
      }
    }
  }
}

public struct TuringQwenNativeSamplingPolicy:
  Codable,
  Sendable,
  Hashable
{
  public let talker: TuringQwenNativeTokenSamplerConfiguration
  public let codePredictor: TuringQwenNativeTokenSamplerConfiguration

  public init(
    talker:
      TuringQwenNativeTokenSamplerConfiguration,
    codePredictor:
      TuringQwenNativeTokenSamplerConfiguration
  ) {
    self.talker = talker
    self.codePredictor = codePredictor
  }

  public static let greedy =
    TuringQwenNativeSamplingPolicy(
      talker: .greedy,
      codePredictor: .greedy
    )

  /// Production candidate for Rich:
  ///
  /// - The talker is sampled because the talker emits the first codec token
  ///   and the EOS token.
  /// - The residual code predictor remains on the existing proven greedy
  ///   path. Residual tokens cannot cause EOS, and sampling all 15 residual
  ///   groups was the dominant unsafe/costly part of the failed patch.
  public static let sampledTalkerGreedyCodePredictor =
    TuringQwenNativeSamplingPolicy(
      talker: .qwenDefaultTalker,
      codePredictor: .greedy
    )

  /// Diagnostic/full-quality candidate. Do not make this a production
  /// default until the on-device Fresh2 acceptance matrix passes.
  public static let qwenDefaultSampled =
    TuringQwenNativeSamplingPolicy(
      talker: .qwenDefaultTalker,
      codePredictor:
        .qwenDefaultCodePredictor
    )

  public func validate() throws {
    try talker.validate(stage: "talker")
    try codePredictor.validate(
      stage: "codePredictor"
    )
  }
}

public enum TuringQwenNativeSamplingError:
  LocalizedError,
  Sendable,
  Equatable
{
  case invalidConfiguration(String)
  case invalidLogitsShape(
    expected: [Int],
    actual: [Int]
  )
  case noFiniteCandidates
  case invalidCandidateArrays
  case invalidRandomDraw(Double)

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration(let message):
      return message

    case .invalidLogitsShape(
      let expected,
      let actual
    ):
      return "Expected logits shape \(expected), got \(actual)."

    case .noFiniteCandidates:
      return "Sampling produced no finite token candidates."

    case .invalidCandidateArrays:
      return "Sampled token candidate IDs and logits do not match."

    case .invalidRandomDraw(let value):
      return "Sampling random draw must be in [0, 1), got \(value)."
    }
  }
}
