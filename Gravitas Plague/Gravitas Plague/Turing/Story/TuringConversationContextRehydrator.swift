import Foundation

enum TuringConversationContextRehydrator {
    static func rehydrate(
        terminalScriptPointID: String
    ) async throws {
        let descriptor = try TuringFlowDescriptorStore().require(
            terminalScriptPointID
        )
        let promptID = try promptVoiceID(for: descriptor)
        let prerecordingID = conversationPrerecordingID(for: descriptor)
        let prerecording = try TuringPrerecordingStore().descriptor(
            id: prerecordingID
        )
        guard prerecording.transcriptMode == .manual,
              !prerecording.transcript.trimmingCharacters(
                in: .whitespacesAndNewlines
              ).isEmpty else {
            throw TuringRuntimeError.invalidConfig(
                "\(terminalScriptPointID) requires an authored PR transcript and promptVoice descriptor."
            )
        }

        let prompt = try TuringVoicePromptTriggerStore().descriptor(id: promptID)
        let context = TuringPromptVoiceStoryContextBuilder.standard(prompt)
        let key = descriptor.transmission.conversationKey
        await TuringConversationInputStore.shared.updatePrerecording(
            id: prerecording.prerecordingID,
            transcript: prerecording.transcript,
            for: key
        )
        await TuringConversationInputStore.shared.updatePromptVoiceStoryContext(
            context.storyContext,
            for: key
        )
        await TuringConversationInputStore.shared.updatePromptVariant(
            .forScriptPointID(terminalScriptPointID),
            for: key
        )
        await TuringConversationInputStore.shared.updateCharacterProfileID(
            prompt.characterProfileID,
            for: key
        )
        print("""
        [TuringContinuation] Story conversation context rehydrated
          scriptPointID: \(terminalScriptPointID)
          conversationKey: \(key)
          prerecordingID: \(prerecording.prerecordingID)
          characterProfileID: \(prompt.characterProfileID)
          authoredPR: true
          generatedHistoryIncluded: false
        """)
    }

    private static func promptVoiceID(
        for descriptor: TuringFlowDescriptor
    ) throws -> String {
        if let promptID = descriptor.transmission.voicePromptID {
            return promptID
        }
        if let promptID = descriptor.transmission.generationPipeline?
            .stages
            .last(where: { $0.kind == .voicePrompt })?
            .voicePromptID {
            return promptID
        }
        throw TuringRuntimeError.invalidConfig(
            "\(descriptor.scriptPointID) has no promptVoice descriptor."
        )
    }

    private static func conversationPrerecordingID(
        for descriptor: TuringFlowDescriptor
    ) -> String {
        descriptor.transmission.generationPipeline?
            .stages
            .compactMap(\.authoredPrerecordingAfterStageID)
            .last ?? descriptor.transmission.prerecordingID
    }
}
