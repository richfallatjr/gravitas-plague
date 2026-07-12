import Foundation

enum TuringBigMikeConversationRunner {
  static func run(
    playerDictation: String,
    seedStore: TuringConversationSeedStore = .shared,
    onSegmentZeroReady:
      (@MainActor @Sendable () -> Void)? = nil
  ) async -> TuringVoiceRunResult {
    let trimmed =
      playerDictation
      .trimmingCharacters(
        in: .whitespacesAndNewlines
      )

    guard trimmed.isEmpty == false else {
      return .failed(
        "Big Mike conversation requires nonempty player dictation."
      )
    }

    let playback = await MainActor.run {
      TuringStoryWalkiePlaybackCoordinator
        .makeBigMikeCoordinator()
    }

    do {
      let threadContext = await seedStore.context(
        for:
          TuringDialogueThreadIdentity
          .bigMikeRich
      )
      let legacyScriptPoint01Context = await seedStore.context(
        for: "big_mike"
      )
      let context: TuringConversationPromptContext
      let contextSource: String

      if threadContext.lastVoicePromptSeed.isEmptySeed == false
        || threadContext.prerecordingTranscript.isEmpty == false
      {
        context = threadContext
        contextSource = TuringDialogueThreadIdentity.bigMikeRich
      } else {
        // ScriptPoint01 remains untouched and currently stores its initial
        // context under the legacy Big Mike key. Use it for the first custom
        // message, before ScriptPoint02 establishes the shared thread key.
        context = legacyScriptPoint01Context
        contextSource = "big_mike"
      }

      print(
        """
        [TuringBigMikeConversation] context selected
          source: \(contextSource)
          seedPresent: \(context.lastVoicePromptSeed.isEmptySeed == false)
          prerecordingTranscriptUTF16: \(context.prerecordingTranscript.utf16.count)
        """)

      let request =
        ConversationPromptNoBibleRequest(
          id:
            "prologue.bigMike.continuingConversation",
          speaker:
            TuringBigMikeVoiceIdentity
            .displayName,
          voiceID:
            TuringBigMikeVoiceIdentity
            .voiceID,
          voiceVariantID:
            TuringBigMikeVoiceIdentity
            .defaultVariantID,
          characterProfileID:
            TuringBigMikeVoiceIdentity
            .characterID,
          playerDictation: trimmed,
          episodeStateForWordsOnly:
            "Rich and Big Mike are in an active early-outbreak radio conversation. "
            + "ScriptPoint02 and ScriptPoint03 have occurred. Big Mike remains "
            + "nearby, protective, tired, uncertain about the Plague, and under "
            + "possible threat at his own service door.",
          emotion:
            "protective, grounded, tired, alert",
          prerecordingTranscript:
            context
            .prerecordingTranscript,
          lastVoicePromptSeed:
            context
            .lastVoicePromptSeed
        )

      let plan =
        try await TuringDialogueService()
        .generateConversationNoBible(
          request
        )

      await playback.beginRun(
        runID:
          "bigMikeConversationNoBible",
        expectedSegmentCount:
          plan.segments.count
      )

      let zeroReady =
        TuringSegmentZeroReadyNotifier(
          callback:
            onSegmentZeroReady
        )
      let renderer =
        TuringBigMikeQwenRenderer()

      try await renderer.render(
        segments: plan.segments,
        runID:
          "bigMikeConversationNoBible",
        onStarted: { index in
          await playback
            .qwenComputeStarted(
              segmentIndex: index
            )
        },
        onFinished: {
          index,
          audio in

          await zeroReady
            .notifyIfNeeded(
              segmentIndex: index
            )
          await playback
            .qwenComputeFinished(
              segmentIndex: index,
              audio: audio
            )
        },
        onSkipped: {
          index,
          reason in

          await playback
            .qwenComputeSkipped(
              segmentIndex: index,
              reason: reason
            )
        }
      )

      await playback
        .qwenComputeAllFinished()
      await playback
        .waitUntilPlaybackFinished()

      let completedPlaybackCount = await playback
        .completedGeneratedSegmentCount()
      guard completedPlaybackCount > 0 else {
        throw TuringRuntimeError.invalidConfig(
          "Big Mike custom response completed without playing generated TTS."
        )
      }

      print(
        """
        [TuringBigMikeConversation] generated playback completed
          completedSegmentCount: \(completedPlaybackCount)
          completionSource: actualPlaybackCompletion
          eligibleForScriptPoint02Trigger: true
        """)

      await TuringWalkieCommsFXController
        .shared
        .stopAmbientWalkieStatic(
          reason:
            "bigMikeConversationFinished"
        )

      print(
        """
        [TuringBigMikeConversation] dispatching script completion
          event: scriptPoint01ConversationVoicePlaybackCompleted
          completionSource: actualPlaybackCompletion
          uiOwner: false
        """)

      if let progressionResult = await
        TuringScriptPointProgressionController.shared
        .triggerAfterFirstSuccessfulWalkieCustomMessage(
          seedStore: seedStore
        )
      {
        return progressionResult
      }

      return .succeeded("Finished Big Mike conversation response")
    } catch {
      await playback.runCancelled(
        reason:
          "bigMikeConversationFailed.\(error.localizedDescription)"
      )
      await TuringWalkieCommsFXController
        .shared
        .stopSendingLeadIn(
          reason:
            "bigMikeConversationFailed"
        )
      await TuringWalkieCommsFXController
        .shared
        .stopAmbientWalkieStatic(
          reason:
            "bigMikeConversationFailed"
        )

      return .failed(
        error.localizedDescription
      )
    }
  }
}

private actor TuringSegmentZeroReadyNotifier {
  private let callback: (@MainActor @Sendable () -> Void)?
  private var notified = false

  init(
    callback:
      (@MainActor @Sendable () -> Void)?
  ) {
    self.callback = callback
  }

  func notifyIfNeeded(
    segmentIndex: Int
  ) async {
    guard segmentIndex == 0,
      notified == false
    else {
      return
    }

    notified = true
    await callback?()
  }
}
