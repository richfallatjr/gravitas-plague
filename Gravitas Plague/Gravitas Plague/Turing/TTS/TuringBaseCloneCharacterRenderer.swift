import Foundation
import TuringQwenNative

actor TuringBaseCloneCharacterRenderer {
  enum Character: String, Sendable {
    case rich
    case bigMike
  }

  typealias StartedCallback =
    @Sendable (Int) async -> Void

  typealias FinishedCallback =
    @Sendable (
      Int,
      TuringComputeGapGeneratedAudio
    ) async -> Void

  typealias SkippedCallback =
    @Sendable (
      Int,
      String
    ) async -> Void

  private let character: Character
  private let resources: TuringBaseCloneRuntimeResources
  private let arbiter: TuringQwenCharacterPoolArbiter

  init(
    character: Character,
    resources: TuringBaseCloneRuntimeResources =
      TuringBaseCloneRuntimeResources(),
    arbiter: TuringQwenCharacterPoolArbiter = .shared
  ) {
    self.character = character
    self.resources = resources
    self.arbiter = arbiter
  }

  func render(
    segments: [TuringSpeechSegment],
    runID: String,
    onStarted: @escaping StartedCallback,
    onFinished: @escaping FinishedCallback,
    onSkipped: @escaping SkippedCallback
  ) async throws {
    guard segments.isEmpty == false else {
      throw TuringRuntimeError.invalidConfig(
        "\(character.rawValue) Qwen render requires at least one segment."
      )
    }

    let owner = "\(character.rawValue).\(runID)"
    await arbiter.acquire(owner: owner)

    var pool: TuringQwenNativeFreshInstancePool?

    do {
      try Task.checkCancellation()

      guard let bundleRoot = Bundle.main.resourceURL else {
        throw TuringRuntimeError.invalidConfig(
          "Missing app resource root for \(character.rawValue) clone."
        )
      }

      let loader = TuringQwenNativeCloneProfileLoader()
      let profile: TuringQwenNativeCloneProfile

      switch character {
      case .rich:
        profile = try loader.loadRichBaseCloneProfile(
          from: bundleRoot,
          voiceID: TuringRichVoiceIdentity.voiceID
        )
      case .bigMike:
        profile = try loader.loadBigMikeBaseCloneProfile(
          from: bundleRoot,
          voiceID: TuringBigMikeVoiceIdentity.voiceID
        )
      }

      let bundledModel = try resources.locateBundledModel()
      let stagedModel = try resources.stageWritableModel(
        from: bundledModel
      )

      let freshPool =
        try TuringQwenNativeGenerationSchedulerFactory
        .makeFresh2Pool()
      pool = freshPool

      try await freshPool.warmLoadExactlyRequestedInstances(
        modelRoot: stagedModel,
        cloneProfile: profile,
        variantID: profile.defaultVariantID,
        performanceMode: .performance
      )

      let scheduler =
        TuringQwenNativeGenerationSchedulerFactory
        .makeFresh2Scheduler(
          instancePool: freshPool
        )

      let requests = segments.enumerated().map {
        index,
        segment in

        TuringQwenNativeBaseCloneSegmentRequest(
          segmentIndex: index,
          text: segment.text,
          language: "english",
          cloneProfile: profile,
          maxNewRows: 160,
          performanceMode: .performance,
          referenceRowLimit: 160,
          referenceWindowStrategy: .suffix
        )
      }

      print(
        """
        [TuringCharacterRenderer] render started
          character: \(character.rawValue)
          runID: \(runID)
          voiceID: \(profile.voiceID)
          segmentCount: \(segments.count)
          requestedInstanceCount: 2
          sharedWeights: false
          fallbackUsed: false
        """)

      let report = try await scheduler.renderSegments(
        requests,
        runID: runID,
        skipSegmentFailures: true,
        onSegmentStarted: {
          _,
          segmentIndex in

          await onStarted(segmentIndex)
        },
        onSegmentFinished: { result in
          await onFinished(
            result.segmentIndex,
            TuringComputeGapGeneratedAudio(
              segmentIndex: result.segmentIndex,
              samples: result.audio.samples,
              sampleRate: Double(
                result.audio.sampleRate
              ),
              channelCount: 1
            )
          )
        },
        onSegmentSkipped: { skipped in
          await onSkipped(
            skipped.segmentIndex,
            skipped.errorDescription
          )
        }
      )

      report.log()

      await freshPool.unloadAll(
        reason: "\(character.rawValue)Finished.\(runID)"
      )
      pool = nil
      await arbiter.release(owner: owner)

      print(
        """
        [TuringCharacterRenderer] render finished
          character: \(character.rawValue)
          runID: \(runID)
          voiceID: \(profile.voiceID)
        """)
    } catch {
      await pool?.unloadAll(
        reason: "\(character.rawValue)Failed.\(runID)"
      )
      await arbiter.release(owner: owner)
      throw error
    }
  }
}
