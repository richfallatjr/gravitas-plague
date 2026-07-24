import Foundation

actor TuringVoiceScriptStageExecutor: TuringSpeechStageExecuting {
    nonisolated let kind:
        TuringFlowGenerationPipelineDescriptor.Stage.Kind = .voiceScriptLongform

    private let longform: any TuringVoiceScriptLongformPlanning

    init(
        longform: any TuringVoiceScriptLongformPlanning =
            TuringVoiceScriptLongformRunner()
    ) {
        self.longform = longform
    }

    func execute(
        stage: TuringFlowGenerationPipelineDescriptor.Stage,
        context: TuringSpeechStageContext,
        onPreparedBatch: @Sendable (TuringPreparedSpeechBatch) async throws -> Void
    ) async throws -> TuringSpeechStageExecutionResult {
        guard stage.kind == kind,
              let sourceResourcePath = stage.sourceResourcePath,
              stage.voicePromptID == nil else {
            throw TuringRuntimeError.invalidConfig(
                "Script Voice stage \(stage.stageID) must provide only sourceResourcePath."
            )
        }

        let sourceURL = try TuringResourceLoader.resourceURL(
            resourcePath: sourceResourcePath
        )
        let sourceText = try String(contentsOf: sourceURL, encoding: .utf8)
        guard sourceText.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "Script Voice stage \(stage.stageID) source is empty."
            )
        }

        let request = TuringLongformVoiceScriptRequest(
            requestID: "\(context.descriptor.scriptPointID).\(stage.stageID)",
            sourceText: sourceText,
            speakerID: context.character.characterID,
            voiceID: context.character.voiceID,
            defaultEmotion: stage.defaultEmotion,
            playbackTarget: TuringPlaybackTarget(
                id: context.descriptor.transmission.outputRoute.rawValue
            ),
            debugLabel: stage.stageID
        )
        let sourcePlan = try longform.makeSourcePlan(request: request)
        guard sourcePlan.sections.isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "Script Voice stage \(stage.stageID) produced no source sections."
            )
        }
        let longformPlanner = longform

        func makeSectionTask(
            _ index: Int
        ) -> Task<TuringAudiobookSectionSegmentationResult, Error>? {
            guard sourcePlan.sections.indices.contains(index) else {
                return nil
            }
            let section = sourcePlan.sections[index]
            let requestContext = TuringFoundationRequestScope.current?
                .withSectionIndex(index)
            return Task.detached(priority: .userInitiated) {
                if let requestContext {
                    return try await TuringFoundationRequestScope
                        .$current.withValue(requestContext) {
                            try await longformPlanner.prepareSection(
                                section,
                                in: sourcePlan,
                                request: request
                            )
                        }
                }
                return try await longformPlanner.prepareSection(
                    section,
                    in: sourcePlan,
                    request: request
                )
            }
        }

        var sectionIndex = 0
        var currentTask = makeSectionTask(sectionIndex)
        var acceptedSectionCount = 0
        var failedSections: [String] = []

        while let task = currentTask {
            try Task.checkCancellation()
            let nextSectionIndex = sectionIndex + 1
            let nextTask = makeSectionTask(nextSectionIndex)

            let result: TuringAudiobookSectionSegmentationResult
            do {
                result = try await task.value
            } catch is CancellationError {
                nextTask?.cancel()
                throw CancellationError()
            } catch {
                failedSections.append(
                    "section \(sectionIndex): \(error.localizedDescription)"
                )
                print("""
                [TuringStagedSpeech] Script Voice section failed
                  scriptPointID: \(context.descriptor.scriptPointID)
                  stageID: \(stage.stageID)
                  sectionIndex: \(sectionIndex)
                  error: \(error.localizedDescription)
                """)

                sectionIndex = nextSectionIndex
                currentTask = nextTask
                continue
            }

            let segments = result.segments.map {
                TuringSpeechSegment(
                    text: $0.spokenText,
                    emotion: $0.emotion
                )
            }
            guard segments.isEmpty == false else {
                nextTask?.cancel()
                throw TuringRuntimeError.foundationJSONGateFailed(
                    "Script Voice section \(result.section.index) returned no accepted segments."
                )
            }

            print("""
            [TuringStagedSpeech] Script Voice section accepted
              scriptPointID: \(context.descriptor.scriptPointID)
              stageID: \(stage.stageID)
              sectionIndex: \(result.section.index)
              segmentCount: \(segments.count)
            """)

            do {
                try await onPreparedBatch(
                    TuringPreparedSpeechBatch(
                        stageID: stage.stageID,
                        batchID: "\(stage.stageID).section\(result.section.index)",
                        isFinalBatchForStage: nextTask == nil,
                        segments: segments
                    )
                )
                acceptedSectionCount += 1
            } catch {
                nextTask?.cancel()
                throw error
            }

            sectionIndex = nextSectionIndex
            currentTask = nextTask
        }

        guard acceptedSectionCount > 0 else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "No Script Voice source section committed."
            )
        }

        return TuringSpeechStageExecutionResult(
            normalizedSourceTranscript: sourcePlan.normalizedSourceText,
            promptVoiceSeed: nil,
            failedBatchDescriptions: failedSections
        )
    }
}
