import Foundation
import TuringQwenNative

struct TuringCharacterRuntimeDefinition:
  Codable,
  Sendable,
  Hashable
{
  let characterID: String
  let displayName: String
  let voiceID: String
  let cloneProfileResourcePath: String
  let allowedOutputRoutes: [TuringVoiceOutputContext]
  let outputProcessing: OutputProcessing
  let qwen: Qwen
  let audio: Audio

  struct OutputProcessing:
    Codable,
    Sendable,
    Hashable
  {
    let playbackRate: Double
  }

  struct Qwen:
    Codable,
    Sendable,
    Hashable
  {
    let maxNewRows: Int
    let useExactReferenceRowCount: Bool
    let referenceWindowStrategy: String
    let skipSegmentFailures: Bool
    let decoding: Decoding
    let qualityGate: QualityGate

    struct Decoding:
      Codable,
      Sendable,
      Hashable
    {
      let talker: Sampler
      let codePredictor: Sampler

      struct Sampler:
        Codable,
        Sendable,
        Hashable
      {
        let mode: String
        let backend: String
        let temperature: Float
        let topK: Int
        let topP: Float
        let repetitionPenalty: Float

        var native: TuringQwenNativeTokenSamplerConfiguration {
          TuringQwenNativeTokenSamplerConfiguration(
            mode:
              TuringQwenNativeTokenSamplingMode(
                rawValue: mode
              )!,
            backend:
              TuringQwenNativeSamplingBackend(
                rawValue: backend
              )!,
            temperature:
              temperature,
            topK: topK,
            topP: topP,
            repetitionPenalty:
              repetitionPenalty
          )
        }
      }

      var native: TuringQwenNativeSamplingPolicy {
        TuringQwenNativeSamplingPolicy(
          talker: talker.native,
          codePredictor:
            codePredictor.native
        )
      }
    }

    struct QualityGate:
      Codable,
      Sendable,
      Hashable
    {
      let requireEOSBeforeDecode: Bool
      let minimumPeakAbs: Float
      let minimumRMS: Float

      var native: TuringQwenNativeGenerationQualityPolicy {
        TuringQwenNativeGenerationQualityPolicy(
          requireEOSBeforeDecode:
            requireEOSBeforeDecode,
          minimumPeakAbs:
            minimumPeakAbs,
          minimumRMS:
            minimumRMS
        )
      }
    }

    var samplingPolicy: TuringQwenNativeSamplingPolicy {
      decoding.native
    }

    var generationQualityPolicy: TuringQwenNativeGenerationQualityPolicy {
      qualityGate.native
    }
  }

  struct Audio:
    Codable,
    Sendable,
    Hashable
  {
    let generatedGainDB: Float
    let prerecordingGainDB: Float
    let fillerGainDB: Float
    let fillerDirectoryCandidates: [String]
    let fillerExtensions: [String]
  }

  var outputProcessingPolicy: TuringQwenOutputProcessingPolicy {
    TuringQwenOutputProcessingPolicy(
      voiceID: voiceID,
      playbackRate:
        outputProcessing.playbackRate
    )
  }

  func supports(
    _ route: TuringVoiceOutputContext
  ) -> Bool {
    allowedOutputRoutes.contains(route)
  }
}

private struct TuringCharacterRuntimeRegistryResource:
  Codable,
  Sendable
{
  let schemaVersion: Int
  let characters: [TuringCharacterRuntimeDefinition]
}

protocol TuringCharacterRuntimeProviding:
  Sendable
{
  func require(
    _ characterID: String
  ) throws -> TuringCharacterRuntimeDefinition
}

struct TuringCharacterRuntimeRegistry:
  TuringCharacterRuntimeProviding,
  Sendable
{
  private let definitions: [String: TuringCharacterRuntimeDefinition]

  init(
    resourcePath: String =
      "Turing/Config/character-runtimes.json"
  ) throws {
    let resource =
      try TuringResourceLoader
      .decodeResource(
        TuringCharacterRuntimeRegistryResource.self,
        resourcePath:
          resourcePath
      )

    guard resource.schemaVersion == 2 else {
      throw
        TuringRuntimeError
        .invalidConfig(
          "character-runtimes schemaVersion must be 2."
        )
    }

    var result: [String: TuringCharacterRuntimeDefinition] =
      [:]

    for definition in resource.characters {
      try Self.validate(definition)

      guard
        result[
          definition.characterID
        ] == nil
      else {
        throw
          TuringRuntimeError
          .invalidConfig(
            "Duplicate Turing character runtime: \(definition.characterID)."
          )
      }

      result[
        definition.characterID
      ] = definition
    }

    guard result.isEmpty == false else {
      throw
        TuringRuntimeError
        .invalidConfig(
          "character-runtimes must contain at least one character."
        )
    }

    self.definitions = result
  }

  init(
    definitions:
      [TuringCharacterRuntimeDefinition]
  ) throws {
    var result: [String: TuringCharacterRuntimeDefinition] =
      [:]

    for definition in definitions {
      try Self.validate(definition)

      guard
        result[
          definition.characterID
        ] == nil
      else {
        throw
          TuringRuntimeError
          .invalidConfig(
            "Duplicate Turing character runtime: \(definition.characterID)."
          )
      }

      result[
        definition.characterID
      ] = definition
    }

    self.definitions = result
  }

  func require(
    _ characterID: String
  ) throws -> TuringCharacterRuntimeDefinition {
    guard
      let definition =
        definitions[characterID]
    else {
      throw
        TuringRuntimeError
        .invalidConfig(
          "No Turing character runtime for \(characterID)."
        )
    }

    return definition
  }

  private static func validate(
    _ definition:
      TuringCharacterRuntimeDefinition
  ) throws {
    let required = [
      definition.characterID,
      definition.displayName,
      definition.voiceID,
      definition.cloneProfileResourcePath,
    ]

    guard
      required.allSatisfy({
        $0.trimmingCharacters(
          in: .whitespacesAndNewlines
        ).isEmpty == false
      })
    else {
      throw
        TuringRuntimeError
        .invalidConfig(
          "A Turing character runtime contains an empty identity field."
        )
    }

    guard
      definition
        .allowedOutputRoutes
        .isEmpty == false
    else {
      throw
        TuringRuntimeError
        .invalidConfig(
          "\(definition.characterID) must allow at least one output route."
        )
    }

    guard
      definition.outputProcessing
        .playbackRate > 0.25,
      definition.outputProcessing
        .playbackRate <= 2
    else {
      throw
        TuringRuntimeError
        .invalidConfig(
          "\(definition.characterID) playbackRate must be in (0.25, 2.0]."
        )
    }

    guard definition.qwen.maxNewRows > 0 else {
      throw
        TuringRuntimeError
        .invalidConfig(
          "\(definition.characterID) maxNewRows must be positive."
        )
    }

    let strategy =
      definition.qwen
      .referenceWindowStrategy

    guard strategy == "full" || strategy == "suffix" else {
      throw
        TuringRuntimeError
        .invalidConfig(
          "\(definition.characterID) referenceWindowStrategy must be full or suffix."
        )
    }

    try validate(
      definition.qwen.decoding.talker,
      stage:
        "\(definition.characterID).talker"
    )
    try validate(
      definition.qwen.decoding
        .codePredictor,
      stage:
        "\(definition.characterID).codePredictor"
    )

    guard
      definition.qwen.qualityGate
        .minimumPeakAbs >= 0,
      definition.qwen.qualityGate
        .minimumPeakAbs.isFinite,
      definition.qwen.qualityGate
        .minimumRMS >= 0,
      definition.qwen.qualityGate
        .minimumRMS.isFinite
    else {
      throw
        TuringRuntimeError
        .invalidConfig(
          "\(definition.characterID) quality thresholds must be finite and nonnegative."
        )
    }

    try definition.qwen
      .samplingPolicy
      .validate()
  }

  private static func validate(
    _ sampler:
      TuringCharacterRuntimeDefinition
      .Qwen.Decoding.Sampler,
    stage: String
  ) throws {
    guard
      TuringQwenNativeTokenSamplingMode(
        rawValue: sampler.mode
      ) != nil
    else {
      throw
        TuringRuntimeError
        .invalidConfig(
          "\(stage) has unsupported mode \(sampler.mode)."
        )
    }

    guard
      TuringQwenNativeSamplingBackend(
        rawValue: sampler.backend
      ) != nil
    else {
      throw
        TuringRuntimeError
        .invalidConfig(
          "\(stage) has unsupported backend \(sampler.backend)."
        )
    }
  }
}
