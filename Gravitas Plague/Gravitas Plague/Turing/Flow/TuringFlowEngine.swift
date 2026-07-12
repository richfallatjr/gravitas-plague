import Foundation

protocol TuringPrerecordingLoading: Sendable {
    func descriptor(
        id: String
    ) throws -> TuringPrerecordingDescriptor

    func audioURL(
        for descriptor: TuringPrerecordingDescriptor
    ) throws -> URL
}

extension TuringPrerecordingStore:
    TuringPrerecordingLoading
{
}

protocol TuringVoicePromptTriggerLoading: Sendable {
    func descriptor(
        id: String
    ) throws -> TuringVoicePromptTriggerDescriptor
}

extension TuringVoicePromptTriggerStore:
    TuringVoicePromptTriggerLoading
{
}

protocol TuringFlowVoicePromptGenerating: Sendable {
    func generateVoicePrompt(
        _ request: VoicePromptRequest
    ) async throws -> TuringVoicePromptPlan
}

extension TuringDialogueService:
    TuringFlowVoicePromptGenerating
{
}

struct TuringCharacterRuntimeStore:
    TuringCharacterRuntimeProviding,
    Sendable
{
    func require(
        _ characterID: String
    ) throws -> TuringCharacterRuntimeDefinition {
        try TuringCharacterRuntimeRegistry()
            .require(characterID)
    }
}

actor TuringFlowEngine {
    static let shared = TuringFlowEngine()

    private let descriptorStore:
        any TuringFlowDescriptorLoading
    private let prerecordingStore:
        any TuringPrerecordingLoading
    private let voicePromptStore:
        any TuringVoicePromptTriggerLoading
    private let characterRuntimeStore:
        any TuringCharacterRuntimeProviding
    private let dialogueServiceFactory:
        @Sendable () -> any TuringFlowVoicePromptGenerating
    private let routeResolver:
        any TuringFlowRouteResolving
    private let rendererFactory:
        any TuringCharacterRendererMaking
    private let seedStore:
        TuringConversationSeedStore
    private let historyStore:
        TuringDialogueHistoryStore

    private var activeFlow:
        TuringFlowIdentity?

    init(
        descriptorStore:
            any TuringFlowDescriptorLoading =
                TuringFlowDescriptorStore(),
        prerecordingStore:
            any TuringPrerecordingLoading =
                TuringPrerecordingStore(),
        voicePromptStore:
            any TuringVoicePromptTriggerLoading =
                TuringVoicePromptTriggerStore(),
        characterRuntimeStore:
            any TuringCharacterRuntimeProviding =
                TuringCharacterRuntimeStore(),
        dialogueServiceFactory:
            @escaping @Sendable () -> any TuringFlowVoicePromptGenerating = {
                TuringDialogueService(
                    runner: TuringFoundationModelsRunner()
                )
            },
        routeResolver:
            any TuringFlowRouteResolving =
                TuringDefaultFlowRouteResolver(),
        rendererFactory:
            any TuringCharacterRendererMaking =
                TuringCharacterQwenRendererFactory(),
        seedStore:
            TuringConversationSeedStore = .shared,
        historyStore:
            TuringDialogueHistoryStore = .shared
    ) {
        self.descriptorStore = descriptorStore
        self.prerecordingStore = prerecordingStore
        self.voicePromptStore = voicePromptStore
        self.characterRuntimeStore =
            characterRuntimeStore
        self.dialogueServiceFactory =
            dialogueServiceFactory
        self.routeResolver = routeResolver
        self.rendererFactory = rendererFactory
        self.seedStore = seedStore
        self.historyStore = historyStore
    }

    func run(
        scriptPointID: String,
        trigger: TuringFlowTriggerSource
    ) async -> TuringFlowResult {
        guard activeFlow == nil else {
            return .ignored(
                .ignoredAnotherFlowActive,
                message:
                    "Ignored \(scriptPointID): another Turing Flow is active."
            )
        }

        let descriptor: TuringFlowDescriptor
        let prerecording:
            TuringPrerecordingDescriptor
        let voicePrompt:
            TuringVoicePromptTriggerDescriptor
        let character:
            TuringCharacterRuntimeDefinition
        let prerecordingURL: URL

        do {
            descriptor =
                try descriptorStore.require(
                    scriptPointID
                )

            guard trigger.kind ==
                    descriptor.trigger.kind ||
                    trigger.kind == .manualDebug else {
                return .ignored(
                    .triggerMismatch,
                    message:
                        "Trigger \(trigger.logValue) does not match \(descriptor.trigger.kind.rawValue) for \(scriptPointID)."
                )
            }

            prerecording =
                try prerecordingStore.descriptor(
                    id:
                        descriptor.transmission
                            .prerecordingID
                )
            prerecordingURL =
                try prerecordingStore.audioURL(
                    for: prerecording
                )
            voicePrompt =
                try voicePromptStore.descriptor(
                    id:
                        descriptor.transmission
                            .voicePromptID
                )
            character =
                try characterRuntimeStore.require(
                    descriptor.transmission
                        .characterID
                )
        } catch {
            return TuringFlowResult(
                outcome: .configurationFailed,
                identity: nil,
                expectedGeneratedSegmentCount: 0,
                completedGeneratedSegmentCount: 0,
                skippedGeneratedSegmentIndices: [],
                message:
                    "Could not load \(scriptPointID): \(error.localizedDescription)"
            )
        }

        let identity = TuringFlowIdentity(
            scriptPointID:
                descriptor.scriptPointID,
            characterID:
                character.characterID,
            prerecordingID:
                prerecording.prerecordingID,
            voicePromptID:
                voicePrompt.voicePromptID
        )

        activeFlow = identity
        defer {
            activeFlow = nil
        }

        var playback:
            (any TuringFlowPlaybackControlling)?
        var completionTask:
            Task<Void, Never>?
        var planTask:
            Task<TuringVoicePromptPlan, Error>?
        var route:
            (any TuringFlowRouteRuntime)?
        var expectedSegmentCount = 0

        await TuringFlowInteractionGateController
            .shared
            .beginFlow(identity: identity)

        TuringFlowLog.event(
            "point started",
            identity: identity,
            fields: [
                ("trigger", trigger.logValue),
                (
                    "outputRoute",
                    descriptor.transmission
                        .outputRoute.rawValue
                )
            ]
        )

        do {
            try Self.validateIdentity(
                descriptor: descriptor,
                prerecording: prerecording,
                voicePrompt: voicePrompt,
                character: character
            )

            let resolvedRoute =
                try await routeResolver.require(
                    descriptor.transmission
                        .outputRoute
                )
            route = resolvedRoute

            try await resolvedRoute.validate(
                descriptor: descriptor,
                character: character
            )

            let flowContext =
                await historyStore
                    .makeVoicePromptContext(
                        conversationKey:
                            descriptor.transmission
                                .conversationKey,
                        historyLimit: 6,
                        prerecording:
                            prerecording
                    )

            await seedStore.updatePrerecording(
                id:
                    prerecording
                        .prerecordingID,
                transcript:
                    prerecording.transcript,
                for:
                    descriptor.transmission
                        .conversationKey
            )

            func makePlanTask()
                -> Task<
                    TuringVoicePromptPlan,
                    Error
                > {
                let dialogueService =
                    dialogueServiceFactory()

                TuringFlowLog.event(
                    "Foundation started",
                    identity: identity,
                    fields: [
                        (
                            "authoredPRTranscriptSHA256",
                            TuringFlowHash.sha256(
                                prerecording
                                    .transcript
                            )
                        ),
                        (
                            "dialogueHistoryTurnCount",
                            String(
                                flowContext
                                    .dialogueHistory
                                    .count
                                )
                        ),
                        (
                            "freshDialogueService",
                            "true"
                        )
                    ]
                )

                return Task.detached(
                    priority: .userInitiated
                ) {
                    try await dialogueService
                        .generateVoicePrompt(
                            VoicePromptRequest(
                                id:
                                    voicePrompt
                                        .voicePromptID,
                                speaker:
                                    character
                                        .displayName,
                                voiceID:
                                    character.voiceID,
                                voiceVariantID:
                                    prerecording
                                        .voiceVariantID,
                                characterProfileID:
                                    voicePrompt
                                        .characterProfileID,
                                intent:
                                    voicePrompt.intent,
                                emotion:
                                    voicePrompt.emotion,
                                prerecordingTranscript:
                                    prerecording
                                        .transcript,
                                voicePromptSeedIntent:
                                    voicePrompt
                                        .seedIntent,
                                flowContext:
                                    flowContext
                            )
                        )
                }
            }

            switch descriptor.transmission.computeStart {
            case .beforePrerecording,
                 .afterPriorPoint:
                let task = makePlanTask()
                planTask = task

            case .withPrerecording:
                break
            }

            await resolvedRoute
                .runFixedLeadInIfNeeded(
                    descriptor: descriptor,
                    identity: identity
                )

            try await resolvedRoute
                .playOpenIfNeeded(
                    descriptor: descriptor,
                    identity: identity
                )

            if planTask == nil {
                planTask = makePlanTask()
            }

            let createdPlayback =
                try await resolvedRoute.makePlayback(
                    descriptor: descriptor,
                    character: character,
                    identity: identity
                )
            playback = createdPlayback

            await createdPlayback
                .configureFlowIdentity(identity)
            await createdPlayback.beginRun(
                runID:
                    identity.playbackRunID,
                expectedSegmentCount: nil
            )
            await createdPlayback
                .enqueuePrerecording(
                    id:
                        prerecording
                            .prerecordingID,
                    fileURL:
                        prerecordingURL
                )

            let createdCompletionTask =
                Task {
                    await createdPlayback
                        .waitUntilPlaybackFinished()
                }
            completionTask =
                createdCompletionTask

            let plan: TuringVoicePromptPlan

            do {
                guard let planTask else {
                    throw TuringRuntimeError
                        .invalidConfig(
                            "Turing Flow Foundation task was not created."
                        )
                }
                plan = try await planTask.value
            } catch {
                await createdPlayback
                    .setExpectedGeneratedSegmentCount(
                        0
                    )
                await createdPlayback
                    .qwenComputeAllFinished()
                await createdCompletionTask.value

                await historyStore
                    .appendCompletedScriptPoint(
                        identity: identity,
                        prerecording:
                            prerecording,
                        generatedSegments: [],
                        conversationKey:
                            descriptor.transmission
                                .conversationKey,
                        skippedSegmentIndices: []
                    )

                await resolvedRoute.finish(
                    descriptor: descriptor,
                    identity: identity,
                    succeeded: false
                )
                await TuringFlowInteractionGateController
                    .shared
                    .failFlow(
                        identity: identity,
                        reason:
                            "generatedPlanFailed"
                    )

                TuringFlowLog.event(
                    "point failed",
                    identity: identity,
                    fields: [
                        (
                            "stage",
                            "generatedPlanFailed"
                        ),
                        (
                            "activePrerecordingCancelled",
                            "false"
                        ),
                        (
                            "error",
                            error.localizedDescription
                        )
                    ]
                )

                return TuringFlowResult(
                    outcome:
                        .generatedPlanFailed,
                    identity: identity,
                    expectedGeneratedSegmentCount:
                        0,
                    completedGeneratedSegmentCount:
                        0,
                    skippedGeneratedSegmentIndices:
                        [],
                    message:
                        "\(scriptPointID) PR completed, but Foundation voicePrompt failed: \(error.localizedDescription)"
                )
            }

            expectedSegmentCount =
                plan.segments.count

            guard expectedSegmentCount > 0 else {
                throw TuringRuntimeError
                    .invalidConfig(
                        "\(scriptPointID) voicePrompt returned no speech segments."
                    )
            }

            TuringFlowLog.event(
                "Foundation response accepted",
                identity: identity,
                fields: [
                    (
                        "generatedSegmentCount",
                        String(
                            expectedSegmentCount
                        )
                    ),
                    (
                        "conversationSeedID",
                        plan.conversationSeed
                            .seedID
                    )
                ]
            )

            await seedStore.updateSeed(
                plan.conversationSeed,
                for:
                    descriptor.transmission
                        .conversationKey
            )

            await createdPlayback
                .setExpectedGeneratedSegmentCount(
                    expectedSegmentCount
                )

            let renderer =
                rendererFactory.make(
                    runtime: character
                )

            let renderReport:
                TuringCharacterRenderReport

            do {
                renderReport =
                    try await renderer.render(
                        segments: plan.segments,
                        runID:
                            identity
                                .playbackRunID,
                        onStarted: { index in
                            await createdPlayback
                                .qwenComputeStarted(
                                    segmentIndex:
                                        index
                                )
                        },
                        onFinished: {
                            index,
                            audio in

                            await createdPlayback
                                .qwenComputeFinished(
                                    segmentIndex:
                                        index,
                                    audio: audio
                                )
                        },
                        onSkipped: {
                            index,
                            reason in

                            await createdPlayback
                                .qwenComputeSkipped(
                                    segmentIndex:
                                        index,
                                    reason: reason
                                )
                        }
                    )
                await createdPlayback
                    .qwenComputeAllFinished()
            } catch {
                await createdPlayback
                    .qwenComputeFailed(
                        expectedSegmentCount:
                            expectedSegmentCount,
                        reason:
                            error.localizedDescription
                    )
                await createdCompletionTask.value

                await historyStore
                    .appendCompletedScriptPoint(
                        identity: identity,
                        prerecording:
                            prerecording,
                        generatedSegments: [],
                        conversationKey:
                            descriptor.transmission
                                .conversationKey,
                        skippedSegmentIndices:
                            Set(
                                0..<expectedSegmentCount
                            )
                    )

                await resolvedRoute.finish(
                    descriptor: descriptor,
                    identity: identity,
                    succeeded: false
                )
                await TuringFlowInteractionGateController
                    .shared
                    .failFlow(
                        identity: identity,
                        reason:
                            "generatedAudioFailed"
                    )

                let completed =
                    await createdPlayback
                        .completedGeneratedSegmentCount()

                TuringFlowLog.event(
                    "point failed",
                    identity: identity,
                    fields: [
                        (
                            "stage",
                            "generatedAudioFailed"
                        ),
                        (
                            "activePrerecordingCancelled",
                            "false"
                        ),
                        (
                            "completedGeneratedSegmentCount",
                            String(completed)
                        ),
                        (
                            "error",
                            error.localizedDescription
                        )
                    ]
                )

                return TuringFlowResult(
                    outcome:
                        .generatedAudioFailed,
                    identity: identity,
                    expectedGeneratedSegmentCount:
                        expectedSegmentCount,
                    completedGeneratedSegmentCount:
                        completed,
                    skippedGeneratedSegmentIndices:
                        Array(
                            0..<expectedSegmentCount
                        ),
                    message:
                        "\(scriptPointID) PR completed, but Qwen failed: \(error.localizedDescription)"
                )
            }

            await createdCompletionTask.value

            let completed =
                await createdPlayback
                    .completedGeneratedSegmentCount()
            let skipped =
                renderReport
                    .skippedSegmentIndices

            await historyStore
                .appendCompletedScriptPoint(
                    identity: identity,
                    prerecording:
                        prerecording,
                    generatedSegments:
                        plan.segments,
                    conversationKey:
                        descriptor.transmission
                            .conversationKey,
                    skippedSegmentIndices:
                        skipped
                )

            guard renderReport.isCompleteSuccess,
                  completed ==
                    expectedSegmentCount else {
                await resolvedRoute.finish(
                    descriptor: descriptor,
                    identity: identity,
                    succeeded: false
                )
                await TuringFlowInteractionGateController
                    .shared
                    .failFlow(
                        identity: identity,
                        reason:
                            "partialGeneratedFailure"
                    )

                TuringFlowLog.event(
                    "point failed",
                    identity: identity,
                    fields: [
                        (
                            "stage",
                            "partialGeneratedFailure"
                        ),
                        (
                            "expectedGeneratedSegmentCount",
                            String(
                                expectedSegmentCount
                            )
                        ),
                        (
                            "completedGeneratedSegmentCount",
                            String(completed)
                        ),
                        (
                            "skippedGeneratedSegmentIndices",
                            "\(skipped.sorted())"
                        )
                    ]
                )

                return TuringFlowResult(
                    outcome:
                        .partialGeneratedFailure,
                    identity: identity,
                    expectedGeneratedSegmentCount:
                        expectedSegmentCount,
                    completedGeneratedSegmentCount:
                        completed,
                    skippedGeneratedSegmentIndices:
                        skipped.sorted(),
                    message:
                        "\(scriptPointID) completed its PR but generated speech was partial."
                )
            }

            try await resolvedRoute
                .playSendIfNeeded(
                    descriptor: descriptor,
                    identity: identity
                )

            await resolvedRoute.finish(
                descriptor: descriptor,
                identity: identity,
                succeeded: true
            )

            await TuringFlowInteractionGateController
                .shared
                .applyCompletionGate(
                    descriptor.progression
                        .interactionGateAfterCompletion,
                    identity: identity
                )

            TuringFlowLog.event(
                "point completed",
                identity: identity,
                fields: [
                    (
                        "expectedGeneratedSegmentCount",
                        String(
                            expectedSegmentCount
                        )
                    ),
                    (
                        "completedGeneratedSegmentCount",
                        String(completed)
                    ),
                    (
                        "interactionGate",
                        descriptor.progression
                            .interactionGateAfterCompletion
                            .rawValue
                    ),
                    (
                        "nextScriptPointID",
                        descriptor.progression
                            .nextScriptPointID ??
                            "none"
                    )
                ]
            )

            return TuringFlowResult(
                outcome: .succeeded,
                identity: identity,
                expectedGeneratedSegmentCount:
                    expectedSegmentCount,
                completedGeneratedSegmentCount:
                    completed,
                skippedGeneratedSegmentIndices:
                    [],
                message:
                    "Finished \(scriptPointID)"
            )
        } catch is CancellationError {
            planTask?.cancel()

            if let playback,
               let completionTask {
                await playback.qwenComputeFailed(
                    expectedSegmentCount:
                        expectedSegmentCount,
                    reason: "cancelled"
                )
                await completionTask.value
            }

            if let route {
                await route.finish(
                    descriptor: descriptor,
                    identity: identity,
                    succeeded: false
                )
            }

            await TuringFlowInteractionGateController
                .shared
                .failFlow(
                    identity: identity,
                    reason: "cancelled"
                )

            return TuringFlowResult(
                outcome: .cancelled,
                identity: identity,
                expectedGeneratedSegmentCount:
                    expectedSegmentCount,
                completedGeneratedSegmentCount:
                    0,
                skippedGeneratedSegmentIndices:
                    [],
                message:
                    "Cancelled \(scriptPointID)"
            )
        } catch {
            planTask?.cancel()

            if let playback,
               let completionTask {
                // Once the PR has been queued, never cancel valid authored
                // media because a later language/model stage failed.
                await playback.qwenComputeFailed(
                    expectedSegmentCount:
                        expectedSegmentCount,
                    reason:
                        error.localizedDescription
                )
                await completionTask.value
            } else if let playback {
                await playback.runCancelled(
                    reason:
                        "flowFailedBeforePrerecordingQueued"
                )
            }

            if let route {
                await route.finish(
                    descriptor: descriptor,
                    identity: identity,
                    succeeded: false
                )
            }

            await TuringFlowInteractionGateController
                .shared
                .failFlow(
                    identity: identity,
                    reason:
                        error.localizedDescription
                )

            TuringFlowLog.event(
                "point failed",
                identity: identity,
                fields: [
                    (
                        "stage",
                        "configurationOrPlayback"
                    ),
                    (
                        "error",
                        error.localizedDescription
                    )
                ]
            )

            return TuringFlowResult(
                outcome: .playbackFailed,
                identity: identity,
                expectedGeneratedSegmentCount:
                    expectedSegmentCount,
                completedGeneratedSegmentCount:
                    0,
                skippedGeneratedSegmentIndices:
                    [],
                message:
                    "\(scriptPointID) failed: \(error.localizedDescription)"
            )
        }
    }

    private static func validateIdentity(
        descriptor: TuringFlowDescriptor,
        prerecording:
            TuringPrerecordingDescriptor,
        voicePrompt:
            TuringVoicePromptTriggerDescriptor,
        character:
            TuringCharacterRuntimeDefinition
    ) throws {
        guard descriptor.transmission
                .characterID ==
                character.characterID,
              prerecording.speaker ==
                character.characterID,
              prerecording.voiceID ==
                character.voiceID,
              voicePrompt.speakerID ==
                character.characterID,
              voicePrompt.voiceID ==
                character.voiceID,
              voicePrompt.characterProfileID ==
                character.characterID,
              voicePrompt.conversationKey ==
                descriptor.transmission
                    .conversationKey,
              voicePrompt.outputContext ==
                descriptor.transmission
                    .outputRoute else {
            throw TuringRuntimeError.invalidConfig(
                "Turing Flow \(descriptor.scriptPointID) character, voice, prompt, PR, route, or conversation identity mismatch."
            )
        }

        guard character.supports(
            descriptor.transmission
                .outputRoute
        ) else {
            throw TuringRuntimeError.invalidConfig(
                "\(character.characterID) does not support \(descriptor.transmission.outputRoute.rawValue)."
            )
        }

        guard prerecording.transcriptMode ==
                .manual,
              prerecording.transcript
                .trimmingCharacters(
                    in:
                        .whitespacesAndNewlines
                )
                .isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "\(descriptor.scriptPointID) requires a reviewed manual PR transcript."
            )
        }
    }
}
