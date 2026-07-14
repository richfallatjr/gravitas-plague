import Foundation

public enum TuringQwenNativeReferenceWindowStrategy:
  String,
  Sendable
{
  case full
  case prefix
  case suffix
}

public struct TuringQwenNativeBaseClonePrompt:
  Sendable
{
  public let text: String
  public let language: String
  public let cloneProfile: TuringQwenNativeCloneProfile
  public let maxNewRows: Int
  public let performanceMode: TuringQwenNativePerformanceMode
  public let referenceRowLimit: Int?
  public let referenceWindowStrategy: TuringQwenNativeReferenceWindowStrategy

  public let samplingPolicy: TuringQwenNativeSamplingPolicy
  public let samplingSeed: UInt64
  public let generationQualityPolicy: TuringQwenNativeGenerationQualityPolicy

  public init(
    text: String,
    language: String,
    cloneProfile:
      TuringQwenNativeCloneProfile,
    maxNewRows: Int = 38,
    performanceMode:
      TuringQwenNativePerformanceMode =
      .performance,
    referenceRowLimit: Int? = nil,
    referenceWindowStrategy:
      TuringQwenNativeReferenceWindowStrategy =
      .full,
    samplingPolicy:
      TuringQwenNativeSamplingPolicy =
      .greedy,
    samplingSeed: UInt64 =
      0x9E37_79B9_7F4A_7C15,
    generationQualityPolicy:
      TuringQwenNativeGenerationQualityPolicy =
      .permissive
  ) {
    self.text = text
    self.language = language
    self.cloneProfile = cloneProfile
    self.maxNewRows = maxNewRows
    self.performanceMode =
      performanceMode
    self.referenceRowLimit =
      referenceRowLimit
    self.referenceWindowStrategy =
      referenceWindowStrategy
    self.samplingPolicy =
      samplingPolicy
    self.samplingSeed =
      samplingSeed
    self.generationQualityPolicy =
      generationQualityPolicy
  }
}
