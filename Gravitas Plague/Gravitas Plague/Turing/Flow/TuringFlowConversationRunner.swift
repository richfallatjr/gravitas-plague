import Foundation

struct TuringFlowConversationRequest: Sendable {
    let characterID: String
    let outputRoute: TuringVoiceOutputContext
    let conversationKey: String
    let playerDictation: String
    let episodeStateForWordsOnly: String
    let emotion: String
}

enum TuringFlowConversationRunner {
    static func run(
        request: TuringFlowConversationRequest,
        seedStore: TuringConversationSeedStore = .shared,
        historyStore: TuringDialogueHistoryStore = .shared,
        onSegmentZeroReady:
            (@MainActor @Sendable () -> Void)? = nil
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

        await TuringFlowInteractionGateController
            .shared
            .beginConversation(
                conversationRunID:
                    conversationRunID
            )

        do {
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

            let route =
                try await TuringDefaultFlowRouteResolver()
                    .require(
                        request.outputRoute
                    )

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

            try await route.validate(
                descriptor:
                    syntheticDescriptor,
                character: runtime
            )
            await playback
                .configureFlowIdentity(
                    identity
                )

            let prerecordingTranscript =
                await seedStore.prerecordingTranscript(
                    for:
                        request.conversationKey
                )

            let plan =
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
                                """
                                Story context:
                                \(request.episodeStateForWordsOnly)

                                Emotional tone:
                                \(request.emotion)
                                """,
                            prerecordingTranscript:
                                prerecordingTranscript
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

            await historyStore.appendConversation(
                conversationKey:
                    request.conversationKey,
                playerText: text,
                responseSpeakerID:
                    runtime.characterID,
                responseSegments:
                    plan.segments,
                conversationRunID:
                    conversationRunID
            )

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
                    conversationKey: request.conversationKey
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
