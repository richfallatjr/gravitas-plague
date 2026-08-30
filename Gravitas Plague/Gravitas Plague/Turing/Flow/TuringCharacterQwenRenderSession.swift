import Foundation
import TuringQwenNative

protocol TuringCharacterRenderSession: Sendable {
    func begin() async throws

    func renderStage(
        _ stage: TuringCommittedSpeechStage,
        onStarted: @Sendable @escaping (Int) async -> Void,
        onFinished: @Sendable @escaping (
            Int,
            TuringComputeGapGeneratedAudio
        ) async -> Void,
        onSkipped: @Sendable @escaping (Int, String) async -> Void
    ) async throws -> TuringCharacterRenderReport

    func finish(reason: String) async
    func cancel(reason: String) async
}

protocol TuringCharacterRenderSessionMaking: Sendable {
    func make(
        runtime: TuringCharacterRuntimeDefinition,
        runID: String
    ) -> any TuringCharacterRenderSession
}

struct TuringCharacterQwenRenderSessionFactory:
    TuringCharacterRenderSessionMaking,
    TuringCharacterStreamingRenderSessionMaking,
    Sendable
{
    private let highMemoryPreflight:
        any TuringHighMemoryScenePreparing
    private let gpuAdmissionConfiguration:
        TuringQwenGPUAdmissionExperimentConfiguration?
    private let residencyConfiguration:
        TuringQwenResidencyExperimentConfiguration?

    init(
        highMemoryPreflight: any TuringHighMemoryScenePreparing =
            TuringHighMemoryPreflightCoordinator.shared,
        gpuAdmissionConfiguration:
            TuringQwenGPUAdmissionExperimentConfiguration? = nil,
        residencyConfiguration:
            TuringQwenResidencyExperimentConfiguration? = nil
    ) {
        self.highMemoryPreflight = highMemoryPreflight
        self.gpuAdmissionConfiguration = gpuAdmissionConfiguration
        self.residencyConfiguration = residencyConfiguration
    }

    func make(
        runtime: TuringCharacterRuntimeDefinition,
        runID: String
    ) -> any TuringCharacterRenderSession {
        TuringCharacterQwenRenderSession(
            runtime: runtime,
            runID: runID,
            highMemoryPreflight: highMemoryPreflight,
            gpuAdmissionConfiguration: gpuAdmissionConfiguration,
            residencyConfiguration: residencyConfiguration
        )
    }

    func makeStreamingSession(
        runtime: TuringCharacterRuntimeDefinition,
        runID: String
    ) -> any TuringCharacterStreamingRenderSession {
        TuringCharacterQwenRenderSession(
            runtime: runtime,
            runID: runID,
            highMemoryPreflight: highMemoryPreflight,
            gpuAdmissionConfiguration: gpuAdmissionConfiguration,
            residencyConfiguration: residencyConfiguration
        )
    }

    func makeStreamingSession(
        runtime: TuringCharacterRuntimeDefinition,
        runID: String,
        continuity: TuringSpokenPresentationContinuity?
    ) -> any TuringCharacterStreamingRenderSession {
        TuringCharacterQwenRenderSession(
            runtime: runtime,
            runID: runID,
            highMemoryPreflight: highMemoryPreflight,
            gpuAdmissionConfiguration: gpuAdmissionConfiguration,
            residencyConfiguration: residencyConfiguration,
            spokenPresentationContinuity: continuity
        )
    }
}

actor TuringCharacterQwenRenderSession:
    TuringCharacterRenderSession,
    TuringCharacterStreamingRenderSession
{
    private let runtime: TuringCharacterRuntimeDefinition
    private let runID: String
    private let recoverySessionID = UUID()
    private let resources: TuringBaseCloneRuntimeResources
    private let arbiter: TuringQwenCharacterPoolArbiter
    private let highMemoryPreflight:
        any TuringHighMemoryScenePreparing
    private let spokenPresentationContinuity: TuringSpokenPresentationContinuity?
    private let gpuAdmissionConfiguration:
        TuringQwenGPUAdmissionExperimentConfiguration?
    private let residencyConfiguration:
        TuringQwenResidencyExperimentConfiguration?

    private var pool: TuringQwenNativeFreshInstancePool?
    private var scheduler: TuringQwenNativeFreshInstanceScheduler?
    private var profile: TuringQwenNativeCloneProfile?
    private var stagedModel: URL?
    private var referenceRowLimit: Int?
    private var windowStrategy:
        TuringQwenNativeReferenceWindowStrategy = .full
    private var ownerID: String?
    private var started = false
    private var finished = false
    private var streamingQueue: TuringQwenOpenSegmentQueue?
    private var streamingTask:
        Task<TuringQwenNativeFreshInstanceRunReport, Error>?
    private var streamingState: TuringCharacterStreamingRenderState?
    private var streamingInputSealed = false
    private var recoveryGeneration: TuringQwenNativeRecoveryGeneration = .initial

    init(
        runtime: TuringCharacterRuntimeDefinition,
        runID: String,
        resources: TuringBaseCloneRuntimeResources =
            TuringBaseCloneRuntimeResources(),
        arbiter: TuringQwenCharacterPoolArbiter = .shared,
        highMemoryPreflight: any TuringHighMemoryScenePreparing =
            TuringHighMemoryPreflightCoordinator.shared,
        gpuAdmissionConfiguration:
            TuringQwenGPUAdmissionExperimentConfiguration? = nil,
        residencyConfiguration:
            TuringQwenResidencyExperimentConfiguration? = nil,
        spokenPresentationContinuity: TuringSpokenPresentationContinuity? = nil
    ) {
        self.runtime = runtime
        self.runID = runID
        self.resources = resources
        self.arbiter = arbiter
        self.highMemoryPreflight = highMemoryPreflight
        self.gpuAdmissionConfiguration = gpuAdmissionConfiguration
        self.residencyConfiguration = residencyConfiguration
        self.spokenPresentationContinuity = spokenPresentationContinuity
    }

    func begin() async throws {
        guard started == false else { return }

        let recoveryAdmission = try await
            TuringQwenNativeRecoveryCoordinator.shared
                .acquireSessionAdmission(
                    sessionID: recoverySessionID,
                    runID: runID
                )
        recoveryGeneration = recoveryAdmission.generation

        let resolvedGPUAdmissionConfiguration = try
            gpuAdmissionConfiguration ?? .current()
        let resolvedResidencyConfiguration = try
            residencyConfiguration ?? .current()
        let gpuAdmissionPolicy = try resolvedGPUAdmissionConfiguration.policy()
        let mlxCommandBufferConfiguration = try
            TuringMLXCommandBufferExperimentConfiguration.current()

        TuringQwenActiveModelTelemetry.register(
            runID: runID,
            modelID: Self.diagnosticModelID,
            quantization: Self.diagnosticQuantization
        )

        logMemory("session.beforeHighMemoryPreflight")
        do {
            try await highMemoryPreflight.prepareForTuringHighMemoryRun(
                runID: runID,
                continuity: spokenPresentationContinuity
            )
        } catch {
            TuringQwenActiveModelTelemetry.unregister(runID: runID)
            throw error
        }
        logMemory("session.afterHighMemoryPreflight")

        let owner = "\(runtime.characterID).\(runID)"
        await arbiter.acquire(owner: owner)
        ownerID = owner
        logMemory("session.afterOwnershipAcquired")

        do {
            guard let bundleRoot = Bundle.main.resourceURL else {
                throw TuringRuntimeError.invalidConfig(
                    "Missing app resource root for \(runtime.characterID) clone."
                )
            }

            let loadedProfile =
                try TuringQwenNativeCloneProfileLoader()
                    .loadBaseCloneProfile(
                        from: bundleRoot,
                        profileResourcePath:
                            runtime.cloneProfileResourcePath,
                        expectedVoiceID: runtime.voiceID,
                        expectedCharacterID: runtime.characterID,
                        logPrefix: runtime.displayName
                    )
            let bundledModel = try resources.locateBundledModel()
            let writableModel = try resources.stageWritableModel(
                from: bundledModel
            )
            let freshPool =
                try TuringQwenNativeGenerationSchedulerFactory
                    .makeFresh2Pool(
                        residencyMode: resolvedResidencyConfiguration.mode,
                        recoverySessionID: recoverySessionID,
                        recoveryRunID: runID,
                        recoveryGeneration: recoveryAdmission.generation
                    )
            pool = freshPool

            logMemory("session.beforeFresh2WarmLoad")
            try await freshPool.warmLoadExactlyRequestedInstances(
                modelRoot: writableModel,
                cloneProfile: loadedProfile,
                variantID: loadedProfile.defaultVariantID,
                performanceMode: .performance
            )
            _ = try mlxCommandBufferConfiguration
                .verifyResolvedDeviceConfiguration()
            logMemory("session.afterFresh2WarmLoad")

            if resolvedResidencyConfiguration.mode == .sharedImmutableFresh2 {
                referenceRowLimit = runtime.qwen.useExactReferenceRowCount
                    ? try await freshPool.preparedSharedCloneReferenceRowCount()
                    : nil
            } else {
                let selectedVariant = try loadedProfile.requireVariant(
                    loadedProfile.defaultVariantID
                )
                let selectedArtifacts =
                    try TuringQwenNativeCloneArtifactsLoader().load(
                        from: selectedVariant,
                        expectedVoiceID: loadedProfile.voiceID
                    )
                referenceRowLimit = runtime.qwen.useExactReferenceRowCount
                    ? selectedArtifacts.referenceRowCount
                    : nil
            }

            switch runtime.qwen.referenceWindowStrategy {
            case "full":
                windowStrategy = .full
            case "suffix":
                windowStrategy = .suffix
            default:
                throw TuringRuntimeError.invalidConfig(
                    "Unsupported referenceWindowStrategy \(runtime.qwen.referenceWindowStrategy)."
                )
            }

            scheduler =
                TuringQwenNativeGenerationSchedulerFactory
                    .makeFresh2Scheduler(
                        instancePool: freshPool,
                        gpuAdmissionPolicy: gpuAdmissionPolicy,
                        commandBufferProfile: mlxCommandBufferConfiguration.profile
                    )
            profile = loadedProfile
            stagedModel = writableModel
            started = true
            logMemory("session.ready")

            let residencyOwnership = try await freshPool.residencyOwnershipReport()
            print("""
            [TuringStagedSpeech] Fresh2 render session started
              runID: \(runID)
              characterID: \(runtime.characterID)
              voiceID: \(runtime.voiceID)
              requestedInstanceCount: 2
              actualInstanceCount: 2
              residencyMode: \(resolvedResidencyConfiguration.mode.rawValue)
              uniqueResidentResources: \(residencyOwnership.uniqueResidentResourceCount)
              uniqueWeightStores: \(residencyOwnership.uniqueWeightStoreCount)
              uniqueCloneConditionings: \(residencyOwnership.uniqueCloneConditioningCount)
              laneEngineCount: \(residencyOwnership.laneEngineCount)
              sharedWeights: \(resolvedResidencyConfiguration.mode == .sharedImmutableFresh2)
              gpuAdmissionMode: \(resolvedGPUAdmissionConfiguration.mode.rawValue)
              mlxCommandBufferProfile: \(mlxCommandBufferConfiguration.profile.rawValue)
              mlxTargetedBoundary: \(mlxCommandBufferConfiguration.targetedBoundary.rawValue)
              fallbackUsed: false
              recoveryGeneration: \(recoveryAdmission.generation.rawValue)
              recoverySessionID: \(recoverySessionID.uuidString)
              recoveryPoolID: \(freshPool.poolID.uuidString)
            """)
        } catch {
            logMemory(
                "session.beginFailed",
                details: ["error": error.localizedDescription]
            )
            await pool?.unloadAll(
                reason: "turingFlow.\(runtime.characterID).beginFailed.\(runID)"
            )
            pool = nil
            _ = await TuringQwenNativeRecoveryCoordinator.shared
                .waitUntilRecoverySettles()
            await releaseOwner(reason: "beginFailed")
            TuringQwenActiveModelTelemetry.unregister(runID: runID)
            throw error
        }
    }

    func renderStage(
        _ stage: TuringCommittedSpeechStage,
        onStarted: @escaping @Sendable (Int) async -> Void,
        onFinished: @escaping @Sendable (
            Int,
            TuringComputeGapGeneratedAudio
        ) async -> Void,
        onSkipped: @escaping @Sendable (Int, String) async -> Void
    ) async throws -> TuringCharacterRenderReport {
        guard started,
              finished == false,
              let scheduler,
              let profile,
              let stagedModel else {
            throw TuringRuntimeError.invalidConfig(
                "Fresh2 render session is not active."
            )
        }
        guard stage.globalRange.count == stage.segments.count,
              stage.segments.isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "Committed stage \(stage.stageID) has an invalid segment range."
            )
        }

        let state = TuringCharacterStageRenderState(
            expectedSegmentCount: stage.segments.count,
            segmentRange: stage.globalRange,
            sourceTexts: stage.segments.map(\.text)
        )
        let requests = makeRequests(stage, profile: profile)
        let diagnosticsRunID = runID
        let diagnosticsCharacterID = runtime.characterID
        let diagnosticsVoiceID = runtime.voiceID

        logMemory(
            "stage.renderStarted.\(stage.stageID)",
            details: ["segmentCount": String(stage.segments.count)]
        )

        print("""
        [TuringStagedSpeech] stage render started
          runID: \(runID)
          stageID: \(stage.stageID)
          globalRange: \(stage.globalRange)
          segmentCount: \(stage.segments.count)
          freshInstanceCount: 2
        """)

        let stageRunID = "\(runID).\(stage.stageID)"
        let failureProfile = try
            TuringMLXCommandBufferExperimentConfiguration.current().profile
        let failureAdmissionMode = try (
            gpuAdmissionConfiguration ?? .current()
        ).mode
        let nativeReport: TuringQwenNativeFreshInstanceRunReport
        do {
            nativeReport = try await scheduler.runSegments(
                requests,
                runID: stageRunID,
                modelRoot: stagedModel,
                skipSegmentFailures: runtime.qwen.skipSegmentFailures,
                onSegmentStarted: { _, segmentIndex in
                TuringMemoryBudgetProbe.log(
                    label: "qwen.segment.renderStarted",
                    activeQwenModelID: Self.diagnosticModelID,
                    quantization: Self.diagnosticQuantization,
                    runID: diagnosticsRunID,
                    segmentIndex: segmentIndex,
                    details: [
                        "characterID": diagnosticsCharacterID,
                        "voiceID": diagnosticsVoiceID
                    ]
                )
                await onStarted(segmentIndex)
                },
                onSegmentDecoded: { result in
                TuringMemoryBudgetProbe.log(
                    label: "qwen.segment.audioMaterialized",
                    activeQwenModelID: Self.diagnosticModelID,
                    quantization: Self.diagnosticQuantization,
                    runID: diagnosticsRunID,
                    segmentIndex: result.segmentIndex,
                    details: [
                        "characterID": diagnosticsCharacterID,
                        "voiceID": diagnosticsVoiceID
                    ]
                )
                #if GR_MIND_EYE_QUALIFICATION
                Task { @MainActor in
                    MindEyeReleaseQualificationHooks.shared.fireAndForget(
                        .qwenGenerationPeak,
                        playbackRunID: diagnosticsRunID,
                        mediaIdentity: "generated:\(result.segmentIndex)"
                    )
                }
                #endif
                guard let exactSourceText = await state.sourceText(
                    for: result.segmentIndex
                ) else {
                    let reason = "Missing exact source text for decoded segment index."
                    await state.recordSkipped(result.segmentIndex, reason: reason)
                    await onSkipped(result.segmentIndex, reason)
                    return
                }
                await onFinished(
                    result.segmentIndex,
                    TuringComputeGapGeneratedAudio(
                        segmentIndex: result.segmentIndex,
                        samples: result.audio.samples,
                        sampleRate: Double(result.audio.sampleRate),
                        channelCount: 1,
                        sourceText: exactSourceText
                    )
                )
                await state.recordSuccess(result.segmentIndex)
                },
                onSegmentSkipped: { skipped in
                TuringMemoryBudgetProbe.log(
                    label: "qwen.segment.skipped",
                    activeQwenModelID: Self.diagnosticModelID,
                    quantization: Self.diagnosticQuantization,
                    runID: diagnosticsRunID,
                    segmentIndex: skipped.segmentIndex,
                    details: [
                        "characterID": diagnosticsCharacterID,
                        "voiceID": diagnosticsVoiceID,
                        "error": skipped.errorDescription
                    ]
                )
                await state.recordSkipped(
                    skipped.segmentIndex,
                    reason: skipped.errorDescription
                )
                await onSkipped(
                    skipped.segmentIndex,
                    skipped.errorDescription
                )
                }
            )
        } catch {
            await TuringMLXCommandBufferDiagnosticsExporter.export(
                runID: stageRunID,
                profile: failureProfile,
                admissionMode: failureAdmissionMode,
                runMetrics: nil
            )
            throw error
        }
        nativeReport.log()
        await TuringMLXCommandBufferDiagnosticsExporter.export(
            runID: stageRunID,
            profile: nativeReport.commandBufferMetrics.profile,
            admissionMode: nativeReport.commandBufferMetrics.admissionMode,
            runMetrics: nativeReport.commandBufferMetrics,
            freshRunReport: nativeReport
        )

        let result = await state.snapshot()
        logMemory("stage.renderCompleted.\(stage.stageID)")
        print("""
        [TuringStagedSpeech] stage render completed
          runID: \(runID)
          stageID: \(stage.stageID)
          successfulSegmentIndices: \(result.successfulSegmentIndices.sorted())
          skippedSegmentIndices: \(result.skippedSegmentIndices.sorted())
        """)
        return result
    }

    func begin(
        onStarted: @escaping @Sendable (Int) async -> Void,
        onFinished: @escaping @Sendable (
            Int,
            TuringComputeGapGeneratedAudio
        ) async throws -> Void,
        onSkipped: @escaping @Sendable (Int, String) async -> Void
    ) async throws {
        try await begin()
        guard streamingTask == nil,
              let scheduler,
              let stagedModel else {
            throw TuringRuntimeError.invalidConfig(
                "Fresh2 streaming render session is already active or unavailable."
            )
        }

        let queue = TuringQwenOpenSegmentQueue()
        let state = TuringCharacterStreamingRenderState()
        let streamRunID = runID
        let diagnosticsCharacterID = runtime.characterID
        let diagnosticsVoiceID = runtime.voiceID
        let skipSegmentFailures = runtime.qwen.skipSegmentFailures
        let commandBufferProfile = try
            TuringMLXCommandBufferExperimentConfiguration.current().profile
        let admissionMode = try
            TuringQwenGPUAdmissionExperimentConfiguration.current().mode
        streamingQueue = queue
        streamingState = state
        streamingInputSealed = false

        streamingTask = Task.detached(priority: .userInitiated) {
            do {
                let report = try await scheduler.runOpenQueue(
                    queue,
                    runID: streamRunID,
                    modelRoot: stagedModel,
                    skipSegmentFailures: skipSegmentFailures,
                    onSegmentStarted: { _, segmentIndex in
                        TuringMemoryBudgetProbe.log(
                            label: "qwen.segment.renderStarted",
                            activeQwenModelID: Self.diagnosticModelID,
                            quantization: Self.diagnosticQuantization,
                            runID: streamRunID,
                            segmentIndex: segmentIndex,
                            details: [
                                "characterID": diagnosticsCharacterID,
                                "voiceID": diagnosticsVoiceID
                            ]
                        )
                        await onStarted(segmentIndex)
                    },
                    onSegmentDecoded: { result in
                        TuringMemoryBudgetProbe.log(
                            label: "qwen.segment.audioMaterialized",
                            activeQwenModelID: Self.diagnosticModelID,
                            quantization: Self.diagnosticQuantization,
                            runID: streamRunID,
                            segmentIndex: result.segmentIndex,
                            details: [
                                "characterID": diagnosticsCharacterID,
                                "voiceID": diagnosticsVoiceID
                            ]
                        )
                        #if GR_MIND_EYE_QUALIFICATION
                        Task { @MainActor in
                            MindEyeReleaseQualificationHooks.shared.fireAndForget(
                                .qwenGenerationPeak,
                                playbackRunID: streamRunID,
                                mediaIdentity: "generated:\(result.segmentIndex)"
                            )
                        }
                        #endif
                        let sourceText = try await state.requireSourceText(
                            for: result.segmentIndex
                        )
                        let audio = TuringComputeGapGeneratedAudio(
                            segmentIndex: result.segmentIndex,
                            samples: result.audio.samples,
                            sampleRate: Double(result.audio.sampleRate),
                            channelCount: 1,
                            sourceText: sourceText
                        )
                        try await onFinished(result.segmentIndex, audio)
                        await state.recordPublished(result.segmentIndex)
                    },
                    onSegmentSkipped: { skipped in
                        TuringMemoryBudgetProbe.log(
                            label: "qwen.segment.skipped",
                            activeQwenModelID: Self.diagnosticModelID,
                            quantization: Self.diagnosticQuantization,
                            runID: streamRunID,
                            segmentIndex: skipped.segmentIndex,
                            details: [
                                "characterID": diagnosticsCharacterID,
                                "voiceID": diagnosticsVoiceID,
                                "error": skipped.errorDescription
                            ]
                        )
                        await onSkipped(
                            skipped.segmentIndex,
                            skipped.errorDescription
                        )
                        await state.recordSkipped(
                            skipped.segmentIndex,
                            reason: skipped.errorDescription
                        )
                    }
                )
                report.log()
                await TuringMLXCommandBufferDiagnosticsExporter.export(
                    runID: streamRunID,
                    profile: report.commandBufferMetrics.profile,
                    admissionMode: report.commandBufferMetrics.admissionMode,
                    runMetrics: report.commandBufferMetrics,
                    freshRunReport: report
                )
                await state.schedulerFinished()
                return report
            } catch {
                await TuringMLXCommandBufferDiagnosticsExporter.export(
                    runID: streamRunID,
                    profile: commandBufferProfile,
                    admissionMode: admissionMode,
                    runMetrics: nil
                )
                TuringMemoryBudgetProbe.log(
                    label: "qwen.streamingSchedulerFailed",
                    activeQwenModelID: Self.diagnosticModelID,
                    quantization: Self.diagnosticQuantization,
                    runID: streamRunID,
                    details: [
                        "characterID": diagnosticsCharacterID,
                        "voiceID": diagnosticsVoiceID,
                        "error": error.localizedDescription
                    ]
                )
                await state.fail(reason: error.localizedDescription)
                throw error
            }
        }

        print("""
        [TuringScriptVoiceStreaming] render session opened
          runID: \(runID)
          freshInstanceCount: 2
          decoderConcurrency: 1
          inputQueueSealed: false
        """)
    }

    func submit(_ stage: TuringCommittedSpeechStage) async throws {
        guard streamingInputSealed == false,
              let streamingQueue,
              let streamingState,
              let profile else {
            throw TuringRuntimeError.invalidConfig(
                "Fresh2 streaming render session cannot accept a batch."
            )
        }
        guard stage.globalRange.count == stage.segments.count,
              stage.segments.isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "Committed stage \(stage.stageID) has an invalid segment range."
            )
        }

        let requests = makeRequests(stage, profile: profile)
        try await streamingState.register(
            stage.globalRange,
            sourceTexts: stage.segments.map(\.text)
        )
        do {
            try await streamingQueue.append(requests)
        } catch {
            await streamingState.fail(reason: error.localizedDescription)
            throw error
        }
        let depth = await streamingQueue.depth()
        print("""
        [TuringScriptVoiceStreaming] submitted
          runID: \(runID)
          stageID: \(stage.stageID)
          kind: \(stage.kind.rawValue)
          globalRange: \(stage.globalRange)
          openQueueDepth: \(depth)
        """)
    }

    func waitUntilPublished(throughExclusiveIndex: Int) async throws {
        guard let streamingState else {
            throw TuringRuntimeError.invalidConfig(
                "Fresh2 streaming render session is not active."
            )
        }
        try await streamingState.waitUntilResolved(
            throughExclusiveIndex: throughExclusiveIndex
        )
    }

    func sealInput(finalExpectedSegmentCount: Int) async {
        guard streamingInputSealed == false else { return }
        streamingInputSealed = true
        await streamingState?.seal(expectedSegmentCount: finalExpectedSegmentCount)
        await streamingQueue?.seal()
        print("""
        [TuringScriptVoiceStreaming] input sealed
          runID: \(runID)
          finalExpectedSegmentCount: \(finalExpectedSegmentCount)
        """)
    }

    func waitUntilPublished() async throws -> TuringCharacterRenderReport {
        guard streamingInputSealed,
              let streamingTask,
              let streamingState else {
            throw TuringRuntimeError.invalidConfig(
                "Fresh2 streaming input must be sealed before final publication wait."
            )
        }
        _ = try await streamingTask.value
        return try await streamingState.finalReport()
    }

    func finish(reason: String) async {
        guard finished == false else { return }
        if streamingTask != nil, streamingInputSealed == false {
            let registeredUpperBound: Int
            if let streamingState {
                registeredUpperBound = await streamingState
                    .registeredUpperBound()
            } else {
                registeredUpperBound = 0
            }
            await sealInput(
                finalExpectedSegmentCount: registeredUpperBound
            )
        }
        _ = try? await streamingTask?.value
        finished = true
        logMemory(
            "session.beforeUnload",
            details: ["reason": reason]
        )
        await pool?.unloadAll(
            reason: "turingFlow.\(runtime.characterID).\(reason).\(runID)"
        )
        pool = nil
        scheduler = nil
        profile = nil
        stagedModel = nil
        streamingQueue = nil
        streamingTask = nil
        streamingState = nil
        _ = await TuringQwenNativeRecoveryCoordinator.shared
            .waitUntilRecoverySettles()
        await releaseOwner(reason: reason)
        TuringQwenActiveModelTelemetry.unregister(runID: runID)
        logMemory(
            "session.afterUnload",
            details: ["reason": reason]
        )
    }

    func cancel(reason: String) async {
        await streamingQueue?.cancel(reason: reason)
        streamingTask?.cancel()
        await finish(reason: "cancel.\(reason)")
    }

    private func makeRequests(
        _ stage: TuringCommittedSpeechStage,
        profile: TuringQwenNativeCloneProfile
    ) -> [TuringQwenNativeBaseCloneSegmentRequest] {
        zip(stage.globalRange, stage.segments).map { globalIndex, segment in
            let samplingSeed = TuringQwenNativeSamplingSeed.make(
                voiceID: runtime.voiceID,
                runID: runID,
                segmentIndex: globalIndex
            )
            print("""
            [TuringFlow] exact Qwen input
              characterID: \(runtime.characterID)
              voiceID: \(runtime.voiceID)
              playbackRunID: \(runID)
              stageID: \(stage.stageID)
              segmentIndex: \(globalIndex)
              qwenInputTextSHA256: \(TuringFlowHash.sha256(segment.text))
              textUTF16: \(segment.text.utf16.count)
              samplingSeed: \(samplingSeed)
            """)

            return TuringQwenNativeBaseCloneSegmentRequest(
                segmentIndex: globalIndex,
                text: segment.text,
                language: "english",
                cloneProfile: profile,
                maxNewRows: runtime.qwen.maxNewRows,
                performanceMode: .performance,
                referenceRowLimit: referenceRowLimit,
                referenceWindowStrategy: windowStrategy,
                samplingPolicy: runtime.qwen.samplingPolicy,
                samplingSeed: samplingSeed,
                generationQualityPolicy: runtime.qwen.generationQualityPolicy
            )
        }
    }

    private func releaseOwner(reason: String) async {
        guard let ownerID else { return }
        self.ownerID = nil
        await arbiter.release(owner: ownerID)
        print("""
        [TuringStagedSpeech] render-session ownership released
          runID: \(runID)
          reason: \(reason)
        """)
    }

    @discardableResult
    private func logMemory(
        _ label: String,
        segmentIndex: Int? = nil,
        details: [String: String] = [:]
    ) -> TuringMemoryBudgetSnapshot {
        var mergedDetails = details
        mergedDetails["characterID"] = runtime.characterID
        mergedDetails["voiceID"] = runtime.voiceID
        return TuringMemoryBudgetProbe.log(
            label: "qwen.\(label)",
            activeQwenModelID: Self.diagnosticModelID,
            quantization: Self.diagnosticQuantization,
            runID: runID,
            segmentIndex: segmentIndex,
            details: mergedDetails
        )
    }

    private static let diagnosticModelID =
        "qwen3-tts-12hz-1.7b-base-4bit"
    private static let diagnosticQuantization = "4bit"
}

private actor TuringCharacterStreamingRenderState {
    private var registeredIndices = Set<Int>()
    private var sourceTextBySegmentIndex: [Int: String] = [:]
    private var publishedIndices = Set<Int>()
    private var skippedReasons: [Int: String] = [:]
    private var expectedSegmentCount: Int?
    private var failureReason: String?
    private var schedulerDidFinish = false
    private var waiters: [
        (throughExclusiveIndex: Int, continuation: CheckedContinuation<Void, Error>)
    ] = []

    func register(
        _ range: Range<Int>,
        sourceTexts: [String]
    ) throws {
        guard range.count == sourceTexts.count else {
            throw TuringRuntimeError.invalidConfig(
                "Streaming speech text count does not match its segment range."
            )
        }
        for (index, sourceText) in zip(range, sourceTexts) {
            guard registeredIndices.insert(index).inserted else {
                throw TuringRuntimeError.invalidConfig(
                    "Duplicate streaming segment index \(index)."
                )
            }
            sourceTextBySegmentIndex[index] = sourceText
        }
    }

    func requireSourceText(for segmentIndex: Int) throws -> String {
        guard let value = sourceTextBySegmentIndex[segmentIndex] else {
            throw TuringRuntimeError.invalidConfig(
                "Missing exact source text for decoded segment \(segmentIndex)."
            )
        }
        return value
    }

    func recordPublished(_ index: Int) {
        publishedIndices.insert(index)
        sourceTextBySegmentIndex.removeValue(forKey: index)
        skippedReasons.removeValue(forKey: index)
        reconcileWaiters()
    }

    func recordSkipped(_ index: Int, reason: String) {
        guard publishedIndices.contains(index) == false else { return }
        skippedReasons[index] = reason
        reconcileWaiters()
    }

    func waitUntilResolved(throughExclusiveIndex: Int) async throws {
        if let failureReason {
            throw Self.error(failureReason)
        }
        if isResolved(throughExclusiveIndex: throughExclusiveIndex) {
            return
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append((throughExclusiveIndex, continuation))
        }
    }

    func seal(expectedSegmentCount: Int) {
        self.expectedSegmentCount = expectedSegmentCount
    }

    func schedulerFinished() {
        schedulerDidFinish = true
        reconcileWaiters()
    }

    func fail(reason: String) {
        guard failureReason == nil else { return }
        failureReason = reason
        let current = waiters
        waiters.removeAll(keepingCapacity: false)
        current.forEach { $0.continuation.resume(throwing: Self.error(reason)) }
    }

    func registeredUpperBound() -> Int {
        (registeredIndices.max() ?? -1) + 1
    }

    func finalReport() throws -> TuringCharacterRenderReport {
        if let failureReason {
            throw Self.error(failureReason)
        }
        guard schedulerDidFinish, let expectedSegmentCount else {
            throw TuringRuntimeError.invalidConfig(
                "Fresh2 streaming scheduler has not finished."
            )
        }
        let expectedIndices = Set(0..<expectedSegmentCount)
        guard registeredIndices == expectedIndices,
              publishedIndices.union(skippedReasons.keys) == expectedIndices else {
            throw TuringRuntimeError.invalidConfig(
                "Fresh2 streaming scheduler did not resolve its exact sealed index set."
            )
        }
        return TuringCharacterRenderReport(
            expectedSegmentCount: expectedSegmentCount,
            successfulSegmentIndices: publishedIndices,
            skippedSegmentReasons: skippedReasons
        )
    }

    private func isResolved(throughExclusiveIndex: Int) -> Bool {
        guard throughExclusiveIndex > 0 else { return true }
        return (0..<throughExclusiveIndex).allSatisfy {
            publishedIndices.contains($0) || skippedReasons[$0] != nil
        }
    }

    private func reconcileWaiters() {
        guard failureReason == nil else { return }
        var remaining: [
            (throughExclusiveIndex: Int, continuation: CheckedContinuation<Void, Error>)
        ] = []
        for waiter in waiters {
            if isResolved(throughExclusiveIndex: waiter.throughExclusiveIndex) {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
    }

    private static func error(_ reason: String) -> NSError {
        NSError(
            domain: "TuringCharacterStreamingRenderSession",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }
}

private actor TuringCharacterStageRenderState {
    private let expectedSegmentCount: Int
    private var sourceTextBySegmentIndex: [Int: String]
    private var successful = Set<Int>()
    private var skipped: [Int: String] = [:]

    init(
        expectedSegmentCount: Int,
        segmentRange: Range<Int>,
        sourceTexts: [String]
    ) {
        self.expectedSegmentCount = expectedSegmentCount
        sourceTextBySegmentIndex = Dictionary(
            uniqueKeysWithValues: zip(segmentRange, sourceTexts)
        )
    }

    func sourceText(for index: Int) -> String? {
        sourceTextBySegmentIndex[index]
    }

    func recordSuccess(_ index: Int) {
        successful.insert(index)
        sourceTextBySegmentIndex.removeValue(forKey: index)
        skipped.removeValue(forKey: index)
    }

    func recordSkipped(_ index: Int, reason: String) {
        guard successful.contains(index) == false else { return }
        sourceTextBySegmentIndex.removeValue(forKey: index)
        skipped[index] = reason
    }

    func snapshot() -> TuringCharacterRenderReport {
        TuringCharacterRenderReport(
            expectedSegmentCount: expectedSegmentCount,
            successfulSegmentIndices: successful,
            skippedSegmentReasons: skipped
        )
    }
}
