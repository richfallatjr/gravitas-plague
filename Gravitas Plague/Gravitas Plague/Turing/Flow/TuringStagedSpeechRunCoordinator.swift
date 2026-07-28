import Foundation

actor TuringStagedSpeechRunCoordinator {
    private let executors: [
        TuringFlowGenerationPipelineDescriptor.Stage.Kind:
            any TuringSpeechStageExecuting
    ]
    private let rendererFactory:
        any TuringCharacterStreamingRenderSessionMaking
    private let inputStore: TuringConversationInputStore

    init(
        voiceScriptExecutor: any TuringSpeechStageExecuting =
            TuringVoiceScriptStageExecutor(),
        promptVoiceExecutor: any TuringSpeechStageExecuting =
            TuringPromptVoiceStageExecutor(),
        rendererFactory: any TuringCharacterStreamingRenderSessionMaking =
            TuringCharacterQwenRenderSessionFactory(),
        inputStore: TuringConversationInputStore = .shared
    ) {
        executors = [
            .voiceScriptLongform: voiceScriptExecutor,
            .voicePrompt: promptVoiceExecutor
        ]
        self.rendererFactory = rendererFactory
        self.inputStore = inputStore
    }

    func run(
        descriptor: TuringFlowDescriptor,
        pipeline: TuringFlowGenerationPipelineDescriptor,
        character: TuringCharacterRuntimeDefinition,
        prerecording: TuringPrerecordingDescriptor,
        authoredBridges: [String: TuringAuthoredSpeechBridge] = [:],
        playback: any TuringFlowPlaybackControlling,
        identity: TuringFlowIdentity
    ) async throws -> TuringStagedSpeechRunReport {
        let session = rendererFactory.makeStreamingSession(
            runtime: character,
            runID: identity.playbackRunID
        )
        let state = TuringStagedSpeechRunState()
        var terminalError: Error?
        var playbackWasTerminallyFailed = false

        do {
            try await session.begin(
                onStarted: { index in
                    await playback.qwenComputeStarted(segmentIndex: index)
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
                let foundationContext = TuringFoundationRequestContext(
                    flowRunID: identity.playbackRunID,
                    scriptPointID: descriptor.scriptPointID,
                    stageID: stageDescriptor.stageID,
                    sectionIndex: nil
                )
                let stageAuthoredBridge:
                    TuringAuthoredSpeechBridge?
                if let bridgeID =
                        stageDescriptor
                            .authoredPrerecordingAfterStageID {
                    guard let bridge = authoredBridges[bridgeID] else {
                        throw TuringRuntimeError.invalidConfig(
                            "Missing resolved authored bridge \(bridgeID) for stage \(stageDescriptor.stageID)."
                        )
                    }
                    stageAuthoredBridge = bridge
                } else {
                    stageAuthoredBridge = nil
                }

                do {
                    let result = try await TuringFoundationRequestScope
                        .$current.withValue(foundationContext) {
                            try await executor.execute(
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

                                if batch.isFinalBatchForStage,
                                   let bridge = stageAuthoredBridge {
                                    await playback.enqueueAuthoredBridge(
                                        id: bridge.prerecordingID,
                                        fileURL: bridge.fileURL,
                                        beforeGeneratedSegmentIndex:
                                            committed.globalRange.upperBound
                                    )
                                    await state.recordAuthoredBridgeReserved(
                                        stageID: stageDescriptor.stageID,
                                        bridge: bridge
                                    )
                                    print("""
                                    [TuringStagedSpeech] authored bridge reserved
                                      scriptPointID: \(descriptor.scriptPointID)
                                      stageID: \(stageDescriptor.stageID)
                                      prerecordingID: \(bridge.prerecordingID)
                                      beforeGeneratedSegmentIndex: \(committed.globalRange.upperBound)
                                      waitsForBridgePlaybackBeforeNextStageCompute: false
                                    """)
                                }

                                do {
                                    try await session.submit(committed)
                                } catch {
                                    throw TuringStagedSpeechRenderFailure(
                                        reason: error.localizedDescription
                                    )
                                }

                                print("""
                                [TuringStagedSpeech] stage batch submitted
                                  scriptPointID: \(descriptor.scriptPointID)
                                  stageID: \(committed.stageID)
                                  globalRange: \(committed.globalRange)
                                  openRenderQueue: true
                                """)
                            }
                    }

                    if stageAuthoredBridge != nil,
                       await state.authoredBridgeWasReserved(
                            stageID: stageDescriptor.stageID
                       ) == false {
                            throw TuringRuntimeError.invalidConfig(
                                "Stage \(stageDescriptor.stageID) completed without a final batch for its authored bridge."
                            )
                    }

                    if committedKind == .scriptVoice {
                        let upperBound = await state.nextGlobalIndex()
                        do {
                            try await session.waitUntilPublished(
                                throughExclusiveIndex: upperBound
                            )
                        } catch {
                            throw TuringStagedSpeechRenderFailure(
                                reason: error.localizedDescription
                            )
                        }
                        print("""
                        [TuringStagedSpeech] Script Voice publication gate passed
                          scriptPointID: \(descriptor.scriptPointID)
                          throughExclusiveIndex: \(upperBound)
                          waitsForPlaybackCompletion: false
                        """)
                    }

                    if let transcript = result.normalizedSourceTranscript {
                        await state.recordSourceTranscript(
                            transcript,
                            stageID: stageDescriptor.stageID
                        )
                    }
                    if let promptVoiceContext = result.promptVoiceContext {
                        await state.recordPromptVoiceContext(
                            promptVoiceContext
                        )
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
            await session.sealInput(
                finalExpectedSegmentCount: finalCount
            )
            if playbackWasTerminallyFailed == false {
                await playback.setExpectedGeneratedSegmentCount(finalCount)
            }
            let renderReport = try await session.waitUntilPublished()
            guard renderReport.successfulSegmentIndices.count +
                    renderReport.skippedSegmentIndices.count == finalCount else {
                throw TuringStagedSpeechRenderFailure(
                    reason: "Streaming render session did not resolve every committed segment."
                )
            }
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

            if let bridge = await state.lastReservedAuthoredBridge(),
               let transcript = bridge.conversationTranscript {
                await inputStore.updatePrerecording(
                    id: bridge.prerecordingID,
                    transcript: transcript,
                    for: descriptor.transmission.conversationKey
                )
                print("""
                [TuringStagedSpeech] conversation transcript advanced to authored bridge
                  scriptPointID: \(descriptor.scriptPointID)
                  prerecordingID: \(bridge.prerecordingID)
                  conversationKey: \(descriptor.transmission.conversationKey)
                  transcriptUTF16: \(transcript.utf16.count)
                  afterActualPlaybackCompletion: true
                """)
            }

            if let promptVoiceContext =
                    await state.promptVoiceContext() {
                await inputStore.updatePromptVoiceStoryContext(
                    promptVoiceContext.storyContext,
                    for: descriptor.transmission.conversationKey
                )
                await inputStore.updatePromptVariant(
                    .forScriptPointID(descriptor.scriptPointID),
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
    private var storedPromptVoiceContext:
        TuringAuthoredPromptVoiceContext?
    private var skippedIndices = Set<Int>()
    private var authoredBridgeStageIDs = Set<String>()
    private var reservedAuthoredBridges:
        [TuringAuthoredSpeechBridge] = []

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

    func recordPromptVoiceContext(
        _ context: TuringAuthoredPromptVoiceContext
    ) {
        storedPromptVoiceContext = context
    }

    func promptVoiceContext() -> TuringAuthoredPromptVoiceContext? {
        storedPromptVoiceContext
    }

    func recordSkipped(_ index: Int) {
        skippedIndices.insert(index)
    }

    func recordAuthoredBridgeReserved(
        stageID: String,
        bridge: TuringAuthoredSpeechBridge
    ) {
        authoredBridgeStageIDs.insert(stageID)
        reservedAuthoredBridges.append(bridge)
    }

    func authoredBridgeWasReserved(stageID: String) -> Bool {
        authoredBridgeStageIDs.contains(stageID)
    }

    func lastReservedAuthoredBridge() -> TuringAuthoredSpeechBridge? {
        reservedAuthoredBridges.last
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
