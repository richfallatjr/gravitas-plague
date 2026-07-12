import Foundation

actor TuringScriptPoint02And03FlowController {
  static let shared = TuringScriptPoint02And03FlowController()

  private var running = false

  func run(
    seedStore: TuringConversationSeedStore = .shared
  ) async -> TuringVoiceRunResult {
    guard running == false else {
      return .failed(
        "ScriptPoint02/03 flow is already running."
      )
    }

    running = true
    defer {
      running = false
    }

    let scriptPointStore = TuringWalkieScriptPointStore()
    let prerecordingStore = TuringPrerecordingStore()
    let triggerStore = TuringVoicePromptTriggerStore()
    let dialogueService = TuringDialogueService()

    let scriptPoint02ID = "prologue.scriptPoint02"
    let scriptPoint03ID = "prologue.scriptPoint03"

    var richPlayback: TuringStoryWalkiePlaybackCoordinator?
    var richCompletionTask: Task<Void, Never>?
    var richExpectedSegmentCount: Int?
    var scriptPoint03Playback: TuringStoryWalkiePlaybackCoordinator?
    var scriptPoint03CompletionTask: Task<Void, Never>?

    var richPlanTask: Task<TuringVoicePromptPlan, Error>?
    var richRendererTask: Task<Void, Error>?
    var bigMikePlanTask: Task<TuringVoicePromptPlan, Error>?
    var bigMikeRendererTask: Task<TuringVoicePromptPlan, Error>?

    do {
      let point02 = try scriptPointStore.descriptor(
        id: scriptPoint02ID
      )
      let point03 = try scriptPointStore.descriptor(
        id: scriptPoint03ID
      )

      let richPrerecording = try prerecordingStore.descriptor(
        id: point02.prerecordingID
      )
      let bigMikePrerecording = try prerecordingStore.descriptor(
        id: point03.prerecordingID
      )
      let richPrerecordingURL = try prerecordingStore.audioURL(
        for: richPrerecording
      )
      let bigMikePrerecordingURL = try prerecordingStore.audioURL(
        for: bigMikePrerecording
      )

      let richTrigger = try triggerStore.descriptor(
        id: point02.responseVoicePromptID
      )
      let bigMikeTrigger = try triggerStore.descriptor(
        id: point03.responseVoicePromptID
      )

      try Self.validate(
        point02: point02,
        point03: point03,
        richPrerecording: richPrerecording,
        bigMikePrerecording: bigMikePrerecording,
        richTrigger: richTrigger,
        bigMikeTrigger: bigMikeTrigger
      )

      await seedStore.updatePrerecording(
        id: richPrerecording.prerecordingID,
        transcript: richPrerecording.transcript,
        for: TuringDialogueThreadIdentity.bigMikeRich
      )

      try await TuringWalkieCommsFXController.shared
        .playScriptedOpenComm(
          reason: "scriptPoint02RichTransmissionStarted"
        )

      let createdRichPlayback = await MainActor.run {
        TuringStoryWalkiePlaybackCoordinator
          .makeRichGlobalCoordinator()
      }
      richPlayback = createdRichPlayback

      await createdRichPlayback.beginRun(
        runID: point02.scriptPointID,
        expectedSegmentCount: nil
      )
      await createdRichPlayback.enqueuePrerecording(
        id: richPrerecording.prerecordingID,
        fileURL: richPrerecordingURL
      )
      let createdRichCompletionTask = Task {
        await createdRichPlayback.waitUntilPlaybackFinished()
      }
      richCompletionTask = createdRichCompletionTask

      print(
        """
        [TuringScriptPoint02] started
          scriptPointID: \(point02.scriptPointID)
          prerecordingID: \(richPrerecording.prerecordingID)
          prerecordingSpeaker: rich
          prerecordingRoute: headTrackedSpatial
          prerecordingEmitter: TuringRichHeadset_AudioEmitter
          prerecordingCompletionSource: AudioPlaybackController.completionHandler
          playbackOwner: TuringStoryWalkiePlaybackCoordinator
          commSFXRoute: spatialWalkie
          commSFXEmitter: TuringStoryWalkieTalkie_AudioEmitter
          responseVoicePromptID: \(richTrigger.voicePromptID)
          responseCharacter: rich
          sequence: openComm,richPR,richGenerated,sendComm
          automaticAdvanceTo: \(point02.nextScriptPointID ?? "none")
          playerInteractionGate: false
        """)

      let createdRichPlanTask = Task.detached(
        priority: .userInitiated
      ) {
        try await dialogueService.generateVoicePrompt(
          VoicePromptRequest(
            id: richTrigger.voicePromptID,
            speaker: TuringRichVoiceIdentity.displayName,
            voiceID: richTrigger.voiceID,
            voiceVariantID: TuringRichVoiceIdentity.defaultVariantID,
            characterProfileID: richTrigger.characterProfileID,
            intent: richTrigger.intent,
            emotion: richTrigger.emotion,
            prerecordingTranscript: richPrerecording.transcript,
            voicePromptSeedIntent: richTrigger.seedIntent
          )
        )
      }
      richPlanTask = createdRichPlanTask

      print(
        """
        [TuringScriptPoint02] Rich voicePrompt compute launched during PR playback
          prerecordingID: \(richPrerecording.prerecordingID)
          FoundationTaskStarted: true
          playbackOwner: TuringStoryWalkiePlaybackCoordinator
          fillerBridgeAfterPR: continuousUntilGeneratedSegment0Ready
        """)

      let richPlan: TuringVoicePromptPlan
      do {
        richPlan = try await createdRichPlanTask.value
      } catch {
        richExpectedSegmentCount = 0
        await createdRichPlayback.qwenComputeFailed(
          expectedSegmentCount: 0,
          reason: error.localizedDescription
        )
        await createdRichCompletionTask.value
        print(
          """
          [TuringScriptPoint02] Foundation failed after PR started
            prerecordingAllowedToFinish: true
            prerecordingCompletionWaited: true
            generatedContinuationStarted: false
            error: \(error.localizedDescription)
          """)
        throw error
      }
      await seedStore.updateSeed(
        richPlan.conversationSeed,
        for: TuringDialogueThreadIdentity.bigMikeRich
      )

      let generatedRichTranscript = richPlan.segments
        .map(\.text)
        .joined(separator: " ")
      let completeRichTransmission = [
        richPrerecording.transcript,
        generatedRichTranscript,
      ]
      .filter {
        $0.trimmingCharacters(
          in: .whitespacesAndNewlines
        ).isEmpty == false
      }
      .joined(separator: " ")

      print(
        """
        [TuringScriptPoint02] Rich voicePrompt plan ready
          prerecordingUTF16: \(richPrerecording.transcript.utf16.count)
          generatedSegmentCount: \(richPlan.segments.count)
          generatedUTF16: \(generatedRichTranscript.utf16.count)
          completeTransmissionUTF16: \(completeRichTransmission.utf16.count)
          BigMikeFoundationDeferredUntilRichSendCompletes: true
        """)

      await createdRichPlayback.setExpectedGeneratedSegmentCount(
        richPlan.segments.count
      )
      richExpectedSegmentCount = richPlan.segments.count

      let bigMikeContext = """
        RICH AUTHORED OUTGOING PR:
        \(richPrerecording.transcript)

        RICH GENERATED CONTINUATION:
        \(generatedRichTranscript)

        BIG MIKE AUTHORED PR THAT WILL PLAY BEFORE HIS GENERATED CONTINUATION:
        \(bigMikePrerecording.transcript)
        """

      let richRenderer = TuringRichQwenRenderer()
      let createdRichRendererTask = Task {
        do {
          try await richRenderer.render(
            segments: richPlan.segments,
            runID: richTrigger.voicePromptID,
            onStarted: { index in
              await createdRichPlayback.qwenComputeStarted(
                segmentIndex: index
              )
            },
            onFinished: { index, audio in
              await createdRichPlayback.qwenComputeFinished(
                segmentIndex: index,
                audio: audio
              )
            },
            onSkipped: { index, reason in
              await createdRichPlayback.qwenComputeSkipped(
                segmentIndex: index,
                reason: reason
              )
            }
          )
          await createdRichPlayback.qwenComputeAllFinished()
        } catch {
          await createdRichPlayback.qwenComputeFailed(
            expectedSegmentCount: richPlan.segments.count,
            reason: error.localizedDescription
          )
          throw error
        }
      }
      richRendererTask = createdRichRendererTask

      // Rich owns the only resident Fresh2 character pool until all Rich
      // segments have been generated and the pool has unloaded. Rich's
      // already-authored/head-tracked playback may continue after this task.
      let richGenerationFailure: Error?
      do {
        try await createdRichRendererTask.value
        richGenerationFailure = nil
      } catch {
        richGenerationFailure = error
      }

      await createdRichCompletionTask.value
      if let richGenerationFailure {
        print(
          """
          [TuringScriptPoint02] Rich generation failed
            prerecordingAllowedToFinish: true
            prerecordingCompletionWaited: true
            generatedContinuationCompleted: false
            error: \(richGenerationFailure.localizedDescription)
          """)
        throw richGenerationFailure
      }
      let richPlaybackCount = await createdRichPlayback
        .completedGeneratedSegmentCount()
      guard richPlaybackCount == richPlan.segments.count else {
        throw TuringRuntimeError.playbackFailed(
          "ScriptPoint02 requires every Rich voicePrompt segment to play. "
            + "Expected \(richPlan.segments.count), played \(richPlaybackCount)."
        )
      }

      try await TuringWalkieCommsFXController.shared
        .playScriptedSendComm(
          reason: "scriptPoint02RichTransmissionCompleted"
        )

      print(
        """
        [TuringScriptPoint02] completed
          RichPrerecordingCompleted: true
          RichGeneratedCompleted: true
          RichGeneratedPlaybackCount: \(richPlaybackCount)
          RichSendCommCompleted: true
          playerInteractionGate: false
          automaticAdvanceTo: \(point03.scriptPointID)
        """)

      let createdBigMikePlanTask = Task.detached(
        priority: .userInitiated
      ) {
        try await dialogueService.generateVoicePrompt(
          VoicePromptRequest(
            id: bigMikeTrigger.voicePromptID,
            speaker: TuringBigMikeVoiceIdentity.displayName,
            voiceID: bigMikeTrigger.voiceID,
            voiceVariantID: TuringBigMikeVoiceIdentity.defaultVariantID,
            characterProfileID: bigMikeTrigger.characterProfileID,
            intent: bigMikeTrigger.intent,
            emotion: bigMikeTrigger.emotion,
            prerecordingTranscript: bigMikeContext,
            voicePromptSeedIntent: bigMikeTrigger.seedIntent
          )
        )
      }
      bigMikePlanTask = createdBigMikePlanTask

      await TuringWalkieCommsFXController.shared
        .runFixedResponseLeadInAfterExternalSend(
          reason: "scriptPoint02RichTransmissionFinished",
          durationSeconds: 10
        )

      let createdPoint03Playback = await MainActor.run {
        TuringStoryWalkiePlaybackCoordinator
          .makeBigMikeTuringFlowCoordinator()
      }
      scriptPoint03Playback = createdPoint03Playback

      await createdPoint03Playback.beginRun(
        runID: point03.scriptPointID,
        expectedSegmentCount: nil
      )
      await createdPoint03Playback.enqueuePrerecording(
        id: bigMikePrerecording.prerecordingID,
        fileURL: bigMikePrerecordingURL
      )

      let createdBigMikeRendererTask = Task {
        let plan: TuringVoicePromptPlan

        do {
          plan = try await createdBigMikePlanTask.value
        } catch {
          await createdPoint03Playback.setExpectedGeneratedSegmentCount(0)
          await createdPoint03Playback.qwenComputeAllFinished()
          throw error
        }

        guard plan.segments.isEmpty == false else {
          await createdPoint03Playback.setExpectedGeneratedSegmentCount(0)
          await createdPoint03Playback.qwenComputeAllFinished()
          throw TuringRuntimeError.invalidConfig(
            "ScriptPoint03 voicePrompt returned no Big Mike TTS segments."
          )
        }

        await createdPoint03Playback.setExpectedGeneratedSegmentCount(
          plan.segments.count
        )
        await seedStore.updateSeed(
          plan.conversationSeed,
          for: TuringDialogueThreadIdentity.bigMikeRich
        )
        await seedStore.updatePrerecording(
          id: bigMikePrerecording.prerecordingID,
          transcript: bigMikePrerecording.transcript,
          for: TuringDialogueThreadIdentity.bigMikeRich
        )

        print(
          """
          [TuringScriptPoint03] Big Mike voicePrompt plan ready
            generatedSegmentCount: \(plan.segments.count)
            foundationComputeOverlap: sendingLeadInAndPrerecording
            qwenComputeOverlap: prerecordingPlayback
            playbackSink: directTuringFlowCoordinator
          """)

        let renderer = TuringBigMikeQwenRenderer()

        do {
          try await renderer.render(
            segments: plan.segments,
            runID: bigMikeTrigger.voicePromptID,
            onStarted: { index in
              await createdPoint03Playback.qwenComputeStarted(
                segmentIndex: index
              )
            },
            onFinished: { index, audio in
              await createdPoint03Playback.qwenComputeFinished(
                segmentIndex: index,
                audio: audio
              )
            },
            onSkipped: { index, reason in
              await createdPoint03Playback.qwenComputeSkipped(
                segmentIndex: index,
                reason: reason
              )
            }
          )
          await createdPoint03Playback.qwenComputeAllFinished()
          return plan
        } catch {
          await createdPoint03Playback.qwenComputeFailed(
            expectedSegmentCount: plan.segments.count,
            reason: error.localizedDescription
          )
          throw error
        }
      }
      bigMikeRendererTask = createdBigMikeRendererTask

      let point03CompletionTask = Task {
        await createdPoint03Playback.waitUntilPlaybackFinished()
      }
      scriptPoint03CompletionTask = point03CompletionTask

      print(
        """
        [TuringScriptPoint03] started
          scriptPointID: \(point03.scriptPointID)
          prerecordingID: \(bigMikePrerecording.prerecordingID)
          prerecordingSpeaker: big_mike
          prerecordingRoute: spatialWalkie
          responseVoicePromptID: \(bigMikeTrigger.voicePromptID)
          responseCharacter: big_mike
          generatedRoute: spatialWalkie
          sendingLeadInCompletedSeconds: 10.000
          voicePromptFoundationStartedDuringLeadIn: true
          qwenEventsRoutedDirectlyToPlayback: true
          turingFlow: prerecording,computeGapFiller,generatedTTS,microphoneOpen
          continuedQuestionsEnabled: \(point03.conversationRemainsEnabled)
        """)

      let bigMikeGenerationFailure: Error?
      var bigMikePlan: TuringVoicePromptPlan?

      do {
        bigMikePlan = try await createdBigMikeRendererTask.value
        bigMikeGenerationFailure = nil
      } catch {
        bigMikeGenerationFailure = error
      }

      await point03CompletionTask.value

      await TuringWalkieCommsFXController.shared
        .stopAmbientWalkieStatic(
          reason: "scriptPoint03Finished"
        )

      if let bigMikeGenerationFailure {
        return .failed(
          "ScriptPoint03 PR completed, but Big Mike generation failed: "
            + bigMikeGenerationFailure.localizedDescription
        )
      }

      guard let bigMikePlan else {
        return .failed(
          "ScriptPoint03 PR completed, but no Big Mike voicePrompt plan was available."
        )
      }

      let bigMikePlaybackCount = await createdPoint03Playback
        .completedGeneratedSegmentCount()
      guard bigMikePlaybackCount == bigMikePlan.segments.count else {
        return .failed(
          "ScriptPoint03 Big Mike TTS playback was incomplete. Expected "
            + "\(bigMikePlan.segments.count), played \(bigMikePlaybackCount)."
        )
      }

      print(
        """
        [TuringScriptPoint03] completed
          prerecordingCompleted: true
          generatedSegmentCount: \(bigMikePlan.segments.count)
          generatedPlaybackCount: \(bigMikePlaybackCount)
          generatedCompletionSource: actualPlaybackCompletion
          conversationKey: \(TuringDialogueThreadIdentity.bigMikeRich)
          continuedQuestionsEnabled: \(point03.conversationRemainsEnabled)
          microphoneGate: open
        """)

      return .succeeded(
        "Finished corrected ScriptPoint02 Rich flow and ScriptPoint03 Big Mike flow"
      )
    } catch {
      richPlanTask?.cancel()
      richRendererTask?.cancel()
      bigMikePlanTask?.cancel()
      bigMikeRendererTask?.cancel()

      if let richPlayback, let richCompletionTask {
        await richPlayback.qwenComputeFailed(
          expectedSegmentCount: richExpectedSegmentCount ?? 0,
          reason: error.localizedDescription
        )
        await richCompletionTask.value
        print(
          """
          [TuringScriptPoint02] failure cleanup preserved active Rich playback
            prerecordingAllowedToFinish: true
            activePlaybackCancelled: false
            expectedGeneratedSegmentCount: \(richExpectedSegmentCount ?? 0)
          """)
      } else if let richPlayback {
        await richPlayback.runCancelled(
          reason: "scriptPoint02And03FailedBeforeRichPrerecordingQueued"
        )
      }

      // If ScriptPoint03's authored Big Mike PR already started, let that
      // valid Story media reach its actual completion even if generated
      // continuation fails. Otherwise cancel the unstarted owner.
      if let scriptPoint03CompletionTask {
        await scriptPoint03CompletionTask.value
      } else if let scriptPoint03Playback {
        await scriptPoint03Playback.runCancelled(
          reason: "scriptPoint02And03FailedBeforePoint03Playback"
        )
      }

      await TuringWalkieCommsFXController.shared.stopAll(
        reason: "scriptPoint02And03Failed"
      )

      print(
        """
        [TuringScriptPointFlow] failed
          error: \(error.localizedDescription)
        """)

      return .failed(error.localizedDescription)
    }
  }

  private static func validate(
    point02: TuringWalkieScriptPointDescriptor,
    point03: TuringWalkieScriptPointDescriptor,
    richPrerecording: TuringPrerecordingDescriptor,
    bigMikePrerecording: TuringPrerecordingDescriptor,
    richTrigger: TuringVoicePromptTriggerDescriptor,
    bigMikeTrigger: TuringVoicePromptTriggerDescriptor
  ) throws {
    guard point02.prerecordingOutputContext == .walkieOutgoingGlobal,
      point02.responseSpeakerID == TuringRichVoiceIdentity.speakerID,
      richPrerecording.speaker == TuringRichVoiceIdentity.speakerID,
      richPrerecording.voiceID == TuringRichVoiceIdentity.voiceID,
      richTrigger.speakerID == TuringRichVoiceIdentity.speakerID,
      richTrigger.voiceID == TuringRichVoiceIdentity.voiceID,
      richTrigger.characterProfileID == TuringRichVoiceIdentity.characterID,
      richTrigger.outputContext == .walkieOutgoingGlobal
    else {
      throw TuringRuntimeError.invalidConfig(
        "ScriptPoint02 must use Rich player-head voice plus spatial walkie comm SFX."
      )
    }

    guard point03.prerecordingOutputContext == .walkieSpatial,
      point03.responseSpeakerID == TuringBigMikeVoiceIdentity.speakerID,
      bigMikePrerecording.speaker == TuringBigMikeVoiceIdentity.speakerID,
      bigMikePrerecording.voiceID == TuringBigMikeVoiceIdentity.voiceID,
      bigMikeTrigger.speakerID == TuringBigMikeVoiceIdentity.speakerID,
      bigMikeTrigger.voiceID == TuringBigMikeVoiceIdentity.voiceID,
      bigMikeTrigger.characterProfileID == TuringBigMikeVoiceIdentity.characterID,
      bigMikeTrigger.outputContext == .walkieSpatial
    else {
      throw TuringRuntimeError.invalidConfig(
        "ScriptPoint03 must be Big Mike PR plus Big Mike spatial Turing continuation."
      )
    }

    for prerecording in [
      richPrerecording,
      bigMikePrerecording,
    ] {
      guard prerecording.transcriptMode == .manual,
        prerecording.transcript
          .trimmingCharacters(
            in: .whitespacesAndNewlines
          )
          .isEmpty == false
      else {
        throw TuringRuntimeError.invalidConfig(
          "ScriptPoint prerecording must have a reviewed manual transcript."
        )
      }
    }

    guard point02.responseComputeStart == .whenPrerecordingStarts,
      point02.responsePlaybackGate == .afterPrerecordingActualCompletion,
      point02.nextScriptPointID == point03.scriptPointID,
      point02.automaticAdvance,
      point02.conversationRemainsEnabled == false,
      point03.responseComputeStart == .whenPriorGeneratedPlanIsReady,
      point03.responsePlaybackGate == .afterPrerecordingActualCompletion,
      point03.automaticAdvance == false,
      point03.conversationRemainsEnabled
    else {
      throw TuringRuntimeError.invalidConfig(
        "ScriptPoint02/03 sequencing contract is invalid."
      )
    }

    guard richTrigger.conversationKey == TuringDialogueThreadIdentity.bigMikeRich,
      bigMikeTrigger.conversationKey == TuringDialogueThreadIdentity.bigMikeRich
    else {
      throw TuringRuntimeError.invalidConfig(
        "ScriptPoint02/03 must use dialogue.big_mike.rich."
      )
    }
  }
}
