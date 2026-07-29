import Foundation

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
    private let stagedRendererFactory:
        any TuringCharacterStreamingRenderSessionMaking
    private let inputStore:
        TuringConversationInputStore

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
        stagedRendererFactory:
            any TuringCharacterStreamingRenderSessionMaking =
                TuringCharacterQwenRenderSessionFactory(),
        inputStore:
            TuringConversationInputStore = .shared
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
        self.stagedRendererFactory = stagedRendererFactory
        self.inputStore = inputStore
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
            TuringVoicePromptTriggerDescriptor?
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
            if let voicePromptID =
                descriptor.transmission.voicePromptID {
                voicePrompt =
                    try voicePromptStore.descriptor(
                        id: voicePromptID
                    )
            } else {
                voicePrompt = nil
            }
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
                Self.identityVoicePromptID(
                    descriptor: descriptor,
                    voicePrompt: voicePrompt
                ),
            interactionSurface:
                descriptor.transmission
                    .effectiveInteractionSurface
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
            Task<TuringFlowCompositeSpeechPlan, Error>?
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

            await inputStore.updatePrerecording(
                id:
                    prerecording
                        .prerecordingID,
                transcript:
                    prerecording.transcript,
                for:
                    descriptor.transmission
                        .conversationKey
            )

            if let voicePrompt {
                let promptVoiceContext =
                    TuringPromptVoiceStoryContextBuilder.standard(
                        voicePrompt
                    )
                await inputStore.updatePromptVoiceStoryContext(
                    promptVoiceContext.storyContext,
                    for:
                        descriptor.transmission
                            .conversationKey
                )
                await inputStore.updatePromptVariant(
                    .resolved(
                        scriptPointID:
                            descriptor.scriptPointID,
                        promptTemplateID:
                            voicePrompt
                                .effectivePromptTemplateID
                    ),
                    for:
                        descriptor.transmission
                            .conversationKey
                )
            }

            if let pipeline =
                descriptor.transmission.generationPipeline {
                return await runStagedPipeline(
                    descriptor: descriptor,
                    pipeline: pipeline,
                    prerecording: prerecording,
                    prerecordingURL: prerecordingURL,
                    character: character,
                    identity: identity,
                    route: resolvedRoute
                )
            }

            func makePlanTask()
                -> Task<
                    TuringFlowCompositeSpeechPlan,
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
                            "promptInputContract",
                            descriptor.transmission.usesCompositePipeline
                                ? "scriptVoiceSource,characterDisplayName,listenerDisplayName,characterBackstory,storyIntent,prerecordingTranscript"
                                : "characterDisplayName,listenerDisplayName,characterBackstory,storyIntent,prerecordingTranscript"
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
                    guard let voicePrompt else {
                        throw TuringRuntimeError.invalidConfig(
                            "\(scriptPointID) missing legacy voicePrompt descriptor."
                        )
                    }

                    let promptVoiceContext =
                        TuringPromptVoiceStoryContextBuilder.standard(
                            voicePrompt
                        )
                    let foundationContext =
                        TuringFoundationRequestContext(
                            flowRunID:
                                identity.flowInstanceID
                                    .uuidString,
                            scriptPointID:
                                descriptor.scriptPointID,
                            stageID: "promptVoice",
                            sectionIndex: nil
                        )
                    let promptPlan =
                        try await TuringFoundationRequestScope
                            .$current.withValue(
                                foundationContext
                            ) {
                                try await dialogueService
                                    .generateVoicePrompt(
                                        VoicePromptRequest(
                                            id:
                                                voicePrompt
                                                    .voicePromptID,
                                            characterProfileID:
                                                voicePrompt
                                                    .characterProfileID,
                                            listenerProfileID:
                                                voicePrompt
                                                    .listenerProfileID,
                                            promptContext:
                                                promptVoiceContext
                                                    .storyContext,
                                            prerecordingTranscript:
                                                prerecording
                                                    .transcript,
                                            storyIntent:
                                                voicePrompt
                                                    .intent,
                                            promptTemplateID:
                                                voicePrompt
                                                    .effectivePromptTemplateID
                                        )
                                    )
                            }
                    return TuringFlowCompositeSpeechPlan(
                        segments: promptPlan.segments,
                        promptVoiceContext:
                            promptVoiceContext
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

            let plan: TuringFlowCompositeSpeechPlan

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
                    )
                ]
            )

            await inputStore.updatePromptVoiceStoryContext(
                plan.promptVoiceContext.storyContext,
                for:
                    descriptor.transmission
                        .conversationKey
            )
            if let voicePrompt {
                await inputStore.updatePromptVariant(
                    .resolved(
                        scriptPointID:
                            descriptor.scriptPointID,
                        promptTemplateID:
                            voicePrompt
                                .effectivePromptTemplateID
                    ),
                    for:
                        descriptor.transmission
                            .conversationKey
                )
            }

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

            let authoredGate =
                descriptor.progression
                    .interactionGateAfterCompletion
            let suppressInteractionForAutomaticAdvance =
                descriptor.progression
                    .automaticAdvance &&
                descriptor.progression
                    .nextScriptPointID != nil
            let effectiveGate = descriptor.progression
                .effectiveInteractionGateAfterCompletion

            print("""
            [TuringFlowGate] completion override
              scriptPointID: \(descriptor.scriptPointID)
              authoredGate: \(authoredGate.rawValue)
              effectiveGate: \(effectiveGate.rawValue)
              automaticAdvance: \(descriptor.progression.automaticAdvance)
              nextScriptPointID: \(descriptor.progression.nextScriptPointID ?? "none")
              reason: \(suppressInteractionForAutomaticAdvance ? "automaticAdvance" : "normalCompletion")
            """)

            await TuringFlowInteractionGateController
                .shared
                .applyCompletionGate(
                    effectiveGate,
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
                        effectiveGate.rawValue
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

    private func runStagedPipeline(
        descriptor: TuringFlowDescriptor,
        pipeline: TuringFlowGenerationPipelineDescriptor,
        prerecording: TuringPrerecordingDescriptor,
        prerecordingURL: URL,
        character: TuringCharacterRuntimeDefinition,
        identity: TuringFlowIdentity,
        route: any TuringFlowRouteRuntime
    ) async -> TuringFlowResult {
        var playback: (any TuringFlowPlaybackControlling)?
        var stagedTask: Task<TuringStagedSpeechRunReport, Error>?

        do {
            let authoredBridges = try resolveAuthoredBridges(
                pipeline: pipeline,
                character: character
            )
            let createdPlayback = try await route.makePlayback(
                descriptor: descriptor,
                character: character,
                identity: identity
            )
            playback = createdPlayback
            await createdPlayback.configureFlowIdentity(identity)
            await createdPlayback.beginRun(
                runID: identity.playbackRunID,
                expectedSegmentCount: nil
            )
            await createdPlayback.expectPrerecordingBeforeGenerated()

            let coordinator = TuringStagedSpeechRunCoordinator(
                promptVoiceExecutor: TuringPromptVoiceStageExecutor(
                    promptStore: voicePromptStore,
                    generator: dialogueServiceFactory(),
                    inputStore: inputStore
                ),
                rendererFactory: stagedRendererFactory,
                inputStore: inputStore
            )
            let task = Task.detached(priority: .userInitiated) {
                try await coordinator.run(
                    descriptor: descriptor,
                    pipeline: pipeline,
                    character: character,
                    prerecording: prerecording,
                    authoredBridges: authoredBridges,
                    playback: createdPlayback,
                    identity: identity
                )
            }
            stagedTask = task

            TuringFlowLog.event(
                "staged speech started",
                identity: identity,
                fields: [
                    ("stageCount", String(pipeline.stages.count)),
                    ("startsBeforeFixedLeadIn", "true"),
                    ("playbackInputOpen", "true"),
                    ("freshDialogueService", "true")
                ]
            )

            await route.runFixedLeadInIfNeeded(
                descriptor: descriptor,
                identity: identity
            )
            try await route.playOpenIfNeeded(
                descriptor: descriptor,
                identity: identity
            )
            await createdPlayback.enqueuePrerecording(
                id: prerecording.prerecordingID,
                fileURL: prerecordingURL
            )

            let report = try await task.value
            let expected = report.finalExpectedSegmentCount
            let completed = report.completedPlaybackCount
            let skipped = report.skippedSegmentIndices.sorted()

            guard report.completedWithoutStageFailure else {
                await route.finish(
                    descriptor: descriptor,
                    identity: identity,
                    succeeded: false
                )
                await TuringFlowInteractionGateController.shared.failFlow(
                    identity: identity,
                    reason: "stagedSpeechPartialFailure"
                )

                let failures = report.failedStages.map {
                    "\($0.stageID): \($0.reason)"
                }.joined(separator: " | ")
                TuringFlowLog.event(
                    "point failed",
                    identity: identity,
                    fields: [
                        ("stage", "stagedSpeechPartialFailure"),
                        ("committedSegmentCount", String(expected)),
                        ("completedGeneratedSegmentCount", String(completed)),
                        ("committedWorkErased", "false"),
                        ("failures", failures)
                    ]
                )

                return TuringFlowResult(
                    outcome: skipped.isEmpty
                        ? .generatedPlanFailed
                        : .partialGeneratedFailure,
                    identity: identity,
                    expectedGeneratedSegmentCount: expected,
                    completedGeneratedSegmentCount: completed,
                    skippedGeneratedSegmentIndices: skipped,
                    message:
                        "\(descriptor.scriptPointID) staged speech failed after preserving committed playback: \(failures)"
                )
            }

            try await route.playSendIfNeeded(
                descriptor: descriptor,
                identity: identity
            )
            await route.finish(
                descriptor: descriptor,
                identity: identity,
                succeeded: true
            )
            let effectiveGate = descriptor.progression
                .effectiveInteractionGateAfterCompletion
            await TuringFlowInteractionGateController.shared
                .applyCompletionGate(
                    effectiveGate,
                    identity: identity
                )

            TuringFlowLog.event(
                "point completed",
                identity: identity,
                fields: [
                    ("pipeline", "stagedSpeech"),
                    ("committedBatchCount", String(report.committedStages.count)),
                    ("expectedGeneratedSegmentCount", String(expected)),
                    ("completedGeneratedSegmentCount", String(completed)),
                    ("interactionGate", effectiveGate.rawValue),
                    (
                        "nextScriptPointID",
                        descriptor.progression.nextScriptPointID ?? "none"
                    )
                ]
            )

            return TuringFlowResult(
                outcome: .succeeded,
                identity: identity,
                expectedGeneratedSegmentCount: expected,
                completedGeneratedSegmentCount: completed,
                skippedGeneratedSegmentIndices: [],
                message: "Finished \(descriptor.scriptPointID)"
            )
        } catch is CancellationError {
            stagedTask?.cancel()
            if let stagedTask {
                _ = try? await stagedTask.value
            }
            await playback?.runCancelled(reason: "stagedSpeechCancelled")
            await route.finish(
                descriptor: descriptor,
                identity: identity,
                succeeded: false
            )
            await TuringFlowInteractionGateController.shared.failFlow(
                identity: identity,
                reason: "cancelled"
            )
            return TuringFlowResult(
                outcome: .cancelled,
                identity: identity,
                expectedGeneratedSegmentCount: 0,
                completedGeneratedSegmentCount: 0,
                skippedGeneratedSegmentIndices: [],
                message: "Cancelled \(descriptor.scriptPointID)"
            )
        } catch {
            stagedTask?.cancel()
            if let stagedTask {
                _ = try? await stagedTask.value
            }
            await playback?.runCancelled(reason: "stagedSpeechFailed")
            await route.finish(
                descriptor: descriptor,
                identity: identity,
                succeeded: false
            )
            await TuringFlowInteractionGateController.shared.failFlow(
                identity: identity,
                reason: error.localizedDescription
            )
            let completed: Int
            if let playback {
                completed = await playback
                    .completedGeneratedSegmentCount()
            } else {
                completed = 0
            }
            TuringFlowLog.event(
                "point failed",
                identity: identity,
                fields: [
                    ("stage", "stagedSpeechFatalFailure"),
                    ("committedWorkErased", "false"),
                    ("error", error.localizedDescription)
                ]
            )
            return TuringFlowResult(
                outcome: .generatedAudioFailed,
                identity: identity,
                expectedGeneratedSegmentCount: completed,
                completedGeneratedSegmentCount: completed,
                skippedGeneratedSegmentIndices: [],
                message:
                    "\(descriptor.scriptPointID) staged speech failed: \(error.localizedDescription)"
            )
        }
    }

    private func resolveAuthoredBridges(
        pipeline: TuringFlowGenerationPipelineDescriptor,
        character: TuringCharacterRuntimeDefinition
    ) throws -> [String: TuringAuthoredSpeechBridge] {
        var resolved: [String: TuringAuthoredSpeechBridge] = [:]

        for stage in pipeline.stages {
            guard let prerecordingID =
                    stage.authoredPrerecordingAfterStageID else {
                continue
            }
            if resolved[prerecordingID] != nil {
                continue
            }

            let descriptor = try prerecordingStore.descriptor(
                id: prerecordingID
            )
            guard descriptor.speaker == character.characterID,
                  descriptor.voiceID == character.voiceID else {
                throw TuringRuntimeError.invalidConfig(
                    "Authored bridge \(prerecordingID) does not match character \(character.characterID)."
                )
            }
            resolved[prerecordingID] = TuringAuthoredSpeechBridge(
                prerecordingID: prerecordingID,
                fileURL: try prerecordingStore.audioURL(for: descriptor),
                conversationTranscript:
                    descriptor.transcriptMode == .none ||
                    descriptor.transcript.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                        ? nil
                        : descriptor.transcript
            )
        }

        return resolved
    }

    private static func validateIdentity(
        descriptor: TuringFlowDescriptor,
        prerecording:
            TuringPrerecordingDescriptor,
        voicePrompt:
            TuringVoicePromptTriggerDescriptor?,
        character:
            TuringCharacterRuntimeDefinition
    ) throws {
        guard descriptor.transmission
                .characterID ==
                character.characterID,
              prerecording.speaker ==
                character.characterID,
              prerecording.voiceID ==
                character.voiceID else {
            throw TuringRuntimeError.invalidConfig(
                "Turing Flow \(descriptor.scriptPointID) character, voice, or PR identity mismatch."
            )
        }

        if descriptor.transmission.usesLegacyVoicePrompt {
            guard let voicePrompt,
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
                    "Turing Flow \(descriptor.scriptPointID) prompt, route, or conversation identity mismatch."
                )
            }
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

    private static func identityVoicePromptID(
        descriptor: TuringFlowDescriptor,
        voicePrompt: TuringVoicePromptTriggerDescriptor?
    ) -> String {
        if let voicePrompt {
            return voicePrompt.voicePromptID
        }

        let pipelinePromptIDs =
            descriptor.transmission.generationPipeline?.stages
                .compactMap(\.voicePromptID) ?? []
        if pipelinePromptIDs.isEmpty == false {
            return pipelinePromptIDs.joined(separator: "+")
        }

        return "compositePipeline"
    }
}
