import Foundation

@MainActor
private final class TuringConversationResponsePlaybackLifecycleSink:
    TuringFlowPlaybackLifecycleSink
{
    let turnID: UUID
    let playbackRunID: String
    let conversationSink: (any TuringConversationLifecycleSink)?
    private var segmentZeroStartDelivered = false

    init(
        turnID: UUID,
        playbackRunID: String,
        conversationSink: (any TuringConversationLifecycleSink)?
    ) {
        self.turnID = turnID
        self.playbackRunID = playbackRunID
        self.conversationSink = conversationSink
    }

    func receivePlaybackLifecycleEvent(
        _ event: TuringFlowPlaybackLifecycleEvent
    ) async {
        guard event.runID == playbackRunID,
              segmentZeroStartDelivered == false,
              case .generatedSegmentStarted(
                _,
                let segmentIndex,
                let handle
              ) = event,
              segmentIndex == 0 else {
            return
        }
        segmentZeroStartDelivered = true
        await conversationSink?.emit(
            .responsePlaybackStarted(
                turnID: turnID,
                handle: handle
            )
        )
    }
}

struct TuringFlowConversationRequest: Sendable {
    let conversationRunID: UUID
    let characterID: String
    let outputRoute: TuringVoiceOutputContext
    let conversationKey: String
    let playerDictation: String
    let interactionLease: StoryInteractionLease?
    let interactionSurface: StoryInteractionSurfaceID
    let immutableSeed: TuringLiveConversationSeed?
    let leasePolicy: TuringConversationLeasePolicy
    let progressionPolicy: TuringConversationProgressionPolicy
    let completionPresentation: TuringConversationCompletionPresentation
    let playbackConfiguration: TuringGeneratedPlaybackConfiguration
    let lifecycleSink: (any TuringConversationLifecycleSink)?

    init(
        conversationRunID: UUID = UUID(),
        characterID: String,
        outputRoute: TuringVoiceOutputContext,
        conversationKey: String,
        playerDictation: String,
        interactionLease: StoryInteractionLease? = nil,
        interactionSurface: StoryInteractionSurfaceID = .walkie,
        immutableSeed: TuringLiveConversationSeed? = nil,
        leasePolicy: TuringConversationLeasePolicy = .ownedByConversation,
        progressionPolicy: TuringConversationProgressionPolicy = .existingInteractiveBehavior,
        completionPresentation: TuringConversationCompletionPresentation = .restoreStableMicrophone,
        playbackConfiguration: TuringGeneratedPlaybackConfiguration = .routeDefault,
        lifecycleSink: (any TuringConversationLifecycleSink)? = nil
    ) {
        self.conversationRunID = conversationRunID
        self.characterID = characterID
        self.outputRoute = outputRoute
        self.conversationKey = conversationKey
        self.playerDictation = playerDictation
        self.interactionLease = interactionLease
        self.interactionSurface = interactionSurface
        self.immutableSeed = immutableSeed
        self.leasePolicy = leasePolicy
        self.progressionPolicy = progressionPolicy
        self.completionPresentation = completionPresentation
        self.playbackConfiguration = playbackConfiguration
        self.lifecycleSink = lifecycleSink
    }
}

enum TuringFlowConversationRunner {
    static func run(
        request: TuringFlowConversationRequest,
        inputStore: TuringConversationInputStore = .shared,
        onSegmentZeroReady:
            (@MainActor @Sendable () -> Void)? = nil
    ) async -> TuringVoiceRunResult {
        let interactionLease: StoryInteractionLease
        do {
            switch request.leasePolicy {
            case .ownedByConversation:
                if let suppliedLease = request.interactionLease {
                    try await StoryInteractionArbiter.shared.requireCurrent(
                        suppliedLease
                    )
                    interactionLease = suppliedLease
                } else {
                    interactionLease = try await TuringHighMemoryPreflightCoordinator
                        .shared
                        .acquireInteractionLease(
                            runID:
                                "conversation.\(request.conversationRunID.uuidString)",
                            source: "conversationVoice",
                            mode: .manual,
                            interactionSurface:
                                request.interactionSurface
                        )
                }

            case .borrowedFromAuthoredFlow(
                let hostFlowSequenceID,
                let hostFlowInstanceID,
                let parentLeaseID
            ):
                let suppliedLease = try TuringBorrowedAuthoredFlowLeaseValidator
                    .requireValid(
                        hostFlowSequenceID: hostFlowSequenceID,
                        hostFlowInstanceID: hostFlowInstanceID,
                        parentLeaseID: parentLeaseID,
                        suppliedLease: request.interactionLease,
                        seed: request.immutableSeed
                    )
                try await StoryInteractionArbiter.shared.requireCurrent(
                    suppliedLease
                )
                interactionLease = suppliedLease
            }
        } catch {
            let snapshot =
                await StoryInteractionArbiter.shared
                    .currentSnapshot()
            print("""
            [TuringConversationFailure] conversationVoice lease acquisition failed
              conversationKey: \(request.conversationKey)
              characterID: \(request.characterID)
              suppliedLease: \(request.interactionLease != nil)
              currentOwner: \(snapshot.exclusiveOwner?.logValue ?? "none")
              turingGate: \(snapshot.turingGate.rawValue)
              doorState: \(snapshot.doorState.rawValue)
              capabilities: \(snapshot.capabilities.map(\.rawValue).sorted())
              errorType: \(String(reflecting: type(of: error)))
              error: \(error.localizedDescription)
            """)
            return .failed(
                "Device operation failed: \(error.localizedDescription)"
            )
        }

        let musicOwnerID =
            "chapter02.conversation.\(request.conversationRunID.uuidString)"
        let ducksChapter02Music =
            Chapter02BattleMusicInteractionPolicy.ducksConversation(
                conversationKey: request.conversationKey
            )
        if ducksChapter02Music {
            _ = await Chapter02BattleMusicActor.shared.duck(
                ownerID: musicOwnerID
            )
        }

        let result = await runWithInteractionLease(
            request: request,
            interactionLease: interactionLease,
            inputStore: inputStore,
            onSegmentZeroReady: onSegmentZeroReady
        )
        if case .ownedByConversation = request.leasePolicy {
            await StoryInteractionArbiter.shared.release(
                interactionLease,
                reason: "conversationFinished"
            )
        }
        if ducksChapter02Music {
            await Chapter02BattleMusicActor.shared.restore(
                ownerID: musicOwnerID
            )
        }
        return result
    }

    private static func runWithInteractionLease(
        request: TuringFlowConversationRequest,
        interactionLease: StoryInteractionLease,
        inputStore: TuringConversationInputStore,
        onSegmentZeroReady:
            (@MainActor @Sendable () -> Void)?
    ) async -> TuringVoiceRunResult {
        let text = request.playerDictation
            .trimmingCharacters(
                in: .whitespacesAndNewlines
            )

        guard text.isEmpty == false else {
            return .failed(
                "Conversation requires nonempty player dictation."
            )
        }

        let conversationRunID =
            request.conversationRunID
        var failureStage = "validatingPlayerDictation"

        switch request.leasePolicy {
        case .ownedByConversation:
            await TuringFlowInteractionGateController
                .shared
                .beginConversation(
                    conversationRunID:
                        conversationRunID,
                    surfaceID:
                        request.interactionSurface
                )

        case .borrowedFromAuthoredFlow(
            let hostFlowSequenceID,
            let hostFlowInstanceID,
            _
        ):
            print("""
            [TuringLiveConversation] authored interaction gate preserved
              conversationRunID: \(conversationRunID.uuidString)
              hostFlowSequenceID: \(hostFlowSequenceID.uuidString)
              hostFlowInstanceID: \(hostFlowInstanceID.uuidString)
              seedOriginSequenceID: \(request.immutableSeed?.parentFlowSequenceID.uuidString ?? "none")
              seedOriginFlowInstanceID: \(request.immutableSeed?.parentFlowInstanceID.uuidString ?? "none")
              surface: \(request.interactionSurface.rawValue)
              gateOwnership: inheritedFromAuthoredFlow
            """)
        }

        do {
            failureStage = "loadingCharacterRuntime"
            let runtime =
                try TuringCharacterRuntimeStore()
                    .require(
                        request.characterID
                    )

            if let seed = request.immutableSeed {
                guard seed.characterID == runtime.characterID,
                      seed.outputRoute == request.outputRoute,
                      seed.conversationKey == request.conversationKey,
                      seed.interactionSurface == request.interactionSurface else {
                    throw TuringRuntimeError.invalidConfig(
                        "Live conversation immutable seed does not match the requested runtime."
                    )
                }
            }

            guard runtime.supports(
                request.outputRoute
            ) else {
                throw TuringRuntimeError
                    .invalidConfig(
                        "\(runtime.characterID) does not support \(request.outputRoute.rawValue)."
                    )
            }

            failureStage = "resolvingOutputRoute"
            let route =
                try await TuringDefaultFlowRouteResolver()
                    .require(
                        request.outputRoute
                    )

            failureStage = "creatingGeneratedPlayback"
            // Every live TTS response carries its upcoming speaker and surface,
            // even when the interaction did not originate from an immutable
            // authored seed. Mind's Eye needs that child identity during Qwen
            // compute so it can keep or prepare the correct idle portrait
            // before filler/generated audio is ready. The parent remains
            // optional because debug and unseeded conversation entry points do
            // not have an authored parent to identify.
            let spokenPresentationContinuity =
                TuringConversationCharacterID(rawValue: runtime.characterID)
                    .map { generatedSpeaker in
                        TuringSpokenPresentationContinuity(
                            continuityID: UUID(),
                            parent: request.immutableSeed.map { seed in
                                .init(
                                    playbackRunID: seed.parentPlaybackRunID,
                                    flowInstanceID: seed.parentFlowInstanceID,
                                    mediaIdentity:
                                        "authored.\(seed.authoredMediaRole.rawValue)." +
                                        seed.authoredMediaItemID
                                )
                            },
                            childPlaybackRunID: conversationRunID.uuidString,
                            childFlowInstanceID: conversationRunID,
                            speakerCharacterID: generatedSpeaker,
                            interactionSurface: request.interactionSurface
                        )
                    }
            let generatedOnly =
                try await route
                    .makeGeneratedOnlyPlayback(
                        character: runtime,
                        conversationRunID:
                            conversationRunID,
                        interactionSurface:
                            request.interactionSurface,
                        spokenPresentationContinuity:
                            spokenPresentationContinuity
                    )
            let playback =
                generatedOnly.playback
            let identity =
                generatedOnly.identity
            let syntheticDescriptor =
                generatedOnly.descriptor

            failureStage = "validatingOutputRoute"
            try await route.validate(
                descriptor:
                    syntheticDescriptor,
                character: runtime
            )
            await playback
                .configureFlowIdentity(
                    identity
                )
            await playback.configureGeneratedPlayback(
                request.playbackConfiguration
            )
            let responsePlaybackLifecycleSink =
                await TuringConversationResponsePlaybackLifecycleSink(
                    turnID: conversationRunID,
                    playbackRunID: identity.playbackRunID,
                    conversationSink: request.lifecycleSink
                )
            defer {
                withExtendedLifetime(responsePlaybackLifecycleSink) {}
            }
            await playback.setPlaybackLifecycleSink(
                responsePlaybackLifecycleSink
            )
            await request.lifecycleSink?.responsePlaybackOwnerReady(
                turnID: conversationRunID,
                playback: playback
            )
            await request.lifecycleSink?.emit(
                .responsePlaybackOwnerReady(
                    turnID: conversationRunID,
                    playbackRunID: identity.playbackRunID
                )
            )

            failureStage = "resolvingConversationInputs"
            let prerecordingTranscript: String
            let immediateDeviceSpeakerID: String
            let targetPriorTranscript: String?
            let targetContextPosition: TuringConversationTargetContextPosition
            let promptVoiceStoryContext: String
            let promptVariant: TuringConversationPromptVariant
            let characterProfileID: String
            if let seed = request.immutableSeed {
                prerecordingTranscript = seed.prerecordingTranscript
                immediateDeviceSpeakerID =
                    seed.immediateDeviceContext.speakerCharacterID.rawValue
                targetPriorTranscript = seed.targetContext.priorTargetTranscript
                targetContextPosition = seed.targetContext.selectionPosition
                promptVoiceStoryContext = seed.promptVoiceStoryContext
                promptVariant = seed.promptVariant
                characterProfileID = seed.characterProfileID
                print("""
                [TuringLiveConversation] immutable prompt seed selected
                  seedID: \(seed.seedID.uuidString)
                  prerecordingID: \(seed.prerecordingID)
                  prerecordingSHA256: \(seed.prerecordingProof.sha256)
                  voicePromptID: \(seed.voicePromptID)
                  voicePromptSHA256: \(seed.voicePromptProof.sha256)
                  storyContextSHA256: \(TuringFlowHash.sha256(seed.promptVoiceStoryContext))
                  characterProfileID: \(seed.characterProfileID)
                  promptVariant: \(seed.promptVariant.rawValue)
                  conversationKey: \(seed.conversationKey)
                  interactionSurface: \(seed.interactionSurface.rawValue)
                  immediateDeviceSpeakerID: \(seed.immediateDeviceContext.speakerCharacterID.rawValue)
                  targetCharacterID: \(seed.targetContext.targetCharacterID.rawValue)
                  targetContextPosition: \(seed.targetContext.selectionPosition.rawValue)
                  targetPriorTranscriptIncluded: \(seed.targetContext.priorTargetTranscript != nil)
                  dialogueHistoryIncluded: false
                """)
            } else {
                prerecordingTranscript = await inputStore.prerecordingTranscript(
                    for: request.conversationKey
                )
                guard let mutableContext = await inputStore.promptVoiceStoryContext(
                    for: request.conversationKey
                ) else {
                    throw TuringRuntimeError.invalidConfig(
                        "Conversation requires the current promptVoice Story Context for \(request.conversationKey)."
                    )
                }
                promptVoiceStoryContext = mutableContext
                promptVariant = await inputStore.promptVariant(
                    for: request.conversationKey
                )
                characterProfileID = await inputStore.characterProfileID(
                    for: request.conversationKey
                ) ?? runtime.characterID
                immediateDeviceSpeakerID = runtime.characterID
                targetPriorTranscript = nil
                targetContextPosition = .currentOrPrior
            }

            print("""
            [TuringFlow] conversation promptVoice Story Context resolved
              conversationRunID: \(conversationRunID.uuidString)
              conversationKey: \(request.conversationKey)
              source: currentAuthoredPromptVoiceStoryContext
              promptContextSHA256: \(TuringFlowHash.sha256(promptVoiceStoryContext))
              fabricatedStoryContextIncluded: false
              fabricatedEmotionIncluded: false
              dialogueHistoryIncluded: false
              promptVariant: \(promptVariant.rawValue)
              characterProfileID: \(characterProfileID)
            """)

            failureStage = "submittingFoundationConversationPrompt"
            await request.lifecycleSink?.emit(
                .foundationStarted(turnID: conversationRunID)
            )
            let foundationContext =
                TuringFoundationRequestContext(
                    flowRunID:
                        conversationRunID.uuidString,
                    scriptPointID:
                        promptVariant == .scriptPoint05
                            ? "prologue.scriptPoint05"
                            : nil,
                    stageID:
                        "conversationVoice",
                    sectionIndex:
                        nil
                )
            let plan =
                try await TuringFoundationRequestScope
                    .$current
                    .withValue(
                        foundationContext
                    ) {
                        try await TuringDialogueService()
                            .generateConversationNoBible(
                                ConversationPromptNoBibleRequest(
                                    id:
                                        "conversation.\(conversationRunID.uuidString)",
                                    characterProfileID:
                                        characterProfileID,
                                    userInput:
                                        text,
                                    promptContext:
                                        promptVoiceStoryContext,
                                    immediateDeviceTranscript:
                                        prerecordingTranscript,
                                    immediateDeviceSpeakerID:
                                        immediateDeviceSpeakerID,
                                    targetPriorTranscript:
                                        targetPriorTranscript,
                                    targetContextPosition:
                                        targetContextPosition,
                                    promptVariant:
                                        promptVariant
                                )
                        )
                    }

            await request.lifecycleSink?.emit(
                .foundationCompleted(
                    turnID: conversationRunID,
                    segmentCount: plan.segments.count
                )
            )

            guard plan.segments.isEmpty == false else {
                throw TuringRuntimeError
                    .foundationJSONGateFailed(
                        "Conversation returned no speech segments."
                    )
            }

            await playback.beginRun(
                runID:
                    identity.playbackRunID,
                expectedSegmentCount:
                    plan.segments.count
            )

            let firstReady =
                TuringFlowSegmentZeroNotifier(
                    callback:
                        onSegmentZeroReady
                )
            let renderer =
                TuringCharacterQwenRenderer(
                    runtime: runtime,
                    spokenPresentationContinuity:
                        spokenPresentationContinuity
                )

            let report:
                TuringCharacterRenderReport

            do {
                report =
                    try await renderer.render(
                        segments: plan.segments,
                        runID:
                            identity
                                .playbackRunID,
                        onStarted: { index in
                            await playback
                                .qwenComputeStarted(
                                    segmentIndex:
                                        index
                                )
                        },
                        onFinished: {
                            index,
                            audio in

                            await request.lifecycleSink?.emit(
                                .segmentPublished(
                                    turnID: conversationRunID,
                                    index: index
                                )
                            )
                            if index == 0 {
                                await request.lifecycleSink?.emit(
                                    .segmentZeroPrepared(
                                        turnID: conversationRunID
                                    )
                                )
                            }
                            await firstReady
                                .notifyIfNeeded(
                                    segmentIndex:
                                        index
                                )
                            await playback
                                .qwenComputeFinished(
                                    segmentIndex:
                                        index,
                                    audio: audio
                                )
                        },
                        onSkipped: {
                            index,
                            reason in

                            await playback
                                .qwenComputeSkipped(
                                    segmentIndex:
                                        index,
                                    reason: reason
                                )
                        }
                    )

                await playback
                    .qwenComputeAllFinished()
                await request.lifecycleSink?.emit(
                    .allTTSComputeFinished(
                        turnID: conversationRunID,
                        expectedCount: plan.segments.count,
                        skippedIndices: report.skippedSegmentIndices.sorted()
                    )
                )
            } catch {
                await request.lifecycleSink?.emit(
                    .failed(
                        turnID: conversationRunID,
                        stage: "qwen",
                        message: error.localizedDescription
                    )
                )
                await playback
                    .qwenComputeFailed(
                        expectedSegmentCount:
                            plan.segments.count,
                        reason:
                            error.localizedDescription
                    )
                await playback
                    .waitUntilPlaybackFinished()
                try? await route.finish(
                    descriptor:
                        syntheticDescriptor,
                    identity: identity,
                    succeeded: false
                )
                await restoreMicrophoneIfOwned(
                    request: request,
                    conversationRunID: conversationRunID
                )

                return .failed(
                    "Conversation Qwen generation failed: \(error.localizedDescription)"
                )
            }

            await playback
                .waitUntilPlaybackFinished()

            let completed =
                await playback
                    .completedGeneratedSegmentCount()

            guard report.isCompleteSuccess,
                  completed ==
                    plan.segments.count else {
                try? await route.finish(
                    descriptor:
                        syntheticDescriptor,
                    identity: identity,
                    succeeded: false
                )
                await restoreMicrophoneIfOwned(
                    request: request,
                    conversationRunID: conversationRunID
                )

                return .failed(
                    "Conversation generated speech was incomplete. Expected \(plan.segments.count), played \(completed), skipped \(report.skippedSegmentIndices.sorted())."
                )
            }

            try await route.finish(
                descriptor:
                    syntheticDescriptor,
                identity: identity,
                succeeded: true
            )

            await request.lifecycleSink?.emit(
                .responsePlaybackCompleted(turnID: conversationRunID)
            )

            print("""
            [TuringFlow] conversation playback completed
              conversationRunID: \(conversationRunID.uuidString)
              conversationKey: \(request.conversationKey)
              characterID: \(runtime.characterID)
              completedGeneratedSegmentCount: \(completed)
              completionSource: actualPlaybackCompletion
            """)

            if case .neverAdvanceStory = request.progressionPolicy {
                return .succeeded(
                    "Finished \(runtime.displayName) live conversation response"
                )
            }

            guard let pending = await TuringEpisodeFlowController.shared
                .pendingConversationAdvanceContext(
                    for: request.conversationKey
                ) else {
                await restoreMicrophoneIfOwned(
                    request: request,
                    conversationRunID: conversationRunID
                )
                return .succeeded(
                    "Finished \(runtime.displayName) conversation response"
                )
            }

            try await TuringEpisodeFlowController.shared
                .notifyConversationPlaybackCompleted(
                    TuringConversationPlaybackCompletionEvent(
                        eventID: UUID(),
                        conversationRunID: conversationRunID,
                        conversationKey: request.conversationKey,
                        parentScriptPointID: pending.parentScriptPointID
                    )
                )

            if let progression = await TuringEpisodeFlowController.shared
                .conversationPlaybackCompleted(
                    conversationKey: request.conversationKey,
                    interactionLease: interactionLease
                ) {
                if progression.succeeded == false {
                    await TuringFlowInteractionGateController
                        .shared
                        .restoreMicrophoneAfterProgressionFailure(
                            conversationRunID:
                                conversationRunID,
                            surfaceID:
                                request.interactionSurface,
                            reason:
                                progression.pickerStatus
                        )
                }
                return progression
            }

            throw TuringRuntimeError.invalidConfig(
                "Conversation checkpoint was saved but authored progression was unavailable."
            )
        } catch {
            await request.lifecycleSink?.emit(
                .failed(
                    turnID: conversationRunID,
                    stage: failureStage,
                    message: error.localizedDescription
                )
            )
            print("""
            [TuringConversationFailure] conversationVoice failed
              conversationRunID: \(conversationRunID.uuidString)
              conversationKey: \(request.conversationKey)
              characterID: \(request.characterID)
              outputRoute: \(request.outputRoute.rawValue)
              failureStage: \(failureStage)
              errorType: \(String(reflecting: type(of: error)))
              error: \(error.localizedDescription)
            """)
            await TuringWalkieCommsFXController
                .shared
                .stopSendingLeadIn(
                    reason:
                        "conversationFailed.\(conversationRunID.uuidString)"
                )
            await TuringWalkieCommsFXController
                .shared
                .stopAmbientWalkieStatic(
                    reason:
                        "conversationFailed.\(conversationRunID.uuidString)"
                )
            await restoreMicrophoneIfOwned(
                request: request,
                conversationRunID: conversationRunID
            )

            return .failed(
                error.localizedDescription
            )
        }
    }

    private static func restoreMicrophoneIfOwned(
        request: TuringFlowConversationRequest,
        conversationRunID: UUID
    ) async {
        guard case .restoreStableMicrophone =
                request.completionPresentation else {
            return
        }
        await TuringFlowInteractionGateController.shared
            .restoreMicrophoneAfterConversation(
                conversationRunID: conversationRunID,
                surfaceID: request.interactionSurface
            )
    }
}

private actor TuringFlowSegmentZeroNotifier {
    private let callback:
        (@MainActor @Sendable () -> Void)?
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
              notified == false else {
            return
        }

        notified = true
        await callback?()
    }
}
