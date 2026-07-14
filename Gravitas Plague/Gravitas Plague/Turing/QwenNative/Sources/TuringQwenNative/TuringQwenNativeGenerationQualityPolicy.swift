import Foundation

public struct TuringQwenNativeGenerationQualityPolicy:
  Codable,
  Sendable,
  Hashable
{
  public let requireEOSBeforeDecode: Bool
  public let minimumPeakAbs: Float
  public let minimumRMS: Float

  public init(
    requireEOSBeforeDecode: Bool,
    minimumPeakAbs: Float,
    minimumRMS: Float
  ) {
    self.requireEOSBeforeDecode =
      requireEOSBeforeDecode
    self.minimumPeakAbs =
      minimumPeakAbs
    self.minimumRMS =
      minimumRMS
  }

  public static let permissive =
    TuringQwenNativeGenerationQualityPolicy(
      requireEOSBeforeDecode: false,
      minimumPeakAbs: 0,
      minimumRMS: 0
    )

  public static let productionSpeech =
    TuringQwenNativeGenerationQualityPolicy(
      requireEOSBeforeDecode: true,
      minimumPeakAbs: 0.001,
      minimumRMS: 0.0001
    )

  public func validateBeforeDecode(
    voiceID: String,
    generatedRowCount: Int,
    maxNewRows: Int,
    reachedEOS: Bool
  ) throws {
    guard requireEOSBeforeDecode == false || reachedEOS else {
      throw
        TuringQwenNativeGenerationQualityError
        .rowCapWithoutEOS(
          voiceID: voiceID,
          generatedRowCount:
            generatedRowCount,
          maxNewRows:
            maxNewRows
        )
    }
  }

  public func validateAfterDecode(
    voiceID: String,
    generatedRowCount: Int,
    peakAbs: Float,
    rms: Float,
    durationSeconds: Double
  ) throws {
    guard peakAbs.isFinite,
      rms.isFinite,
      durationSeconds.isFinite
    else {
      throw
        TuringQwenNativeGenerationQualityError
        .invalidAudioMetrics(
          voiceID: voiceID
        )
    }

    guard peakAbs >= minimumPeakAbs,
      rms >= minimumRMS
    else {
      throw
        TuringQwenNativeGenerationQualityError
        .effectivelySilent(
          voiceID: voiceID,
          generatedRowCount:
            generatedRowCount,
          peakAbs: peakAbs,
          rms: rms,
          durationSeconds:
            durationSeconds,
          requiredPeakAbs:
            minimumPeakAbs,
          requiredRMS:
            minimumRMS
        )
    }
  }
}

public enum TuringQwenNativeGenerationQualityError:
  LocalizedError,
  Sendable,
  Equatable
{
  case rowCapWithoutEOS(
    voiceID: String,
    generatedRowCount: Int,
    maxNewRows: Int
  )

  case effectivelySilent(
    voiceID: String,
    generatedRowCount: Int,
    peakAbs: Float,
    rms: Float,
    durationSeconds: Double,
    requiredPeakAbs: Float,
    requiredRMS: Float
  )

  case invalidAudioMetrics(
    voiceID: String
  )

  public var errorDescription: String? {
    switch self {
    case .rowCapWithoutEOS(
      let voiceID,
      let generatedRowCount,
      let maxNewRows
    ):
      return """
        \(voiceID) reached the \(maxNewRows)-row safety cap without EOS \
        (generatedRows=\(generatedRowCount)). The segment was rejected \
        before speech decode and will not be played.
        """

    case .effectivelySilent(
      let voiceID,
      let generatedRowCount,
      let peakAbs,
      let rms,
      let durationSeconds,
      let requiredPeakAbs,
      let requiredRMS
    ):
      return """
        \(voiceID) generated effectively silent audio \
        (rows=\(generatedRowCount), duration=\(durationSeconds), \
        peakAbs=\(peakAbs), rms=\(rms), \
        requiredPeakAbs=\(requiredPeakAbs), requiredRMS=\(requiredRMS)). \
        The segment will not be played.
        """

    case .invalidAudioMetrics(
      let voiceID
    ):
      return """
        \(voiceID) produced non-finite decoded-audio metrics. \
        The segment will not be played.
        """
    }
  }
}
