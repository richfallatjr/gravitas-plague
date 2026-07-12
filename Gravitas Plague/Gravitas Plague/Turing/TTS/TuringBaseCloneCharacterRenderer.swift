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

      let selectedVariant = try profile.requireVariant(
        profile.defaultVariantID
      )
      let selectedArtifacts =
        try TuringQwenNativeCloneArtifactsLoader().load(
          from: selectedVariant,
          expectedVoiceID: profile.voiceID
        )

      // Use the exact authored row count for every clone. This is 159 for
      // Big Mike and 178 for the current Rich reference.
      let referenceRowLimit: Int? =
        selectedArtifacts.referenceRowCount
      let referenceWindowStrategy:
        TuringQwenNativeReferenceWindowStrategy = .full

      let requests = segments.enumerated().map {
        index,
        segment in

        print(
          """
          [TuringCharacterRenderer] exact Qwen input
            character: \(character.rawValue)
            runID: \(runID)
            segmentIndex: \(index)
            textUTF16: \(segment.text.utf16.count)
            BEGIN_TEXT
          \(segment.text)
            END_TEXT
          """)

        return TuringQwenNativeBaseCloneSegmentRequest(
          segmentIndex: index,
          text: segment.text,
          language: "english",
          cloneProfile: profile,
          maxNewRows: 160,
          performanceMode: .performance,
          referenceRowLimit: referenceRowLimit,
          referenceWindowStrategy: referenceWindowStrategy
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
          referenceRowLimit: \(referenceRowLimit.map(String.init) ?? "full")
          referenceWindowStrategy: \(referenceWindowStrategy.rawValue)
        """)

      let attemptState = TuringCharacterRenderAttemptState()
      let isRich = character == .rich
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
          await attemptState.recordSuccess(result.segmentIndex)
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
          if isRich {
            await attemptState.recordSkipped(
              skipped.segmentIndex,
              reason: skipped.errorDescription
            )
          } else {
            await onSkipped(
              skipped.segmentIndex,
              skipped.errorDescription
            )
          }
        }
      )

      report.log()

      if isRich {
        let skipped = await attemptState.skippedSnapshot()
        if skipped.isEmpty == false {
          let retryRequests = requests.filter {
            skipped[$0.segmentIndex] != nil
          }
          print(
            """
            [TuringCharacterRenderer] retrying skipped Rich segments
              runID: \(runID)
              retryCount: \(retryRequests.count)
              segmentIndices: \(retryRequests.map(\.segmentIndex).sorted())
              retryLimit: 1
            """)

          let retryState = TuringCharacterRenderAttemptState()
          let retryReport = try await scheduler.renderSegments(
            retryRequests,
            runID: "\(runID).richRetry1",
            skipSegmentFailures: true,
            onSegmentStarted: { _, segmentIndex in
              await onStarted(segmentIndex)
            },
            onSegmentFinished: { result in
              await retryState.recordSuccess(result.segmentIndex)
              await attemptState.recordSuccess(result.segmentIndex)
              await onFinished(
                result.segmentIndex,
                TuringComputeGapGeneratedAudio(
                  segmentIndex: result.segmentIndex,
                  samples: result.audio.samples,
                  sampleRate: Double(result.audio.sampleRate),
                  channelCount: 1
                )
              )
            },
            onSegmentSkipped: { finalSkip in
              await retryState.recordSkipped(
                finalSkip.segmentIndex,
                reason: finalSkip.errorDescription
              )
              await onSkipped(
                finalSkip.segmentIndex,
                finalSkip.errorDescription
              )
            }
          )
          retryReport.log()

          let finalSkipped = await retryState.skippedSnapshot()
          if finalSkipped.isEmpty == false {
            throw TuringRuntimeError.playbackFailed(
              "Rich Qwen failed after one retry for segments: "
                + finalSkipped.keys.sorted().map(String.init).joined(separator: ", ")
            )
          }
        }

        let successful = await attemptState.successfulIndices()
        guard successful.isEmpty == false else {
          throw TuringRuntimeError.playbackFailed(
            "Rich Qwen produced no generated voicePrompt audio."
          )
        }
      }

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

private actor TuringCharacterRenderAttemptState {
  private var successes = Set<Int>()
  private var skipped: [Int: String] = [:]

  func recordSuccess(_ segmentIndex: Int) {
    successes.insert(segmentIndex)
    skipped.removeValue(forKey: segmentIndex)
  }

  func recordSkipped(_ segmentIndex: Int, reason: String) {
    guard successes.contains(segmentIndex) == false else {
      return
    }
    skipped[segmentIndex] = reason
  }

  func successfulIndices() -> Set<Int> {
    successes
  }

  func skippedSnapshot() -> [Int: String] {
    skipped
  }
}
