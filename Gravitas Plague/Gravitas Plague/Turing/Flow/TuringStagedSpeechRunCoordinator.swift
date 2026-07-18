import Foundation

actor TuringStagedSpeechRunCoordinator {
    private let executors: [
        TuringFlowGenerationPipelineDescriptor.Stage.Kind:
            any TuringSpeechStageExecuting
    ]
    private let rendererFactory: any TuringCharacterRenderSessionMaking
    private let seedStore: TuringConversationSeedStore

    init(
        voiceScriptExecutor: any TuringSpeechStageExecuting =
            TuringVoiceScriptStageExecutor(),
        promptVoiceExecutor: any TuringSpeechStageExecuting =
            TuringPromptVoiceStageExecutor(),
        rendererFactory: any TuringCharacterRenderSessionMaking =
            TuringCharacterQwenRenderSessionFactory(),
        seedStore: TuringConversationSeedStore = .shared
    ) {
        executors = [
            .voiceScriptLongform: voiceScriptExecutor,
            .voicePrompt: promptVoiceExecutor
        ]
        self.rendererFactory = rendererFactory
        self.seedStore = seedStore
    }

    func run(
        descriptor: TuringFlowDescriptor,
        pipeline: TuringFlowGenerationPipelineDescriptor,
        character: TuringCharacterRuntimeDefinition,
        prerecording: TuringPrerecordingDescriptor,
        playback: any TuringFlowPlaybackControlling,
        identity: TuringFlowIdentity
    ) async throws -> TuringStagedSpeechRunReport {
        let session = rendererFactory.make(
            runtime: character,
            runID: identity.playbackRunID
        )
        let state = TuringStagedSpeechRunState()
        var terminalError: Error?
        var playbackWasTerminallyFailed = false

        do {
            try await session.begin()

            for stageDescriptor in pipeline.stages {
                try Task.checkCancellation()
                guard let executor = executors[stageDescriptor.kind] else {
                    throw TuringRuntimeError.invalidConfig(
                        "No executor for stage kind \(stageDescriptor.kind.rawValue)."
                    )
                }

                let context = TuringSpeechStageContext(
                    descriptor: descriptor,
                    character: character,
                    prerecording: prerecording,
                    stageSourceTranscripts:
                        await state.sourceTranscripts()
                )
                let committedKind = Self.committedKind(
                    for: stageDescriptor.kind
                )

                do {
                    let result = try await executor.execute(
                        stage: stageDescriptor,
                        context: context
                    ) { batch in
                        let committed = await state.reserve(
                            batch: batch,
                            kind: committedKind
                        )
                        print("""
                        [TuringStagedSpeech] stage committed
                          scriptPointID: \(descriptor.scriptPointID)
                          stageID: \(committed.stageID)
                          kind: \(committed.kind.rawValue)
                          globalRange: \(committed.globalRange)
                        """)

                        let renderReport: TuringCharacterRenderReport
                        do {
                            renderReport = try await session.renderStage(
                                committed,
                                onStarted: { index in
                                    await playback.qwenComputeStarted(
                                        segmentIndex: index
                                    )
                                },
                                onFinished: { index, audio in
                                    await playback.qwenComputeFinished(
                                        segmentIndex: index,
                                        audio: audio
                                    )
                                },
                                onSkipped: { index, reason in
                                    await state.recordSkipped(index)
                                    await playback.qwenComputeSkipped(
                                        segmentIndex: index,
                                        reason: reason
                                    )
                                }
                            )
                        } catch {
                            throw TuringStagedSpeechRenderFailure(
                                reason: error.localizedDescription
                            )
                        }

                        guard renderReport.isCompleteSuccess else {
                            throw TuringStagedSpeechRenderFailure(
                                reason:
                                    "Stage \(committed.stageID) Qwen render was partial."
                            )
                        }

                        print("""
                        [TuringStagedSpeech] stage batch published
                          scriptPointID: \(descriptor.scriptPointID)
                          stageID: \(committed.stageID)
                          globalRange: \(committed.globalRange)
                          waitsForPlaybackCompletion: false
                        """)
                    }

                    if let transcript = result.normalizedSourceTranscript {
                        await state.recordSourceTranscript(
                            transcript,
                            stageID: stageDescriptor.stageID
                        )
                    }
                    if let promptVoiceSeed = result.promptVoiceSeed {
                        await state.recordPromptVoiceSeed(promptVoiceSeed)
                    }
                    for failure in result.failedBatchDescriptions {
                        await state.recordFailure(
                            stageID: stageDescriptor.stageID,
                            kind: committedKind,
                            reason: failure
                        )
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    await state.recordFailure(
                        stageID: stageDescriptor.stageID,
                        kind: committedKind,
                        reason: error.localizedDescription
                    )

                    let committedCount = await state.nextGlobalIndex()
                    print("""
                    [TuringStagedSpeech] stage failed
                      scriptPointID: \(descriptor.scriptPointID)
                      stageID: \(stageDescriptor.stageID)
                      kind: \(committedKind.rawValue)
                      committedSegmentCount: \(committedCount)
                      committedRangesPreserved: true
                      error: \(error.localizedDescription)
                    """)

                    if committedKind == .scriptVoice,
                       await state.hasCommitted(kind: .scriptVoice) == false {
                        terminalError = error
                    }

                    if Self.isRenderFailure(error) {
                        await playback.qwenComputeFailed(
                            expectedSegmentCount: committedCount,
                            reason: error.localizedDescription
                        )
                        playbackWasTerminallyFailed = true
                        terminalError = error
                    }
                    break
                }
            }

            let finalCount = await state.nextGlobalIndex()
            if playbackWasTerminallyFailed == false {
                await playback.sealGeneratedInput(
                    finalExpectedSegmentCount: finalCount
                )
            }
            await playback.waitUntilPlaybackFinished()
            await session.finish(reason: "stagedSpeechCompleted")

            if let terminalError {
                throw terminalError
            }

            if let promptVoiceSeed = await state.promptVoiceSeed() {
                await seedStore.updatePromptVoiceSeed(
                    promptVoiceSeed,
                    for: descriptor.transmission.conversationKey
                )
            }

            let completedPlaybackCount =
                await playback.completedGeneratedSegmentCount()
            return await state.report(
                completedPlaybackCount: completedPlaybackCount
            )
        } catch {
            let finalCount = await state.nextGlobalIndex()
            if playbackWasTerminallyFailed == false {
                await playback.qwenComputeFailed(
                    expectedSegmentCount: finalCount,
                    reason: error.localizedDescription
                )
            }
            await playback.waitUntilPlaybackFinished()
            await session.cancel(reason: error.localizedDescription)
            throw error
        }
    }

    private static func committedKind(
        for kind: TuringFlowGenerationPipelineDescriptor.Stage.Kind
    ) -> TuringCommittedSpeechStage.Kind {
        switch kind {
        case .voiceScriptLongform:
            return .scriptVoice
        case .voicePrompt:
            return .promptVoice
        }
    }

    private static func isRenderFailure(_ error: Error) -> Bool {
        error is TuringStagedSpeechRenderFailure
    }
}

private struct TuringStagedSpeechRenderFailure: LocalizedError, Sendable {
    let reason: String

    var errorDescription: String? {
        reason
    }
}

private actor TuringStagedSpeechRunState {
    private var nextIndex = 0
    private var committedStages: [TuringCommittedSpeechStage] = []
    private var failures: [TuringSpeechStageFailure] = []
    private var transcripts: [String: String] = [:]
    private var storedPromptVoiceSeed: TuringPromptVoiceSeed?
    private var skippedIndices = Set<Int>()

    func reserve(
        batch: TuringPreparedSpeechBatch,
        kind: TuringCommittedSpeechStage.Kind
    ) -> TuringCommittedSpeechStage {
        let range = nextIndex..<(nextIndex + batch.segments.count)
        let committed = TuringCommittedSpeechStage(
            stageID: batch.batchID,
            kind: kind,
            globalRange: range,
            segments: batch.segments
        )
        committedStages.append(committed)
        nextIndex = range.upperBound
        return committed
    }

    func nextGlobalIndex() -> Int {
        nextIndex
    }

    func hasCommitted(kind: TuringCommittedSpeechStage.Kind) -> Bool {
        committedStages.contains { $0.kind == kind }
    }

    func recordFailure(
        stageID: String,
        kind: TuringCommittedSpeechStage.Kind,
        reason: String
    ) {
        failures.append(
            TuringSpeechStageFailure(
                stageID: stageID,
                stageKind: kind,
                reason: reason
            )
        )
    }

    func recordSourceTranscript(_ transcript: String, stageID: String) {
        transcripts[stageID] = transcript
    }

    func sourceTranscripts() -> [String: String] {
        transcripts
    }

    func recordPromptVoiceSeed(_ seed: TuringPromptVoiceSeed) {
        storedPromptVoiceSeed = seed
    }

    func promptVoiceSeed() -> TuringPromptVoiceSeed? {
        storedPromptVoiceSeed
    }

    func recordSkipped(_ index: Int) {
        skippedIndices.insert(index)
    }

    func report(
        completedPlaybackCount: Int
    ) -> TuringStagedSpeechRunReport {
        TuringStagedSpeechRunReport(
            committedStages: committedStages,
            failedStages: failures,
            finalExpectedSegmentCount: nextIndex,
            completedPlaybackCount: completedPlaybackCount,
            skippedSegmentIndices: skippedIndices
        )
    }
}
