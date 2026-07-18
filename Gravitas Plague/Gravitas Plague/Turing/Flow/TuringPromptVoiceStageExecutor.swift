import Foundation

actor TuringPromptVoiceStageExecutor: TuringSpeechStageExecuting {
    nonisolated let kind:
        TuringFlowGenerationPipelineDescriptor.Stage.Kind = .voicePrompt

    private let promptStore: any TuringVoicePromptTriggerLoading
    private let generator: any TuringFlowVoicePromptGenerating

    init(
        promptStore: any TuringVoicePromptTriggerLoading =
            TuringVoicePromptTriggerStore(),
        generator: any TuringFlowVoicePromptGenerating =
            TuringDialogueService(runner: TuringFoundationModelsRunner())
    ) {
        self.promptStore = promptStore
        self.generator = generator
    }

    func execute(
        stage: TuringFlowGenerationPipelineDescriptor.Stage,
        context: TuringSpeechStageContext,
        onPreparedBatch: @Sendable (TuringPreparedSpeechBatch) async throws -> Void
    ) async throws -> TuringSpeechStageExecutionResult {
        guard stage.kind == kind,
              let promptID = stage.voicePromptID,
              stage.sourceResourcePath == nil else {
            throw TuringRuntimeError.invalidConfig(
                "Prompt Voice stage \(stage.stageID) must provide only voicePromptID."
            )
        }

        let prompt = try promptStore.descriptor(id: promptID)
        try Self.validatePromptIdentity(
            prompt,
            descriptor: context.descriptor,
            character: context.character
        )

        let priorTranscript: String
        switch stage.contextSource.kind {
        case .prerecordingTranscript:
            guard stage.contextSource.stageID == nil else {
                throw TuringRuntimeError.invalidConfig(
                    "Prompt Voice stage \(stage.stageID) prerecording context cannot name a stage."
                )
            }
            priorTranscript = context.prerecording.transcript

        case .stageSourceTranscript:
            guard let sourceStageID = stage.contextSource.stageID,
                  let transcript = context.stageSourceTranscripts[sourceStageID] else {
                throw TuringRuntimeError.invalidConfig(
                    "Prompt Voice stage \(stage.stageID) cannot resolve its source transcript."
                )
            }
            priorTranscript = transcript
        }

        let promptVoiceSeed = TuringPromptVoiceSeedBuilder.standard(prompt)
        print("""
        [TuringStagedSpeech] Prompt Voice Foundation started
          scriptPointID: \(context.descriptor.scriptPointID)
          stageID: \(stage.stageID)
          voicePromptID: \(prompt.voicePromptID)
          priorTranscriptSource: \(stage.contextSource.kind.rawValue)
          priorTranscriptSHA256: \(TuringFlowHash.sha256(priorTranscript))
        """)

        let plan = try await generator.generateVoicePrompt(
            VoicePromptRequest(
                id: prompt.voicePromptID,
                characterProfileID: prompt.characterProfileID,
                promptContext: promptVoiceSeed.promptContext,
                prerecordingTranscript: priorTranscript
            )
        )
        guard plan.segments.isEmpty == false else {
            throw TuringRuntimeError.foundationJSONGateFailed(
                "Prompt Voice stage \(stage.stageID) returned no segments."
            )
        }

        try await onPreparedBatch(
            TuringPreparedSpeechBatch(
                stageID: stage.stageID,
                batchID: stage.stageID,
                isFinalBatchForStage: true,
                segments: plan.segments
            )
        )

        return TuringSpeechStageExecutionResult(
            normalizedSourceTranscript: nil,
            promptVoiceSeed: promptVoiceSeed,
            failedBatchDescriptions: []
        )
    }

    private static func validatePromptIdentity(
        _ prompt: TuringVoicePromptTriggerDescriptor,
        descriptor: TuringFlowDescriptor,
        character: TuringCharacterRuntimeDefinition
    ) throws {
        guard prompt.speakerID == character.characterID,
              prompt.voiceID == character.voiceID,
              prompt.characterProfileID == character.characterID,
              prompt.conversationKey == descriptor.transmission.conversationKey,
              prompt.outputContext == descriptor.transmission.outputRoute else {
            throw TuringRuntimeError.invalidConfig(
                "\(descriptor.scriptPointID) pipeline prompt identity mismatch."
            )
        }
    }
}
