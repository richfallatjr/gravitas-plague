import Foundation

struct TuringFlowConversationRequest: Sendable {
    let characterID: String
    let outputRoute: TuringVoiceOutputContext
    let conversationKey: String
    let playerDictation: String
    let interactionLease: StoryInteractionLease?

    init(
        characterID: String,
        outputRoute: TuringVoiceOutputContext,
        conversationKey: String,
        playerDictation: String,
        interactionLease: StoryInteractionLease? = nil
    ) {
        self.characterID = characterID
        self.outputRoute = outputRoute
        self.conversationKey = conversationKey
        self.playerDictation = playerDictation
        self.interactionLease = interactionLease
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
            if let suppliedLease = request.interactionLease {
                try await StoryInteractionArbiter.shared.requireCurrent(
                    suppliedLease
                )
                interactionLease = suppliedLease
            } else {
                interactionLease = try await TuringHighMemoryPreflightCoordinator
                    .shared
                    .acquireInteractionLease(
                        runID: "conversation.\(UUID().uuidString)",
                        source: "conversationVoice",
                        mode: .manual
                    )
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

        let result = await runWithInteractionLease(
            request: request,
            interactionLease: interactionLease,
            inputStore: inputStore,
            onSegmentZeroReady: onSegmentZeroReady
        )
        await StoryInteractionArbiter.shared.release(
            interactionLease,
            reason: "conversationFinished"
        )
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

        let conversationRunID = UUID()
        var failureStage = "validatingPlayerDictation"

        await TuringFlowInteractionGateController
            .shared
            .beginConversation(
                conversationRunID:
                    conversationRunID
            )

        do {
            failureStage = "loadingCharacterRuntime"
            let runtime =
                try TuringCharacterRuntimeStore()
                    .require(
                        request.characterID
                    )

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
            let generatedOnly =
                try await route
                    .makeGeneratedOnlyPlayback(
                        character: runtime,
                        conversationRunID:
                            conversationRunID
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

            failureStage = "resolvingConversationInputs"
            let prerecordingTranscript =
                await inputStore.prerecordingTranscript(
                    for:
                        request.conversationKey
                )
            guard let promptVoiceStoryContext =
                await inputStore.promptVoiceStoryContext(
                    for:
                        request.conversationKey
                ) else {
                throw TuringRuntimeError.invalidConfig(
                    "Conversation requires the current promptVoice Story Context for \(request.conversationKey)."
                )
            }
            let promptVariant =
                await inputStore.promptVariant(
                    for: request.conversationKey
                )

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
            """)

            failureStage = "submittingFoundationConversationPrompt"
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
                                        runtime.characterID,
                                    userInput:
                                        text,
                                    promptContext:
                                        promptVoiceStoryContext,
                                    prerecordingTranscript:
                                        prerecordingTranscript,
                                    promptVariant:
                                        promptVariant
                                )
                        )
                    }

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
                    runtime: runtime
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
            } catch {
                await playback
                    .qwenComputeFailed(
                        expectedSegmentCount:
                            plan.segments.count,
                        reason:
                            error.localizedDescription
                    )
                await playback
                    .waitUntilPlaybackFinished()
                await route.finish(
                    descriptor:
                        syntheticDescriptor,
                    identity: identity,
                    succeeded: false
                )
                await TuringFlowInteractionGateController
                    .shared
                    .restoreMicrophoneAfterConversation(
                        conversationRunID:
                            conversationRunID
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
                await route.finish(
                    descriptor:
                        syntheticDescriptor,
                    identity: identity,
                    succeeded: false
                )
                await TuringFlowInteractionGateController
                    .shared
                    .restoreMicrophoneAfterConversation(
                        conversationRunID:
                            conversationRunID
                    )

                return .failed(
                    "Conversation generated speech was incomplete. Expected \(plan.segments.count), played \(completed), skipped \(report.skippedSegmentIndices.sorted())."
                )
            }

            await route.finish(
                descriptor:
                    syntheticDescriptor,
                identity: identity,
                succeeded: true
            )

            print("""
            [TuringFlow] conversation playback completed
              conversationRunID: \(conversationRunID.uuidString)
              conversationKey: \(request.conversationKey)
              characterID: \(runtime.characterID)
              completedGeneratedSegmentCount: \(completed)
              completionSource: actualPlaybackCompletion
            """)

            guard let pending = await TuringEpisodeFlowController.shared
                .pendingConversationAdvanceContext(
                    for: request.conversationKey
                ) else {
                await TuringFlowInteractionGateController.shared
                    .restoreMicrophoneAfterConversation(
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
            await TuringFlowInteractionGateController
                .shared
                .restoreMicrophoneAfterConversation(
                    conversationRunID:
                        conversationRunID
                )

            return .failed(
                error.localizedDescription
            )
        }
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
