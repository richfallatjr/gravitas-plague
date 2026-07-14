import Testing

@testable import TuringQwenNative

struct TuringQwenNativeHostSamplerTests {
  @Test
  func greedyConfigurationRemainsExplicit() {
    let policy =
      TuringQwenNativeSamplingPolicy.greedy

    #expect(
      policy.talker.mode == .greedy
    )
    #expect(
      policy.codePredictor.mode == .greedy
    )
  }

  @Test
  func richProductionCandidateSamplesOnlyTalker() {
    let policy =
      TuringQwenNativeSamplingPolicy
      .sampledTalkerGreedyCodePredictor

    #expect(
      policy.talker.mode == .temperatureTopP
    )
    #expect(
      policy.talker.temperature == 0.9
    )
    #expect(
      policy.talker.topK == 50
    )
    #expect(
      policy.talker.topP == 1
    )
    #expect(
      policy.talker
        .repetitionPenalty == 1.05
    )
    #expect(
      policy.codePredictor.mode == .greedy
    )
  }

  @Test
  func sampledTokenStaysInsideTopK()
    throws
  {
    let logits: [Float] = [
      -8,
      -7,
      -6,
      -5,
      -4,
      -3,
      -2,
      -1,
      0,
      1,
    ]
    let configuration =
      TuringQwenNativeTokenSamplerConfiguration(
        mode:
          .temperatureTopP,
        temperature: 1,
        topK: 3,
        topP: 1,
        repetitionPenalty: 1
      )

    for draw in stride(
      from: 0.0,
      to: 1.0,
      by: 0.01
    ) {
      let token =
        try TuringQwenNativeSampler
        .sampleMaterializedLogits(
          logits,
          configuration:
            configuration,
          generatedTokenHistory: [],
          randomDraw: draw
        )

      #expect(
        [7, 8, 9].contains(token)
      )
    }
  }

  @Test
  func topPAlwaysKeepsAtLeastOneCandidate()
    throws
  {
    let configuration =
      TuringQwenNativeTokenSamplerConfiguration(
        mode:
          .temperatureTopP,
        temperature: 1,
        topK: 4,
        topP: 0.0001,
        repetitionPenalty: 1
      )

    let token =
      try TuringQwenNativeSampler
      .sampleMaterializedLogits(
        [10, 5, 1, 0],
        configuration:
          configuration,
        generatedTokenHistory: [],
        randomDraw: 0.999
      )

    #expect(token == 0)
  }

  @Test
  func repetitionPenaltyCanDemoteRepeatedWinner()
    throws
  {
    let configuration =
      TuringQwenNativeTokenSamplerConfiguration(
        mode:
          .temperatureTopP,
        temperature: 0.01,
        topK: 2,
        topP: 1,
        repetitionPenalty: 2
      )

    let token =
      try TuringQwenNativeSampler
      .sampleMaterializedLogits(
        [10, 6],
        configuration:
          configuration,
        generatedTokenHistory: [0],
        randomDraw: 0.5
      )

    #expect(token == 1)
  }

  @Test
  func candidateBudgetAccountsForRepeatedDemotions() {
    let budget =
      TuringQwenNativeSampler
      .candidateBudget(
        vocabSize: 2_048,
        topK: 50,
        generatedTokenHistory: [
          4,
          4,
          9,
          12,
        ]
      )

    #expect(budget == 53)
  }

  @Test
  func deterministicSeedIsStableAndSegmentSpecific() {
    let first =
      TuringQwenNativeSamplingSeed.make(
        voiceID: "rich",
        runID: "run",
        segmentIndex: 0
      )
    let second =
      TuringQwenNativeSamplingSeed.make(
        voiceID: "rich",
        runID: "run",
        segmentIndex: 0
      )
    let otherSegment =
      TuringQwenNativeSamplingSeed.make(
        voiceID: "rich",
        runID: "run",
        segmentIndex: 1
      )
    let otherVoice =
      TuringQwenNativeSamplingSeed.make(
        voiceID: "third_voice",
        runID: "run",
        segmentIndex: 0
      )

    #expect(first == second)
    #expect(first != otherSegment)
    #expect(first != otherVoice)
  }

  @Test
  func sampledConfigurationRejectsUnboundedTopK()
    throws
  {
    let configuration =
      TuringQwenNativeTokenSamplerConfiguration(
        mode:
          .temperatureTopP,
        temperature: 0.9,
        topK: 0,
        topP: 1,
        repetitionPenalty: 1
      )

    #expect(throws: Error.self) {
      try configuration.validate(
        stage: "test"
      )
    }
  }
}
