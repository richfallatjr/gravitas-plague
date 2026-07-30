import Foundation

actor TuringPromptVoiceStageExecutor: TuringSpeechStageExecuting {
    nonisolated let kind:
        TuringFlowGenerationPipelineDescriptor.Stage.Kind = .voicePrompt

    private let promptStore: any TuringVoicePromptTriggerLoading
    private let generator: any TuringFlowVoicePromptGenerating
    private let inputStore: TuringConversationInputStore

    init(
        promptStore: any TuringVoicePromptTriggerLoading =
            TuringVoicePromptTriggerStore(),
        generator: any TuringFlowVoicePromptGenerating =
            TuringDialogueService(runner: TuringFoundationModelsRunner()),
        inputStore: TuringConversationInputStore = .shared
    ) {
        self.promptStore = promptStore
        self.generator = generator
        self.inputStore = inputStore
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

        let promptVoiceContext =
            TuringPromptVoiceStoryContextBuilder.standard(prompt)
        await inputStore.updateCharacterProfileID(
            prompt.characterProfileID,
            for:
                context.descriptor.transmission
                    .conversationKey
        )
        await inputStore.updatePromptVoiceStoryContext(
            promptVoiceContext.storyContext,
            for: context.descriptor.transmission.conversationKey
        )
        await inputStore.updatePromptVariant(
            prompt.effectivePromptTemplateID.conversationVariant,
            for: context.descriptor.transmission.conversationKey
        )
        print("""
        [TuringStagedSpeech] authored promptVoice Story Context committed
          scriptPointID: \(context.descriptor.scriptPointID)
          stageID: \(stage.stageID)
          voicePromptID: \(prompt.voicePromptID)
          conversationKey: \(context.descriptor.transmission.conversationKey)
          committedBeforeFoundation: true
          generatedSeedIncluded: false
          promptContextSHA256: \(TuringFlowHash.sha256(promptVoiceContext.storyContext))
        """)
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
                listenerProfileID: prompt.listenerProfileID,
                promptContext: promptVoiceContext.storyContext,
                prerecordingTranscript: priorTranscript,
                storyIntent: prompt.intent,
                promptTemplateID: prompt.effectivePromptTemplateID
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
            promptVoiceContext: promptVoiceContext,
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
              characterProfileMatches(
                profileID:
                    prompt.characterProfileID,
                characterID:
                    character.characterID
              ),
              prompt.conversationKey == descriptor.transmission.conversationKey,
              prompt.outputContext == descriptor.transmission.outputRoute else {
            throw TuringRuntimeError.invalidConfig(
                "\(descriptor.scriptPointID) pipeline prompt identity mismatch."
            )
        }
    }

    private static func characterProfileMatches(
        profileID: String,
        characterID: String
    ) -> Bool {
        if profileID == characterID {
            return true
        }
        guard let profile =
                try? TuringCharacterProfileStore()
                    .profile(id: profileID) else {
            return false
        }
        return profile.characterID == characterID
    }
}
