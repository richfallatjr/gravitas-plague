import Testing

@testable import TuringQwenNative

struct TuringQwenNativeGenerationQualityPolicyTests {
  @Test
  func richPolicyRejectsRowCapBeforeDecode()
    throws
  {
    let policy =
      TuringQwenNativeGenerationQualityPolicy
      .productionSpeech

    #expect(throws: Error.self) {
      try policy.validateBeforeDecode(
        voiceID: "rich",
        generatedRowCount: 160,
        maxNewRows: 160,
        reachedEOS: false
      )
    }
  }

  @Test
  func richPolicyAcceptsEOSBeforeDecode()
    throws
  {
    try TuringQwenNativeGenerationQualityPolicy
      .productionSpeech
      .validateBeforeDecode(
        voiceID: "rich",
        generatedRowCount: 24,
        maxNewRows: 160,
        reachedEOS: true
      )
  }

  @Test
  func richPolicyRejectsControlledSilentMetrics()
    throws
  {
    let policy =
      TuringQwenNativeGenerationQualityPolicy
      .productionSpeech

    #expect(throws: Error.self) {
      try policy.validateAfterDecode(
        voiceID: "rich",
        generatedRowCount: 24,
        peakAbs: 0.000126,
        rms: 0.000034,
        durationSeconds: 2
      )
    }
  }

  @Test
  func richPolicyAcceptsControlledAudibleMetrics()
    throws
  {
    try TuringQwenNativeGenerationQualityPolicy
      .productionSpeech
      .validateAfterDecode(
        voiceID: "rich",
        generatedRowCount: 24,
        peakAbs: 0.473762,
        rms: 0.077425,
        durationSeconds: 2.32
      )
  }

  @Test
  func permissiveBigMikePolicyDoesNotChangeLegacyBehavior()
    throws
  {
    let policy =
      TuringQwenNativeGenerationQualityPolicy
      .permissive

    try policy.validateBeforeDecode(
      voiceID: "big_mike",
      generatedRowCount: 160,
      maxNewRows: 160,
      reachedEOS: false
    )
    try policy.validateAfterDecode(
      voiceID: "big_mike",
      generatedRowCount: 160,
      peakAbs: 0,
      rms: 0,
      durationSeconds: 0
    )
  }
}
